# frozen_string_literal: true
require 'fileutils'
require 'json'
require 'digest'

module MTDesign
  module SmartLibrary
    # Sao lưu / khôi phục MÃ NGUỒN plugin (loader + thư mục mt_smart_library).
    # Bản sao lưu nằm trong thư mục dữ liệu người dùng: <data>/backups/<version>_<thời gian>/
    # Chỉ thao tác filesystem thuần Ruby — an toàn khi chạy trong luồng nền.
    class BackupManager
      KEEP = 5
      META = 'backup.json'

      def initialize(backups_dir, plugins_root, logger = nil)
        @dir = backups_dir
        @plugins_root = plugins_root
        @logger = logger
        FileUtils.mkdir_p(@dir)
      end

      attr_reader :dir

      def loader
        File.join(@plugins_root, Paths::LOADER_NAME)
      end

      def code_dir
        File.join(@plugins_root, Paths::CODE_DIR_NAME)
      end

      # Tạo bản sao lưu của phiên bản đang cài. Trả đường dẫn bản sao lưu.
      def create(version, reason)
        raise 'Không tìm thấy file loader của plugin đang cài.' unless File.file?(loader)
        raise 'Không tìm thấy thư mục mã nguồn plugin đang cài.' unless File.directory?(code_dir)
        stamp = Time.now.strftime('%Y%m%d_%H%M%S')
        dest = File.join(@dir, "#{Util.safe_filename(version, 20)}_#{stamp}")
        dest += "_#{rand(1000)}" if File.exist?(dest)
        tmp = dest + '.partial'
        FileUtils.rm_rf(tmp)
        FileUtils.mkdir_p(tmp)
        FileUtils.cp(loader, File.join(tmp, Paths::LOADER_NAME))
        FileUtils.cp_r(code_dir, File.join(tmp, Paths::CODE_DIR_NAME))
        files = BackupManager.manifest_of(tmp)
        meta = { 'plugin_id' => PLUGIN_ID, 'version' => version, 'created_at' => Time.now.strftime('%Y-%m-%d %H:%M:%S'),
                 'reason' => reason, 'files' => files.size, 'bytes' => files.values.sum { |v| v[0] } }
        File.write(File.join(tmp, META), JSON.pretty_generate(meta))
        verify_copy!(code_dir, File.join(tmp, Paths::CODE_DIR_NAME))
        File.rename(tmp, dest)
        @logger&.info("Đã sao lưu phiên bản #{version} vào #{dest}")
        prune(dest)
        dest
      rescue StandardError
        FileUtils.rm_rf(tmp) if tmp
        raise
      end

      def list
        Dir.glob(File.join(@dir, '*', META)).map do |m|
          begin
            meta = JSON.parse(File.read(m, encoding: 'UTF-8'))
            d = File.dirname(m)
            next unless meta.is_a?(Hash) && meta['plugin_id'] == PLUGIN_ID
            next unless File.file?(File.join(d, Paths::LOADER_NAME)) && File.directory?(File.join(d, Paths::CODE_DIR_NAME))
            meta.merge('path' => d, 'id' => File.basename(d))
          rescue StandardError
            nil
          end
        end.compact.sort_by { |b| b['created_at'].to_s }.reverse
      end

      def find(id)
        list.find { |b| b['id'] == id }
      end

      # Danh sách {đường_dẫn_tương_đối => [size, sha256]} của 1 cây thư mục.
      def self.manifest_of(root)
        out = {}
        Dir.glob(File.join(root, '**', '*'), File::FNM_DOTMATCH).each do |f|
          next unless File.file?(f)
          rel = f[(root.length + 1)..-1]
          out[rel] = [File.size(f), Digest::SHA256.file(f).hexdigest]
        end
        out
      end

      private

      def verify_copy!(src, dst)
        a = BackupManager.manifest_of(src)
        b = BackupManager.manifest_of(dst)
        raise 'Sao lưu không đầy đủ (số file/nội dung không khớp).' unless a == b
      end

      def prune(keep_path)
        all = list
        return if all.size <= KEEP
        all.drop(KEEP).each do |b|
          next if b['path'] == keep_path
          FileUtils.rm_rf(b['path'])
          @logger&.info("Xóa bản sao lưu cũ #{b['id']}")
        end
      end
    end
  end
end
