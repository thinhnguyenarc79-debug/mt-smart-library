# frozen_string_literal: true
require 'digest'
require 'json'
require 'base64'
require 'fileutils'

module MTDesign
  module SmartLibrary
    # Bộ điều khiển: HtmlDialog, callbacks, UI timer. Toàn bộ SketchUp API chạy ở main thread.
    # Luồng nền (quét, HTTP, cập nhật) chỉ trao đổi qua Queue/Mutex và được poll bởi timer.
    class App
      TICK = 0.1
      ALLOWED_OPEN_HOSTS = (%w[sketchfab.com www.sketchfab.com platform.openai.com github.com www.blender.org polyhaven.com
                               app.tavily.com serper.dev serpapi.com api-dashboard.search.brave.com docs.searxng.org
                               console.cloud.google.com] +
                            AccountManager.hosts + WebModels::HOSTS + %w[www.google.com]).uniq.freeze

      def self.instance
        @instance ||= new
      end

      attr_reader :settings, :index, :indexer, :log, :updater, :http

      def initialize
        FileUtils.mkdir_p(Paths.data_root)
        @log = Logger.new(Paths.sub('logs', 'mt_smart_library.log'))
        @log.info("Khởi động #{PRODUCT_NAME} #{VERSION} | SketchUp #{su_version} | Ruby #{RUBY_VERSION} | data=#{Paths.data_root}")
        @settings = Settings.new(Paths.sub('settings.json'), @log)
        @index = SearchIndex.new
        @indexer = Indexer.new(Paths.sub('index_cache.json'), @log)
        @thumbs = ThumbService.new(Paths.sub('thumbs'), @log) { |skp, png| Sketchup.save_thumbnail(skp, png) }
        @http = HttpClient.new(@log)
        @updater = Updater.new(logger: @log, http: @http)
        @secrets = { 'openai' => nil, 'sketchfab' => nil }
        load_remembered_secrets
        @dialog = nil
        @ready = false
        @up_dialog = nil
        @up_ready = false
        @timer = nil
        @ticking = false
        @cache_thread = nil
        @library_loaded = false
        @roots_state = {}
        @scan_summary = nil
        @last_progress_emit = 0
        @ai_seq = 0
        @ai_image = nil
        @sf_items = {}
        @downloads = {}
        @pending_pkg = nil
        @online_info = nil
        @update_available = nil
        @startup_msg = @updater.startup_report
        @log.info(@startup_msg) if @startup_msg
        @result_cache = ResultCache.new(max: 80, ttl: 600)
        @providers = [
          Providers::LocalProvider.new(@index),
          Providers::SketchfabProvider.new(@http, @result_cache, @log),
          Providers::PolyHavenProvider.new(@http, Paths.data_root, @log),
          Providers::WpProvider.new('cgtips', @http, @result_cache, @log),
          Providers::WpProvider.new('sketchupfree', @http, @result_cache, @log),
          Providers::WpProvider.new('thuviensketchup', @http, @result_cache, @log)
        ] + AccountManager::SOURCES.reject { |x| AccountManager::INTEGRATED.include?(x['id']) }.map do |x|
          Providers::UnavailableProvider.new(x['id'], x['name'], "Chưa tích hợp: #{x['note']}")
        end
        @runtime = RuntimeManager.new(http: @http, runner: BlenderRunner.new(@log), data_root: Paths.data_root,
                                      code_dir: Paths.code_dir, logger: @log)
        @sources = SourceRegistry.new(Paths.sub('sources.json'), builtins: builtin_sources)
        add_custom_providers
        @providers << Providers::CatalogProvider.new(@runtime, -> { disabled_source_ids })
        # V1.0.16: model trên các website thư viện 3D qua công cụ tìm kiếm web (key chỉ giữ trong bộ nhớ, không ghi log).
        @web_models = Providers::WebModelsProvider.new(@http, ResultCache.new(max: 300, ttl: 1800),
                                                       -> { %w[tavily serper serpapi brave].map { |k| [k, secret(k)] }.to_h }, @log)
        @web_models.on_sites = ->(pl) { emit('web_sites', pl) }
        @web_models.on_report = ->(r) { Util.atomic_write(Paths.sub('web_last.json'), JSON.pretty_generate(r)) rescue nil } # rubocop:disable Style/RescueModifier
        @providers << @web_models
        # Khóa chỉ đưa vào biến môi trường của tiến trình trích xuất (làn crawl) — không ghi vào file job/log.
        @runtime.env_provider = ->(lane) { lane == 'crawl' ? CRAWL_KEYS.map { |k| ["MT_SRC_#{k.upcase}_KEY", secret(k)] }.to_h : {} }
        @sync = {}
        @src_stats = {}
        @cat_buf = {}
        @cat_last = Time.now.to_f
        @visual = VisualSearchManager.new(runtime: @runtime, index: @index, thumbs: @thumbs, online_providers: -> { @providers.select(&:online?) },
                                          settings: @settings, emit: ->(t, pl) { emit(t, pl) }, logger: @log)
        @runtime.device_pref = @settings['ai']['device']
        @vs_image = nil
        @vs_last_sync = 0
        @watcher = DownloadWatcher.new
        @found = nil
        @sf_expired = false
        @converter = ConverterManager.new(settings: @settings, data_root: Paths.data_root, logger: @log)
        @search = SearchManager.new(providers: @providers, settings: @settings, emit: ->(t, pl) { collect_catalog(t, pl); emit(t, pl) }, logger: @log)
      end

      attr_reader :search

      # ================================================================ Dialog chính
      def show
        if @dialog
          @dialog.visible? ? @dialog.bring_to_front : @dialog.show
          return
        end
        d = UI::HtmlDialog.new(dialog_title: "#{PRODUCT_NAME} #{VERSION}", preferences_key: 'MTDesign.SmartLibraryPro',
                               scrollable: false, resizable: true, width: 1180, height: 780, min_width: 720, min_height: 520,
                               style: UI::HtmlDialog::STYLE_DIALOG)
        d.set_file(File.join(Paths.code_dir, 'ui', 'index.html'))
        register_main_callbacks(d)
        d.set_on_closed do
          @dialog = nil
          @ready = false
          @thumbs.clear_queue
        end
        @dialog = d
        d.show
        ensure_timer
        load_library unless @library_loaded || (@cache_thread && @cache_thread.alive?)
      end

      def emit(type, payload = nil)
        return unless @dialog && @ready
        @dialog.execute_script("window.MT&&MT.receive(#{Util.json_for_js(type.to_s)},#{Util.json_for_js(payload)})")
      rescue StandardError => e
        @log.error('execute_script lỗi', e)
      end

      def status(msg, kind = 'info', hint = nil)
        emit('status', { 'msg' => Util.utf8(msg), 'kind' => kind, 'hint' => hint })
      end

      def register_main_callbacks(d)
        cb(d, 'ready') { |*| @ready = true; send_init }
        cb(d, 'search') { |json| do_search(parse(json)) }
        cb(d, 'sr_start') { |json| @search.start(parse(json)); ensure_timer }
        cb(d, 'sr_more') { |sid| @search.more(sid); ensure_timer }
        cb(d, 'sr_filter') do |sid, f|
          @visual.visual_sid?(sid) ? @visual.set_filter(sid.to_i, f.to_s) : @search.set_filter(sid, f.to_s)
          save_settings('ui' => { 'filter' => f.to_s })
        end
        cb(d, 'vs_pick') { |*| vs_pick }
        cb(d, 'vs_start') { |json| vs_start(parse(json)) }
        cb(d, 'vs_crop') { |json| vs_crop(parse(json)) }
        cb(d, 'vs_cancel') { |*| @visual.cancel }
        cb(d, 'vs_clear') { |*| @visual.cancel(silent: true); @vs_image = nil }
        cb(d, 'vs_install') { |*| vs_install }
        cb(d, 'src_add') { |json| src_add(parse(json)) }
        cb(d, 'src_update') { |json| src_update(parse(json)) }
        cb(d, 'src_toggle') { |id, on| src_toggle(id.to_s, on == true || on.to_s == 'true') }
        cb(d, 'src_delete') { |id| src_delete(id.to_s) }
        cb(d, 'src_check') { |id| src_check_deep(id.to_s) }
        cb(d, 'src_scan') { |id, mode| src_scan(id.to_s, mode.to_s) }
        cb(d, 'src_stop') { |id| src_stop(id.to_s) }
        cb(d, 'src_sync_all') { |*| src_sync_all }
        cb(d, 'src_sync_all_stop') { |*| src_sync_all_stop }
        cb(d, 'search_test') { |p| search_test(p.to_s) }
        cb(d, 'fb_open') { |id| fb_open(id.to_s) }
        cb(d, 'vs_mode') { |m| @visual.set_mode(m.to_s) }
        cb(d, 'src_log') { |id| src_log(id.to_s) }
        cb(d, 'src_stats') { |*| src_stats }
        cb(d, 'src_open') { |id| src_open(id.to_s) }
        cb(d, 'team_export') { |*| team_export }
        cb(d, 'team_import') { |*| team_import }
        cb(d, 'src_export') { |*| src_export }
        cb(d, 'src_import') { |*| src_import }
        cb(d, 'link_import') { |url| link_import(url.to_s) }
        cb(d, 'cat_stats') { |*| cat_stats }
        cb(d, 'cat_check_links') { |*| cat_check_links }
        cb(d, 'cat_clear') { |*| cat_clear }
        cb(d, 'vs_repair') { |*| vs_repair }
        cb(d, 'vs_open_log') { |*| UI.openURL(Util.file_url(@runtime.work_dir)) }
        cb(d, 'insert_item') { |key| insert_any(key.to_s) }
        cb(d, 'fav_item') { |key| fav_any(key.to_s) }
        cb(d, 'open_source') { |key| open_source(key.to_s) }
        cb(d, 'cat_save') { |json| category_save(parse(json)) }
        cb(d, 'cat_delete') { |id| category_delete(id.to_s) }
        cb(d, 'thumbs') { |json| request_thumbs(parse(json)) }
        cb(d, 'add_root') { |*| add_root }
        cb(d, 'remove_root') { |path| remove_root(path.to_s) }
        cb(d, 'scan') { |mode| start_scan(mode.to_s == 'full') }
        cb(d, 'cancel_scan') { |*| @indexer.cancel; status('Đang hủy quét…') }
        cb(d, 'favorite') { |id| toggle_favorite(id.to_s) }
        cb(d, 'insert') { |id, newer| insert_item(id.to_s, newer == true || newer.to_s == 'true') }
        cb(d, 'import_skp') { |*| import_skp_dialog }
        cb(d, 'import_3d') { |*| import_3d_dialog }
        cb(d, 'insert_path') { |path| insert_path(path.to_s) }
        cb(d, 'open_folder') { |id| open_item_folder(id.to_s) }
        cb(d, 'online_link') { |src, q| UI.openURL(LinkSources.url_for(src, q)) }
        cb(d, 'open_url') { |url| open_safe_url(url.to_s) }
        cb(d, 'sf_search') { |json| sketchfab_search(parse(json)) }
        cb(d, 'sf_download') { |json| sketchfab_download(parse(json)) }
        cb(d, 'dl_open') { |uid| open_download_folder(uid.to_s) }
        cb(d, 'set_secret') { |json| set_secret(parse(json)) }
        cb(d, 'clear_secret') { |kind| clear_secret(kind.to_s) }
        cb(d, 'save_settings') { |json| save_settings(parse(json)) }
        cb(d, 'check_openai') { |*| check_openai }
        cb(d, 'check_network') { |*| check_network }
        cb(d, 'ai_pick') { |*| ai_pick }
        cb(d, 'ai_send') { |json| ai_send(parse(json)) }
        cb(d, 'ai_cancel') { |*| @ai_seq += 1; status('Đã hủy phân tích AI.') }
        cb(d, 'clear_thumbs') { |*| n = @thumbs.clear_cache; status("Đã xóa #{n} file thumbnail cache.", 'ok') }
        cb(d, 'open_data_dir') { |*| UI.openURL(Util.file_url(Paths.data_root)) }
        cb(d, 'open_log') { |*| UI.openURL(Util.file_url(File.dirname(@log.path.to_s))) }
        cb(d, 'open_updater') { |*| show_updater }
        cb(d, 'insert_found') { |*| insert_found }
        cb(d, 'found_dismiss') { |*| @found = nil; @watcher.stop }
        cb(d, 'found_save') { |*| save_found }
        cb(d, 'lib_import') { |*| lib_import_pick }
        cb(d, 'web_search_site') { |id, q| web_search_site(id.to_s, q.to_s) }
        cb(d, 'web_open') { |key| insert_any(key.to_s) }
        cb(d, 'acct_action') { |id, act| account_action(id.to_s, act.to_s) }
        cb(d, 'convert_cancel') { |*| @converter.cancel_all; status('Đã hủy chuyển đổi.', 'warn'); emit('convert_state', { 'state' => 'cancelled' }) }
        cb(d, 'blender_detect') { |*| blender_detect(nil) }
        cb(d, 'blender_pick') { |*| blender_pick }
        cb(d, 'convert_clear_cache') { |*| @converter.cache.clear; status('Đã xóa cache chuyển đổi.', 'ok') }
      end

      def cb(dialog, name)
        dialog.add_action_callback(name) do |_ctx, *args|
          begin
            yield(*args)
          rescue Inserter::NewerVersionError => e
            status(e.message, 'warn')
          rescue StandardError => e
            @log.error("Callback #{name}", e)
            status("Lỗi: #{@log.redact(e.message)}", 'error', 'Xem log trong Cài đặt > Dữ liệu nếu lỗi lặp lại.')
          end
        end
      end

      def parse(json)
        return json if json.is_a?(Hash)
        JSON.parse(json.to_s)
      rescue JSON::ParserError
        {}
      end

      # Menu Extensions › Hỗ trợ kỹ thuật: mở thư viện rồi hiện bảng chẩn đoán.
      def show_support
        @pending_support = true
        show
        flush_support
      end

      def flush_support
        return unless @pending_support && @dialog && @ready
        @pending_support = false
        emit('open_support')
      end

      def send_init
        emit('init', {
               'version' => VERSION, 'plugin_id' => PLUGIN_ID, 'build' => BUILD_DATE, 'su' => su_version,
               'settings' => @settings.public_hash, 'secrets' => secrets_state, 'sources' => LinkSources.list,
               'data_root' => Paths.data_root, 'log' => @log.path, 'secret_store' => SecretStore.available?,
               'roots_state' => @roots_state, 'loaded' => @library_loaded, 'library_size' => @index.size,
               'scan' => @indexer.progress, 'summary' => @scan_summary, 'startup' => @startup_msg,
               'settings_warning' => @settings.load_warning, 'update_available' => @update_available,
               'pending_restart' => @updater.pending_restart_version,
               'categories' => Categories.all(@settings['categories_custom']),
               'sources_status' => sources_status,
               'blender' => @converter.blender_status, 'accounts' => accounts_state, 'visual' => @runtime.status,
               'src' => sources_payload
             })
        flush_support
      end

      # ================================================================ Tìm kiếm tổng hợp & chèn
      def find_item(key)
        @visual.item(key) || @search.item(key) || Array(@settings['online_favorites']).find { |f| f['key'] == key }
      end

      def insert_any(key)
        if key.start_with?('local:')
          it = find_item(key)
          id = it ? it['id'] : nil
          return status('Không tìm thấy model. Hãy tìm lại.', 'warn') unless id
          return insert_item(id)
        end
        it = find_item(key)
        return status('Không còn thông tin model — hãy tìm lại.', 'warn') unless it
        return insert_sketchfab(it) if it['source'] == 'sketchfab'
        return insert_polyhaven(it) if it['source'] == 'polyhaven'
        return insert_catalog(it) if it['from_catalog'] || it['links']
        return insert_web(it) if it['web_only']
        return insert_webmodel(it) if it['web_model']
        status('Nguồn này chưa hỗ trợ chèn trực tiếp.', 'warn')
      end

      def insert_sketchfab(it)
        unless it['downloadable']
          open_safe_url(it['url'].to_s)
          return status('Tác giả không cho phép tải model này — đã mở trang nguồn để xem.', 'warn')
        end
        unless secret('sketchfab')
          emit('need_token', { 'key' => it['key'] })
          return status('Dán Sketchfab token để tải model.', 'warn')
        end
        d = @downloads[it['uid']]
        if d && d['state'] == 'done' && (f = Array(d['files']).find { |x| %w[skp gltf import convert].include?(x['kind']) })
          return smart_insert(f['path'], name: it['title'])
        end
        types = Array(it['formats']).map { |f| f['type'] }
        # GLB/glTF: plugin tự đọc và chèn được (từ V1.0.3); bản gốc (source) có thể là định dạng phần mềm khác.
        fmt = %w[glb gltf source usdz].find { |f| types.include?(f) } || 'glb'
        @sf_items[it['uid']] = { 'name' => it['title'], 'author' => it['author'], 'author_url' => it['author_url'],
                                 'license' => it['license'], 'viewer_url' => it['url'], 'downloadable' => true, 'key' => it['key'] }
        sketchfab_download('uid' => it['uid'], 'format' => fmt, 'auto_insert' => true)
      end

      # Poly Haven: lấy danh sách file glTF (API /files) → tải gltf + bin + texture (kiểm MD5) → chèn bằng bộ đọc tích hợp.
      def insert_polyhaven(it)
        uid = it['uid'].to_s
        id = uid.sub(/\Aph-/, '')
        return status('Mã model Poly Haven không hợp lệ.', 'warn') unless PolyHaven.valid_id?(id)
        d = @downloads[uid]
        if d && d['state'] == 'done' && d['main'] && File.file?(d['main'])
          return smart_insert(d['main'], name: it['title'])
        end
        return status('Model này đang được tải.', 'warn') if d && %w[requesting downloading].include?(d['state'])
        @downloads[uid] = { 'state' => 'requesting', 'progress' => { 'bytes' => 0, 'total' => 0 }, 'base' => 0, 'auto_insert' => true }
        emit('dl_state', { 'uid' => uid, 'state' => 'requesting' })
        status("Đang tải “#{it['title']}” từ Poly Haven…")
        @http.request(url: PolyHaven.files_url(id), headers: { 'Accept' => 'application/json' }, timeout: net_timeout) do |res|
          begin
            raise(res.code > 0 ? "Poly Haven trả lỗi HTTP #{res.code}." : HttpClient.friendly(res)) unless res.ok
            plan = PolyHaven.pick_gltf(res.body)
            folder = Paths.sub('downloads', 'polyhaven', id)
            FileUtils.mkdir_p(folder)
            dd = @downloads[uid]
            dd.merge!('state' => 'downloading', 'queue' => plan['files'].dup, 'folder' => folder, 'res' => plan['resolution'],
                      'total_all' => plan['total'], 'item' => it, 'main' => File.join(folder, plan['files'][0]['rel']))
            emit('dl_state', { 'uid' => uid, 'state' => 'downloading', 'total' => plan['total'] })
            ph_next(uid)
          rescue StandardError => e
            ph_fail(uid, e.message)
          end
        end
        ensure_timer
      end

      def ph_next(uid)
        d = @downloads[uid]
        f = d['queue'].shift
        return ph_done(uid) unless f
        dest = File.join(d['folder'], *f['rel'].split('/'))
        if File.file?(dest) && f['md5'] =~ /\A\h{32}\z/ && Digest::MD5.file(dest).hexdigest == f['md5'].downcase
          d['base'] += f['size'] # đã có từ lần trước
          return ph_next(uid)
        end
        d['progress'] = { 'bytes' => 0, 'total' => f['size'] }
        @http.request(url: f['url'], dest: dest, timeout: [net_timeout, 60].max, progress: d['progress']) do |res|
          begin
            raise "Không tải được #{f['rel']}: #{HttpClient.friendly(res)}" unless res.ok
            if f['md5'] =~ /\A\h{32}\z/ && Digest::MD5.file(dest).hexdigest != f['md5'].downcase
              File.delete(dest)
              raise "File #{f['rel']} tải về bị lỗi (sai MD5)."
            end
            d['base'] += f['size']
            d['progress'] = { 'bytes' => 0, 'total' => 0 }
            ph_next(uid)
          rescue StandardError => e
            ph_fail(uid, e.message)
          end
        end
      end

      def ph_done(uid)
        d = @downloads[uid]
        it = d['item']
        File.write(File.join(d['folder'], 'ATTRIBUTION.txt'), PolyHaven.attribution(it, d['res']), mode: 'w:UTF-8')
        d['state'] = 'done'
        d['files'] = [classify(d['main'])]
        emit('dl_state', { 'uid' => uid, 'state' => 'done', 'folder' => d['folder'], 'files' => d['files'], 'note' => 'Đã tải xong.',
                           'key' => it['key'] })
        smart_insert(d['main'], name: it['title'])
      rescue StandardError => e
        ph_fail(uid, e.message)
      end

      def ph_fail(uid, msg)
        @downloads[uid] ||= {}
        @downloads[uid]['state'] = 'error'
        emit('dl_state', { 'uid' => uid, 'state' => 'error', 'msg' => msg })
        status(msg, 'error')
      end

      # Nguồn không cho tải tự động: mở trang tải chính thức, theo dõi thư mục Downloads để nhận file người dùng vừa tải.
      # ================================================================ Tìm bằng ảnh (AI cục bộ, không cần OpenAI)
      VS_MAX = 15 * 1024 * 1024

      def vs_pick
        path = UI.openpanel('Chọn ảnh mẫu để tìm model tương tự', '', 'Ảnh|*.jpg;*.jpeg;*.png;*.webp||')
        return unless path
        path = Util.utf8(path)
        return status('Ảnh lớn hơn 15 MB.', 'warn') if File.size(path) > VS_MAX
        bytes = File.binread(path)
        mime = Vision.mime_of(bytes)
        return status('File không phải ảnh JPG/PNG/WEBP hợp lệ.', 'error') unless mime && mime != 'image/gif'
        emit('vs_image', { 'src' => "data:#{mime};base64,#{Base64.strict_encode64(bytes)}", 'name' => File.basename(path) })
        vs_begin(bytes, mime, nil)
      end

      # Ảnh dán từ Clipboard / kéo thả (base64 từ giao diện).
      def vs_start(o)
        b64 = o['b64'].to_s.gsub(/\s+/, '')
        return status('Ảnh không hợp lệ.', 'error') if b64.empty? || b64 !~ %r{\A[A-Za-z0-9+/=]+\z} || b64.length * 3 / 4 > VS_MAX
        bytes = Base64.strict_decode64(b64)
        mime = Vision.mime_of(bytes)
        return status('Ảnh không phải JPG/PNG/WEBP.', 'error') unless mime && mime != 'image/gif'
        vs_begin(bytes, mime, o['crop'])
      rescue ArgumentError
        status('Ảnh không hợp lệ.', 'error')
      end

      def vs_crop(o)
        return status('Chưa có ảnh mẫu.', 'warn') unless @vs_image && File.file?(@vs_image)
        box = Array(o['crop']).map(&:to_f)
        box = nil unless box.size == 4 && box.all? { |v| v >= 0 && v <= 1 } && box[2] > box[0] && box[3] > box[1]
        @visual.start(@vs_image, crop: box)
        ensure_timer
      end

      def vs_begin(bytes, mime, crop)
        ext = { 'image/png' => '.png', 'image/jpeg' => '.jpg', 'image/webp' => '.webp' }[mime]
        dir = File.join(@runtime.work_dir, 'query')
        FileUtils.mkdir_p(dir)
        Dir.glob(File.join(dir, 'input_*')).each { |f| File.delete(f) rescue nil }
        @vs_image = File.join(dir, "input_#{Time.now.to_i}#{ext}")
        File.binwrite(@vs_image, bytes)
        @visual.start(@vs_image, crop: crop)
        ensure_timer
      end

      def vs_install
        emit('vs_state', { 'state' => 'installing', 'msg' => 'Đang cài bộ AI tìm bằng ảnh…' })
        @runtime.install do |ok, err|
          if ok
            emit('vs_state', { 'state' => 'installed', 'msg' => 'Đã cài xong bộ AI. Đang tìm…' })
            @visual.resume
          else
            emit('vs_state', { 'state' => 'error', 'msg' => "Chưa cài được bộ AI: #{err}" })
          end
        end
        ensure_timer
      end

      def vs_repair
        emit('vs_state', { 'state' => 'installing', 'msg' => 'Đang cài lại thành phần AI (giữ nguyên mô hình đã tải)…' })
        @runtime.repair do |ok, err|
          status(ok ? 'Đã cài lại thành phần AI.' : "Cài lại thành phần AI lỗi: #{err}", ok ? 'ok' : 'error')
          emit('vs_state', { 'state' => ok ? 'installed' : 'error', 'msg' => ok ? 'Bộ AI sẵn sàng.' : err.to_s })
        end
        ensure_timer
      end

      # ================================================================ SMART SOURCE MANAGER
      def builtin_sources
        integrated = { 'local' => %w[local local], 'sketchfab' => %w[website api], 'polyhaven' => %w[website api],
                       'cgtips' => %w[website wp_rest], 'sketchupfree' => %w[website wp_rest], 'thuviensketchup' => %w[website wp_rest] }
        WebModels::SITES.each { |w| integrated[w['id']] = %w[website web_search] }
        list = [{ 'id' => 'local', 'name' => 'Thư viện máy tính', 'type' => 'local', 'method' => 'local', 'url' => '' }]
        AccountManager::SOURCES.each do |a|
          t, m = integrated[a['id']] || %w[website unverified]
          list << { 'id' => a['id'], 'name' => a['name'], 'type' => t, 'method' => m, 'url' => a['site'], 'note' => a['note'] }
        end
        list
      end

      # Nguồn website người dùng thêm, đã xác minh WordPress REST API → provider tìm kiếm thật.
      def add_custom_providers
        @providers.reject! { |p| p.is_a?(Providers::WpProvider) && p.site['custom'] }
        @sources.enabled_wp.each do |s|
          @providers << Providers::WpProvider.new(WpSources.from_custom(s).merge('custom' => true, 'enabled' => s['enabled']), @http, @result_cache, @log)
        end
      end

      def disabled_source_ids
        @settings['sources'].select { |_, v| v == false }.keys + @sources.custom.reject { |s| s['enabled'] }.map { |s| s['id'] }
      end

      # ================================================================ SMART SOURCE EXTRACTOR (quét / đồng bộ / dừng / nhật ký)
      SCAN_LIMIT = { 'full' => 3000, 'sync' => 600 }.freeze

      def source_spec(id)
        if (s = @sources.find(id))
          return s.slice('id', 'name', 'type', 'url', 'method').merge('free' => nil)
        end
        site = WpSources::SITES[id.to_s]
        return nil unless site
        { 'id' => id.to_s, 'name' => site['name'], 'type' => 'website', 'url' => site['base'], 'method' => 'wp_rest',
          'free' => site['free'], 'license' => site['license'] }
      end

      def scannable?(s)
        return false if s['type'] == 'local'
        return WpSources::SITES.key?(s['id']) if s['builtin']
        %w[website gdrive facebook_group facebook_page].include?(s['type'])
      end

      def src_scan(id, mode)
        mode = mode == 'full' ? 'full' : 'sync'
        spec = source_spec(id)
        return status('Nguồn này không quét được.', 'warn') unless spec
        return status('Cần cài bộ AI (Python) để quét nguồn — bấm 📷 Tìm bằng ảnh để cài một lần.', 'warn') unless @runtime.available?
        return status('Nguồn đang được quét.', 'warn') if @sync[id] && @sync[id]['running']
        @sync[id] = { 'running' => true, 'phase' => 'Đang chuẩn bị…', 'done' => 0, 'total' => 0, 'mode' => mode }
        emit('src_progress', @sync[id].merge('id' => id))
        job = @runtime.submit('src_crawl', { 'source' => spec, 'mode' => mode, 'limit' => SCAN_LIMIT[mode], 'search' => @settings['search'] }, lane: 'crawl',
                              on_progress: lambda { |p|
                                @sync[id].merge!(p.slice('phase', 'done', 'total', 'found', 'with_links'))
                                emit('src_progress', @sync[id].merge('id' => id))
                              }) do |r|
          @sync[id]['running'] = false
          if r['ok']
            x = r['result']
            @sync[id].merge!('phase' => "Xong: #{x['found']} model, #{x['with_links']} có link tải", 'result' => x)
            @sources.set_status(id, 'method' => x['method'], 'status' => 'ok') if @sources.find(id)
            @sources.rename_auto(id, x['group_name']) if x['group_name'] && @sources.find(id)
            used = x['providers_used'].is_a?(Hash) && !x['providers_used'].empty? ? " · qua #{x['providers_used'].keys.join(', ')}" : ''
            @sync[id]['phase'] += used
            status("#{spec['name']}: đã trích xuất #{x['found']} model (#{x['with_links']} có link tải)#{used}. Đang tạo vector ảnh…", 'ok')
            @runtime.submit('catalog_embed', { 'source' => id, 'limit' => 600 }, lane: 'index') { |_e| src_stats }
          elsif r['cancelled']
            @sync[id]['phase'] = 'Đã dừng.'
          else
            @sync[id]['phase'] = "Lỗi: #{r['error']}"
            @sources.set_status(id, 'status' => 'error', 'note' => r['error'].to_s[0, 300]) if @sources.find(id)
            status("#{spec['name']}: #{r['error']}", 'error')
          end
          emit('src_progress', @sync[id].merge('id' => id))
          src_stats
          sync_all_next(id, r)
        end
        @sync[id]['job'] = job
        ensure_timer
        true
      end

      # ĐỒNG BỘ TẤT CẢ NGUỒN: lần lượt từng nguồn đang bật; nguồn lỗi được ghi lại và bỏ qua, các nguồn khác vẫn chạy tiếp.
      def src_sync_all
        return status('Đang đồng bộ tất cả nguồn.', 'warn') if @sync_all && @sync_all['running']
        return status('Cần cài bộ AI (Python) để quét nguồn — bấm 📷 Tìm bằng ảnh để cài một lần.', 'warn') unless @runtime.available?
        ids = sources_payload['list'].select { |x| x['enabled'] && x['scannable'] }.map { |x| x['id'] }
        return status('Chưa có nguồn nào quét được đang bật.', 'warn') if ids.empty?
        @sync_all = { 'running' => true, 'queue' => ids.dup, 'total' => ids.size, 'done' => 0, 'results' => [] }
        sync_all_step
      end

      def sync_all_step
        a = @sync_all
        return unless a && a['running']
        id = a['queue'].shift
        unless id
          a['running'] = false
          a['current'] = nil
          ok = a['results'].count { |x| x['ok'] }
          found = a['results'].sum { |x| x['found'].to_i }
          status("Đồng bộ tất cả xong: #{ok}/#{a['total']} nguồn thành công, #{found} model.", ok == a['total'] ? 'ok' : 'warn')
          return emit('src_all', a)
        end
        a['current'] = id
        emit('src_all', a)
        started = begin
          src_scan(id, 'sync') == true
        rescue StandardError => e
          a['results'] << { 'id' => id, 'ok' => false, 'error' => e.message }
          false
        end
        unless started
          a['results'] << { 'id' => id, 'ok' => false, 'error' => 'Không bắt đầu được (đang quét hoặc không hỗ trợ).' } unless a['results'].any? { |x| x['id'] == id }
          a['done'] += 1
          defer { sync_all_step }
        end
      end

      def sync_all_next(id, r)
        a = @sync_all
        return unless a && a['running'] && a['current'] == id
        x = r['ok'] ? r['result'] : {}
        a['results'] << { 'id' => id, 'name' => (source_spec(id) || {})['name'], 'ok' => r['ok'] ? true : false,
                          'found' => x['found'].to_i, 'with_links' => x['with_links'].to_i,
                          'error' => r['ok'] ? nil : (r['cancelled'] ? 'Đã dừng' : r['error'].to_s[0, 200]) }
        a['done'] += 1
        if r['cancelled'] && a['stop']
          a['running'] = false
          return emit('src_all', a)
        end
        sync_all_step
      end

      def src_sync_all_stop
        a = @sync_all
        return unless a && a['running']
        a['stop'] = true
        a['queue'].clear
        src_stop(a['current']) if a['current']
      end

      # ---- Công cụ tìm kiếm (Tavily / Serper / SerpApi / Brave / SearXNG): kiểm tra kết nối thật
      def search_test(provider)
        return status('Cần cài bộ AI (Python) trước — bấm 📷 Tìm bằng ảnh để cài một lần.', 'warn') unless @runtime.available?
        emit('search_test', { 'provider' => provider, 'state' => 'checking' })
        @runtime.submit('search_test', { 'provider' => provider.to_s, 'search' => @settings['search'] }, lane: 'crawl') do |r|
          x = r['ok'] ? r['result'] : { 'ok' => false, 'error' => r['error'] }
          emit('search_test', x.merge('provider' => provider, 'state' => x['ok'] ? 'ok' : 'error'))
        end
        ensure_timer
      end

      # ---- Facebook: đăng nhập thủ công trong cửa sổ riêng + lưu bài đang xem
      def fb_open(id)
        s = @sources.find(id)
        return status('Chỉ dùng cho nguồn Facebook.', 'warn') unless s && s['type'].to_s.start_with?('facebook')
        return status('Cần cài bộ AI (Python) để lưu bài — bấm 📷 Tìm bằng ảnh để cài một lần.', 'warn') unless @runtime.available?
        @fb ||= FbCapture.new(on_posts: method(:fb_posts), on_title: method(:fb_title), logger: @log)
        @fb.open(s)
        status('Đã mở nhóm. Tự đăng nhập Facebook trong cửa sổ (plugin không đọc mật khẩu), cuộn xem bài rồi bấm “MT: Lưu bài đang hiển thị”.', 'info')
      end

      def fb_title(id, name)
        emit_sources if @sources.rename_auto(id, name)
      end

      def fb_posts(id, payload)
        s = @sources.find(id)
        return unless s
        posts = Array(payload['posts']).select { |p| p.is_a?(Hash) }.first(200)
        return @fb&.notify('Không thấy bài viết nào trên màn hình.') if posts.empty?
        spec = source_spec(id)
        @fb&.notify("Đang lưu #{posts.size} bài…")
        @runtime.submit('fb_ingest', { 'source' => spec, 'posts' => posts, 'group_name' => payload['group'].to_s[0, 120] }, lane: 'crawl') do |r|
          if r['ok']
            x = r['result']
            @sources.set_status(id, 'status' => 'ok', 'method' => s['method'] == 'index' ? 'index' : 'manual')
            msg = "Đã lưu #{x['found']} bài (#{x['added']} mới, #{x['with_links']} có link tải, #{x['images']} ảnh)."
            @fb&.notify(msg)
            status("#{s['name']}: #{msg}", 'ok')
          else
            @fb&.notify("Lỗi: #{r['error']}")
            status("#{s['name']}: #{r['error']}", 'error')
          end
          src_stats
        end
        ensure_timer
      end

      def src_stop(id)
        j = @sync[id] && @sync[id]['job']
        @runtime.cancel(j) if j
        status('Đang dừng quét…')
      end

      def src_stats
        return unless @runtime.available?
        ids = @sources.list.map { |s| s['id'] }
        @runtime.submit('catalog_source_stats', { 'ids' => ids }) do |r|
          @src_stats = r['result'] if r['ok']
          emit_sources
        end
        ensure_timer
      end

      def src_log(id)
        path = File.join(@runtime.work_dir, 'crawl', "#{id.to_s.gsub(/[^A-Za-z0-9_-]/, '_')[0, 60]}.log")
        text = File.file?(path) ? Util.utf8(File.binread(path)).lines.last(200).join : 'Chưa có nhật ký.'
        emit('src_log', { 'id' => id, 'text' => text })
      end

      # Kiểm tra kết nối bằng bộ trích xuất (Python); chưa cài bộ AI thì dùng kiểm tra cơ bản.
      def src_check_deep(id)
        spec = source_spec(id)
        return src_check(id) unless spec && @runtime.available? && @sources.find(id)
        @sources.set_status(id, 'status' => 'checking')
        emit_sources
        @runtime.submit('src_check', { 'source' => spec, 'search' => @settings['search'] }, lane: 'search') do |r|
          x = r['ok'] ? r['result'] : { 'method' => 'unverified', 'status' => 'error', 'note' => r['error'] }
          @sources.set_status(id, x.slice('method', 'status', 'note', 'sitemaps'))
          add_custom_providers
          emit_sources
          status("#{spec['name']}: #{x['note']}", x['ok'] ? 'ok' : 'warn')
        end
        ensure_timer
      end

      # CHÈN model từ kho dữ liệu: link tải trực tiếp → tải & chèn; trang trung gian → mở trình duyệt + tự nhận file vừa tải.
      def insert_catalog(it)
        links = Array(it['links'])
        pw = [it['password']].compact
        best = links.find { |l| l['kind'] == 'gdrive_api' } || links.find { |l| %w[direct dropbox].include?(l['kind']) }
        if best
          url = best['url'].to_s
          if best['kind'] == 'gdrive_api'
            key = secret('google')
            return status('Cần Google API key (Tài khoản thư viện) để tải từ Google Drive.', 'warn') unless key
            url = url.sub('%7BGOOGLE_KEY%7D', URI.encode_www_form_component(key)).sub('{GOOGLE_KEY}', URI.encode_www_form_component(key))
          end
          return link_import(url, name: it['title'], passwords: pw, direct: true)
        end
        target = links.first ? links.first['url'] : it['url']
        return status('Model này không có link hợp lệ.', 'warn') unless target.to_s =~ %r{\Ahttps://}
        UI.openURL(target)
        @watcher.start(source: it['source_label'], title: it['title'], passwords: pw) && ensure_timer
        note = pw.empty? ? '' : " Mật khẩu giải nén (plugin tự dùng): #{pw.first}."
        status("Đã mở link tải của “#{it['title']}”. Tải xong plugin tự nhận file để chèn.#{note}", 'info')
      end

      def site_for(source_id)
        p = @providers.find { |x| x.is_a?(Providers::WpProvider) && x.id == source_id.to_s }
        p && p.site
      end

      def sources_payload
        state = {}
        @providers.each { |p| state[p.id] = { 'enabled' => p.id == 'local' ? true : p.enabled?(@settings), 'integrated' => p.status_info(@settings)['integrated'] } }
        WebModels::SITES.each { |w| state[w['id']] = { 'enabled' => @settings['sources'][w['id']] != false, 'integrated' => true } }
        list = @sources.list(state).map do |s|
          auto = %w[wp_rest sitemap gdrive index api].include?(s['method'])
          integrated = s['builtin'] ? (s['integrated'] ? true : false) : auto
          s.merge('type_label' => SourceRegistry::TYPES[s['type']], 'method_label' => SourceRegistry::METHODS[s['method']],
                  'integrated' => integrated,
                  'note' => s['note'] || SourceRegistry::NOTES[s['type']] || '',
                  'enabled' => s['builtin'] ? s['enabled'] != false : s['enabled'],
                  'scannable' => scannable?(s), 'stats' => @src_stats[s['id']], 'sync' => (@sync[s['id']] || {}).reject { |k, _| k == 'job' })
        end
        { 'list' => list, 'types' => SourceRegistry::TYPES }
      end

      def emit_sources
        emit('src_list', sources_payload)
      end

      def src_add(o)
        s = @sources.add(o)
        emit_sources
        status("Đã thêm nguồn “#{s['name']}”.", 'ok')
        src_check_deep(s['id'])
      rescue StandardError => e
        status(e.message, 'warn')
      end

      def src_update(o)
        @sources.update(o['id'], o)
        add_custom_providers
        emit_sources
        status('Đã lưu nguồn.', 'ok')
      rescue StandardError => e
        status(e.message, 'warn')
      end

      def src_toggle(id, on)
        if @sources.find(id)
          @sources.toggle(id, on)
          add_custom_providers
        else
          save_settings('sources' => { id => on })
        end
        emit_sources
      end

      def src_delete(id)
        @sources.delete(id)
        add_custom_providers
        emit_sources
        status('Đã xóa nguồn.', 'ok')
      end

      # Kiểm tra phương thức truy cập: website → robots.txt + WordPress REST API; dịch vụ khác → phương thức cố định.
      def src_check(id)
        s = @sources.find(id)
        return unless s
        if s['type'] == 'website'
          @sources.set_status(id, 'status' => 'checking')
          emit_sources
          SiteProbe.probe(@http, s['url']) do |r|
            @sources.set_status(id, r)
            add_custom_providers
            emit_sources
            status("#{s['name']}: #{r['note']}", r['method'] == 'wp_rest' ? 'ok' : 'warn')
          end
          ensure_timer
        elsif s['type'] == 'local'
          ok = File.directory?(s['url'])
          @sources.set_status(id, 'status' => ok ? 'ok' : 'error', 'note' => ok ? 'Thư mục đã thêm vào thư viện máy tính.' : 'Không thấy thư mục.')
          add_root_path(s['url']) if ok
          emit_sources
        else
          @sources.set_status(id, 'status' => s['type'].start_with?('facebook') ? 'login' : 'ok', 'note' => SourceRegistry::NOTES[s['type']])
          emit_sources
        end
      end

      def add_root_path(path)
        return if @settings.roots.any? { |r| Util.path_key(r) == Util.path_key(path) }
        @settings.add_root(path)
        @settings.save
        emit('settings', @settings.public_hash)
        start_scan(false)
      end

      def src_open(id)
        s = @sources.find(id) || @sources.list.find { |x| x['id'] == id.to_s }
        return unless s && s['url'].to_s.start_with?('https://')
        UI.openURL(s['url'])
        @watcher.start(source: s['name'], title: s['name'], passwords: []) && ensure_timer
        status("Đã mở #{s['name']}. Tải file trên trang — plugin sẽ tự nhận file vừa tải để chèn.", 'info')
      end

      # Chỉ chuyển các thiết lập được phép; không sao chép DPAPI, lịch sử, cookie, token.
      def team_export
        path = UI.savepanel('Xuất cấu hình công ty', '', 'MT_TEAM_CONFIG.json')
        return unless path
        data = TeamConfig.export(@settings, @sources)
        Util.atomic_write(path, JSON.pretty_generate(data))
        status('Đã xuất cấu hình công ty (không chứa API Key).', 'ok')
      rescue StandardError => e
        status("Không xuất được cấu hình: #{e.message}", 'error')
      end

      def team_import
        path = UI.openpanel('Nhập cấu hình công ty đáng tin cậy', '', 'JSON|*.json||')
        return unless path
        raise 'File quá lớn.' if File.size(path) > 2 * 1024 * 1024
        return unless UI.messagebox('Nhập cấu hình và nguồn từ file này? Nguồn hiện tại được giữ; cài đặt tìm kiếm/cập nhật có thể thay đổi. Chỉ dùng file của quản trị viên.', MB_YESNO) == IDYES
        n = TeamConfig.import(JSON.parse(File.read(path, encoding: 'UTF-8')), @settings, @sources)
        @runtime.device_pref = @settings['ai']['device']
        @index.bump
        add_custom_providers
        emit('settings', @settings.public_hash)
        emit('categories', { 'list' => Categories.all(@settings['categories_custom']) })
        emit_sources
        status("Đã nhập cấu hình; thêm #{n} nguồn. API Key riêng không bị thay đổi.", 'ok')
      rescue StandardError => e
        status("Không nhập được cấu hình: #{e.message}", 'error')
      end

      def src_export
        path = UI.savepanel('Xuất danh sách nguồn', '', 'mt_sources.json')
        return unless path
        File.write(Util.utf8(path), @sources.export_json, mode: 'w:UTF-8')
        status('Đã xuất danh sách nguồn.', 'ok')
      end

      def src_import
        path = UI.openpanel('Nhập danh sách nguồn (JSON)', '', 'JSON|*.json||')
        return unless path
        raise 'File quá lớn.' if File.size(path) > 2 * 1024 * 1024
        n = @sources.import_json(File.read(Util.utf8(path), encoding: 'UTF-8'))
        emit_sources
        status("Đã nhập #{n} nguồn.", 'ok')
        @sources.custom.select { |s| s['status'] == 'unchecked' }.first(10).each { |s| src_check(s['id']) }
      rescue StandardError => e
        status("Không nhập được: #{e.message}", 'error')
      end

      # “Nhập link model”: tải trực tiếp khi link cho phép, còn lại mở trang + tự nhận file vừa tải.
      def link_import(raw, name: nil, passwords: [], direct: false)
        r = direct ? { kind: :download, url: raw.to_s } : LinkImport.classify(raw)
        if r[:kind] == :open
          UI.openURL(r[:url])
          @watcher.start(source: SourceRegistry::TYPES[r[:service]] || 'trang nguồn', title: 'model từ link', passwords: []) && ensure_timer
          return status('Đã mở link trên trình duyệt. Tải file trên trang — plugin sẽ tự nhận file vừa tải để chèn.', 'info')
        end
        dir = Paths.sub('downloads', 'links', Time.now.strftime('%Y%m%d_%H%M%S'))
        FileUtils.mkdir_p(dir)
        dest = File.join(dir, direct && name ? Util.safe_filename(name)[0, 60] + '.download' : LinkImport.filename_for(r[:url]))
        prog = { 'bytes' => 0, 'total' => 0 }
        status('Đang tải từ link…')
        @http.request(url: r[:url], dest: dest, timeout: 120, progress: prog) do |res|
          next status("Không tải được: #{HttpClient.friendly(res)}", 'error') unless res.ok
          ext = LinkImport.sniff(dest)
          if ext.nil? # trang HTML (cần đăng nhập/xác minh) → mở trên trình duyệt
            File.delete(dest)
            UI.openURL(r[:url])
            @watcher.start(source: 'link', title: 'model từ link', passwords: []) && ensure_timer
            next status('Link không phải file tải trực tiếp — đã mở trên trình duyệt; tải xong plugin tự nhận file.', 'warn')
          end
          final = dest.sub(/\.[^.\/\\]*\z/, '') + ext
          File.rename(dest, final) unless final == dest
          smart_insert(final, name: name || File.basename(final, '.*'), passwords: passwords)
        end
        ensure_timer
      rescue StandardError => e
        status(e.message, 'warn')
      end

      # Kho dữ liệu: ghi lại metadata kết quả online đã thấy (không tải file).
      def collect_catalog(type, pl)
        return unless type == 'sr_update' && pl['items']
        pl['items'].each do |i|
          next if i['source'] == 'local' || i['key'].to_s.empty? || @cat_buf.size > 2000
          @cat_buf[i['key']] = i.reject { |k, _| %w[fav score].include?(k) }
        end
      end

      def flush_catalog
        return if @cat_buf.empty? || Time.now.to_f - @cat_last < 10 || !@runtime.available?
        @cat_last = Time.now.to_f
        items = @cat_buf.values.first(400)
        items.each { |i| @cat_buf.delete(i['key']) }
        @runtime.submit('catalog_upsert', { 'items' => items }) { |_r| nil }
      end

      def cat_stats
        return emit('cat_stats', { 'available' => false }) unless @runtime.available?
        @runtime.submit('catalog_stats', {}) { |r| emit('cat_stats', r['ok'] ? r['result'].merge('available' => true) : { 'error' => r['error'] }) }
        ensure_timer
      end

      def cat_check_links
        return status('Cần cài bộ AI tìm bằng ảnh để dùng kho dữ liệu.', 'warn') unless @runtime.available?
        status('Đang kiểm tra link trong kho dữ liệu (tối đa 4 kết nối cùng lúc)…')
        @runtime.submit('catalog_check_links', { 'limit' => 150, 'concurrency' => 4 },
                        on_progress: ->(p) { emit('cat_progress', p) }) do |r|
          if r['ok']
            x = r['result']
            status("Đã kiểm tra #{x['checked']} link: #{x['ok']} còn hoạt động, #{x['dead']} đã mất, #{x['error']} không xác định.", 'ok')
          else
            status("Kiểm tra link lỗi: #{r['error']}", 'error')
          end
          cat_stats
        end
        ensure_timer
      end

      def cat_clear
        return unless @runtime.available?
        @runtime.submit('catalog_clear', {}) do |r|
          status(r['ok'] ? 'Đã xóa dữ liệu cache của kho (metadata, vector, ảnh xem trước).' : "Xóa lỗi: #{r['error']}", r['ok'] ? 'ok' : 'error')
          cat_stats
        end
        ensure_timer
      end

      def insert_web(it)
        site = site_for(it['source']) || WpSources::SITES[it['source'].to_s]
        url = site ? WpSources.safe_url_for(it['url'], site) : nil
        return status('Liên kết nguồn không hợp lệ.', 'warn') unless url
        UI.openURL(url)
        ok = @watcher.start(source: it['source_label'], title: it['title'], passwords: site['zip_passwords'])
        msg = "Đã mở “#{it['title']}” trên #{it['source_label']}. Tải file trên trang"
        status(ok ? "#{msg} — plugin sẽ tự nhận file vừa tải để chèn." : "#{msg}, rồi dùng “Chèn file từ máy…”.", 'info')
        ensure_timer
      end

      # V1.0.16 — Model website: mở trang chi tiết bằng trình duyệt mặc định (Chrome nếu Chrome là mặc định).
      # Người dùng tự đăng nhập và tải SKP; plugin theo dõi thư mục Tải về để chèn / lưu vào thư viện.
      def insert_webmodel(it)
        site = WebModels.site(it['site'])
        url = it['url'].to_s
        host = (URI.parse(url).host.to_s.downcase rescue '') # rubocop:disable Style/RescueModifier
        return status('Liên kết model không hợp lệ.', 'warn') unless site && url.start_with?('https://') && site['hosts'].include?(host)
        UI.openURL(url)
        ok = @watcher.start(source: site['name'], title: it['title'], passwords: [])
        msg = "Đã mở “#{it['title']}” trên #{site['name']}. Tự đăng nhập (nếu cần) và tải file SKP"
        status(ok ? "#{msg} — tải xong plugin hỏi CHÈN hoặc LƯU VÀO THƯ VIỆN." : "#{msg}, rồi bấm “Nhập SKP đã tải”.", 'info')
        ensure_timer
      end

      def sources_status
        @providers.map { |p| p.status_info(@settings) } + WebModels::SITES.map do |w|
          { 'id' => w['id'], 'name' => w['name'], 'enabled' => @settings['sources'][w['id']] != false, 'integrated' => true,
            'note' => 'Tìm qua công cụ tìm kiếm web → link chi tiết model; tự đăng nhập/tải trên trang.' }
        end
      end

      def web_search_site(id, q)
        url = WebModels.search_url(id, q.strip.empty? ? (@search.session&.online_q || '') : q)
        return status('Website không hợp lệ.', 'warn') unless url
        UI.openURL(url)
      end

      # Thư mục thư viện chứa model người dùng tự tải từ website (tự thêm vào Thư viện máy tính lần đầu).
      def web_lib_dir
        dir = Util.norm_path(Paths.sub('Thu_vien_tai_ve'))
        FileUtils.mkdir_p(dir)
        dir
      end

      def lib_import_pick
        path = UI.openpanel('Chọn file SKP (hoặc ZIP chứa SKP) đã tải để lưu vào thư viện', DownloadWatcher.default_dir.to_s,
                            'SketchUp/ZIP|*.skp;*.zip||')
        return unless path
        lib_import(Util.norm_path(Util.utf8(path)))
      end

      def save_found
        f = @found
        return status('Không còn file vừa tải.', 'warn') unless f && File.file?(f[:path])
        @found = nil
        web = WebModels::SITES.any? { |w| w['name'] == f[:source] }
        lib_import(f[:path], title: web ? f[:title] : nil, site: web ? f[:source] : nil, passwords: f[:passwords])
      end

      # Sao chép SKP (hoặc các SKP trong ZIP) vào thư mục thư viện → quét để dùng lần sau. File gốc giữ nguyên.
      def lib_import(path, title: nil, site: nil, passwords: [])
        ext = File.extname(path).downcase
        return status('File không còn tồn tại.', 'warn') unless File.file?(path)
        dir = web_lib_dir
        saved = []
        if ext == '.skp'
          saved << copy_unique(path, dir, title || File.basename(path, '.*'), site)
        elsif ext == '.zip'
          pw = Array(passwords).compact.first
          begin
            zr = ZipReader.new(path, password: pw, lenient: true, max_total: 1024 * 1024 * 1024)
          rescue ZipReader::Error => e
            return status("Không đọc được ZIP: #{e.message}", 'error')
          end
          skps = zr.entries.reject(&:directory?).select { |e| e.name =~ /\.skp\z/i && ZipReader.unsafe_reason(e.name).nil? }
          return status('ZIP không chứa file .skp — giải nén và chọn file SKP.', 'warn') if skps.empty?
          return status('ZIP có mật khẩu — giải nén bằng WinRAR/7-Zip rồi chọn file SKP.', 'warn') if zr.encrypted? && pw.nil?
          skps.first(50).each do |e|
            data = zr.read(e)
            base = skps.size == 1 && title ? title : File.basename(e.name, '.*')
            dest = unique_dest(dir, base, site)
            File.binwrite(dest, data)
            saved << dest
          end
        else
          return status('Chỉ nhận file .skp hoặc .zip chứa .skp (RAR/7z: giải nén trước).', 'warn')
        end
        if @settings.roots.any? { |r| Util.under_root?(dir, r) }
          start_scan(false)
        else
          add_root_path(dir)
        end
        status("Đã lưu #{saved.size} model vào thư viện (#{File.basename(saved.first)}#{saved.size > 1 ? '…' : ''}). " \
               'Lần sau tìm ngay trong Thư viện máy tính.', 'ok')
        emit('lib_saved', { 'count' => saved.size, 'dir' => dir })
        saved
      rescue StandardError => e
        @log.error("Lưu vào thư viện #{path}", e)
        status("Không lưu được vào thư viện: #{e.message}", 'error')
        nil
      end

      def unique_dest(dir, base, site)
        name = Util.safe_filename(base.to_s.strip.empty? ? 'model' : base, 90)
        name += " (#{Util.safe_filename(site, 30)})" if site && !site.to_s.empty? && !name.include?(site.to_s)
        dest = File.join(dir, "#{name}.skp")
        i = 2
        while File.exist?(dest)
          dest = File.join(dir, "#{name} #{i}.skp")
          i += 1
        end
        dest
      end

      def copy_unique(src, dir, base, site)
        dest = unique_dest(dir, base, site)
        FileUtils.cp(src, dest)
        dest
      end

      def poll_watcher
        f = @watcher.poll
        return unless f
        @found = f
        emit('dl_found', { 'name' => File.basename(f[:path]), 'title' => f[:title], 'source' => f[:source] })
      end

      def insert_found
        f = @found
        return status('Không còn file vừa tải.', 'warn') unless f && File.file?(f[:path])
        @found = nil
        smart_insert(f[:path], name: f[:title], passwords: f[:passwords])
      end

      def fav_any(key)
        if key.start_with?('local:')
          it = find_item(key)
          return status('Không tìm thấy model.', 'warn') unless it
          on = @settings.toggle_favorite(it['id'])
        else
          it = find_item(key)
          return status('Không còn thông tin model — hãy tìm lại.', 'warn') unless it
          on = @settings.toggle_online_favorite(it)
        end
        @settings.save
        @index.bump
        emit('fav', { 'key' => key, 'on' => on })
      end

      def open_source(key)
        it = find_item(key)
        return unless it
        if it['source'] == 'local'
          UI.openURL(Util.file_url(File.dirname(it['path'].to_s)))
        else
          open_safe_url(it['url'].to_s)
        end
      end

      def category_save(o)
        name = Util.utf8(o['name']).strip
        kws = o['keywords'].is_a?(Array) ? o['keywords'] : o['keywords'].to_s.split(/[,;\n]/)
        kws = kws.map(&:strip).reject(&:empty?)
        return status('Nhập tên danh mục.', 'warn') if name.empty?
        return status('Nhập ít nhất 1 từ khóa cho danh mục.', 'warn') if kws.empty?
        if o['id'].to_s.empty? && @settings['categories_custom'].size >= Categories::MAX_CUSTOM
          return status("Tối đa #{Categories::MAX_CUSTOM} danh mục tùy chỉnh.", 'warn')
        end
        c = @settings.save_category('id' => o['id'].to_s, 'name' => name, 'keywords' => kws)
        @settings.save
        emit('categories', { 'list' => Categories.all(@settings['categories_custom']), 'select' => c && c['id'] })
        status("Đã lưu danh mục “#{name}”.", 'ok')
      end

      def category_delete(id)
        return unless @settings.delete_category(id)
        @settings.save
        emit('categories', { 'list' => Categories.all(@settings['categories_custom']), 'select' => 'all' })
        status('Đã xóa danh mục.', 'ok')
      end

      # ================================================================ Thư viện offline
      def load_library
        roots = @settings.roots.dup
        @cache_thread = Thread.new do
          Thread.current.report_on_exception = false
          Thread.current[:entries] = @indexer.load_cache(roots)
        end
        ensure_timer
      end

      def poll_cache_load
        t = @cache_thread
        return unless t && !t.alive?
        @cache_thread = nil
        entries = t[:entries] || []
        @index.replace(entries)
        @library_loaded = true
        emit('library', { 'size' => @index.size, 'info' => @indexer.cache_info })
        emit('refresh')
        if @settings['scan_on_open'] && !@settings.roots.empty?
          start_scan(false)
        elsif @settings.roots.empty?
          status('Chưa có thư mục thư viện. Bấm "+ Thêm thư mục" để bắt đầu.', 'info')
        end
      end

      def start_scan(full)
        if @settings.roots.empty?
          status('Chưa có thư mục thư viện để quét.', 'warn', 'Bấm "+ Thêm thư mục".')
          return
        end
        r = @indexer.start(@settings.roots.dup, full: full || !@settings['quick_scan'])
        status(r == :restarting ? 'Danh sách thư mục thay đổi — đang dừng lượt quét cũ và quét lại…' : 'Đang quét thư viện…')
        ensure_timer
      end

      def poll_indexer
        res = @indexer.poll
        return unless res
        case res.status
        when :done
          @index.replace(res.entries)
          @roots_state = res.roots_state
          @scan_summary = { 'models' => res.entries.size, 'errors' => res.errors.size, 'seconds' => res.stats['seconds'],
                            'reused' => res.stats['reused'], 'listed' => res.stats['listed'],
                            'error_samples' => res.errors.first(30).map { |p, m| { 'path' => p.to_s, 'msg' => m.to_s } } }
          res.errors.first(200).each { |p, m| @log.warn("Quét: #{p}: #{m}") }
          emit('scan_done', @scan_summary.merge('roots_state' => @roots_state))
          emit('refresh')
          kind = res.errors.empty? ? 'ok' : 'warn'
          status("Đã lập chỉ mục #{res.entries.size} model trong #{res.stats['seconds']} giây" +
                 (res.errors.empty? ? '.' : " — #{res.errors.size} mục lỗi truy cập (xem Cài đặt)."), kind)
        when :cancelled
          emit('scan_done', { 'cancelled' => true })
          status('Đã hủy quét. Giữ nguyên chỉ mục trước đó.', 'warn') unless @indexer.running?
        when :failed
          emit('scan_done', { 'failed' => true })
          status("Quét thất bại: #{res.errors.first && res.errors.first[1]}", 'error', 'Xem log để biết chi tiết.')
        end
      end


      def do_search(o)
        ui = @settings['ui']
        tab = o['tab'].to_s
        res = @index.search(query: o['q'].to_s[0, 300], any_of: Array(o['any_of']).first(12),
                            tab: tab, favorites: @settings['favorites'], history: @settings['history'],
                            size_max_mb: o.key?('size_max_mb') ? o['size_max_mb'].to_i : ui['size_max_mb'],
                            root: o['root'].to_s, sort: o['sort'] || ui['sort'],
                            page: o['page'].to_i, per_page: o['per_page'] || ui['page_size'])
        res['items'].each { |it| it['fav'] = @settings['favorites'].include?(it['id']) }
        res['seq'] = o['seq']
        res['tab'] = tab
        emit('results', res)
      end

      def request_thumbs(ids)
        list = Array(ids).first(200).map { |id| @index[id.to_s] }.compact
        @thumbs.request(list)
        ensure_timer
      end

      def poll_thumbs
        return unless @dialog && @ready && @thumbs.pending?
        @thumbs.process(0.045) { |id, data| emit('thumb', { 'id' => id, 'src' => data }) }
      end

      def add_root
        path = UI.select_directory(title: 'Chọn thư mục thư viện SKP')
        return unless path
        path = Util.norm_path(path)
        if @settings.roots.any? { |r| Util.under_root?(path, r) && Util.path_key(path) != Util.path_key(r) }
          status('Thư mục này nằm trong một thư mục gốc đã có — không cần thêm.', 'warn')
          return
        end
        unless @settings.add_root(path)
          status('Thư mục đã có trong danh sách.', 'warn')
          return
        end
        @settings.save
        emit('settings', @settings.public_hash)
        start_scan(false)
      end

      def remove_root(path)
        return unless @settings.remove_root(path)
        @settings.save
        kept = []
        @settings.roots.each { |r| kept.concat(@index.entries_under(r)) }
        emit('settings', @settings.public_hash)
        start_scan(false) unless @settings.roots.empty?
        if @settings.roots.empty?
          @indexer.cancel
          @index.replace([])
          emit('refresh')
          status('Đã xóa thư mục cuối cùng khỏi thư viện.', 'ok')
        else
          @index.replace(kept)
          emit('refresh')
        end
      end

      def toggle_favorite(id)
        return status('Không tìm thấy model.', 'warn') unless id =~ /\A[0-9a-f]{64}\z/
        on = @settings.toggle_favorite(id)
        @settings.save
        @index.bump
        emit('fav', { 'id' => id, 'on' => on })
      end

      def insert_item(id, allow_newer = false)
        e = @index[id]
        return status('Không tìm thấy model trong chỉ mục. Hãy quét lại.', 'warn') unless e
        status("Đang nạp “#{e.name}”…")
        defer do
          begin
            Inserter.place_skp(e.path, allow_newer: allow_newer)
            @settings.push_history(e.id)
            @settings.save
            @index.bump
            status("Đã nạp “#{e.name}”. Bấm vào công trình để đặt (Esc để hủy).", 'ok')
            emit('inserted', { 'id' => e.id })
          rescue Inserter::NewerVersionError => ex
            emit('confirm_newer', { 'id' => e.id, 'name' => e.name, 'msg' => ex.message })
          rescue StandardError => ex
            @log.error("Chèn model #{e.path}", ex)
            status("Không chèn được “#{e.name}”: #{ex.message}", 'error', 'File có thể hỏng, đang mở ở chương trình khác, hoặc ổ mạng mất kết nối.')
          end
        end
      end

      # Từ giao diện: chỉ cho phép file trong thư mục tải về của plugin.
      def insert_path(path)
        p = path.to_s
        allowed = [Paths.sub('downloads')].any? { |root| Util.under_root?(p, root) }
        return status('Đường dẫn không hợp lệ.', 'error') unless allowed
        smart_insert(p)
      end

      # MỘT điểm vào cho mọi định dạng: chọn cách nhập phù hợp, tự chuyển đổi khi cần.
      def smart_insert(path, name: nil, passwords: [])
        name ||= File.basename(path, '.*')
        if path =~ /\.(rar|7z)\z/i
          return status("File #{File.extname(path).upcase} chưa giải nén được trong plugin — giải nén bằng WinRAR/7-Zip rồi dùng “Chèn file từ máy…”.", 'warn')
        end
        case ImportManager.route(path)
        when :skp then defer { place_any_skp(path) }
        when :gltf
          if @settings['converter']['gltf_engine'] == 'blender' && @settings['converter']['blender_ok']
            convert_and_insert(path, name)
          else
            insert_gltf(path)
          end
        when :dae then defer { import_dae(path, name, nil) }
        when :convert then convert_and_insert(path, name)
        when :native
          defer do
            begin
              Inserter.import_3d(path)
              status('Đã nhập. Bấm vào công trình để đặt.', 'ok')
            rescue StandardError => ex
              path =~ /\.stl\z/i ? convert_and_insert(path, name) : status("Không nhập được: #{ex.message}", 'error')
            end
          end
        when :zip then prepare_zip(path, name, passwords)
        else status("Định dạng #{File.extname(path)} chưa hỗ trợ.", 'error')
        end
      end

      # Giải nén ZIP ở luồng nền rồi chèn file model chính.
      def prepare_zip(path, name, passwords = [])
        return status('Đang xử lý một file khác, vui lòng đợi.', 'warn') if @zip_job
        status('Đang giải nén…')
        dest = if Util.path_key(path).start_with?(Util.path_key(Paths.data_root))
                 path.sub(/\.zip\z/i, '') + '_extracted'
               else # file ở Downloads của người dùng: giải nén vào thư mục dữ liệu plugin, không xả rác ra Downloads
                 key = Digest::SHA256.hexdigest("#{path}|#{File.size(path)}|#{File.mtime(path).to_i}")[0, 10]
                 Paths.sub('downloads', 'imported', "#{Util.safe_filename(File.basename(path, '.*'))[0, 60]}_#{key}")
               end
        t = Thread.new do
          Thread.current.report_on_exception = false
          begin
            ImportManager.extract_zip(path, dest, passwords: Array(passwords)) unless File.directory?(dest)
            Thread.current[:pick] = ImportManager.pick_model(dest)
          rescue StandardError => e
            Thread.current[:error] = e.message
          end
        end
        @zip_job = { thread: t, name: name }
        ensure_timer
      end

      def poll_zip
        job = @zip_job
        return unless job && !job[:thread].alive?
        @zip_job = nil
        t = job[:thread]
        return status("Không giải nén được: #{t[:error]}", 'error') if t[:error]
        return status('Trong file ZIP không có model 3D nào chèn được.', 'error') unless t[:pick]
        smart_insert(t[:pick], name: job[:name])
      end

      def convert_and_insert(path, name)
        @pending_convert = [path, name]
        emit('convert_state', { 'state' => 'running', 'name' => name })
        r = @converter.convert(path) { |kind, a, b| on_converted(kind, a, b, name) }
        status(r == :waiting ? 'Đang tìm Blender trên máy…' : "Đang chuyển đổi “#{name}”…", 'info')
        ensure_timer
      end

      def on_converted(kind, a, b, name)
        case kind
        when :ok
          @pending_convert = nil
          emit('convert_state', { 'state' => 'done' })
          status(b && b['cached'] ? "Dùng bản đã chuyển đổi của “#{name}”…" : "Đang nhập “#{name}” vào SketchUp…")
          defer { import_dae(a, name, b && b['dimensions_m']) }
        when :need_blender
          emit('convert_state', { 'state' => 'error' })
          emit('need_blender', { 'reason' => a, 'blender' => @converter.blender_status })
          status(a.to_s, 'warn')
        when :cancelled
          @pending_convert = nil
          emit('convert_state', { 'state' => 'cancelled' })
        else
          @pending_convert = nil
          emit('convert_state', { 'state' => 'error' })
          status(a.to_s, 'error')
        end
      end

      def import_dae(path, name, expected_m)
        _defn, warn = ImportManager.import_component(path, name: name, expected_m: expected_m)
        msg = "Đã chèn “#{name}”. Bấm vào công trình để đặt (Esc để hủy)."
        status(warn.empty? ? msg : "#{msg} Lưu ý: #{warn.join(' ')}", warn.empty? ? 'ok' : 'warn')
      rescue StandardError => e
        @log.error("Nhập DAE lỗi #{path}", e)
        status("Không nhập được model: #{e.message}", 'error')
      end

      def blender_detect(preferred)
        emit('blender', @converter.blender_status.merge('checking' => true))
        @converter.detect(preferred: preferred) do |st|
          emit('blender', st)
          if st['ok']
            status("Đã nhận Blender #{st['version']}.", 'ok')
            p, n = @pending_convert
            convert_and_insert(p, n) if p
          else
            status(st['reason'].to_s, 'warn')
          end
        end
        ensure_timer
      end

      def blender_pick
        path = UI.openpanel('Chọn blender.exe (Blender 4.5 LTS)', '', 'Blender|blender.exe;blender||')
        return unless path
        blender_detect(Util.norm_path(Util.utf8(path)))
      end

      # glTF/GLB: đọc file trong luồng nền (thuần Ruby), dựng hình ở main thread rồi cho người dùng đặt bằng chuột.
      def insert_gltf(path)
        return status('Đang chèn một model khác, vui lòng đợi.', 'warn') if @gltf_job
        status("Đang đọc model “#{File.basename(path)}”…")
        tex_dir = File.join(File.dirname(path), 'textures_su')
        t = Thread.new do
          Thread.current.report_on_exception = false
          begin
            Thread.current[:model] = Gltf.parse(path, tex_dir)
          rescue StandardError => e
            Thread.current[:error] = e.message
          end
        end
        @gltf_job = { thread: t, path: path }
        ensure_timer
      end

      def poll_gltf
        job = @gltf_job
        return unless job && !job[:thread].alive?
        @gltf_job = nil
        t = job[:thread]
        if t[:error]
          @log.warn("glTF lỗi #{job[:path]}: #{t[:error]} — chuyển sang Blender")
          return convert_and_insert(job[:path], File.basename(job[:path], '.*'))
        end
        data = t[:model]
        status("Đang dựng model (#{data.triangles} tam giác)…")
        defer do
          begin
            definition = Gltf::Builder.build(data, Sketchup.active_model)
            Sketchup.active_model.place_component(definition, false)
            msg = "Đã chèn “#{data.name}”. Bấm vào công trình để đặt (Esc để hủy)."
            msg += " Lưu ý: #{data.warnings.uniq.first(2).join(' ')}" unless data.warnings.empty?
            status(msg, 'ok')
          rescue StandardError => e
            @log.error('Dựng glTF lỗi', e)
            status("Không dựng được model: #{e.message}", 'error')
          end
        end
      end

      def import_skp_dialog
        path = UI.openpanel('Chọn model SKP để chèn', '', 'SketchUp (*.skp)|*.skp||')
        return unless path
        defer { place_any_skp(Util.utf8(path)) }
      end

      def place_any_skp(path)
        Inserter.place_skp(path)
        status("Đã nạp “#{File.basename(path)}”. Bấm vào công trình để đặt.", 'ok')
      rescue Inserter::NewerVersionError => ex
        r = UI.messagebox("#{ex.message}\n\nThử nạp với chế độ cho phép phiên bản mới hơn? (có thể mất một số tính năng)", MB_YESNO)
        if r == IDYES
          Inserter.place_skp(path, allow_newer: true)
          status('Đã nạp (chế độ phiên bản mới hơn). Kiểm tra lại model.', 'warn')
        end
      rescue StandardError => ex
        status("Không chèn được: #{ex.message}", 'error')
      end

      def import_3d_dialog
        path = UI.openpanel('Chèn file 3D', '', 'Mô hình 3D|*.skp;*.glb;*.gltf;*.fbx;*.obj;*.dae;*.usdz;*.usd;*.3ds;*.kmz;*.stl;*.ply;*.blend;*.zip||')
        return unless path
        smart_insert(Util.utf8(path))
      end

      def open_item_folder(id)
        e = @index[id]
        return status('Không tìm thấy model.', 'warn') unless e
        UI.openURL(Util.file_url(File.dirname(e.path)))
      end

      def open_safe_url(url)
        u = URI.parse(url)
        if u.is_a?(URI::HTTPS) && ALLOWED_OPEN_HOSTS.include?(u.host.to_s.downcase)
          UI.openURL(u.to_s)
        else
          status('Liên kết không được phép mở.', 'warn')
        end
      rescue URI::InvalidURIError
        status('Liên kết không hợp lệ.', 'warn')
      end

      # Chạy block ở nhịp timer kế tiếp để giao diện kịp hiển thị trạng thái (an toàn với modal).
      def defer(&blk)
        tid = nil
        tid = UI.start_timer(0.05, false) do
          UI.stop_timer(tid) if tid
          begin
            blk.call
          rescue StandardError => e
            @log.error('Tác vụ hoãn lỗi', e)
            status("Lỗi: #{e.message}", 'error')
          end
        end
      end

      # ================================================================ Bí mật & cài đặt
      # Khóa/token: openai, sketchfab, google (Drive API), brave (Brave Search API). Cờ “ghi nhớ” trong settings; giá trị chỉ ở bộ nhớ hoặc DPAPI.
      SECRET_FLAGS = { 'openai' => %w[ai remember_key], 'sketchfab' => %w[sketchfab remember_token],
                       'google' => %w[keys google_remember], 'brave' => %w[keys brave_remember],
                       'tavily' => %w[keys tavily_remember], 'serper' => %w[keys serper_remember],
                       'serpapi' => %w[keys serpapi_remember] }.freeze
      SECRET_ENV = { 'openai' => 'OPENAI_API_KEY', 'sketchfab' => 'SKETCHFAB_API_TOKEN', 'google' => 'MT_GOOGLE_API_KEY',
                     'brave' => 'MT_BRAVE_API_KEY', 'tavily' => 'TAVILY_API_KEY', 'serper' => 'SERPER_API_KEY',
                     'serpapi' => 'SERPAPI_API_KEY' }.freeze
      CRAWL_KEYS = %w[google brave tavily serper serpapi].freeze

      def load_remembered_secrets
        SECRET_FLAGS.each_key do |k|
          f = SECRET_FLAGS[k]
          remember = @settings[f[0]][f[1]]
          next unless remember
          v = SecretStore.load(k)
          next unless v && !v.empty?
          @secrets[k] = v
          @log.add_secret(v)
        end
      end

      def secret(kind)
        v = @secrets[kind]
        return v if v && !v.empty?
        env = Util.env_value(SECRET_ENV[kind].to_s)
        @log.add_secret(env) if env && !env.empty?
        env && !env.empty? ? env : nil
      end

      def accounts_state
        AccountManager.list('sketchfab_token' => !secret('sketchfab').to_s.empty?, 'sketchfab_expired' => @sf_expired)
      end

      def account_action(id, act)
        if id == 'sketchfab' && act == 'logout'
          clear_secret('sketchfab')
        elsif id == 'sketchfab' && %w[login reconnect].include?(act)
          emit('need_token', { 'key' => nil })
        elsif (url = AccountManager.url_for(id, act))
          open_safe_url(url)
        end
        emit('accounts', accounts_state)
      end

      def secrets_state
        {
          'openai' => { 'session' => !@secrets['openai'].to_s.empty?, 'env' => !Util.env_value('OPENAI_API_KEY').to_s.empty?,
                        'stored' => SecretStore.stored?('openai') },
          'sketchfab' => { 'session' => !@secrets['sketchfab'].to_s.empty?, 'env' => !Util.env_value('SKETCHFAB_API_TOKEN').to_s.empty?,
                           'stored' => SecretStore.stored?('sketchfab') },
          'google' => { 'session' => !@secrets['google'].to_s.empty?, 'stored' => SecretStore.stored?('google') },
          'brave' => { 'session' => !@secrets['brave'].to_s.empty?, 'stored' => SecretStore.stored?('brave') },
          'tavily' => { 'session' => !secret('tavily').to_s.empty?, 'stored' => SecretStore.stored?('tavily') },
          'serper' => { 'session' => !secret('serper').to_s.empty?, 'stored' => SecretStore.stored?('serper') },
          'serpapi' => { 'session' => !secret('serpapi').to_s.empty?, 'stored' => SecretStore.stored?('serpapi') }
        }
      end

      def set_secret(o)
        kind = o['kind'].to_s
        return unless SECRET_FLAGS.key?(kind)
        v = o['value'].to_s.strip
        return status('Giá trị trống.', 'warn') if v.empty?
        return status('Key/token chứa ký tự không hợp lệ.', 'error') unless v =~ /\A[\x21-\x7e]{8,400}\z/
        @secrets[kind] = v
        @sf_expired = false if kind == 'sketchfab'
        @log.add_secret(v)
        flag = SECRET_FLAGS[kind]
        if o['remember'] == true
          if SecretStore.save(kind, v)
            @settings.data[flag[0]][flag[1]] = true
            status('Đã lưu key (mã hóa Windows DPAPI, chỉ tài khoản Windows này đọc được).', 'ok')
          else
            status('Máy không hỗ trợ lưu mã hóa — key chỉ được giữ trong phiên SketchUp này.', 'warn')
          end
        else
          SecretStore.delete(kind)
          @settings.data[flag[0]][flag[1]] = false
          status('Đã nhận key — chỉ giữ trong phiên SketchUp hiện tại (không ghi ra đĩa).', 'ok')
        end
        @settings.save
        emit('secrets', secrets_state)
        emit('accounts', accounts_state)
        emit('settings', @settings.public_hash)
        @runtime.lane('crawl').restart if CRAWL_KEYS.include?(kind) # khóa mới cho tiến trình trích xuất
      end

      def clear_secret(kind)
        return unless SECRET_FLAGS.key?(kind)
        @log.remove_secret(@secrets[kind]) if @secrets[kind]
        @secrets[kind] = nil
        SecretStore.delete(kind)
        flag = SECRET_FLAGS[kind]
        @settings.data[flag[0]][flag[1]] = false
        @runtime.lane('crawl').restart if CRAWL_KEYS.include?(kind)
        @settings.save
        @sf_expired = false if kind == 'sketchfab'
        emit('secrets', secrets_state)
        emit('accounts', accounts_state)
        status('Đã xóa key khỏi phiên và khỏi máy.', 'ok')
      end

      def save_settings(patch)
        before_quick = @settings['quick_scan']
        @settings.apply_ui(patch)
        @settings.save
        @index.bump
        emit('settings', @settings.public_hash)
        @runtime.device_pref = @settings['ai']['device']
        emit('sources_status', sources_status) if patch.key?('sources')
        emit_sources if patch.key?('sources')
        status('Đã lưu cài đặt.', 'ok') if patch['_notify']
        @log.info('Đổi chế độ quét nhanh') if before_quick != @settings['quick_scan']
      end

      def net_timeout
        @settings['net']['timeout'].to_i
      end

      # ================================================================ Online
      def check_network
        emit('net', { 'state' => 'checking' })
        t0 = Time.now
        @http.request(url: Sketchfab.search_url('chair', count: 1, downloadable: false), timeout: [net_timeout, 15].min) do |res|
          ms = ((Time.now - t0) * 1000).round
          if res.ok
            emit('net', { 'state' => 'online', 'ms' => ms })
          else
            emit('net', { 'state' => 'offline', 'msg' => HttpClient.friendly(res) })
          end
        end
        ensure_timer
      end

      def sketchfab_search(o)
        q = o['q'].to_s
        url = Sketchfab.search_url(q, cursor: o['cursor'], downloadable: o['downloadable'] != false)
        seq = o['seq']
        emit('sf_loading', { 'seq' => seq })
        @http.request(url: url, headers: { 'Accept' => 'application/json' }, timeout: net_timeout) do |res|
          if res.ok
            begin
              data = Sketchfab.parse_search(res.body)
              data['items'].each { |it| @sf_items[it['uid']] = it }
              @sf_items.shift while @sf_items.size > 600
              emit('sf_results', data.merge('seq' => seq, 'q' => q, 'cursor' => o['cursor']))
              emit('net', { 'state' => 'online' })
            rescue StandardError => e
              emit('sf_error', { 'seq' => seq, 'msg' => e.message })
            end
          else
            msg = res.code > 0 ? Sketchfab.error_message(res.code, res.body) : HttpClient.friendly(res)
            emit('sf_error', { 'seq' => seq, 'msg' => msg, 'fallback' => LinkSources.url_for('sketchfab_web', q) })
            emit('net', { 'state' => 'offline', 'msg' => msg }) if res.code.zero?
          end
        end
        ensure_timer
      end

      def sketchfab_download(o)
        uid = o['uid'].to_s
        item = @sf_items[uid]
        return status('Không còn thông tin model — hãy tìm lại.', 'warn') unless item
        return status('Model này không cho phép tải.', 'warn') unless item['downloadable']
        token = secret('sketchfab')
        unless token
          emit('dl_state', { 'uid' => uid, 'state' => 'error', 'msg' => 'Cần Sketchfab API token (Cài đặt > Sketchfab).' })
          return
        end
        return status('Model này đang được tải.', 'warn') if @downloads[uid] && @downloads[uid]['state'] == 'downloading'
        fmt = Sketchfab::FORMATS.include?(o['format']) ? o['format'] : 'gltf'
        @downloads[uid] = { 'state' => 'requesting', 'progress' => { 'bytes' => 0, 'total' => 0 }, 'auto_insert' => o['auto_insert'] == true }
        emit('dl_state', { 'uid' => uid, 'state' => 'requesting' })
        hdr = { 'Authorization' => Sketchfab.auth_header(token, @settings['sketchfab']['token_type']), 'Accept' => 'application/json' }
        @http.request(url: Sketchfab.download_url(uid), headers: hdr, timeout: net_timeout) do |res|
          if !res.ok
            if res.code == 401
              @sf_expired = true
              emit('accounts', accounts_state)
            end
            msg = res.code > 0 ? Sketchfab.error_message(res.code, res.body) : HttpClient.friendly(res)
            @downloads[uid]['state'] = 'error'
            emit('dl_state', { 'uid' => uid, 'state' => 'error', 'msg' => msg })
          else
            begin
              links = Sketchfab.parse_download(res.body)
              chosen = links[fmt] ? fmt : (%w[gltf glb usdz source].find { |f| links[f] })
              raise 'Sketchfab không trả link tải nào cho model này.' unless chosen
              start_file_download(uid, item, chosen, links[chosen])
            rescue StandardError => e
              @downloads[uid]['state'] = 'error'
              emit('dl_state', { 'uid' => uid, 'state' => 'error', 'msg' => e.message })
            end
          end
        end
        ensure_timer
      end

      def start_file_download(uid, item, fmt, link)
        folder = Paths.sub('downloads', 'sketchfab', uid)
        FileUtils.mkdir_p(folder)
        dest = File.join(folder, "#{uid}_#{fmt}#{Sketchfab.extension_for(fmt, link['url'])}")
        prog = @downloads[uid]['progress']
        prog['total'] = link['size'].to_i
        @downloads[uid]['state'] = 'downloading'
        emit('dl_state', { 'uid' => uid, 'state' => 'downloading', 'format' => fmt, 'total' => link['size'].to_i })
        @http.request(url: link['url'], dest: dest, timeout: [net_timeout, 60].max, progress: prog) do |res|
          if res.ok
            File.write(File.join(folder, 'ATTRIBUTION.txt'), Sketchfab.attribution(item, fmt), mode: 'w:UTF-8')
            files = post_process_download(dest, folder)
            importable = files.select { |f| %w[skp gltf import convert].include?(f['kind']) }
            note = if importable.empty?
                     "Đã tải #{fmt.upcase} nhưng không có file chèn được vào SketchUp (định dạng #{fmt.upcase})."
                   else
                     'Đã tải xong.'
                   end
            @downloads[uid]['state'] = 'done'
            @downloads[uid]['files'] = files
            emit('dl_state', { 'uid' => uid, 'state' => 'done', 'folder' => folder, 'files' => files.first(40), 'note' => note,
                               'key' => item['key'] })
            after_download(uid, files, importable, note)
          else
            @downloads[uid]['state'] = 'error'
            emit('dl_state', { 'uid' => uid, 'state' => 'error', 'msg' => HttpClient.friendly(res) })
          end
        end
      end

      # Sau khi tải: tự chèn nếu có SKP/định dạng SketchUp nhập được; lưu vào thư viện cá nhân nếu bật.
      def after_download(uid, files, importable, note)
        if importable.any? { |f| f['kind'] == 'skp' } && @settings['auto_save_downloads']
          dl_root = Paths.sub('downloads')
          if @settings.roots.none? { |r| Util.path_key(r) == Util.path_key(dl_root) }
            @settings.add_root(dl_root)
            @settings.save
            emit('settings', @settings.public_hash)
          end
          start_scan(false)
        end
        return unless @downloads[uid] && @downloads[uid]['auto_insert']
        first = importable.first
        if first
          smart_insert(first['path'], name: @sf_items[uid] && @sf_items[uid]['name'])
        else
          status(note, 'warn', 'Mở chi tiết model › “Mở thư mục tải về” để chuyển đổi bằng phần mềm khác.')
        end
      end

      # Giải nén an toàn (nếu là ZIP) và phân loại file nhập được.
      def post_process_download(path, folder)
        out = []
        if path =~ /\.zip\z/i
          begin
            ex_dir = File.join(folder, 'extracted')
            ImportManager.extract_zip(path, ex_dir)
            Dir.glob(File.join(ex_dir, '**', '*')).select { |f| File.file?(f) }.each { |f| out << classify(f) }
          rescue StandardError => e
            @log.warn("Không giải nén #{path}: #{e.message}")
            out << classify(path)
          end
        else
          out << classify(path)
        end
        out.sort_by { |f| [ImportManager::PRIORITY.index(File.extname(f['path']).downcase) || 99, -f['size'].to_i] }
      end

      def classify(f)
        ext = File.extname(f).downcase
        kind = ext == '.zip' ? 'other' : ImportManager.kind_label(f)
        { 'path' => f, 'name' => File.basename(f), 'kind' => kind, 'size' => File.size(f) }
      end

      def open_download_folder(uid)
        if uid =~ /\Aph-([A-Za-z0-9_\-]{1,80})\z/
          return UI.openURL(Util.file_url(Paths.sub('downloads', 'polyhaven', Regexp.last_match(1))))
        end
        return unless uid =~ /\A[0-9a-f]{32}\z/
        UI.openURL(Util.file_url(Paths.sub('downloads', 'sketchfab', uid)))
      end

      # ================================================================ AI
      def ai_ready?
        return true if secret('openai')
        status('Chưa có OpenAI API key.', 'warn', 'Nhập key trong Cài đặt > AI, hoặc đặt biến môi trường OPENAI_API_KEY rồi mở lại SketchUp.')
        emit('ai_need_key')
        false
      end

      def ai_pick
        return unless ai_ready?
        path = UI.openpanel('Chọn ảnh mẫu để AI phân tích', '', 'Ảnh (*.jpg;*.png;*.webp)|*.jpg;*.jpeg;*.png;*.webp;*.gif||')
        return unless path
        path = Util.utf8(path)
        size = File.size(path)
        return status('Ảnh lớn hơn 15 MB — hãy giảm kích thước ảnh.', 'warn') if size > 15 * 1024 * 1024
        bytes = File.binread(path)
        mime = Vision.mime_of(bytes)
        return status('File không phải ảnh JPG/PNG/WEBP/GIF hợp lệ.', 'error') unless mime
        @ai_image = { 'name' => File.basename(path), 'mime' => mime, 'size' => size }
        emit('ai_preview', { 'src' => "data:#{mime};base64,#{Base64.strict_encode64(bytes)}", 'name' => File.basename(path),
                             'size' => size, 'mime' => mime, 'model' => @settings['ai']['model'],
                             'endpoint' => @settings['ai']['base_url'] })
      end

      # Chỉ gửi khi người dùng bấm xác nhận trong giao diện (đã xem preview).
      def ai_send(o)
        return unless ai_ready?
        b64 = o['b64'].to_s.gsub(/\s+/, '')
        mime = o['mime'].to_s
        return status('Định dạng ảnh không hợp lệ.', 'error') unless %w[image/jpeg image/png image/webp image/gif].include?(mime)
        return status('Ảnh rỗng.', 'error') if b64.empty? || b64 !~ %r{\A[A-Za-z0-9+/=]+\z}
        return status('Ảnh sau nén vẫn quá lớn (>8 MB).', 'error') if b64.length * 3 / 4 > Vision::MAX_IMAGE_BYTES
        @ai_seq += 1
        seq = @ai_seq
        emit('ai_state', { 'state' => 'sending' })
        status("Đang gửi ảnh tới OpenAI (model #{@settings['ai']['model']})…")
        ai_request(seq, mime, b64, [])
        ensure_timer
      end

      def ai_request(seq, mime, b64, variant)
        ai = @settings['ai']
        key = secret('openai')
        body = Vision.build_body(model: ai['model'], mime: mime, b64: b64, detail: ai['detail'], variant: variant)
        @http.request(method: 'POST', url: "#{ai['base_url']}/chat/completions", headers: Vision.headers(key),
                      body: body, timeout: [net_timeout, 90].max, max_body: 2_000_000) do |res|
          next unless seq == @ai_seq
          if res.ok
            begin
              data = Vision.parse_result(res.body)
              emit('ai_result', data)
              status('AI đã gợi ý từ khóa. Có thể sửa từ khóa trước khi tìm.', 'ok')
              @log.info("AI ok model=#{ai['model']} usage=#{data['usage']}")
            rescue StandardError => e
              emit('ai_state', { 'state' => 'error', 'msg' => e.message })
              status(e.message, 'error')
            end
          elsif (nv = Vision.fallback_variant(res.code, res.body, variant))
            @log.warn("AI thử lại với phương án #{nv.inspect}")
            ai_request(seq, mime, b64, nv)
          else
            msg = res.code > 0 ? Vision.error_message(res.code, res.body) : HttpClient.friendly(res)
            msg = @log.redact(msg)
            @log.warn("AI lỗi: #{msg}")
            emit('ai_state', { 'state' => 'error', 'msg' => msg })
            status(msg, 'error')
          end
        end
      end

      def check_openai
        key = secret('openai')
        return status('Chưa có OpenAI API key.', 'warn') unless key
        ai = @settings['ai']
        emit('ai_check', { 'state' => 'checking' })
        @http.request(url: "#{ai['base_url']}/models/#{URI.encode_www_form_component(ai['model'])}",
                      headers: Vision.headers(key), timeout: [net_timeout, 20].min) do |res|
          if res.ok
            emit('ai_check', { 'state' => 'ok', 'msg' => "Key hợp lệ, model “#{ai['model']}” khả dụng." })
          else
            msg = res.code > 0 ? Vision.error_message(res.code, res.body) : HttpClient.friendly(res)
            emit('ai_check', { 'state' => 'error', 'msg' => @log.redact(msg) })
          end
        end
        ensure_timer
      end

      # ================================================================ Cập nhật
      def show_updater
        if @up_dialog
          @up_dialog.visible? ? @up_dialog.bring_to_front : @up_dialog.show
          return
        end
        d = UI::HtmlDialog.new(dialog_title: "Cập nhật #{PRODUCT_NAME}", preferences_key: 'MTDesign.SmartLibraryPro.Update',
                               scrollable: true, resizable: true, width: 820, height: 700, min_width: 600, min_height: 480,
                               style: UI::HtmlDialog::STYLE_DIALOG)
        d.set_file(File.join(Paths.code_dir, 'updater', 'update_dialog.html'))
        cb(d, 'up_ready') { |*| @up_ready = true; send_up_init }
        cb(d, 'up_pick_file') { |*| up_pick_file }
        cb(d, 'up_install') { |force| up_install(force == true || force.to_s == 'true') }
        cb(d, 'up_check_online') { |*| up_check_online(true) }
        cb(d, 'up_install_online') { |*| up_install_online }
        cb(d, 'up_restore') { |id| up_restore(id.to_s) }
        cb(d, 'up_restore_last') { |*| up_restore_last }
        cb(d, 'up_save_source') { |json| save_settings('update' => parse(json)); up_emit('up_source_saved', @settings['update']) }
        cb(d, 'up_publish_lan') { |*| up_publish_lan }
        cb(d, 'up_open_log') { |*| UI.openURL(Util.file_url(File.dirname(@updater.log_path))) }
        cb(d, 'up_open_backups') { |*| UI.openURL(Util.file_url(@updater.backups.dir)) }
        d.set_on_closed do
          @up_dialog = nil
          @up_ready = false
        end
        @up_dialog = d
        d.show
        ensure_timer
      end

      def up_emit(type, payload = nil)
        return unless @up_dialog && @up_ready
        @up_dialog.execute_script("window.UP&&UP.receive(#{Util.json_for_js(type.to_s)},#{Util.json_for_js(payload)})")
      rescue StandardError => e
        @log.error('execute_script (update) lỗi', e)
      end

      def send_up_init
        up_emit('init', {
                  'version' => VERSION, 'plugin_id' => PLUGIN_ID, 'build' => BUILD_DATE, 'su' => su_version, 'ruby' => RUBY_VERSION,
                  'plugins_root' => Paths.plugins_root, 'data_root' => Paths.data_root, 'source' => @settings['update'],
                  'backups' => @updater.backups.list.map { |b| b.reject { |k, _| k == 'path' } },
                  'history' => @updater.history, 'pending_restart' => @updater.pending_restart_version,
                  'busy' => @updater.busy?, 'online' => @online_info, 'startup' => @startup_msg,
                  'official' => { 'label' => UpdateChannel::LABEL, 'repo' => UpdateChannel::REPO, 'page' => UpdateChannel.release_page }
                })
      end

      def up_pick_file
        return up_emit('up_error', 'Đang có tác vụ cập nhật khác.') if @updater.busy?
        path = UI.openpanel('Chọn gói cập nhật MT SMART LIBRARY PRO', '', 'Gói cập nhật (*.rbz;*.zip)|*.rbz;*.zip||')
        return unless path
        @pending_pkg = nil
        info = @updater.inspect_package(Util.utf8(path), su_major: su_major)
        @pending_pkg = info
        up_emit('up_package', info)
      rescue StandardError => e
        @log.warn("Gói bị từ chối: #{e.message}")
        up_emit('up_package_error', e.message)
      end

      def up_install(force)
        info = @pending_pkg
        return up_emit('up_error', 'Chưa chọn gói cập nhật hợp lệ.') unless info
        return up_emit('up_error', info['compat_message']) unless info['compatible']
        if info['relation'] != 'newer' && !force
          return up_emit('up_confirm_downgrade', info)
        end
        reason = info['relation'] == 'newer' ? 'Cập nhật từ file' : 'Cài lại/hạ cấp từ file'
        begin_install(info, reason)
      end

      # “Khôi phục phiên bản trước”: bản sao lưu mới nhất (tạo trước lần cập nhật gần nhất).
      def up_restore_last
        last = @updater.backups.list.first
        return up_emit('up_error', 'Chưa có bản sao lưu nào để khôi phục.') unless last
        up_restore(last['id'].to_s)
      end

      def up_restore(id)
        info = @updater.inspect_backup(id, su_major: su_major)
        return up_emit('up_error', info['compat_message']) unless info['compatible']
        begin_install(info, 'Khôi phục phiên bản')
      rescue StandardError => e
        up_emit('up_error', "Không khôi phục được: #{e.message}")
      end

      def begin_install(info, reason)
        return up_emit('up_error', 'Đang có tác vụ cập nhật khác.') if @updater.busy?
        if @indexer.running?
          @indexer.cancel # tránh ghi cache trong lúc cài
        end
        @updater.start_install(info, reason)
        up_emit('up_started', { 'version' => info['version'], 'reason' => reason })
        ensure_timer
      end

      def up_publish_lan
        return up_emit('up_error', 'Đang có tác vụ cập nhật khác.') if @updater.busy?
        package = UI.openpanel('Chọn RBZ đã kiểm thử', '', 'RBZ|*.rbz||')
        return unless package
        folder = UI.select_directory(title: 'Chọn thư mục phát hành công ty')
        return unless folder
        return unless UI.messagebox('Phát hành gói này cho nhân viên? Chỉ chọn thư mục do quản trị viên có quyền ghi.', MB_YESNO) == IDYES
        su_major_value = su_major
        @updater.team_async(->(kind, data) { up_emit('up_online_state', { 'state' => kind == :ok ? 'ok' : 'error', 'msg' => kind == :ok ? "Đã phát hành #{data['version']}" : data }) }) do
          @updater.publish_lan(package, folder, su_major_value)
        end
        ensure_timer
      rescue StandardError => e
        up_emit('up_error', e.message)
      end

      def up_check_online(manual)
        cfg = @settings['update']
        @online_info = nil
        up_emit('up_online_state', { 'state' => 'checking' }) if manual
        @updater.check_online(cfg, su_major) do |kind, data|
          if kind == :ok
            @online_info = data
            @update_available = data['relation'] == 'newer' && data['compatible'] ? data['version'] : nil
            up_emit('up_online_state', { 'state' => 'ok', 'msg' => "Đã kết nối #{data['channel'] || 'nguồn cập nhật'}." }) if manual
            up_emit('up_online', data)
            emit('update_available', @update_available) if @update_available
          else
            up_emit('up_online_state', { 'state' => 'error', 'msg' => data }) if manual
            @log.warn("Kiểm tra cập nhật: #{data}")
          end
        end
        ensure_timer
      rescue StandardError => e
        up_emit('up_online_state', { 'state' => 'error', 'msg' => e.message }) if manual
      end

      def up_install_online
        m = @online_info
        return up_emit('up_error', 'Hãy bấm "Kiểm tra cập nhật online" trước.') unless m
        return up_emit('up_error', m['compat_message']) unless m['compatible']
        return up_emit('up_error', 'Không có phiên bản mới hơn để cài.') unless m['relation'] == 'newer'
        @updater.download_package(m) do |kind, data|
          if kind == :ok
            begin
              info = @updater.inspect_package(data, su_major: su_major)
              raise "Gói tải về là bản #{info['version']}, khác manifest #{m['version']}." unless info['version'] == m['version']
              @pending_pkg = info
              begin_install(info, 'Cập nhật online')
            rescue StandardError => e
              up_emit('up_error', "Gói online bị từ chối: #{e.message}")
            end
          else
            up_emit('up_error', data)
          end
        end
        up_emit('up_downloading', { 'version' => m['version'], 'size' => m['size'] })
        ensure_timer
      rescue StandardError => e
        up_emit('up_error', e.message)
      end

      def poll_updater
        @updater.poll_team
        if (@updater.busy? || @updater.download_progress) && Time.now.to_f - (@last_up_emit || 0) > 0.3
          @last_up_emit = Time.now.to_f
          pr = @updater.progress
          up_emit('up_progress', { 'progress' => pr, 'download' => @updater.download_progress }) if pr
        end
        @updater.events.each do |type, payload|
          case type
          when :install_done
            if payload['hot']
              ok = hot_apply(payload)
              payload = payload.merge('hot' => ok)
            end
            modified = begin
              Sketchup.active_model && Sketchup.active_model.modified?
            rescue StandardError
              false
            end
            up_emit('up_done', payload.merge('model_modified' => modified, 'progress' => @updater.progress,
                                             'backups' => @updater.backups.list.map { |b| b.reject { |k, _| k == 'path' } },
                                             'history' => @updater.history))
            emit('update_installed', payload['version'])
            if payload['hot']
              status("Đã cập nhật nhanh lên #{payload['version']} — đã áp dụng, không cần khởi động lại SketchUp.", 'ok')
            else
              status("Đã cài phiên bản #{payload['version']} — khởi động lại SketchUp để áp dụng.", 'ok')
            end
            @pending_pkg = nil
          when :install_failed
            up_emit('up_failed', payload.merge('progress' => @updater.progress, 'history' => @updater.history))
          end
        end
      end

      # HYBRID HOT RELOAD (main thread): nạp lại module thuần hàm, tiến trình Python khi rảnh, cấu hình, giao diện.
      # Không chạy lại main.rb, không tạo lại menu/toolbar/timer/callback; bản vẽ đang mở không bị động tới.
      def hot_apply(payload)
        changed = Array(payload['changed'])
        reloaded = HotReload.reload_ruby(changed, Paths.code_dir)
        if changed.any? { |r| r.end_with?('.py') || r.end_with?('model_config.json') }
          @runtime.reload_cfg
          @runtime.lanes.each(&:restart_when_idle)
        end
        if changed.any? { |r| r =~ %r{/ui/.*\.(html|css|js)\z} } && @dialog
          @ready = false
          @dialog.set_file(File.join(Paths.code_dir, 'ui', 'index.html')) # callback giữ nguyên trên dialog; giao diện gửi lại “ready”
        end
        @log.info("Cập nhật nhanh #{payload['version']}: #{changed.size} file, nạp lại Ruby: #{reloaded.join(', ')}")
        true
      rescue StandardError, ScriptError => e
        @log.error('Áp dụng nóng lỗi — chuyển sang chờ khởi động lại', e)
        @updater.mark_pending(payload['version'], 'Áp dụng nóng lỗi')
        false
      end

      def schedule_startup_check
        cfg = @settings['update']
        return unless cfg['check_on_start'] && cfg['source'] != 'none'
        defer_seconds(20) { up_check_online(false) }
      end

      def defer_seconds(sec, &blk)
        tid = nil
        tid = UI.start_timer(sec, false) do
          UI.stop_timer(tid) if tid
          blk.call
        end
      end

      # ================================================================ Timer
      def ensure_timer
        return if @timer
        @timer = UI.start_timer(TICK, true) { tick }
      end

      def stop_timer
        return unless @timer
        UI.stop_timer(@timer)
        @timer = nil
      end

      def vs_progress
        return unless @runtime.installing?
        now = Time.now.to_f
        return if @vs_prog_at && now - @vs_prog_at < 0.5
        @vs_prog_at = now
        emit('vs_state', { 'state' => 'installing', 'msg' => @runtime.status['step'], 'progress' => @runtime.progress })
      end

      def busy?
        !@cache_thread.nil? || !@gltf_job.nil? || !@zip_job.nil? || @converter.busy? || @runtime.busy? || @visual.active? || @indexer.running? || @http.busy? ||
          @updater.busy? || @thumbs.pending?
      end

      def tick
        return if @ticking
        @ticking = true
        begin
          give_threads_time
          poll_cache_load
          poll_gltf
          poll_zip
          poll_watcher
          @runtime.poll
          if (n = @runtime.take_notice)
            status(n, 'warn')
          end
          @visual.poll
          flush_catalog
          vs_progress
          if Time.now.to_f - @vs_last_sync > 30 && @library_loaded && !@indexer.running?
            @vs_last_sync = Time.now.to_f
            @visual.sync_index
          end
          @converter.poll
          poll_indexer
          @http.poll
          poll_updater
          poll_thumbs
          emit_progress
          stop_timer if @dialog.nil? && @up_dialog.nil? && !busy?
        rescue StandardError => e
          @log.error('Lỗi timer', e)
        ensure
          @ticking = false
        end
      end

      # Nhường GVL cho luồng nền (SketchUp chỉ chạy Ruby khi có sự kiện).
      def give_threads_time
        ts = [@cache_thread, @indexer.thread, @updater.thread, @gltf_job && @gltf_job[:thread], @zip_job && @zip_job[:thread]].compact + @http.threads + @runtime.threads
        ts = ts.select(&:alive?)
        return if ts.empty?
        slice = 0.03 / ts.size
        ts.each { |t| t.join(slice) }
      end

      def emit_progress
        now = Time.now.to_f
        return if now - @last_progress_emit < 0.35
        @last_progress_emit = now
        emit('scan_progress', @indexer.progress) if @indexer.running?
        @downloads.each do |uid, d|
          next unless d['state'] == 'downloading'
          if d['total_all'] # tải nhiều file (Poly Haven): cộng dồn
            emit('dl_progress', { 'uid' => uid, 'bytes' => d['base'].to_i + d['progress']['bytes'].to_i, 'total' => d['total_all'] })
          else
            emit('dl_progress', { 'uid' => uid, 'bytes' => d['progress']['bytes'], 'total' => d['progress']['total'] })
          end
        end
      end

      # ================================================================ Tiện ích
      def su_version
        defined?(Sketchup) && Sketchup.respond_to?(:version) ? Sketchup.version.to_s : 'n/a'
      end

      def su_major
        su_version.to_i
      end
    end
  end
end
