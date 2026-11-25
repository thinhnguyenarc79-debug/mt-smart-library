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
        @device_pref = 'cpu'
        @crashes = []
        @broken = nil
        @probe = nil
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
        installing? || !@pending.empty? || !@probe.nil?
      end

      def status
        { 'installed' => installed?, 'installing' => installing?, 'step' => @step_label, 'progress' => progress,
          'error' => @error || @broken, 'device' => @device, 'device_pref' => @device_pref, 'gpu_probe' => gpu_probe, 'download_mb' => @cfg['runtime']['download_mb'],
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
      # Thiết bị: 'cpu' (mặc định, ổn định) | 'gpu' (DirectML — chỉ dùng sau khi kiểm tra trong tiến trình riêng).
      CRASH_WINDOW = 300
      CRASH_LIMIT = 2

      attr_reader :broken, :device_pref

      def device_pref=(v)
        v = v.to_s == 'gpu' ? 'gpu' : 'cpu'
        return if v == @device_pref
        old = @device_pref
        @device_pref = v
        FileUtils.rm_f(gpu_probe_file) if v == 'gpu' && old # người dùng chọn lại GPU: cho kiểm tra lại
        restart_worker if @worker # áp dụng thiết bị mới ở lần chạy sau
      end

      def gpu_probe_file
        File.join(work_dir, 'gpu_probe.json')
      end

      def gpu_probe
        read_json(gpu_probe_file)
      end

      # Thiết bị thực dùng: GPU chỉ khi người dùng chọn VÀ bài kiểm tra GPU đã đạt.
      def effective_device
        return 'cpu' unless @device_pref == 'gpu'
        pr = gpu_probe
        pr && pr['ok'] ? 'gpu' : 'cpu'
      end

      def available?
        installed? && !@broken
      end

      def worker_log
        File.join(work_dir, 'worker.log')
      end

      def worker_alive?
        return false unless @worker
        j = @runner.poll(@worker)
        j && j.state == :running
      end

      # Bỏ trạng thái lỗi khi người dùng chủ động tìm lại (chỉ thử lại 1 lần).
      def reset_broken
        return unless @broken
        @broken = nil
        @crashes = []
      end

      def ensure_worker
        return true if worker_alive? || @probe
        return false if @broken
        FileUtils.mkdir_p(jobs_dir)
        clean_jobs_dir unless @worker # phiên mới: dọn việc tồn đọng của lần chạy trước
        %w[worker.ready.json worker.error.json].each { |n| FileUtils.rm_f(File.join(jobs_dir, n)) }
        touch_heartbeat(true)
        if @device_pref == 'gpu' && gpu_probe.nil?
          start_probe
        else
          start_worker(effective_device)
        end
        true
      end

      def script
        File.join(@code_dir, 'ai_runtime', 'inference_worker.py')
      end

      def start_worker(dev)
        @worker_device = dev
        rlog("Khởi động tiến trình AI (#{dev.upcase})")
        @worker = @runner.start([python_exe, '-B', script, '--models', models_dir, '--data', work_dir, '--device', dev,
                                 '--log', worker_log], timeout: 0, log_path: File.join(work_dir, 'worker.out.log'), cwd: work_dir)
      end

      # Kiểm tra GPU trong tiến trình riêng; sập thì chỉ tiến trình kiểm tra chết.
      def start_probe
        FileUtils.rm_f(gpu_probe_file + '.out')
        rlog('Kiểm tra GPU (DirectML) trong tiến trình riêng')
        @probe = @runner.start([python_exe, '-B', script, '--models', models_dir, '--data', work_dir,
                                '--probe-gpu', gpu_probe_file + '.out', '--log', worker_log],
                               timeout: 180, log_path: File.join(work_dir, 'probe.out.log'), cwd: work_dir)
      end

      def poll_probe
        return unless @probe
        j = @runner.poll(@probe)
        return if j && j.state == :running
        out = read_json(gpu_probe_file + '.out')
        ok = j && j.state == :done && out && out['ok']
        res = { 'ok' => ok ? true : false, 'exit_code' => j && j.exit_code, 'code' => fmt_code(j && j.exit_code),
                'reason' => ok ? nil : ((out && out['reason']) || "GPU làm dừng tiến trình AI (mã #{fmt_code(j && j.exit_code)}) — dùng CPU."),
                'at' => Time.now.to_i }
        Util.atomic_write(gpu_probe_file, JSON.generate(res))
        rlog("Kết quả kiểm tra GPU: #{ok ? 'đạt' : res['reason']}")
        @runner.forget(@probe)
        @probe = nil
        @notice = res['reason'] unless ok
        start_worker(effective_device)
      end

      # Thông báo 1 lần cho giao diện (ví dụ: GPU không tương thích → đã dùng CPU).
      def take_notice
        n = @notice
        @notice = nil
        n
      end

      def restart_worker
        @runner.cancel(@worker) if @worker && worker_alive?
        @worker = nil
      end

      def submit(type, payload = {}, on_progress: nil, &done)
        unless installed? && ensure_worker
          done&.call('ok' => false, 'error' => @broken || 'Bộ AI chưa sẵn sàng.', 'broken' => true)
          return nil
        end
        @seq += 1
        id = format('%<t>012d_%<s>06d', t: (Time.now.to_f * 1000).to_i, s: @seq)
        job = payload.merge('type' => type)
        write_job(id, job)
        @pending[id] = { done: done, prog: on_progress, t: Time.now.to_f, job: job, retried: false }
        id
      end

      def write_job(id, job)
        Util.atomic_write(File.join(jobs_dir, "#{id}.job.json"), JSON.generate(job))
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
        poll_probe
        return if @pending.empty? && !@worker
        touch_heartbeat
        if (r = read_json(File.join(jobs_dir, 'worker.ready.json')))
          @device = r['device']
        end
        @pending.keys.each do |id|
          h = @pending[id]
          next unless h
          out = read_json(File.join(jobs_dir, "#{id}.out.json"))
          if out
            @pending.delete(id)
            FileUtils.rm_f(File.join(jobs_dir, "#{id}.out.json"))
            h[:done]&.call(out)
          elsif h[:prog] && (pr = read_json(File.join(jobs_dir, "#{id}.prog.json")))
            h[:prog].call(pr)
          end
        end
        handle_death if @worker && !@probe && !worker_alive?
      end

      # Tiến trình AI chết: ghi exit code, GPU sập → chạy lại bằng CPU và gửi lại việc dở; CPU sập liên tiếp → dừng hẳn
      # (không tạo vòng lặp việc lỗi), báo lỗi rõ kèm log.
      def handle_death
        j = @runner.poll(@worker)
        code = j && j.exit_code
        err = read_json(File.join(jobs_dir, 'worker.error.json'))
        dev = @worker_device
        @runner.forget(@worker)
        @worker = nil
        if code.to_i.zero? && err.nil? # tự thoát bình thường (rảnh lâu / SketchUp không còn heartbeat)
          rlog('Tiến trình AI tự thoát (rảnh)')
          return @pending.empty? ? nil : resubmit_pending
        end
        rlog("Tiến trình AI (#{dev.to_s.upcase}) dừng, mã thoát #{fmt_code(code)}#{err ? " — #{err['error']}" : ''}")
        if dev == 'gpu'
          Util.atomic_write(gpu_probe_file, JSON.generate('ok' => false, 'exit_code' => code, 'code' => fmt_code(code),
                                                          'reason' => "GPU làm dừng tiến trình AI (mã #{fmt_code(code)}) — đã chuyển sang CPU.",
                                                          'at' => Time.now.to_i))
          @notice = "GPU không ổn định (mã #{fmt_code(code)}) — đã tự chuyển sang CPU."
          return resubmit_pending
        end
        @crashes = (@crashes || []).select { |t| Time.now.to_f - t < CRASH_WINDOW } << Time.now.to_f
        if @crashes.size < CRASH_LIMIT && err.nil?
          return resubmit_pending # sập 1 lần: thử lại 1 lần
        end
        msg = if err
                hint = case err['kind']
                       when 'dll' then ' Cần cài Microsoft Visual C++ Redistributable (x64).'
                       when 'import' then ' Thư viện AI bị thiếu — mở Hỗ trợ kỹ thuật › Cài lại bộ AI.'
                       else ''
                       end
                "#{err['error']}#{hint}"
              else
                "Tiến trình AI dừng bất thường (mã #{fmt_code(code)}). #{log_tail(4)}".strip
              end
        @broken = msg
        clean_jobs_dir
        fail_all(msg)
      end

      def resubmit_pending
        ensure_worker
        @pending.each do |id, h|
          if h[:retried]
            @pending.delete(id)
            h[:done]&.call('ok' => false, 'error' => 'Tiến trình AI dừng khi đang xử lý việc này.')
          else
            h[:retried] = true
            write_job(id, h[:job]) unless File.file?(File.join(jobs_dir, "#{id}.job.json"))
          end
        end
      end

      def fail_all(msg)
        pend = @pending
        @pending = {}
        pend.each_value { |h| h[:done]&.call('ok' => false, 'error' => msg, 'broken' => true) }
      end

      def clean_jobs_dir
        Dir.glob(File.join(jobs_dir, '*.{job,out,prog}.json')).each { |f| FileUtils.rm_f(f) }
        Dir.glob(File.join(jobs_dir, '*.cancel')).each { |f| FileUtils.rm_f(f) }
        Dir.glob(File.join(jobs_dir, '*.tmp*')).each { |f| FileUtils.rm_f(f) }
      end

      def log_tail(n = 6)
        return '' unless File.file?(worker_log)
        lines = Util.utf8(File.binread(worker_log)).split("\n").last(200)
        lines.reject { |l| l.strip.empty? }.last(n).join(' | ')[0, 600]
      rescue StandardError
        ''
      end

      # Windows trả mã NTSTATUS dạng số không dấu (ví dụ 3221225477 = 0xC0000005 access violation).
      def fmt_code(code)
        return '?' if code.nil?
        c = code.to_i
        c = c & 0xFFFFFFFF if c.negative?
        c > 0x7FFFFFFF ? format('0x%08X', c) : c.to_s
      end

      def rlog(msg)
        FileUtils.mkdir_p(work_dir)
        File.open(worker_log, 'a:UTF-8') { |f| f.puts("[Ruby #{Time.now.strftime('%H:%M:%S')}] #{msg}") }
        @log&.info("AI: #{msg}")
      rescue SystemCallError
        nil
      end

      # Cài lại Python + thư viện (giữ nguyên mô hình đã tải: chỉ kiểm tra lại mã băm, không tải lại).
      def repair(&done)
        stop
        FileUtils.rm_f(marker)
        FileUtils.rm_f(File.join(@root, 'pip_ok'))
        reset_broken
        install(&done)
      end

      def stop
        @runner.cancel(@worker) if @worker
        @runner.cancel(@probe) if @probe
        @worker = nil
        @probe = nil
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
