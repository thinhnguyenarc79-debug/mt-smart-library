# frozen_string_literal: true
require 'json'
require 'base64'
require 'fileutils'

module MTDesign
  module SmartLibrary
    # Bộ điều khiển: HtmlDialog, callbacks, UI timer. Toàn bộ SketchUp API chạy ở main thread.
    # Luồng nền (quét, HTTP, cập nhật) chỉ trao đổi qua Queue/Mutex và được poll bởi timer.
    class App
      TICK = 0.1
      ALLOWED_OPEN_HOSTS = %w[sketchfab.com www.sketchfab.com platform.openai.com github.com].freeze

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
      end

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

      def send_init
        emit('init', {
               'version' => VERSION, 'plugin_id' => PLUGIN_ID, 'build' => BUILD_DATE, 'su' => su_version,
               'settings' => @settings.public_hash, 'secrets' => secrets_state, 'sources' => LinkSources.list,
               'data_root' => Paths.data_root, 'log' => @log.path, 'secret_store' => SecretStore.available?,
               'roots_state' => @roots_state, 'loaded' => @library_loaded, 'library_size' => @index.size,
               'scan' => @indexer.progress, 'summary' => @scan_summary, 'startup' => @startup_msg,
               'settings_warning' => @settings.load_warning, 'update_available' => @update_available,
               'pending_restart' => @updater.pending_restart_version
             })
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

      def insert_path(path)
        p = path.to_s
        allowed = [Paths.sub('downloads')].any? { |root| Util.under_root?(p, root) }
        return status('Đường dẫn không hợp lệ.', 'error') unless allowed
        if p =~ /\.skp\z/i
          defer { place_any_skp(p) }
        else
          defer do
            begin
              Inserter.import_3d(p)
              status('Đã nhập. Đặt model rồi kiểm tra lại kích thước (Tape Measure) và vật liệu.', 'ok')
            rescue StandardError => ex
              status("Không nhập được: #{ex.message}", 'error')
            end
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
        path = UI.openpanel('Nhập file 3D (DAE/3DS/KMZ/DWG/STL…)', '', 'Mô hình 3D|*.dae;*.3ds;*.kmz;*.dwg;*.dxf;*.stl;*.ifc;*.obj;*.fbx||')
        return unless path
        defer do
          begin
            Inserter.import_3d(Util.utf8(path))
            status('Đã nhập. Kiểm tra lại tỉ lệ (Tape Measure) và vật liệu sau khi đặt.', 'ok')
          rescue StandardError => ex
            status("Không nhập được: #{ex.message}", 'error')
          end
        end
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
        emit('secrets', secrets_state)
        status('Đã xóa key khỏi phiên và khỏi máy.', 'ok')
      end

      def save_settings(patch)
        before_quick = @settings['quick_scan']
        @settings.apply_ui(patch)
        @settings.save
        @index.bump
        emit('settings', @settings.public_hash)
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
        @downloads[uid] = { 'state' => 'requesting', 'progress' => { 'bytes' => 0, 'total' => 0 } }
        emit('dl_state', { 'uid' => uid, 'state' => 'requesting' })
        hdr = { 'Authorization' => Sketchfab.auth_header(token, @settings['sketchfab']['token_type']), 'Accept' => 'application/json' }
        @http.request(url: Sketchfab.download_url(uid), headers: hdr, timeout: net_timeout) do |res|
          if !res.ok
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
            importable = files.select { |f| %w[skp import].include?(f['kind']) }
            note = if importable.empty?
                     "Đã tải #{fmt.upcase}. SketchUp 2022 KHÔNG nhập trực tiếp glTF/GLB/USDZ — cần chuyển đổi (ví dụ Blender xuất DAE) rồi dùng \"Nhập file 3D\"."
                   else
                     'Đã tải. Có file SketchUp nhập được bên dưới; kiểm tra tỉ lệ và vật liệu sau khi chèn.'
                   end
            @downloads[uid]['state'] = 'done'
            emit('dl_state', { 'uid' => uid, 'state' => 'done', 'folder' => folder, 'files' => files.first(40), 'note' => note })
          else
            @downloads[uid]['state'] = 'error'
            emit('dl_state', { 'uid' => uid, 'state' => 'error', 'msg' => HttpClient.friendly(res) })
          end
        end
      end

      # Giải nén an toàn (nếu là ZIP) và phân loại file nhập được.
      def post_process_download(path, folder)
        out = []
        if path =~ /\.zip\z/i
          begin
            zip = ZipReader.new(path)
            ex_dir = File.join(folder, 'extracted')
            zip.entries.reject(&:directory?).each do |e|
              target = File.join(ex_dir, e.name)
              FileUtils.mkdir_p(File.dirname(target))
              File.open(target, 'wb') { |f| f.write(zip.read(e)) }
            end
            Dir.glob(File.join(ex_dir, '**', '*')).select { |f| File.file?(f) }.each { |f| out << classify(f) }
          rescue StandardError => e
            @log.warn("Không giải nén #{path}: #{e.message}")
            out << classify(path)
          end
        else
          out << classify(path)
        end
        out.sort_by { |f| { 'skp' => 0, 'import' => 1, 'other' => 2 }[f['kind']] }
      end

      def classify(f)
        ext = File.extname(f).downcase
        kind = if ext == '.skp' then 'skp'
               elsif %w[.dae .3ds .kmz .stl .dwg .dxf].include?(ext) then 'import'
               else 'other'
               end
        { 'path' => f, 'name' => File.basename(f), 'kind' => kind, 'size' => File.size(f) }
      end

      def open_download_folder(uid)
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

      def busy?
        !@cache_thread.nil? || @indexer.running? || @http.busy? ||
          @updater.busy? || @thumbs.pending?
      end

      def tick
        return if @ticking
        @ticking = true
        begin
          give_threads_time
          poll_cache_load
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
        ts = [@cache_thread, @indexer.thread, @updater.thread].compact + @http.threads
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
          emit('dl_progress', { 'uid' => uid, 'bytes' => d['progress']['bytes'], 'total' => d['progress']['total'] })
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
