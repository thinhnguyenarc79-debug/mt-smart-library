# frozen_string_literal: true
require 'zlib'

module MTDesign
  module SmartLibrary
    # Đọc ZIP/RBZ thuần Ruby (Zlib có sẵn trong SketchUp). Hỗ trợ Stored/Deflate, kiểm CRC32.
    # Chặn: ZIP64, mã hóa, symlink, đường dẫn tuyệt đối, "..", ký tự ổ đĩa/ADS, tên sai UTF-8.
    class ZipReader
      class Error < StandardError; end
      Entry = Struct.new(:name, :method, :csize, :usize, :offset, :crc, :flags, :ext_attr, :made_by) do
        def directory?
          name.end_with?('/')
        end
      end

      MAX_ENTRIES = 5000
      MAX_TOTAL = 200 * 1024 * 1024
      EOCD_SIG = 0x06054b50
      CEN_SIG = 0x02014b50
      LOC_SIG = 0x04034b50

      attr_reader :path, :entries

      # Mặc định (gói cập nhật): chặn file mã hóa, tên phải UTF-8, tối đa 200 MB.
      # Model tải về (V1.0.8): password: mật khẩu ZipCrypto do trang nguồn công bố; lenient: chấp nhận tên CP437/không UTF-8.
      def initialize(path, password: nil, lenient: false, max_total: MAX_TOTAL)
        @path = path
        @password = password
        @lenient = lenient
        @max_total = max_total
        raise Error, 'Không tìm thấy file gói cập nhật.' unless File.file?(path)
        @entries = read_central
      end

      def encrypted?
        @entries.any? { |e| (e.flags & 1) == 1 }
      end

      # Kiểm tra đường dẫn entry an toàn; trả lý do lỗi hoặc nil.
      def self.unsafe_reason(name)
        return 'tên rỗng' if name.nil? || name.empty?
        return 'chứa ký tự điều khiển' if name =~ /[\x00-\x1f]/
        return 'dùng dấu \\' if name.include?('\\')
        return 'đường dẫn tuyệt đối' if name.start_with?('/') || name =~ /\A[A-Za-z]:/
        return 'chứa ":"' if name.include?(':')
        segs = name.chomp('/').split('/')
        return 'đoạn rỗng' if segs.any?(&:empty?)
        return 'chứa ".."' if segs.any? { |s| s == '..' || s == '.' }
        return 'tên kết thúc bằng dấu cách/dấu chấm' if segs.any? { |s| s.end_with?(' ', '.') }
        reserved = /\A(con|prn|aux|nul|com\d|lpt\d)(\..*)?\z/i
        return 'tên thiết bị Windows' if segs.any? { |s| s =~ reserved }
        nil
      end

      def read(entry)
        File.open(@path, 'rb') do |f|
          f.seek(entry.offset)
          hdr = f.read(30)
          raise Error, "Header hỏng: #{entry.name}" unless hdr && hdr.bytesize == 30 && hdr.unpack1('V') == LOC_SIG
          nlen, elen = hdr.byteslice(26, 4).unpack('vv')
          f.seek(entry.offset + 30 + nlen + elen)
          raw = f.read(entry.csize) || ''.b
          raise Error, "Dữ liệu thiếu: #{entry.name}" unless raw.bytesize == entry.csize
          raw = decrypt(raw, entry) if (entry.flags & 1) == 1
          data = case entry.method
                 when 0 then raw
                 when 8
                   z = Zlib::Inflate.new(-Zlib::MAX_WBITS)
                   begin
                     out = z.inflate(raw)
                     z.finish
                     out
                   ensure
                     z.close
                   end
                 else raise Error, "Kiểu nén #{entry.method} không hỗ trợ: #{entry.name}"
                 end
          raise Error, "Sai kích thước: #{entry.name}" unless data.bytesize == entry.usize
          unless Zlib.crc32(data) == entry.crc
            raise Error, (entry.flags & 1) == 1 ? "Sai mật khẩu giải nén hoặc file hỏng: #{entry.name}" : "Sai CRC (file hỏng): #{entry.name}"
          end
          data
        end
      rescue Zlib::Error => e
        raise Error, (entry.flags & 1) == 1 ? "Sai mật khẩu giải nén hoặc file hỏng: #{entry.name}" : "Giải nén lỗi #{entry.name}: #{e.message}"
      end

      # ---- ZipCrypto (PKWARE truyền thống) ----
      CRC_TABLE = (0..255).map do |n|
        c = n
        8.times { c = (c & 1) == 1 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        c
      end.freeze

      def decrypt(raw, entry)
        raise Error, "File mã hóa cần mật khẩu: #{entry.name}" if @password.nil? || @password.empty?
        raise Error, "Mã hóa AES chưa hỗ trợ: #{entry.name}" if entry.method == 99
        raise Error, "Dữ liệu mã hóa hỏng: #{entry.name}" if raw.bytesize < 12
        t = CRC_TABLE
        k0 = 0x12345678
        k1 = 0x23456789
        k2 = 0x34567890
        upd = lambda do |b|
          k0 = t[(k0 ^ b) & 0xff] ^ (k0 >> 8)
          k1 = ((k1 + (k0 & 0xff)) * 134_775_813 + 1) & 0xffffffff
          k2 = t[(k2 ^ (k1 >> 24)) & 0xff] ^ (k2 >> 8)
        end
        @password.b.each_byte { |b| upd.call(b) }
        out = raw.b.dup # giải mã tại chỗ, không nhân bộ nhớ
        i = 0
        raw.each_byte do |c|
          tmp = (k2 | 2) & 0xffff
          p = c ^ (((tmp * (tmp ^ 1)) >> 8) & 0xff)
          out.setbyte(i, p)
          i += 1
          k0 = t[(k0 ^ p) & 0xff] ^ (k0 >> 8)
          k1 = ((k1 + (k0 & 0xff)) * 134_775_813 + 1) & 0xffffffff
          k2 = t[(k2 ^ (k1 >> 24)) & 0xff] ^ (k2 >> 8)
        end
        # Byte kiểm tra (byte 12 của header) phải khớp CRC (hoặc giờ sửa file khi có data descriptor).
        chk = out.getbyte(11)
        ok = chk == (entry.crc >> 24) & 0xff || ((entry.flags & 8) == 8)
        raise Error, 'Sai mật khẩu giải nén.' unless ok
        out.byteslice(12, out.bytesize - 12)
      end

      private

      def read_central
        size = File.size(@path)
        raise Error, 'File quá nhỏ, không phải ZIP.' if size < 22
        File.open(@path, 'rb') do |f|
          tail_len = [size, 65_557].min
          f.seek(size - tail_len)
          tail = f.read(tail_len)
          pos = tail.rindex([EOCD_SIG].pack('V'))
          raise Error, 'Không phải file ZIP/RBZ hợp lệ.' unless pos
          eocd = tail.byteslice(pos, 22)
          _sig, disk, cd_disk, _n_disk, total, cd_size, cd_off = eocd.unpack('VvvvvVV')
          raise Error, 'ZIP nhiều phần không hỗ trợ.' unless disk.zero? && cd_disk.zero?
          raise Error, 'ZIP64 không hỗ trợ.' if total == 0xFFFF || cd_off == 0xFFFFFFFF
          raise Error, 'Gói có quá nhiều file.' if total > MAX_ENTRIES
          f.seek(cd_off)
          cd = f.read(cd_size).to_s
          raise Error, 'Central directory hỏng.' unless cd.bytesize == cd_size
          parse_cd(cd, total)
        end
      end

      def parse_cd(cd, total)
        list = []
        p = 0
        sum = 0
        total.times do
          raise Error, 'Central directory hỏng.' unless cd.byteslice(p, 4).to_s.unpack1('V') == CEN_SIG
          made_by, _need, flags, method, _t, _d, crc, csize, usize, nlen, elen, clen, _disk, _ia, ext, off =
            cd.byteslice(p + 4, 42).unpack('vvvvvvVVVvvvvvVV')
          raw_name = cd.byteslice(p + 46, nlen).to_s
          p += 46 + nlen + elen + clen
          name = raw_name.dup.force_encoding(Encoding::UTF_8)
          if !name.valid_encoding? && @lenient
            name = raw_name.dup.force_encoding(Encoding::IBM437).encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: '_')
          end
          raise Error, 'Tên file trong gói không phải UTF-8.' unless name.valid_encoding?
          raise Error, "Gói chứa file mã hóa: #{name}" if (flags & 1) == 1 && @password.nil?
          raise Error, 'ZIP64 không hỗ trợ.' if [csize, usize, off].include?(0xFFFFFFFF)
          reason = self.class.unsafe_reason(name)
          raise Error, "Đường dẫn nguy hiểm trong gói (#{reason}): #{name}" if reason
          host = made_by >> 8
          if host == 3 && ((ext >> 16) & 0o170000) == 0o120000
            raise Error, "Gói chứa symlink (bị chặn): #{name}"
          end
          sum += usize
          raise Error, 'Gói giải nén quá lớn.' if sum > @max_total
          list << Entry.new(name, method, csize, usize, off, crc, flags, ext, made_by)
        end
        names = list.map { |e| e.name.downcase }
        raise Error, 'Gói chứa tên file trùng lặp.' if names.uniq.size != names.size
        list
      end
    end
  end
end
