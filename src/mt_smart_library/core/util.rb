# frozen_string_literal: true
require 'json'
require 'fileutils'
require 'digest'

module MTDesign
  module SmartLibrary
    # Hàm tiện ích thuần Ruby (không phụ thuộc SketchUp) để có thể kiểm thử độc lập.
    module Util
      module_function

      WINDOWS = (RUBY_PLATFORM =~ /mswin|mingw|cygwin/) ? true : false

      VN_GROUPS = {
        'a' => 'àáảãạăằắẳẵặâầấẩẫậ',
        'e' => 'èéẻẽẹêềếểễệ',
        'i' => 'ìíỉĩị',
        'o' => 'òóỏõọôồốổỗộơờớởỡợ',
        'u' => 'ùúủũụưừứửữự',
        'y' => 'ỳýỷỹỵ',
        'd' => 'đ'
      }.freeze
      VN_FROM = VN_GROUPS.values.join.freeze
      VN_TO = VN_GROUPS.map { |k, v| k * v.length }.join.freeze
      COMBINING = /[\u0300-\u036f]/.freeze

      # Đưa chuỗi bất kỳ về UTF-8 hợp lệ (đường dẫn Windows, ENV, dữ liệu mạng).
      def utf8(value)
        s = value.to_s
        return s if s.encoding == Encoding::UTF_8 && s.valid_encoding?
        d = s.dup
        if d.encoding == Encoding::ASCII_8BIT || d.encoding == Encoding::UTF_8
          d.force_encoding(Encoding::UTF_8)
          return d if d.valid_encoding?
          return d.scrub('?')
        end
        d.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: '?')
      rescue StandardError
        s.dup.force_encoding(Encoding::UTF_8).scrub('?')
      end

      # Đường dẫn chuẩn: dấu '/', bỏ '/' cuối (giữ "C:/" và UNC "//server/share").
      def norm_path(path)
        p = utf8(path).tr('\\', '/')
        unc = p.start_with?('//')
        p = p.gsub(%r{/+}, '/')
        p = '/' + p if unc
        p = p.sub(%r{/+\z}, '') unless p =~ %r{\A[A-Za-z]:/\z} || p == '/'
        p = p + '/' if p =~ /\A[A-Za-z]:\z/
        p
      end

      # Khóa so sánh đường dẫn (Windows không phân biệt hoa thường).
      def path_key(path)
        k = norm_path(path)
        WINDOWS ? k.downcase : k
      end

      def under_root?(path, root)
        pk = path_key(path)
        rk = path_key(root)
        rk = rk.chomp('/')
        pk == rk || pk.start_with?(rk + '/')
      end

      # ID model giữ tương thích bản cũ: SHA256 của đường dẫn đầy đủ.
      def item_id(path)
        Digest::SHA256.hexdigest(utf8(path))
      end

      # Bỏ dấu tiếng Việt + chữ thường + tách từ (camelCase, chữ/số, ký tự đặc biệt).
      def fold(text)
        s = utf8(text)
        if s =~ COMBINING
          s = begin
            s.unicode_normalize(:nfc)
          rescue StandardError
            s
          end
        end
        s = s.gsub(/([a-z])([A-Z])/, '\1 \2')
        s = s.downcase
        s = s.tr(VN_FROM, VN_TO)
        s = s.gsub(COMBINING, '')
        s = s.gsub(/[^\p{L}\p{N}]+/, ' ')
        s = s.gsub(/(\p{L})(\p{N})/, '\1 \2').gsub(/(\p{N})(\p{L})/, '\1 \2')
        s.strip.squeeze(' ')
      end

      # Chữ thường giữ dấu (dùng tra từ điển có dấu).
      def lower_keep_accents(text)
        s = utf8(text)
        if s =~ COMBINING
          s = begin
            s.unicode_normalize(:nfc)
          rescue StandardError
            s
          end
        end
        s.downcase.gsub(/[^\p{L}\p{N}]+/, ' ').strip.squeeze(' ')
      end

      # Ghi file atomically: ghi file tạm rồi đổi tên, giữ bản .bak.
      def atomic_write(path, data)
        dir = File.dirname(path)
        FileUtils.mkdir_p(dir)
        tmp = "#{path}.tmp#{Process.pid}#{rand(100_000)}"
        File.open(tmp, 'wb') do |f|
          f.write(data)
          f.flush
          begin
            f.fsync
          rescue StandardError
            nil
          end
        end
        if File.exist?(path)
          begin
            FileUtils.cp(path, "#{path}.bak")
          rescue StandardError
            nil
          end
        end
        File.rename(tmp, path)
        true
      ensure
        File.delete(tmp) if tmp && File.exist?(tmp)
      end

      # Đọc JSON; trả nil nếu không có file, raise nếu hỏng.
      def read_json(path)
        return nil unless File.file?(path)
        raw = File.binread(path)
        raw.force_encoding(Encoding::UTF_8)
        raw = raw.sub(/\A\xEF\xBB\xBF/n.force_encoding(Encoding::UTF_8), '') if raw.start_with?("\uFEFF")
        JSON.parse(raw)
      end

      def json_for_js(obj)
        JSON.generate(obj).gsub("\u2028", '\u2028').gsub("\u2029", '\u2029').gsub('</', '<\/')
      end

      def human_size(bytes)
        b = bytes.to_f
        return format('%.0f B', b) if b < 1024
        return format('%.1f KB', b / 1024) if b < 1024 * 1024
        return format('%.2f MB', b / 1_048_576) if b < 1024**3
        format('%.2f GB', b / 1024**3)
      end

      # file:/// URL an toàn cho đường dẫn Unicode/UNC.
      def file_url(path)
        p = norm_path(path)
        enc = p.b.gsub(%r{[^A-Za-z0-9\-._~/:]}n) { |c| format('%%%02X', c.ord) }
        return 'file:' + enc if p.start_with?('//')
        enc.start_with?('/') ? 'file://' + enc : 'file:///' + enc
      end

      def safe_filename(name, max = 80)
        s = utf8(name).gsub(%r{[\\/:*?"<>|\x00-\x1f]}, '_').strip
        s = s.gsub(/\s+/, ' ')
        s = 'model' if s.empty?
        s[0, max]
      end

      def env_value(name)
        v = ENV[name]
        v.nil? ? nil : utf8(v).strip
      end
    end
  end
end
