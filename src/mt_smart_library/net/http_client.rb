# frozen_string_literal: true
require 'net/http'
require 'uri'
require 'openssl'
require 'json'
require 'fileutils'

module MTDesign
  module SmartLibrary
    # HTTP bất đồng bộ: Net::HTTP chạy trong luồng nền (có timeout), callback trả về ở main thread
    # qua poll() từ UI timer. Lỗi SSL trên máy Windows thiếu chứng chỉ -> thử lại bằng Sketchup::Http.
    class HttpClient
      Result = Struct.new(:ok, :code, :body, :headers, :error_kind, :error, :file, :url) do
        def json
          JSON.parse(body.to_s)
        rescue JSON::ParserError
          nil
        end
      end

      MAX_BODY = 8 * 1024 * 1024
      USER_AGENT = "MT-Smart-Library-Pro/#{VERSION} (SketchUp plugin; MT Design)"

      def initialize(logger = nil)
        @logger = logger
        @mutex = Mutex.new
        @done = []
        @jobs = {}
        @seq = 0
        @su_requests = {}
      end

      def busy?
        @mutex.synchronize { !@jobs.empty? || !@done.empty? } || !@su_requests.empty?
      end

      def threads
        @mutex.synchronize { @jobs.values.map { |j| j[:thread] }.compact }
      end

      # opts: method, url, headers, body, timeout, open_timeout, dest (file path), max_body,
      #       progress (Hash dùng chung để đọc tiến độ), allow_sketchup_fallback
      def request(opts, &callback)
        id = @mutex.synchronize { @seq += 1 }
        job = { opts: opts, callback: callback, cancel: false }
        @mutex.synchronize { @jobs[id] = job }
        job[:thread] = Thread.new do
          Thread.current.report_on_exception = false
          res = begin
            perform(opts, job)
          rescue Exception => e # rubocop:disable Lint/RescueException
            Result.new(false, 0, nil, {}, :internal, "#{e.class}: #{e.message}", nil, opts[:url])
          end
          @mutex.synchronize { @done << [id, res] }
        end
        id
      end

      def cancel(id)
        @mutex.synchronize { (j = @jobs[id]) && (j[:cancel] = true) }
      end

      def cancel_all
        @mutex.synchronize { @jobs.each_value { |j| j[:cancel] = true } }
        @su_requests.each_value { |r| r[:req].cancel rescue nil } # rubocop:disable Style/RescueModifier
        @su_requests.clear
      end

      # Main thread: gọi callback cho các request đã xong.
      def poll
        loop do
          item = @mutex.synchronize { @done.shift }
          break unless item
          id, res = item
          job = @mutex.synchronize { @jobs.delete(id) }
          next unless job
          if res.error_kind == :ssl && job[:opts][:allow_sketchup_fallback] != false && !job[:opts][:dest] && sketchup_http?
            @logger&.warn("SSL lỗi với Net::HTTP, thử Sketchup::Http: #{res.error}")
            start_sketchup_request(job)
            next
          end
          safe_callback(job, res)
        end
        check_sketchup_timeouts
      end

      def self.friendly(res)
        case res.error_kind
        when :timeout then 'Hết thời gian chờ máy chủ phản hồi (timeout). Kiểm tra mạng hoặc tăng timeout trong Cài đặt.'
        when :network then "Không kết nối được máy chủ (#{res.error}). Kiểm tra Internet/proxy/tường lửa."
        when :ssl then "Lỗi chứng chỉ SSL (#{res.error}). Kiểm tra ngày giờ máy tính hoặc phần mềm diệt virus chặn HTTPS."
        when :cancelled then 'Đã hủy.'
        when :too_large then 'Dữ liệu trả về quá lớn.'
        when :io then "Lỗi ghi file: #{res.error}"
        when :http then "Máy chủ trả lỗi HTTP #{res.code}."
        else "Lỗi kết nối: #{res.error}"
        end
      end

      private

      def safe_callback(job, res)
        job[:callback]&.call(res)
      rescue StandardError => e
        @logger&.error('Callback HTTP lỗi', e)
      end

      def perform(opts, job, redirects = 0)
        uri = URI.parse(opts[:url].to_s)
        return Result.new(false, 0, nil, {}, :internal, 'URL không hợp lệ', nil, opts[:url]) unless uri.is_a?(URI::HTTP) && uri.host
        timeout = (opts[:timeout] || 30).to_f
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == 'https')
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER if http.use_ssl?
        http.open_timeout = (opts[:open_timeout] || [timeout, 15].min).to_f
        http.read_timeout = timeout
        http.write_timeout = timeout if http.respond_to?(:write_timeout=)
        if http.use_ssl? && opts[:ca_file] && File.file?(opts[:ca_file])
          http.ca_file = opts[:ca_file]
        end
        klass = { 'GET' => Net::HTTP::Get, 'POST' => Net::HTTP::Post, 'HEAD' => Net::HTTP::Head }[(opts[:method] || 'GET').upcase]
        req = klass.new(uri.request_uri)
        req['User-Agent'] = USER_AGENT
        req['Accept-Encoding'] = 'identity' if opts[:dest]
        (opts[:headers] || {}).each { |k, v| req[k] = v }
        req.body = opts[:body] if opts[:body]
        result = nil
        http.start do |conn|
          conn.request(req) do |resp|
            code = resp.code.to_i
            if [301, 302, 303, 307, 308].include?(code) && resp['location'] && redirects < 5
              loc = URI.join(uri.to_s, resp['location']).to_s
              result = [:redirect, loc, code]
              next
            end
            result = read_response(resp, code, opts, job)
          end
        end
        if result.is_a?(Array) && result[0] == :redirect
          new_opts = opts.merge(url: result[1])
          # Không chuyển tiếp Authorization sang host khác (ví dụ link tải S3/GitHub CDN).
          if URI.parse(result[1]).host != uri.host && new_opts[:headers]
            new_opts[:headers] = new_opts[:headers].reject { |k, _| k.to_s.downcase == 'authorization' }
          end
          new_opts[:method] = 'GET' if [301, 302, 303].include?(result[2])
          new_opts[:body] = nil if new_opts[:method] == 'GET'
          return perform(new_opts, job, redirects + 1)
        end
        result
      rescue Net::OpenTimeout, Net::ReadTimeout, Timeout::Error => e
        Result.new(false, 0, nil, {}, :timeout, e.class.name, nil, opts[:url])
      rescue OpenSSL::SSL::SSLError => e
        Result.new(false, 0, nil, {}, :ssl, e.message, nil, opts[:url])
      rescue SocketError, Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH, Errno::ENETUNREACH,
             Errno::ETIMEDOUT, EOFError, IOError => e
        kind = job[:cancel] ? :cancelled : :network
        Result.new(false, 0, nil, {}, kind, e.message, nil, opts[:url])
      rescue SystemCallError => e
        Result.new(false, 0, nil, {}, opts[:dest] ? :io : :network, e.message, nil, opts[:url])
      end

      def read_response(resp, code, opts, job)
        headers = {}
        resp.each_header { |k, v| headers[k] = v }
        ok = code >= 200 && code < 300
        if opts[:dest] && ok
          return download_body(resp, code, headers, opts, job)
        end
        max = opts[:max_body] || MAX_BODY
        buf = +''
        resp.read_body do |chunk|
          raise IOError, 'cancelled' if job[:cancel]
          buf << chunk
          return Result.new(false, code, nil, headers, :too_large, 'body too large', nil, opts[:url]) if buf.bytesize > max
        end
        body = Util.utf8(buf.force_encoding(Encoding::UTF_8))
        Result.new(ok, code, body, headers, ok ? nil : :http, ok ? nil : "HTTP #{code}", nil, opts[:url])
      end

      def download_body(resp, code, headers, opts, job)
        dest = opts[:dest]
        FileUtils.mkdir_p(File.dirname(dest))
        part = dest + '.part'
        total = resp['content-length'].to_i
        got = 0
        prog = opts[:progress]
        File.open(part, 'wb') do |f|
          resp.read_body do |chunk|
            raise IOError, 'cancelled' if job[:cancel]
            f.write(chunk)
            got += chunk.bytesize
            if prog
              prog['bytes'] = got
              prog['total'] = total
            end
          end
        end
        if total > 0 && got != total
          File.delete(part)
          return Result.new(false, code, nil, headers, :network, "Tải thiếu dữ liệu (#{got}/#{total} byte)", nil, opts[:url])
        end
        File.delete(dest) if File.exist?(dest)
        File.rename(part, dest)
        Result.new(true, code, nil, headers, nil, nil, dest, opts[:url])
      rescue IOError, SystemCallError => e
        File.delete(part) if part && File.exist?(part)
        kind = job[:cancel] ? :cancelled : :io
        Result.new(false, code, nil, headers, kind, e.message, nil, opts[:url])
      end

      # ---- Fallback Sketchup::Http (chạy main thread, callback main thread) ----
      def sketchup_http?
        defined?(Sketchup::Http::Request) ? true : false
      end

      def start_sketchup_request(job)
        o = job[:opts]
        meth = { 'GET' => Sketchup::Http::GET, 'POST' => Sketchup::Http::POST }[(o[:method] || 'GET').upcase] || Sketchup::Http::GET
        req = Sketchup::Http::Request.new(o[:url], meth)
        hdr = { 'User-Agent' => USER_AGENT }.merge(o[:headers] || {})
        req.headers = hdr
        req.body = o[:body] if o[:body]
        key = req.object_id
        @su_requests[key] = { req: req, job: job, deadline: Time.now + (o[:timeout] || 30).to_f }
        req.start do |_r, response|
          entry = @su_requests.delete(key)
          next unless entry
          code = response.status_code.to_i
          body = Util.utf8(response.body.to_s.dup.force_encoding(Encoding::UTF_8))
          ok = code >= 200 && code < 300
          res = Result.new(ok, code, body, {}, ok ? nil : (code.zero? ? :network : :http), ok ? nil : "HTTP #{code}", nil, o[:url])
          safe_callback(job, res)
        end
      rescue StandardError => e
        safe_callback(job, Result.new(false, 0, nil, {}, :network, e.message, nil, job[:opts][:url]))
      end

      def check_sketchup_timeouts
        return if @su_requests.empty?
        now = Time.now
        @su_requests.keys.each do |k|
          entry = @su_requests[k]
          next unless entry && now > entry[:deadline]
          @su_requests.delete(k)
          begin
            entry[:req].cancel
          rescue StandardError
            nil
          end
          safe_callback(entry[:job], Result.new(false, 0, nil, {}, :timeout, 'Sketchup::Http timeout', nil, entry[:job][:opts][:url]))
        end
      end
    end
  end
end
