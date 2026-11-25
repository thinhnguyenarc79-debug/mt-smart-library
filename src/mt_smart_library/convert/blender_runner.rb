# frozen_string_literal: true
require 'fileutils'

module MTDesign
  module SmartLibrary
    # Chạy Blender (hoặc tiến trình bất kỳ) ở nền với DANH SÁCH đối số — không bao giờ ghép lệnh shell.
    # - Windows: CreateProcessW + CREATE_NO_WINDOW (không hiện cửa sổ console) qua Fiddle; lỗi Fiddle -> Process.spawn.
    # - Nơi khác / dự phòng: Process.spawn([exe, exe], *args) (không qua shell), stdout/stderr ghi ra file log.
    # Không chặn SketchUp: chỉ khởi chạy rồi poll trạng thái từ UI timer. Có timeout và hủy.
    class BlenderRunner
      Job = Struct.new(:id, :pid, :handle, :started, :timeout, :log_path, :state, :exit_code, :error, :mode)

      def initialize(logger = nil)
        @log = logger
        @jobs = {}
        @seq = 0
      end

      def busy?
        @jobs.values.any? { |j| j.state == :running }
      end

      # argv: [exe, arg1, arg2, ...]. Trả id job.
      def start(argv, timeout:, log_path:, cwd: nil)
        argv = argv.map(&:to_s)
        raise ArgumentError, 'Thiếu chương trình' if argv.empty? || argv[0].empty?
        FileUtils.mkdir_p(File.dirname(log_path))
        @seq += 1
        job = Job.new(@seq, nil, nil, Time.now, timeout.to_f, log_path, :running, nil, nil, nil)
        if WinProc.available?
          begin
            job.handle = WinProc.spawn(argv, cwd: cwd)
            job.mode = :win
          rescue StandardError => e
            @log&.warn("CreateProcessW lỗi (#{e.message}) — dùng Process.spawn")
          end
        end
        unless job.handle
          opts = { out: [log_path, 'w'], err: %i[child out], in: File::NULL }
          opts[:chdir] = cwd if cwd
          opts[:new_pgroup] = true if Util::WINDOWS
          job.pid = Process.spawn([argv[0], argv[0]], *argv[1..-1], opts)
          job.mode = :spawn
        end
        @jobs[job.id] = job
        job.id
      end

      # Trả Job (state :running/:done/:failed/:timeout/:cancelled).
      def poll(id)
        job = @jobs[id]
        return nil unless job
        return job unless job.state == :running
        code = job.mode == :win ? WinProc.poll(job.handle) : spawn_poll(job)
        if code.nil?
          if job.timeout.positive? && Time.now - job.started > job.timeout
            kill(job)
            job.state = :timeout
          end
        else
          job.exit_code = code
          job.state = code.zero? ? :done : :failed
          WinProc.close(job.handle) if job.mode == :win
        end
        job
      end

      def cancel(id)
        job = @jobs[id]
        return unless job && job.state == :running
        kill(job)
        job.state = :cancelled
      end

      def cancel_all
        @jobs.each_key { |id| cancel(id) }
      end

      def forget(id)
        @jobs.delete(id)
      end

      def log_tail(id, lines = 15)
        job = @jobs[id]
        return '' unless job && File.file?(job.log_path)
        Util.utf8(File.binread(job.log_path)).split("\n").last(lines).join("\n")
      rescue StandardError
        ''
      end

      private

      def spawn_poll(job)
        pid, status = Process.waitpid2(job.pid, Process::WNOHANG)
        return nil unless pid
        status.exitstatus || 1
      rescue Errno::ECHILD
        job.exit_code || 1
      end

      def kill(job)
        if job.mode == :win
          WinProc.kill(job.handle)
          WinProc.close(job.handle)
        else
          begin
            Process.kill(Util::WINDOWS ? :KILL : :TERM, job.pid)
            sleep 0.05
            Process.kill(:KILL, job.pid) unless Util::WINDOWS
          rescue StandardError
            nil
          end
          begin
            Process.waitpid(job.pid, Process::WNOHANG)
          rescue StandardError
            nil
          end
        end
      end
    end

    # Win32: CreateProcessW với CREATE_NO_WINDOW. Đối số được trích dẫn theo quy tắc CommandLineToArgvW.
    module WinProc
      CREATE_NO_WINDOW = 0x08000000
      CREATE_UNICODE_ENVIRONMENT = 0x00000400
      WAIT_TIMEOUT = 0x102
      STILL_ACTIVE = 259

      module_function

      def available?
        Util::WINDOWS && api ? true : false
      end

      def api
        return @api if defined?(@api)
        @api = begin
          require 'fiddle'
          k = Fiddle.dlopen('kernel32')
          v = Fiddle::TYPE_VOIDP
          i = Fiddle::TYPE_INT
          {
            create: Fiddle::Function.new(k['CreateProcessW'], [v, v, v, v, i, i, v, v, v, v], i),
            wait: Fiddle::Function.new(k['WaitForSingleObject'], [v, i], i),
            code: Fiddle::Function.new(k['GetExitCodeProcess'], [v, v], i),
            term: Fiddle::Function.new(k['TerminateProcess'], [v, i], i),
            close: Fiddle::Function.new(k['CloseHandle'], [v], i)
          }
        rescue StandardError, LoadError
          nil
        end
      end

      # Quy tắc trích dẫn của CommandLineToArgvW (an toàn với dấu cách, dấu ngoặc kép, gạch chéo ngược).
      def quote(arg)
        a = arg.to_s
        return '""' if a.empty?
        return a unless a =~ /[\s"]/
        out = +'"'
        bs = 0
        a.each_char do |c|
          if c == '\\'
            bs += 1
          elsif c == '"'
            out << '\\' * (bs * 2 + 1) << '"'
            bs = 0
          else
            out << '\\' * bs << c
            bs = 0
          end
        end
        out << '\\' * (bs * 2) << '"'
      end

      def wide(str)
        (Util.utf8(str).encode('UTF-16LE') + "\0".encode('UTF-16LE')).b
      end

      def spawn(argv, cwd: nil)
        raise 'Fiddle không khả dụng' unless api
        cmd = argv.map { |x| quote(x) }.join(' ')
        app_w = wide(argv[0])
        cmd_w = wide(cmd)
        cmd_buf = Fiddle::Pointer.malloc(cmd_w.bytesize)
        cmd_buf[0, cmd_w.bytesize] = cmd_w
        cwd_buf = nil
        if cwd
          cw = wide(cwd)
          cwd_buf = Fiddle::Pointer.malloc(cw.bytesize)
          cwd_buf[0, cw.bytesize] = cw
        end
        si = Fiddle::Pointer.malloc(104)
        si[0, 104] = [104].pack('L') + "\0" * 100
        pi = Fiddle::Pointer.malloc(24)
        pi[0, 24] = "\0" * 24
        ok = api[:create].call(app_w, cmd_buf, nil, nil, 0, CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT, nil, cwd_buf, si, pi)
        raise 'CreateProcessW thất bại' if ok.zero?
        hproc, hthread, = pi[0, 24].unpack('QQLL')
        api[:close].call(hthread)
        { handle: hproc, keep: [cmd_buf, cwd_buf, si, pi] }
      end

      # nil nếu còn chạy, ngược lại mã thoát.
      def poll(h)
        return 1 unless h && h[:handle]
        return nil if api[:wait].call(h[:handle], 0) == WAIT_TIMEOUT
        buf = Fiddle::Pointer.malloc(4)
        buf[0, 4] = "\0\0\0\0"
        api[:code].call(h[:handle], buf)
        code = buf[0, 4].unpack1('L')
        code == STILL_ACTIVE ? nil : code
      end

      def kill(h)
        api[:term].call(h[:handle], 9) if h && h[:handle]
      rescue StandardError
        nil
      end

      def close(h)
        return unless h && h[:handle]
        api[:close].call(h[:handle])
        h[:handle] = nil
      rescue StandardError
        nil
      end
    end
  end
end
