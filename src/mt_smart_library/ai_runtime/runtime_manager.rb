# frozen_string_literal: true
require 'json'
require 'digest'
require 'fileutils'

module MTDesign
  module SmartLibrary
    # Quản lý bộ AI tìm bằng ảnh chạy ngoài SketchUp:
    # - Cài 1 lần (sau khi người dùng đồng ý): Python nhúng (python.org) → pip (bootstrap.pypa.io) → onnxruntime/numpy/pillow (PyPI)
    #   → mô hình CLIP ONNX (Hugging Face, kiểm SHA256 / git SHA1). Lưu ở <dữ liệu>/ai_runtime, không mất khi cập nhật plugin.
    # - Chạy inference_worker.py thành tiến trình riêng (không cửa sổ), giao tiếp qua thư mục công việc.
    # Mọi bước chạy nền; poll() gọi từ timer main thread. Không gọi SketchUp API.
    class RuntimeManager
      attr_reader :root, :error, :state, :device

      def initialize(http:, runner:, data_root:, code_dir:, logger: nil)
        @http = http
        @runner = runner
        @root = File.join(data_root, 'ai_runtime')
        @code_dir = code_dir
        @log = logger
        @cfg = JSON.parse(File.read(File.join(code_dir, 'ai_runtime', 'model_config.json'), encoding: 'UTF-8'))
        @state = :idle
        @error = nil
        @pending = {}
        @seq = 0
        @worker = nil
        @last_hb = 0
        @device = nil
      end

      def cfg
        @cfg
      end

      def threads
        [@bg].compact
      end

      def work_dir
        File.join(@root, 'work')
      end

      def jobs_dir
        File.join(work_dir, 'jobs')
      end

      def python_dir
        File.join(@root, 'python')
      end

      def python_exe
        env = ENV['MT_AI_PYTHON'].to_s
        return env unless env.empty?
        File.join(python_dir, Util::WINDOWS ? 'python.exe' : 'bin/python3')
      end

      def models_dir
        env = ENV['MT_AI_MODELS'].to_s
        env.empty? ? File.join(@root, 'models', @cfg['model']['id']) : env
      end

      def marker
        File.join(@root, 'installed.json')
      end

      def installed?
        return false unless File.file?(python_exe)
        return File.file?(File.join(models_dir, 'vision_model.onnx')) unless ENV['MT_AI_PYTHON'].to_s.empty?
        File.file?(marker) && @cfg['model']['files'].all? { |f| File.size?(File.join(models_dir, f['name'])) == f['size'] }
      end

      def installing?
        @state == :installing
      end

      def busy?
        installing? || !@pending.empty?
      end

      def status
        { 'installed' => installed?, 'installing' => installing?, 'step' => @step_label, 'progress' => progress,
          'error' => @error, 'device' => @device, 'download_mb' => @cfg['runtime']['download_mb'],
          'model' => @cfg['model']['name'], 'license' => @cfg['model']['license'] }
      end

      # ================================================================ Cài đặt (1 lần)
      def install(&on_done)
        return on_done&.call(true, nil) if installed?
        return if installing?
        @state = :installing
        @error = nil
        @on_install = on_done
        FileUtils.mkdir_p(File.join(@root, 'dl'))
        @steps = []
        @steps += %i[python pth getpip pip] unless File.file?(python_exe) && pip_ok?
        @steps += @cfg['model']['files'].map { |f| [:model, f] }
        @steps << :finish
        next_step
      end

      def pip_ok?
        File.file?(File.join(@root, 'pip_ok'))
      end

      def progress
        return nil unless @dl
        tot = @dl['total'].to_i
        tot.positive? ? [(@dl['bytes'].to_i * 100 / tot), 100].min : nil
      end

      def next_step
        step = @steps.shift
        @dl = nil
        case step
        when :python then step_download(@cfg['runtime']['python_zip'], File.join(@root, 'dl', 'python.zip'), 'Đang tải Python…') { |p| step_extract(p) }
        when :pth then step_pth
        when :getpip then step_download(@cfg['runtime']['get_pip'], File.join(@root, 'dl', 'get-pip.py'), 'Đang tải pip…') { |p| run_py([p, '--no-warn-script-location'], 'Đang cài pip…') }
        when :pip then step_pip(@cfg['runtime']['packages'], true)
        when Array then step_model(step[1])
        when :finish
          File.write(marker, JSON.generate('version' => @cfg['version'], 'model' => @cfg['model']['id'], 'at' => Time.now.to_i))
          finish(true, nil)
        end
      rescue StandardError => e
        finish(false, e.message)
      end

      def finish(ok, err)
        @state = :idle
        @error = err
        @step_label = nil
        @bg = nil
        @proc = nil
        cb = @on_install
        @on_install = nil
        @log&.info(ok ? 'Đã cài bộ AI tìm bằng ảnh' : "Cài bộ AI lỗi: #{err}")
        cb&.call(ok, err)
      end

      def step_download(url, dest, label, &after)
        @step_label = label
        @dl = { 'bytes' => 0, 'total' => 0 }
        @http.request(url: url, dest: dest, timeout: 120, progress: @dl) do |res|
          if res.ok
            after.call(dest)
          else
            finish(false, "#{label.sub('Đang ', 'Không ').sub('…', '')} được (#{HttpClient.friendly(res)}).")
          end
        end
      end

      def step_extract(zip)
        @step_label = 'Đang giải nén Python…'
        @bg = bg_thread do
          FileUtils.rm_rf(python_dir)
          ImportManager.extract_zip(zip, python_dir)
        end
      end

      # Bật site-packages cho Python nhúng (theo tài liệu python.org về gói embeddable).
      def step_pth
        pth = File.join(python_dir, @cfg['runtime']['python_pth'])
        raise "Thiếu #{File.basename(pth)} trong gói Python." unless File.file?(pth)
        lines = File.read(pth).lines.map(&:chomp).map { |l| l.strip == '#import site' ? 'import site' : l }
        lines << 'import site' unless lines.include?('import site')
        lines.insert(0, 'Lib\\site-packages') unless lines.include?('Lib\\site-packages')
        File.write(pth, lines.join("\r\n") + "\r\n")
        next_step
      end

      def step_pip(pkgs, first)
        @pip_first = first
        run_py(['-m', 'pip', 'install', '--no-warn-script-location', '--disable-pip-version-check', *pkgs],
               'Đang cài ONNX Runtime…', pip: true)
      end

      def run_py(args, label, pip: false)
        @step_label = label
        log = File.join(@root, 'install.log')
        @proc = { id: @runner.start([python_exe, *args], timeout: 1800, log_path: log, cwd: @root), pip: pip }
      end

      def step_model(f)
        dest = File.join(models_dir, f['name'])
        FileUtils.mkdir_p(models_dir)
        if File.size?(dest) == f['size']
          return verify_bg(dest, f)
        end
        step_download(f['url'], dest + '.part', "Đang tải mô hình AI (#{f['name']})…") do |p|
          verify_bg(p, f, dest)
        end
      end

      def verify_bg(path, f, final = nil)
        @step_label = 'Đang kiểm tra toàn vẹn mô hình…'
        @bg = bg_thread do
          raise "Sai dung lượng #{f['name']}" unless File.size(path) == f['size']
          ok = if f['sha256']
                 Digest::SHA256.file(path).hexdigest == f['sha256']
               else
                 d = Digest::SHA1.new
                 d << "blob #{f['size']}\0"
                 File.open(path, 'rb') { |io| d << io.read(1 << 20) until io.eof? }
                 d.hexdigest == f['git_sha1']
               end
          unless ok
            File.delete(path)
            raise "File #{f['name']} tải về không khớp mã kiểm tra — đã xóa."
          end
          File.rename(path, final) if final
        end
      end

      # Luồng nền không ném ngoại lệ ra ngoài (join ở timer không bị gián đoạn); lỗi lưu ở thread[:error].
      def bg_thread
        Thread.new do
          Thread.current.report_on_exception = false
          begin
            yield
          rescue StandardError => e
            Thread.current[:error] = e.message
          end
        end
      end

      # ================================================================ Tiến trình AI
      def worker_alive?
        return false unless @worker
        j = @runner.poll(@worker)
        j && j.state == :running
      end

      def ensure_worker
        return true if worker_alive?
        FileUtils.mkdir_p(jobs_dir)
        %w[worker.ready.json worker.error.json].each { |n| FileUtils.rm_f(File.join(jobs_dir, n)) }
        touch_heartbeat(true)
        script = File.join(@code_dir, 'ai_runtime', 'inference_worker.py')
        @worker = @runner.start([python_exe, '-B', script, '--models', models_dir, '--data', work_dir,
                                 '--log', File.join(work_dir, 'worker.log')], timeout: 0, log_path: File.join(work_dir, 'worker.out.log'),
                                cwd: work_dir)
        true
      end

      def submit(type, payload = {}, on_progress: nil, &done)
        ensure_worker
        @seq += 1
        id = format('%<t>012d_%<s>06d', t: (Time.now.to_f * 1000).to_i, s: @seq)
        job = payload.merge('type' => type)
        path = File.join(jobs_dir, "#{id}.job.json")
        Util.atomic_write(path, JSON.generate(job))
        @pending[id] = { done: done, prog: on_progress, t: Time.now.to_f }
        id
      end

      def cancel(id)
        return unless id && @pending.key?(id)
        File.write(File.join(jobs_dir, "#{id}.cancel"), '1')
      rescue SystemCallError
        nil
      end

      def touch_heartbeat(force = false)
        now = Time.now.to_f
        return if !force && now - @last_hb < 5
        @last_hb = now
        FileUtils.mkdir_p(jobs_dir)
        File.write(File.join(jobs_dir, 'heartbeat'), now.to_s)
      rescue SystemCallError
        nil
      end

      def poll
        poll_install
        return if @pending.empty? && !worker_alive?
        touch_heartbeat
        if (r = read_json(File.join(jobs_dir, 'worker.ready.json')))
          @device = r['device']
        end
        err = read_json(File.join(jobs_dir, 'worker.error.json'))
        dead = !worker_alive?
        @pending.keys.each do |id|
          h = @pending[id]
          out = read_json(File.join(jobs_dir, "#{id}.out.json"))
          if out
            @pending.delete(id)
            FileUtils.rm_f(File.join(jobs_dir, "#{id}.out.json"))
            h[:done]&.call(out)
          elsif err || dead
            @pending.delete(id)
            h[:done]&.call('ok' => false, 'error' => (err && err['error']) || 'Tiến trình AI đã dừng bất thường.')
          elsif h[:prog] && (pr = read_json(File.join(jobs_dir, "#{id}.prog.json")))
            h[:prog].call(pr)
          end
        end
      end

      def stop
        @runner.cancel(@worker) if @worker
        @worker = nil
      end

      private

      def poll_install
        return unless installing?
        if @bg && !@bg.alive?
          t = @bg
          @bg = nil
          t[:error] ? finish(false, t[:error]) : next_step
        elsif @proc
          j = @runner.poll(@proc[:id])
          return if j.nil? || j.state == :running
          pr = @proc
          @proc = nil
          if j.state == :done
            File.write(File.join(@root, 'pip_ok'), '1') if pr[:pip]
            next_step
          elsif pr[:pip] && @pip_first
            step_pip(@cfg['runtime']['packages_fallback'], false) # không có bản DirectML → bản CPU
          else
            finish(false, "Cài thành phần AI lỗi (mã #{j.exit_code || j.state}). Xem #{File.join(@root, 'install.log')}")
          end
        end
      end

      def read_json(path)
        return nil unless File.file?(path)
        JSON.parse(File.read(path, encoding: 'UTF-8'))
      rescue JSON::ParserError, SystemCallError
        nil
      end
    end
  end
end
