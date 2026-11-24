# frozen_string_literal: true
require 'fileutils'
require 'json'
require 'digest'
require 'uri'

module MTDesign
  module SmartLibrary
    # MT SMART UPDATE SYSTEM
    # - Cập nhật từ file RBZ/ZIP hoặc từ manifest online (URL riêng / GitHub Releases).
    # - Kiểm tra cấu trúc, PLUGIN_ID, phiên bản, tương thích, đường dẫn nguy hiểm, SHA256.
    # - Sao lưu bản đang chạy -> cài đè -> kiểm tra -> tự khôi phục nếu lỗi.
    # - KHÔNG nạp lại mã nóng (không load/reload) => không trùng menu/toolbar/callback.
    #   Bản mới có hiệu lực sau khi người dùng tự khởi động lại SketchUp.
    # - Phần filesystem chạy luồng nền; mọi SketchUp API ở main thread (App truyền thông tin vào).
    class Updater
      CODE = Paths::CODE_DIR_NAME
      LOADER = Paths::LOADER_NAME
      REQUIRED = [LOADER, "#{CODE}/main.rb", "#{CODE}/updater/version.rb", "#{CODE}/updater/update_manifest.json"].freeze
      STEPS = ['Kiểm tra gói', 'Sao lưu bản hiện tại', 'Giải nén', 'Cài đặt', 'Kiểm tra sau cài', 'Hoàn tất'].freeze
      MAX_DOWNLOAD = 100 * 1024 * 1024

      attr_reader :backups

      def initialize(logger:, http: nil, plugins_root: Paths.plugins_root, data_root: Paths.data_root)
        @log = logger
        @http = http
        @plugins_root = plugins_root
        @data_root = data_root
        @updates_dir = File.join(data_root, 'updates')
        @backups = BackupManager.new(File.join(data_root, 'backups'), plugins_root, logger)
        @history_path = File.join(data_root, 'update_history.json')
        @state_path = File.join(data_root, 'update_state.json')
        @mutex = Mutex.new
        @events = []
        @thread = nil
        @progress = nil
        @last_manifest = nil
        FileUtils.mkdir_p(@updates_dir)
      end

      def busy?
        (@thread && @thread.alive?) || @downloading ? true : false
      end

      def thread
        @thread
      end

      def events
        @mutex.synchronize do
          e = @events
          @events = []
          e
        end
      end

      def progress
        @mutex.synchronize { @progress && JSON.parse(JSON.generate(@progress)) }
      end

      # ---------------------------------------------------------------- Kiểm tra gói
      # Trả Hash thông tin gói; raise với thông báo tiếng Việt nếu gói không hợp lệ.
      def inspect_package(path, su_major: MIN_SKETCHUP)
        path = Util.utf8(path)
        ext = File.extname(path).downcase
        raise 'Chỉ chấp nhận file .rbz hoặc .zip.' unless %w[.rbz .zip].include?(ext)
        zip = ZipReader.new(path)
        files = zip.entries.reject(&:directory?)
        prefix = detect_prefix(files.map(&:name))
        install = {}
        files.each do |e|
          next unless e.name.start_with?(prefix)
          rel = e.name[prefix.length..-1]
          next unless rel == LOADER || rel.start_with?("#{CODE}/")
          install[rel] = e
        end
        missing = REQUIRED.reject { |r| install.key?(r) }
        raise "Gói thiếu file bắt buộc: #{missing.join(', ')}" unless missing.empty?
        loader_src = Util.utf8(zip.read(install[LOADER]))
        version_src = Util.utf8(zip.read(install["#{CODE}/updater/version.rb"]))
        manifest = parse_manifest_json(zip.read(install["#{CODE}/updater/update_manifest.json"]), embedded: true)
        info = describe(loader_src, version_src, manifest, su_major)
        info.merge('file' => path, 'prefix' => prefix, 'files' => install.size,
                   'bytes' => install.values.sum(&:usize), 'sha256' => Digest::SHA256.file(path).hexdigest, 'kind' => 'file')
      rescue ZipReader::Error => e
        raise "Gói không hợp lệ: #{e.message}"
      end

      # Thông tin của bản sao lưu (dùng khi khôi phục).
      def inspect_backup(id, su_major: MIN_SKETCHUP)
        b = @backups.find(id.to_s)
        raise 'Không tìm thấy bản sao lưu.' unless b
        dir = b['path']
        loader_src = File.read(File.join(dir, LOADER), encoding: 'UTF-8')
        version_src = File.read(File.join(dir, CODE, 'updater', 'version.rb'), encoding: 'UTF-8')
        mf = File.join(dir, CODE, 'updater', 'update_manifest.json')
        manifest = File.file?(mf) ? parse_manifest_json(File.binread(mf), embedded: true) : {}
        describe(loader_src, version_src, manifest, su_major).merge('backup_id' => id, 'path' => dir, 'kind' => 'backup',
                                                                    'created_at' => b['created_at'])
      end

      def describe(loader_src, version_src, manifest, su_major)
        unless loader_src.include?('SketchupExtension.new') && loader_src.include?("#{CODE}/main")
          raise 'File loader trong gói không phải loader của MT SMART LIBRARY PRO.'
        end
        pid = version_src[/PLUGIN_ID\s*=\s*'([^']+)'/, 1]
        ver = version_src[/VERSION\s*=\s*'([^']+)'/, 1]
        raise "Sai mã định danh plugin (#{pid || 'không có'}). Gói này không phải của #{PRODUCT_NAME}." unless pid == PLUGIN_ID
        raise "Số phiên bản trong gói không hợp lệ: #{ver.inspect}" unless VersionUtil.valid?(ver)
        if manifest['plugin_id'] && manifest['plugin_id'] != PLUGIN_ID
          raise 'update_manifest.json trong gói mang mã định danh khác.'
        end
        if manifest['version'] && manifest['version'] != ver
          raise "Phiên bản trong manifest (#{manifest['version']}) khác version.rb (#{ver})."
        end
        min_su = (version_src[/MIN_SKETCHUP\s*=\s*(\d+)/, 1] || manifest['min_sketchup'] || MIN_SKETCHUP).to_i
        min_rb = version_src[/MIN_RUBY\s*=\s*'([^']+)'/, 1] || manifest['min_ruby'] || MIN_RUBY
        ok, why = compatible?(min_su, manifest['max_sketchup'], min_rb, su_major)
        cmp = VersionUtil.compare(ver, VERSION)
        { 'plugin_id' => pid, 'version' => ver, 'current' => VERSION, 'compare' => cmp,
          'relation' => cmp > 0 ? 'newer' : (cmp.zero? ? 'same' : 'older'),
          'compatible' => ok, 'compat_message' => why, 'min_sketchup' => min_su, 'min_ruby' => min_rb,
          'changelog' => manifest['changelog'] || [], 'released_at' => manifest['released_at'].to_s }
      end

      def compatible?(min_su, max_su, min_rb, su_major)
        if su_major.to_i < min_su.to_i
          return [false, "Cần SketchUp 20#{min_su} trở lên (đang dùng 20#{su_major})."]
        end
        if max_su && max_su.to_i > 0 && su_major.to_i > max_su.to_i
          return [false, "Bản này chỉ hỗ trợ tới SketchUp 20#{max_su}."]
        end
        if VersionUtil.compare(RUBY_VERSION, min_rb.to_s) < 0
          return [false, "Cần Ruby #{min_rb} trở lên (đang có #{RUBY_VERSION})."]
        end
        [true, "Tương thích SketchUp 20#{su_major}, Ruby #{RUBY_VERSION}."]
      end

      # ---------------------------------------------------------------- Cài đặt (luồng nền)
      # source: {'kind'=>'file','file'=>...} hoặc {'kind'=>'backup','backup_id'=>...}
      def start_install(info, reason)
        return false if busy?
        set_progress(0, 'running', 'Bắt đầu…')
        @thread = Thread.new do
          Thread.current.report_on_exception = false
          run_install(info, reason)
        end
        true
      end

      def run_install(info, reason)
        staging = nil
        backup = nil
        installed = false
        t0 = Time.now
        log_update("=== #{reason}: #{VERSION} -> #{info['version']} (#{info['kind']}) ===")
        raise "Gói không tương thích: #{info['compat_message']}" unless info['compatible']
        set_progress(0, 'running', 'Đang kiểm tra lại gói…')
        source_dir = if info['kind'] == 'backup'
                       info['path']
                     else
                       recheck = inspect_package(info['file'])
                       raise 'Gói đã bị thay đổi kể từ lúc kiểm tra.' unless recheck['sha256'] == info['sha256']
                       nil
                     end
        set_progress(1, 'running', 'Đang sao lưu phiên bản hiện tại…')
        backup = @backups.create(VERSION, "Trước khi #{reason} lên #{info['version']}")
        log_update("Sao lưu: #{backup}")
        set_progress(2, 'running', 'Đang giải nén gói…')
        if source_dir.nil?
          staging = File.join(@updates_dir, "staging_#{Time.now.strftime('%Y%m%d%H%M%S')}_#{rand(10_000)}")
          extract(info['file'], staging)
          source_dir = staging
        end
        set_progress(3, 'running', 'Đang cài đè phiên bản mới…')
        apply_tree(source_dir)
        installed = true
        set_progress(4, 'running', 'Đang kiểm tra file sau cài…')
        verify_tree!(source_dir)
        write_state('pending_version' => info['version'], 'from' => VERSION, 'at' => Time.now.to_i, 'reason' => reason)
        add_history('ok', reason, info['version'], backup, nil)
        log_update("Thành công sau #{(Time.now - t0).round(1)}s")
        set_progress(5, 'done', "Đã cài #{info['version']}. Khởi động lại SketchUp để áp dụng.")
        push(:install_done, { 'version' => info['version'], 'backup' => File.basename(backup.to_s), 'reason' => reason })
      rescue Exception => e # rubocop:disable Lint/RescueException
        msg = e.message.to_s
        @log&.error("Cập nhật thất bại", e)
        log_update("LỖI: #{e.class}: #{msg}")
        rollback_msg = nil
        if backup && installed_or_partial?(installed)
          begin
            apply_tree(backup)
            verify_tree!(backup)
            rollback_msg = 'Đã tự động khôi phục phiên bản trước từ bản sao lưu.'
            log_update('Khôi phục tự động thành công.')
          rescue Exception => re # rubocop:disable Lint/RescueException
            rollback_msg = "KHÔNG khôi phục tự động được (#{re.message}). Bản sao lưu nằm tại: #{backup}"
            log_update("Khôi phục tự động LỖI: #{re.message}")
          end
        end
        add_history('failed', reason, info && info['version'], backup, msg)
        set_progress(@progress ? @progress['step'] : 0, 'failed', msg)
        push(:install_failed, { 'error' => msg, 'rollback' => rollback_msg })
      ensure
        FileUtils.rm_rf(staging) if staging
        cleanup_temp_dirs
      end

      def installed_or_partial?(_installed)
        true # bất kỳ lỗi nào sau khi sao lưu đều khôi phục để đảm bảo bản cài nhất quán
      end

      def extract(zip_path, dest)
        zip = ZipReader.new(zip_path)
        files = zip.entries.reject(&:directory?)
        prefix = detect_prefix(files.map(&:name))
        FileUtils.rm_rf(dest)
        files.each do |e|
          next unless e.name.start_with?(prefix)
          rel = e.name[prefix.length..-1]
          next unless rel == LOADER || rel.start_with?("#{CODE}/")
          raise "Đường dẫn nguy hiểm: #{rel}" if ZipReader.unsafe_reason(rel)
          out = File.join(dest, rel)
          real_dest = File.expand_path(dest)
          raise "Đường dẫn vượt khỏi thư mục giải nén: #{rel}" unless File.expand_path(out).start_with?(real_dest + '/')
          FileUtils.mkdir_p(File.dirname(out))
          File.open(out, 'wb') { |f| f.write(zip.read(e)) }
        end
        REQUIRED.each { |r| raise "Giải nén thiếu #{r}" unless File.file?(File.join(dest, r)) }
      end

      # Thay thư mục mã nguồn + loader bằng nội dung source_dir.
      def apply_tree(source_dir)
        src_code = File.join(source_dir, CODE)
        src_loader = File.join(source_dir, LOADER)
        raise 'Nguồn cài đặt thiếu thư mục mã nguồn.' unless File.directory?(src_code) && File.file?(src_loader)
        code = File.join(@plugins_root, CODE)
        new_tmp = code + '.__new__'
        old_tmp = code + '.__old__'
        FileUtils.rm_rf(new_tmp)
        FileUtils.cp_r(src_code, new_tmp)
        swapped = false
        begin
          FileUtils.rm_rf(old_tmp)
          File.rename(code, old_tmp) if File.exist?(code)
          begin
            File.rename(new_tmp, code)
            swapped = true
          rescue SystemCallError
            File.rename(old_tmp, code) if File.exist?(old_tmp) && !File.exist?(code)
            raise
          end
        rescue SystemCallError => e
          log_update("Đổi tên thư mục không được (#{e.message}) — chuyển sang ghi đè từng file.")
          overwrite_in_place(new_tmp, code)
        end
        Util.atomic_write(File.join(@plugins_root, LOADER), File.binread(src_loader))
        bak = File.join(@plugins_root, LOADER + '.bak')
        File.delete(bak) if File.exist?(bak) # tránh SketchUp nạp nhầm file thừa
        FileUtils.rm_rf(old_tmp) if swapped
        FileUtils.rm_rf(new_tmp)
      end

      def overwrite_in_place(src, dst)
        FileUtils.mkdir_p(dst)
        want = BackupManager.manifest_of(src)
        want.each_key do |rel|
          out = File.join(dst, rel)
          FileUtils.mkdir_p(File.dirname(out))
          FileUtils.cp(File.join(src, rel), out)
        end
        BackupManager.manifest_of(dst).each_key do |rel|
          File.delete(File.join(dst, rel)) unless want.key?(rel)
        end
      end

      def verify_tree!(source_dir)
        a = BackupManager.manifest_of(File.join(source_dir, CODE))
        b = BackupManager.manifest_of(File.join(@plugins_root, CODE))
        raise 'Kiểm tra sau cài thất bại: file trong thư mục plugin không khớp gói.' unless a == b
        l1 = Digest::SHA256.file(File.join(source_dir, LOADER)).hexdigest
        l2 = Digest::SHA256.file(File.join(@plugins_root, LOADER)).hexdigest
        raise 'Kiểm tra sau cài thất bại: loader không khớp.' unless l1 == l2
      end

      def cleanup_temp_dirs
        code = File.join(@plugins_root, CODE)
        [code + '.__new__', code + '.__old__'].each { |d| FileUtils.rm_rf(d) if File.exist?(d) }
        Dir.glob(File.join(@updates_dir, 'staging_*')).each { |d| FileUtils.rm_rf(d) }
      rescue StandardError
        nil
      end

      # ---------------------------------------------------------------- Online
      # Kiểm tra phiên bản mới (chỉ kiểm tra, KHÔNG tự cài). callback(:ok, info) / (:error, msg)
      def check_online(cfg, su_major, &cb)
        raise 'Chưa có HTTP client.' unless @http
        case cfg['source']
        when 'manifest'
          url = cfg['manifest_url'].to_s
          return cb.call(:error, 'Chưa cấu hình URL manifest (https://…/update_manifest.json).') unless url =~ %r{\Ahttps://\S+\z}
          fetch_manifest(url, su_major, &cb)
        when 'github'
          repo = cfg['github_repo'].to_s
          return cb.call(:error, 'Chưa cấu hình GitHub repo dạng chu-so-huu/ten-repo.') unless repo =~ %r{\A[\w.\-]+/[\w.\-]+\z}
          api = "https://api.github.com/repos/#{repo}/releases/latest"
          @http.request(url: api, headers: { 'Accept' => 'application/vnd.github+json', 'X-GitHub-Api-Version' => '2022-11-28' },
                        timeout: 20, max_body: 2_000_000) do |res|
            if !res.ok
              msg = res.code == 404 ? "Không tìm thấy release nào trong repo #{repo} (404)." : HttpClient.friendly(res)
              msg = 'GitHub giới hạn số lần gọi API (403/429). Thử lại sau.' if [403, 429].include?(res.code)
              cb.call(:error, msg)
            else
              rel = res.json || {}
              asset = Array(rel['assets']).find { |a| a.is_a?(Hash) && a['name'] == 'update_manifest.json' }
              if asset.nil?
                cb.call(:error, "Release #{rel['tag_name']} chưa có file update_manifest.json đính kèm.")
              else
                fetch_manifest(asset['browser_download_url'].to_s, su_major, &cb)
              end
            end
          end
        else
          cb.call(:error, 'Chưa cấu hình nguồn cập nhật online. Chọn "GitHub Releases" hoặc "URL manifest JSON" ở mục 2 ngay trong cửa sổ này rồi bấm "Lưu nguồn". Hiện vẫn có thể cập nhật từ file ở mục 1.')
        end
      end

      def fetch_manifest(url, su_major, &cb)
        @http.request(url: url, headers: { 'Accept' => 'application/json' }, timeout: 20, max_body: 1_000_000) do |res|
          if !res.ok
            cb.call(:error, "Không tải được manifest: #{HttpClient.friendly(res)}")
          else
            begin
              m = parse_manifest_json(res.body, embedded: false)
              ok, why = compatible?(m['min_sketchup'], m['max_sketchup'], m['min_ruby'], su_major)
              cmp = VersionUtil.compare(m['version'], VERSION)
              info = m.merge('current' => VERSION, 'compare' => cmp, 'compatible' => ok, 'compat_message' => why,
                             'relation' => cmp > 0 ? 'newer' : (cmp.zero? ? 'same' : 'older'))
              @last_manifest = info
              cb.call(:ok, info)
            rescue StandardError => e
              cb.call(:error, "Manifest không hợp lệ: #{e.message}")
            end
          end
        end
      end

      # Tải gói theo manifest đã kiểm tra, xác minh SHA256 rồi trả info gói (callback main thread).
      def download_package(manifest, &cb)
        raise 'Đang có tác vụ cập nhật khác.' if busy?
        m = @last_manifest
        raise 'Hãy kiểm tra cập nhật online trước.' unless m && m['version'] == manifest['version'] && m['sha256'] == manifest['sha256']
        dest = File.join(@updates_dir, 'downloads', "#{PLUGIN_ID}_#{m['version']}.rbz")
        prog = { 'bytes' => 0, 'total' => m['size'].to_i }
        @dl_progress = prog
        @downloading = true
        set_progress(0, 'running', 'Đang tải gói cập nhật…')
        @http.request(url: m['download_url'], dest: dest, timeout: 60, progress: prog) do |res|
          @downloading = false
          @dl_progress = nil
          if !res.ok
            cb.call(:error, "Tải gói thất bại: #{HttpClient.friendly(res)}")
          else
            begin
              sha = Digest::SHA256.file(dest).hexdigest
              raise "SHA256 không khớp (gói hỏng hoặc bị thay đổi). Mong đợi #{m['sha256'][0, 12]}…, nhận #{sha[0, 12]}…" unless sha == m['sha256']
              raise "Kích thước không khớp (#{File.size(dest)} ≠ #{m['size']})." if m['size'].to_i > 0 && File.size(dest) != m['size'].to_i
              raise 'Gói vượt quá 100 MB.' if File.size(dest) > MAX_DOWNLOAD
              cb.call(:ok, dest)
            rescue StandardError => e
              File.delete(dest) if File.exist?(dest)
              log_update("Gói online bị từ chối: #{e.message}")
              cb.call(:error, e.message)
            end
          end
        end
      end

      def download_progress
        @dl_progress && @dl_progress.dup
      end

      def parse_manifest_json(raw, embedded:)
        m = JSON.parse(Util.utf8(raw.to_s.dup.force_encoding(Encoding::UTF_8)))
        raise 'manifest không phải JSON object.' unless m.is_a?(Hash)
        out = {}
        out['schema'] = m['schema'].to_i.zero? ? 1 : m['schema'].to_i
        raise "Schema manifest #{out['schema']} chưa hỗ trợ." if out['schema'] > 1
        out['plugin_id'] = m['plugin_id'].to_s
        raise "plugin_id trong manifest (#{out['plugin_id']}) không phải #{PLUGIN_ID}." unless out['plugin_id'] == PLUGIN_ID
        out['version'] = m['version'].to_s
        raise 'Số phiên bản trong manifest không hợp lệ.' unless VersionUtil.valid?(out['version'])
        out['name'] = Util.utf8(m['name'] || PRODUCT_NAME)[0, 80]
        out['released_at'] = Util.utf8(m['released_at'])[0, 40]
        out['min_sketchup'] = (m['min_sketchup'] || MIN_SKETCHUP).to_i
        out['max_sketchup'] = m['max_sketchup'] ? m['max_sketchup'].to_i : nil
        out['min_ruby'] = (m['min_ruby'] || MIN_RUBY).to_s
        cl = m['changelog']
        cl = cl.split("\n") if cl.is_a?(String)
        out['changelog'] = Array(cl).map { |x| Util.utf8(x).strip[0, 300] }.reject(&:empty?).first(60)
        unless embedded
          url = m['download_url'].to_s
          raise 'download_url phải là liên kết https.' unless url =~ %r{\Ahttps://\S+\z}
          URI.parse(url)
          out['download_url'] = url
          sha = m['sha256'].to_s.downcase
          raise 'Thiếu sha256 hợp lệ (64 ký tự hex) — không thể kiểm tra toàn vẹn gói.' unless sha =~ /\A[0-9a-f]{64}\z/
          out['sha256'] = sha
          out['size'] = m['size'].to_i
        end
        out
      rescue JSON::ParserError => e
        raise "manifest JSON lỗi cú pháp: #{e.message[0, 120]}"
      end

      # ---------------------------------------------------------------- Trạng thái, lịch sử
      # Gọi lúc khởi động: báo kết quả lần cập nhật trước (nếu có).
      def startup_report
        st = read_json_safe(@state_path)
        return nil unless st.is_a?(Hash) && st['pending_version']
        File.delete(@state_path) if File.exist?(@state_path)
        if VersionUtil.compare(st['pending_version'], VERSION).zero?
          "Đã cập nhật thành công lên phiên bản #{VERSION} (từ #{st['from']})."
        else
          "Cảnh báo: đã cài #{st['pending_version']} nhưng SketchUp đang chạy #{VERSION}. Kiểm tra thư mục Plugins có file trùng không."
        end
      rescue StandardError
        nil
      end

      def pending_restart_version
        st = read_json_safe(@state_path)
        st.is_a?(Hash) ? st['pending_version'] : nil
      end

      def history
        h = read_json_safe(@history_path)
        h.is_a?(Array) ? h.first(50) : []
      end

      def log_path
        File.join(@data_root, 'logs', 'update.log')
      end

      def detect_prefix(names)
        return '' if names.include?(LOADER)
        cands = names.select { |n| n =~ %r{\A([^/]+/){1,2}#{Regexp.escape(LOADER)}\z} }
                     .map { |n| n[0, n.length - LOADER.length] }
                     .select { |p| names.include?("#{p}#{CODE}/updater/version.rb") }
        raise 'Không tìm thấy mt_smart_library.rb ở gốc gói (cấu trúc RBZ sai).' if cands.empty?
        raise 'Gói chứa nhiều bản plugin — không xác định được bản cần cài.' if cands.size > 1
        cands.first
      end

      private

      def push(type, payload)
        @mutex.synchronize { @events << [type, payload] }
      end

      def set_progress(step, status, message)
        @mutex.synchronize do
          @progress = { 'step' => step, 'steps' => STEPS, 'status' => status, 'message' => message, 'at' => Time.now.to_i }
        end
      end

      def write_state(h)
        Util.atomic_write(@state_path, JSON.generate(h))
      end

      def add_history(status, reason, version, backup, error)
        h = history
        h.unshift('at' => Time.now.strftime('%Y-%m-%d %H:%M:%S'), 'status' => status, 'reason' => reason, 'from' => VERSION,
                  'to' => version, 'backup' => backup ? File.basename(backup) : nil, 'error' => error)
        Util.atomic_write(@history_path, JSON.pretty_generate(h.first(50)))
      rescue StandardError => e
        @log&.error('Không ghi được lịch sử cập nhật', e)
      end

      def log_update(line)
        FileUtils.mkdir_p(File.dirname(log_path))
        File.open(log_path, 'ab') { |f| f.write("#{Time.now.strftime('%Y-%m-%d %H:%M:%S')} #{@log ? @log.redact(line) : line}\n") }
        @log&.info("[update] #{line}")
      rescue StandardError
        nil
      end

      def read_json_safe(path)
        Util.read_json(path)
      rescue StandardError
        nil
      end
    end
  end
end
