# frozen_string_literal: true
require 'fileutils'
require 'json'

module MTDesign
  module SmartLibrary
    # MT AUTO CONVERT ENGINE: chuyển FBX/OBJ/USDZ/GLB/glTF/STL/PLY/BLEND sang DAE bằng Blender chạy nền,
    # rồi SketchUp nhập DAE. Main thread chỉ khởi chạy + poll (không chặn SketchUp).
    class ConverterManager
      BLENDER_ARGS = ['--background', '--factory-startup', '--disable-autoexec', '--python-exit-code', '1'].freeze
      PROBE_TIMEOUT = 90

      attr_reader :cache, :runner

      def initialize(settings:, data_root:, logger: nil, script: nil)
        @settings = settings
        @log = logger
        @runner = BlenderRunner.new(logger)
        @cache = ModelCache.new(File.join(data_root, 'convert_cache'), logger)
        @work = File.join(data_root, 'convert_work')
        @script = script || File.join(Paths.code_dir, 'convert', 'convert_model.py')
        @jobs = {}
        @probe = nil
        @waiting = [] # yêu cầu chuyển đổi đang chờ tìm Blender
      end

      def cfg
        @settings['converter']
      end

      def busy?
        !@jobs.empty? || !@probe.nil?
      end

      def blender_status
        { 'path' => cfg['blender_path'], 'version' => cfg['blender_version'], 'ok' => cfg['blender_ok'],
          'reason' => cfg['blender_reason'], 'checking' => !@probe.nil? }
      end

      # Tìm & kiểm tra Blender (thử lần lượt các ứng viên cho tới khi có bản xuất được DAE). cb(status)
      def detect(preferred: nil, &cb)
        if @probe
          @probe[:cbs] << cb if cb
          return
        end
        cands = BlenderDetector.sort(BlenderDetector.candidates(preferred || cfg['blender_path']))
        cands.unshift(Util.norm_path(preferred)) if preferred && File.file?(preferred) && !cands.include?(Util.norm_path(preferred))
        @probe = { queue: cands.uniq, cbs: [cb].compact, tried: [] }
        next_probe
      end

      # cb.call(:ok, dae_path, report) | (:need_blender, lý do) | (:error, thông báo) | (:cancelled)
      def convert(input, &cb)
        key = @cache.key_for(input)
        if (dae = @cache.fetch(key))
          return cb.call(:ok, dae, @cache.meta(key).merge('cached' => true))
        end
        unless cfg['blender_ok'] && File.file?(cfg['blender_path'].to_s)
          @waiting << [input, cb]
          detect if @probe.nil?
          return :waiting
        end
        launch(input, key, cb)
      end

      def cancel_all
        @jobs.each_key { |id| @runner.cancel(id) }
        @waiting.each { |_, cb| safe(cb, :cancelled) }
        @waiting.clear
      end

      # Gọi từ UI timer (main thread).
      def poll
        poll_probe
        @jobs.keys.each do |id|
          job = @runner.poll(id)
          next if job.nil? || job.state == :running
          info = @jobs.delete(id)
          finish(job, info)
          @runner.forget(id)
        end
      end

      def set_blender(path, ok, version, reason)
        cfg['blender_path'] = path.to_s
        cfg['blender_ok'] = ok ? true : false
        cfg['blender_version'] = version.to_s
        cfg['blender_reason'] = reason.to_s
        @settings.save
      end

      private

      def launch(input, key, cb)
        tmp = "#{@cache.slot(key)}.part#{rand(10_000)}"
        FileUtils.rm_rf(tmp)
        FileUtils.mkdir_p(tmp)
        out = File.join(tmp, 'model.dae')
        report = File.join(tmp, 'report.json')
        argv = [cfg['blender_path']] + BLENDER_ARGS + ['--python', @script, '--', input, out, report]
        id = @runner.start(argv, timeout: cfg['timeout'].to_i, log_path: File.join(tmp, 'blender.log'))
        @jobs[id] = { cb: cb, key: key, tmp: tmp, out: out, report: report, input: input }
        @log&.info("Chuyển đổi bằng Blender: #{File.basename(input)}")
        :started
      end

      def finish(job, info)
        rep = begin
          JSON.parse(File.read(info[:report], encoding: 'UTF-8'))
        rescue StandardError
          {}
        end
        case job.state
        when :cancelled
          FileUtils.rm_rf(info[:tmp])
          return safe(info[:cb], :cancelled)
        when :timeout
          FileUtils.rm_rf(info[:tmp])
          return safe(info[:cb], :error, "Chuyển đổi quá thời gian (#{cfg['timeout']} giây) — model có thể quá nặng. Tăng thời gian chờ trong Cài đặt › Chuyển đổi.")
        end
        ok = job.state == :done && rep['ok'] == true && File.file?(info[:out]) && File.size(info[:out]).positive?
        unless ok
          tail = @runner.log_tail(job.id)
          @log&.warn("Blender lỗi (exit #{job.exit_code}): #{rep['error']} | #{tail.lines.last(4).join(' ')}")
          msg = rep['error'] || "Blender thoát với mã #{job.exit_code}."
          FileUtils.rm_rf(info[:tmp])
          return safe(info[:cb], :error, "Không chuyển đổi được: #{msg}")
        end
        final = @cache.slot(info[:key])
        FileUtils.rm_rf(final)
        File.rename(info[:tmp], final)
        @cache.commit(info[:key], rep.merge('source' => File.basename(info[:input])))
        safe(info[:cb], :ok, File.join(final, 'model.dae'), rep)
      rescue StandardError => e
        @log&.error('Hoàn tất chuyển đổi lỗi', e)
        safe(info[:cb], :error, e.message)
      end

      def next_probe
        pr = @probe
        exe = pr[:queue].shift
        unless exe
          cbs = pr[:cbs]
          @probe = nil
          reason = if pr[:tried].empty?
                     'Chưa tìm thấy Blender trên máy. Cài Blender 4.5 LTS (miễn phí) hoặc chọn blender.exe (bản Portable cũng được).'
                   else
                     pr[:tried].map { |t| t[:reason] }.compact.first || 'Không có bản Blender nào xuất được DAE.'
                   end
          set_blender(pr[:tried].first ? pr[:tried].first[:exe] : cfg['blender_path'], false, pr[:tried].first && pr[:tried].first[:version], reason)
          return probe_done(cbs)
        end
        dir = File.join(@work, 'probe')
        FileUtils.mkdir_p(dir)
        out = File.join(dir, "probe_#{rand(100_000)}.json")
        pr[:exe] = exe
        pr[:out] = out
        pr[:id] = @runner.start(BlenderDetector.probe_args(exe, out), timeout: PROBE_TIMEOUT, log_path: File.join(dir, 'probe.log'))
      rescue StandardError => e
        pr[:tried] << { exe: exe, reason: "Không chạy được #{exe}: #{e.message}" }
        next_probe
      end

      def poll_probe
        pr = @probe
        return unless pr && pr[:id]
        job = @runner.poll(pr[:id])
        return if job.nil? || job.state == :running
        @runner.forget(pr[:id])
        res = File.file?(pr[:out]) ? BlenderDetector.read_probe(pr[:out]) : { 'ok' => false, 'reason' => "Blender không phản hồi (#{job.state})." }
        File.delete(pr[:out]) if File.exist?(pr[:out])
        if res['ok']
          @probe = nil
          set_blender(pr[:exe], true, res['version_string'], nil)
          @log&.info("Dùng Blender #{res['version_string']}: #{pr[:exe]}")
          probe_done(pr[:cbs])
        else
          pr[:tried] << { exe: pr[:exe], reason: res['reason'], version: res['version_string'] }
          pr[:id] = nil
          next_probe
        end
      end

      def probe_done(cbs)
        st = blender_status
        Array(cbs).each { |c| safe(c, st) }
        waiting = @waiting
        @waiting = []
        waiting.each do |input, cb|
          if cfg['blender_ok']
            launch(input, @cache.key_for(input), cb)
          else
            safe(cb, :need_blender, cfg['blender_reason'])
          end
        end
      end

      def safe(cb, *args)
        cb&.call(*args)
      rescue StandardError => e
        @log&.error('Callback chuyển đổi lỗi', e)
      end
    end
  end
end
