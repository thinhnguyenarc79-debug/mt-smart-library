# frozen_string_literal: true
require 'fileutils'

module MTDesign
  module SmartLibrary
    # Ghi log ra file (xoay vòng 1 MB) và che mọi bí mật (API key/token).
    class Logger
      MAX_BYTES = 1_048_576
      SECRET_PATTERNS = [
        /sk-[A-Za-z0-9_\-]{8,}/,
        /(Bearer|Token)\s+[A-Za-z0-9._\-]{8,}/i,
        /("?(api[_-]?key|token|authorization)"?\s*[:=]\s*"?)[^"\s,}]+/i
      ].freeze

      attr_reader :path

      def initialize(path, echo: false)
        @path = path
        @echo = echo
        @secrets = []
        @mutex = Mutex.new
        FileUtils.mkdir_p(File.dirname(path))
      rescue StandardError
        @path = nil
      end

      attr_accessor :echo

      def add_secret(value)
        v = value.to_s
        @mutex.synchronize { @secrets << v unless v.length < 6 || @secrets.include?(v) }
      end

      def remove_secret(value)
        @mutex.synchronize { @secrets.delete(value.to_s) }
      end

      def redact(text)
        s = Util.utf8(text)
        secrets = @mutex.synchronize { @secrets.dup }
        secrets.each { |k| s = s.gsub(k, '[ẩn]') }
        s = s.gsub(SECRET_PATTERNS[0], '[ẩn]')
        s = s.gsub(SECRET_PATTERNS[1]) { "#{Regexp.last_match(1)} [ẩn]" }
        s = s.gsub(SECRET_PATTERNS[2]) { "#{Regexp.last_match(1)}[ẩn]" }
        s
      end

      def info(msg)
        write('INFO', msg)
      end

      def warn(msg)
        write('WARN', msg)
      end

      def error(msg, exc = nil)
        m = msg.to_s
        if exc
          m += " | #{exc.class}: #{exc.message}"
          bt = Array(exc.backtrace).first(6).join(' <- ')
          m += " | #{bt}" unless bt.empty?
        end
        write('ERROR', m)
      end

      private

      def write(level, msg)
        line = "#{Time.now.strftime('%Y-%m-%d %H:%M:%S')} [#{level}] #{redact(msg)}"
        puts "[MT Smart Library] #{line}" if @echo
        return unless @path
        @mutex.synchronize do
          rotate
          File.open(@path, 'ab') { |f| f.write(line + "\n") }
        end
      rescue StandardError
        nil
      end

      def rotate
        return unless File.file?(@path) && File.size(@path) > MAX_BYTES
        old = @path + '.1'
        File.delete(old) if File.exist?(old)
        File.rename(@path, old)
      rescue StandardError
        nil
      end
    end
  end
end
