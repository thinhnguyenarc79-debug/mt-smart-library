# frozen_string_literal: true
require 'json'
require 'fileutils'

module MTDesign
  module SmartLibrary
    # Một làn xử lý AI = 1 tiến trình worker + 1 thư mục công việc. Tự khởi động khi có việc, ghi mã thoát,
    # GPU sập → chạy lại CPU + gửi lại việc dở; sập liên tiếp → dừng hẳn, dọn hàng đợi, báo lỗi 1 lần (không lặp).
    class WorkerLane
      attr_reader :name, :broken, :device

      def initialize(rt, name, threads)
        @rt = rt
        @name = name
        @threads = threads
        @pending = {}
        @seq = 0
        @worker = nil
        @worker_device = nil
        @crashes = []
        @broken = nil
        @last_hb = 0
        @device = nil
      end

      def dir
        File.join(@rt.work_dir, 'jobs', @name)
      end

      def busy?
        !@pending.empty?
      end

      def alive?
        return false unless @worker
        j = @rt.runner.poll(@worker)
        j && j.state == :running
      end

      def reset_broken
        @broken = nil
        @crashes = []
      end

      def restart
        @rt.runner.cancel(@worker) if @worker && alive?
        @worker = nil
      end

      def stop
        restart
      end

      # Cập nhật nóng Python: khởi động lại tiến trình khi làn rảnh (không cắt ngang việc đang chạy).
      def restart_when_idle
        return restart if @pending.empty?
        @restart_pending = true
      end

      def submit(type, payload, on_progress: nil, &done)
        if @broken
          done&.call('ok' => false, 'error' => @broken, 'broken' => true)
          return nil
        end
        ensure_worker
        @seq += 1
        id = format('%<t>012d_%<s>06d_%<l>s', t: (Time.now.to_f * 1000).to_i, s: @seq, l: @name)
        job = payload.merge('type' => type)
        write_job(id, job)
        @pending[id] = { done: done, prog: on_progress, job: job, retried: false }
        id
      end

      def cancel(id)
        return unless @pending.key?(id)
        File.write(File.join(dir, "#{id}.cancel"), '1')
      rescue SystemCallError
        nil
      end

      def poll
        start_when_ready
        if @restart_pending && @pending.empty?
          @restart_pending = false
          restart
        end
        return if @pending.empty? && !@worker
        touch_heartbeat
        if (r = @rt.read_json(File.join(dir, 'worker.ready.json')))
          @device = r['device']
        end
        @pending.keys.each do |id|
          h = @pending[id]
          next unless h
          out = @rt.read_json(File.join(dir, "#{id}.out.json"))
          if out
            @pending.delete(id)
            FileUtils.rm_f(File.join(dir, "#{id}.out.json"))
            h[:done]&.call(out)
          elsif h[:prog] && (pr = @rt.read_json(File.join(dir, "#{id}.prog.json")))
            h[:prog].call(pr)
          end
        end
        handle_death if @worker && !alive?
      end

      private

      def write_job(id, job)
        FileUtils.mkdir_p(dir)
        Util.atomic_write(File.join(dir, "#{id}.job.json"), JSON.generate(job))
      end

      def ensure_worker
        return if @worker || @waiting
        FileUtils.mkdir_p(dir)
        clean_dir # phiên mới: dọn việc tồn đọng của lần chạy trước
        %w[worker.ready.json worker.error.json].each { |n| FileUtils.rm_f(File.join(dir, n)) }
        touch_heartbeat(true)
        @waiting = true
        @rt.start_probe if @rt.need_probe?
        start_when_ready
      end

      # Chờ bài kiểm tra GPU (nếu có) xong rồi mới khởi động worker.
      def start_when_ready
        return unless @waiting
        return if @rt.probing?
        @waiting = false
        start(@rt.effective_device)
      end

      def start(dev)
        @worker_device = dev
        @rt.rlog("Khởi động tiến trình AI làn #{@name} (#{dev.upcase})")
        env = @rt.env_provider ? @rt.env_provider.call(@name) : {}
        old = env.keys.map { |k| [k, ENV[k]] }.to_h
        env.each { |k, v| ENV[k] = v.to_s.empty? ? nil : v.to_s } # tiến trình con kế thừa; khôi phục ngay sau khi tạo
        @worker = @rt.runner.start([@rt.python_exe, '-B', @rt.script, '--models', @rt.models_dir, '--data', @rt.work_dir,
                                    '--jobs', dir, '--device', dev, '--threads', @threads.to_s, '--log', @rt.worker_log],
                                   timeout: 0, log_path: File.join(dir, 'worker.out.log'), cwd: @rt.work_dir)
      ensure
        old&.each { |k, v| ENV[k] = v }
      end

      def touch_heartbeat(force = false)
        now = Time.now.to_f
        return if !force && now - @last_hb < 5
        @last_hb = now
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, 'heartbeat'), now.to_s)
      rescue SystemCallError
        nil
      end

      def handle_death
        j = @rt.runner.poll(@worker)
        code = j && j.exit_code
        err = @rt.read_json(File.join(dir, 'worker.error.json'))
        dev = @worker_device
        @rt.runner.forget(@worker)
        @worker = nil
        if code.to_i.zero? && err.nil? # tự thoát bình thường (rảnh lâu / SketchUp đã đóng)
          @rt.rlog("Tiến trình AI làn #{@name} tự thoát (rảnh)")
          return @pending.empty? ? nil : resubmit
        end
        @rt.rlog("Tiến trình AI làn #{@name} (#{dev.to_s.upcase}) dừng, mã thoát #{@rt.fmt_code(code)}#{err ? " — #{err['error']}" : ''}")
        if dev == 'gpu'
          @rt.mark_gpu_failed(code)
          return resubmit
        end
        @crashes = @crashes.select { |t| Time.now.to_f - t < WorkerLaneCfg::CRASH_WINDOW } << Time.now.to_f
        return resubmit if @crashes.size < WorkerLaneCfg::CRASH_LIMIT && err.nil? # sập 1 lần: thử lại 1 lần
        msg = if err
                hint = { 'dll' => ' Cần cài Microsoft Visual C++ Redistributable (x64).',
                         'import' => ' Thư viện AI bị thiếu — mở Hỗ trợ kỹ thuật › Cài lại thành phần AI.' }[err['kind']].to_s
                "#{err['error']}#{hint}"
              else
                "Tiến trình AI dừng bất thường (mã #{@rt.fmt_code(code)}). #{@rt.log_tail(4)}".strip
              end
        @broken = msg
        clean_dir
        pend = @pending
        @pending = {}
        pend.each_value { |h| h[:done]&.call('ok' => false, 'error' => msg, 'broken' => true) }
      end

      def resubmit
        ensure_worker
        @pending.each do |id, h|
          if h[:retried]
            @pending.delete(id)
            h[:done]&.call('ok' => false, 'error' => 'Tiến trình AI dừng khi đang xử lý việc này.')
          else
            h[:retried] = true
            write_job(id, h[:job])
          end
        end
      end

      def clean_dir
        Dir.glob(File.join(dir, '*.{job,out,prog}.json')).each { |f| FileUtils.rm_f(f) }
        Dir.glob(File.join(dir, '*.cancel')).each { |f| FileUtils.rm_f(f) }
        Dir.glob(File.join(dir, '*.tmp*')).each { |f| FileUtils.rm_f(f) }
      end
    end

    module WorkerLaneCfg
      CRASH_WINDOW = 300
      CRASH_LIMIT = 2
    end
  end
end
