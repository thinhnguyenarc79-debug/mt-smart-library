# frozen_string_literal: true
require 'digest'
require 'fileutils'
require 'json'

module MTDesign
  module SmartLibrary
    # Cache kết quả chuyển đổi: <data>/convert_cache/<sha256 file nguồn>_<phiên bản bộ chuyển đổi>/model.dae (+ textures).
    # Chèn lại cùng một model không phải chạy Blender lần nữa.
    class ModelCache
      CONVERTER_REV = 'c1'
      MAX_BYTES = 3 * 1024**3

      def initialize(dir, logger = nil)
        @dir = dir
        @log = logger
        FileUtils.mkdir_p(@dir)
      end

      attr_reader :dir

      def key_for(path)
        "#{Digest::SHA256.file(path).hexdigest[0, 32]}_#{CONVERTER_REV}"
      end

      def slot(key)
        File.join(@dir, key)
      end

      # Trả đường dẫn DAE đã chuyển đổi nếu còn hợp lệ.
      def fetch(key)
        d = slot(key)
        meta = File.join(d, 'meta.json')
        dae = File.join(d, 'model.dae')
        return nil unless File.file?(meta) && File.file?(dae) && File.size(dae).positive?
        FileUtils.touch(meta)
        dae
      end

      def meta(key)
        JSON.parse(File.read(File.join(slot(key), 'meta.json'), encoding: 'UTF-8'))
      rescue StandardError
        {}
      end

      def commit(key, info)
        File.write(File.join(slot(key), 'meta.json'), JSON.generate(info.merge('at' => Time.now.to_i)))
        prune
      end

      def discard(key)
        FileUtils.rm_rf(slot(key))
      end

      def size
        Dir.glob(File.join(@dir, '**', '*')).sum { |f| File.file?(f) ? File.size(f) : 0 }
      end

      def clear
        Dir.glob(File.join(@dir, '*')).each { |d| FileUtils.rm_rf(d) }
      end

      # Giữ tổng dung lượng dưới MAX_BYTES, xóa mục ít dùng nhất.
      def prune
        slots = Dir.glob(File.join(@dir, '*')).select { |d| File.directory?(d) }
        total = slots.sum { |d| dir_size(d) }
        return if total <= MAX_BYTES
        slots.sort_by { |d| File.mtime(File.join(d, 'meta.json')) rescue Time.at(0) }.each do |d| # rubocop:disable Style/RescueModifier
          break if total <= MAX_BYTES
          total -= dir_size(d)
          FileUtils.rm_rf(d)
        end
      end

      def dir_size(d)
        Dir.glob(File.join(d, '**', '*')).sum { |f| File.file?(f) ? File.size(f) : 0 }
      end
    end
  end
end
