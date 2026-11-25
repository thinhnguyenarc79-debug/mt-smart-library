# frozen_string_literal: true

module MTDesign
  module SmartLibrary
    # Nhận file model người dùng vừa tải trên trang nguồn chính thức (nguồn không cho tải tự động).
    # Chỉ đọc danh sách file trong thư mục Downloads của Windows (không đọc trình duyệt, không đọc cookie).
    # Chạy ở main thread qua timer, tối đa 1 lần / 2 giây, chỉ quét cấp 1 của thư mục.
    class DownloadWatcher
      EXTS = %w[.skp .zip .glb .gltf .fbx .obj .dae .3ds .kmz .usdz .stl .ply .blend .rar .7z].freeze
      TEMP = /\.(crdownload|part|partial|tmp|download|opdownload)\z/i
      WINDOW = 30 * 60
      INTERVAL = 2.0

      attr_reader :watch

      def self.default_dir
        env = ENV['MT_DOWNLOADS_DIR'].to_s
        return env unless env.empty?
        home = ENV['USERPROFILE'].to_s.empty? ? Dir.home : ENV['USERPROFILE']
        File.join(Util.norm_path(Util.utf8(home)), 'Downloads')
      rescue StandardError
        nil
      end

      def initialize(dir = nil)
        @dir = dir
        @watch = nil
        @last = 0
      end

      def dir
        @dir || self.class.default_dir
      end

      def active?
        !@watch.nil? && Time.now.to_f < @watch[:until]
      end

      def start(source:, title:, passwords: [])
        d = dir
        return false unless d && File.directory?(d)
        before = {}
        each_candidate(d) { |p, st| before[p] = st.mtime.to_f }
        @watch = { since: Time.now.to_f - 2, until: Time.now.to_f + WINDOW, source: source, title: title,
                   passwords: passwords, before: before, sizes: {} }
        @last = 0
        true
      end

      def stop
        @watch = nil
      end

      # Trả { path:, source:, title:, passwords: } khi có file mới đã tải xong (dung lượng đứng yên 2 lần đọc).
      def poll(now = Time.now.to_f)
        w = @watch
        return nil unless w
        return (@watch = nil) if now > w[:until]
        return nil if now - @last < INTERVAL
        @last = now
        found = nil
        each_candidate(dir) do |p, st|
          next if w[:before][p] && w[:before][p] >= st.mtime.to_f # file cũ không đổi
          next if st.mtime.to_f < w[:since]
          size = st.size
          next if size.zero?
          if w[:sizes][p] == size
            found = p if found.nil? || File.mtime(p) > File.mtime(found)
          else
            w[:sizes][p] = size
          end
        end
        return nil unless found
        @watch = nil
        { path: found, source: w[:source], title: w[:title], passwords: w[:passwords] }
      end

      private

      def each_candidate(d)
        return unless d && File.directory?(d)
        Dir.children(d, encoding: 'UTF-8').each do |n|
          next if n =~ TEMP
          next unless EXTS.include?(File.extname(n).downcase)
          p = File.join(d, n)
          st = File.stat(p)
          next unless st.file?
          yield p, st
        end
      rescue SystemCallError
        nil
      end
    end
  end
end
