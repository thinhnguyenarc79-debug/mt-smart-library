# frozen_string_literal: true
require 'base64'
require 'digest'
require 'fileutils'

module MTDesign
  module SmartLibrary
    # Hàng đợi thumbnail. Tạo ảnh bằng Sketchup.save_thumbnail (đọc ảnh preview nhúng trong SKP,
    # KHÔNG nạp model vào công trình). Chạy ở main thread, giới hạn thời gian mỗi nhịp timer.
    class ThumbService
      MAX_BYTES = 1_500_000
      QUEUE_MAX = 400

      # generator: ->(skp_path, png_path) { true/false } — mặc định Sketchup.save_thumbnail.
      def initialize(dir, logger = nil, &generator)
        @dir = dir
        @logger = logger
        @generator = generator
        @queue = []
        @queued = {}
        FileUtils.mkdir_p(@dir)
      end

      def pending?
        !@queue.empty?
      end

      def clear_queue
        @queue.clear
        @queued.clear
      end

      def file_for(entry)
        File.join(@dir, "#{entry.id[0, 24]}_#{entry.mtime}_#{entry.size}.png")
      end

      # Yêu cầu mới nhất (trang đang xem) được ưu tiên trước.
      def request(entries)
        entries.reverse_each do |e|
          next if @queued[e.id]
          @queue.unshift(e)
          @queued[e.id] = true
        end
        while @queue.size > QUEUE_MAX
          dropped = @queue.pop
          @queued.delete(dropped.id)
        end
      end

      # Xử lý trong budget giây; yield(id, data_uri_or_nil) cho mỗi thumbnail.
      def process(budget = 0.04)
        t0 = Time.now
        until @queue.empty?
          e = @queue.shift
          @queued.delete(e.id)
          yield(e.id, thumb_data(e))
          break if Time.now - t0 > budget
        end
      end

      def thumb_data(e)
        png = file_for(e)
        miss = png + '.none'
        return nil if File.exist?(miss)
        unless File.file?(png)
          ok = false
          begin
            ok = @generator ? @generator.call(e.path, png) : false
          rescue StandardError => ex
            @logger&.warn("Thumbnail lỗi: #{e.path}: #{ex.message}")
          end
          unless ok && File.file?(png) && File.size(png) > 0
            File.delete(png) if File.exist?(png)
            File.open(miss, 'wb') { |f| f.write('') }
            return nil
          end
        end
        return nil if File.size(png) > MAX_BYTES
        'data:image/png;base64,' + Base64.strict_encode64(File.binread(png))
      rescue StandardError => ex
        @logger&.warn("Không đọc thumbnail #{e.path}: #{ex.message}")
        nil
      end

      def clear_cache
        n = 0
        Dir.glob(File.join(@dir, '*')).each do |f|
          File.delete(f)
          n += 1
        rescue StandardError
          nil
        end
        clear_queue
        n
      end

      def cache_size
        Dir.glob(File.join(@dir, '*')).sum { |f| File.size(f) rescue 0 }
      end
    end
  end
end
