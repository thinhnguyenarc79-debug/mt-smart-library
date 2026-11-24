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

      def initialize(path)
        @path = path
        raise Error, 'Không tìm thấy file gói cập nhật.' unless File.file?(path)
        @entries = read_central
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
          raise Error, "Sai CRC (file hỏng): #{entry.name}" unless Zlib.crc32(data) == entry.crc
          data
        end
      rescue Zlib::Error => e
        raise Error, "Giải nén lỗi #{entry.name}: #{e.message}"
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
          raise Error, 'Tên file trong gói không phải UTF-8.' unless name.valid_encoding?
          raise Error, "Gói chứa file mã hóa: #{name}" if (flags & 1) == 1
          raise Error, 'ZIP64 không hỗ trợ.' if [csize, usize, off].include?(0xFFFFFFFF)
          reason = self.class.unsafe_reason(name)
          raise Error, "Đường dẫn nguy hiểm trong gói (#{reason}): #{name}" if reason
          host = made_by >> 8
          if host == 3 && ((ext >> 16) & 0o170000) == 0o120000
            raise Error, "Gói chứa symlink (bị chặn): #{name}"
          end
          sum += usize
          raise Error, 'Gói giải nén quá lớn.' if sum > MAX_TOTAL
          list << Entry.new(name, method, csize, usize, off, crc, flags, ext, made_by)
        end
        names = list.map { |e| e.name.downcase }
        raise Error, 'Gói chứa tên file trùng lặp.' if names.uniq.size != names.size
        list
      end
    end
  end
end
