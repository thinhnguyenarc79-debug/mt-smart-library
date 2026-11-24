# frozen_string_literal: true
require 'base64'
require 'fileutils'

module MTDesign
  module SmartLibrary
    # Lưu bí mật TÙY CHỌN (người dùng bật "Ghi nhớ trên máy này"): mã hóa bằng Windows DPAPI
    # (CryptProtectData, gắn với tài khoản Windows hiện tại), lưu file riêng *.dpapi,
    # KHÔNG ghi vào settings.json, KHÔNG ghi log. Không có DPAPI => không lưu (chỉ giữ trong phiên).
    module SecretStore
      FLAG_UI_FORBIDDEN = 0x1
      NAMES = %w[openai sketchfab].freeze

      module_function

      def dir
        File.join(Paths.data_root, 'secrets')
      end

      def available?
        return false unless Util::WINDOWS
        api ? true : false
      end

      def api
        return @api if defined?(@api)
        @api = begin
          require 'fiddle'
          c32 = Fiddle.dlopen('crypt32')
          k32 = Fiddle.dlopen('kernel32')
          v = Fiddle::TYPE_VOIDP
          {
            protect: Fiddle::Function.new(c32['CryptProtectData'], [v, v, v, v, v, Fiddle::TYPE_INT, v], Fiddle::TYPE_INT),
            unprotect: Fiddle::Function.new(c32['CryptUnprotectData'], [v, v, v, v, v, Fiddle::TYPE_INT, v], Fiddle::TYPE_INT),
            free: Fiddle::Function.new(k32['LocalFree'], [v], v)
          }
        rescue StandardError, LoadError
          nil
        end
      end

      def blob_in(bytes)
        buf = Fiddle::Pointer.malloc(bytes.bytesize)
        buf[0, bytes.bytesize] = bytes
        b = Fiddle::Pointer.malloc(16)
        b[0, 16] = [bytes.bytesize, 0, buf.to_i].pack('LLQ')
        [b, buf]
      end

      def call_crypt(fn, bytes)
        inb, keep = blob_in(bytes)
        out = Fiddle::Pointer.malloc(16)
        out[0, 16] = "\0" * 16
        ok = api[fn].call(inb, nil, nil, nil, nil, FLAG_UI_FORBIDDEN, out)
        raise 'DPAPI thất bại' if ok.zero?
        len, _pad, ptr = out[0, 16].unpack('LLQ')
        data = Fiddle::Pointer.new(ptr)[0, len]
        api[:free].call(ptr)
        keep.size # giữ tham chiếu bộ đệm tới sau lời gọi DPAPI
        data
      end

      def save(name, secret)
        raise 'Tên bí mật không hợp lệ' unless NAMES.include?(name)
        return false unless available?
        s = secret.to_s
        return false if s.empty?
        enc = call_crypt(:protect, s.b)
        FileUtils.mkdir_p(dir)
        Util.atomic_write(File.join(dir, "#{name}.dpapi"), Base64.strict_encode64(enc))
        true
      rescue StandardError
        false
      end

      def load(name)
        return nil unless NAMES.include?(name) && available?
        f = File.join(dir, "#{name}.dpapi")
        return nil unless File.file?(f)
        plain = call_crypt(:unprotect, Base64.strict_decode64(File.binread(f).strip))
        Util.utf8(plain)
      rescue StandardError
        nil
      end

      def delete(name)
        f = File.join(dir, "#{name}.dpapi")
        File.delete(f) if File.exist?(f)
        bak = f + '.bak'
        File.delete(bak) if File.exist?(bak)
        true
      rescue StandardError
        false
      end

      def stored?(name)
        File.file?(File.join(dir, "#{name}.dpapi"))
      end
    end
  end
end
