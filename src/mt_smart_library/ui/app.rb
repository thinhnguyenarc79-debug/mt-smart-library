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
      ALLOWED_OPEN_HOSTS = (%w[sketchfab.com www.sketchfab.com platform.openai.com github.com www.blender.org polyhaven.com] +
                            AccountManager.hosts).uniq.freeze

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
        @visual = VisualSearchManager.new(runtime: @runtime, index: @index, thumbs: @thumbs, online_providers: @providers.select(&:online?),
                                          settings: @settings, emit: ->(t, pl) { emit(t, pl) }, logger: @log)
        @runtime.device_pref = @settings['ai']['device']
        @vs_image = nil
        @vs_last_sync = 0
        @watcher = DownloadWatcher.new
        @found = nil
        @sf_expired = false
        @converter = ConverterManager.new(settings: @settings, data_root: Paths.data_root, logger: @log)
        @search = SearchManager.new(providers: @providers, settings: @settings, emit: ->(t, pl) { emit(t, pl) }, logger: @log)
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
               'sources_status' => @providers.map { |p| p.status_info(@settings) },
               'blender' => @converter.blender_status, 'accounts' => accounts_state, 'visual' => @runtime.status
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
        return insert_web(it) if it['web_only']
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

      def insert_web(it)
        site = WpSources::SITES[it['source'].to_s]
        url = WpSources.safe_https(it['url'], site ? site['hosts'] : [])
        return status('Liên kết nguồn không hợp lệ.', 'warn') unless url
        UI.openURL(url)
        ok = @watcher.start(source: it['source_label'], title: it['title'], passwords: site['zip_passwords'])
        msg = "Đã mở “#{it['title']}” trên #{it['source_label']}. Tải file trên trang"
        status(ok ? "#{msg} — plugin sẽ tự nhận file vừa tải để chèn." : "#{msg}, rồi dùng “Chèn file từ máy…”.", 'info')
        ensure_timer
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
      def load_remembered_secrets
        %w[openai sketchfab].each do |k|
          remember = k == 'openai' ? @settings['ai']['remember_key'] : @settings['sketchfab']['remember_token']
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
        env = kind == 'openai' ? Util.env_value('OPENAI_API_KEY') : Util.env_value('SKETCHFAB_API_TOKEN')
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
                           'stored' => SecretStore.stored?('sketchfab') }
        }
      end

      def set_secret(o)
        kind = o['kind'].to_s
        return unless %w[openai sketchfab].include?(kind)
        v = o['value'].to_s.strip
        return status('Giá trị trống.', 'warn') if v.empty?
        return status('Key/token chứa ký tự không hợp lệ.', 'error') unless v =~ /\A[\x21-\x7e]{8,400}\z/
        @secrets[kind] = v
        @sf_expired = false if kind == 'sketchfab'
        @log.add_secret(v)
        flag = kind == 'openai' ? %w[ai remember_key] : %w[sketchfab remember_token]
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
      end

      def clear_secret(kind)
        return unless %w[openai sketchfab].include?(kind)
        @log.remove_secret(@secrets[kind]) if @secrets[kind]
        @secrets[kind] = nil
        SecretStore.delete(kind)
        flag = kind == 'openai' ? %w[ai remember_key] : %w[sketchfab remember_token]
        @settings.data[flag[0]][flag[1]] = false
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
        emit('sources_status', @providers.map { |p| p.status_info(@settings) }) if patch.key?('sources')
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
        cb(d, 'up_save_source') { |json| save_settings('update' => parse(json)); up_emit('up_source_saved', @settings['update']) }
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
                  'busy' => @updater.busy?, 'online' => @online_info, 'startup' => @startup_msg
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

      def up_check_online(manual)
        cfg = @settings['update']
        up_emit('up_online_state', { 'state' => 'checking' }) if manual
        @updater.check_online(cfg, su_major) do |kind, data|
          if kind == :ok
            @online_info = data
            @update_available = data['relation'] == 'newer' && data['compatible'] ? data['version'] : nil
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
        if (@updater.busy? || @updater.download_progress) && Time.now.to_f - (@last_up_emit || 0) > 0.3
          @last_up_emit = Time.now.to_f
          pr = @updater.progress
          up_emit('up_progress', { 'progress' => pr, 'download' => @updater.download_progress }) if pr
        end
        @updater.events.each do |type, payload|
          case type
          when :install_done
            modified = begin
              Sketchup.active_model && Sketchup.active_model.modified?
            rescue StandardError
              false
            end
            up_emit('up_done', payload.merge('model_modified' => modified, 'progress' => @updater.progress,
                                             'backups' => @updater.backups.list.map { |b| b.reject { |k, _| k == 'path' } },
                                             'history' => @updater.history))
            emit('update_installed', payload['version'])
            status("Đã cài phiên bản #{payload['version']} — khởi động lại SketchUp để áp dụng.", 'ok')
            @pending_pkg = nil
          when :install_failed
            up_emit('up_failed', payload.merge('progress' => @updater.progress, 'history' => @updater.history))
          end
        end
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
