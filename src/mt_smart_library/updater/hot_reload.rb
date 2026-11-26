# frozen_string_literal: true
require 'digest'

module MTDesign
  module SmartLibrary
    # HYBRID HOT RELOAD — phân loại bản cập nhật và áp dụng nóng phần được thiết kế để nạp lại.
    #
    # Cập nhật NHANH (không cần khởi động lại) khi MỌI file thay đổi thuộc nhóm nạp lại được:
    #   - giao diện (ui/*.html|css|js, updater/update_dialog.*), biểu tượng, cấu hình JSON;
    #   - Python AI / trích xuất (ai_runtime/*.py, convert/*.py) — chạy ở tiến trình riêng, khởi động lại tiến trình khi rảnh;
    #   - module Ruby thuần hàm (không giữ trạng thái, không đăng ký menu/toolbar/observer/timer) trong RUBY bên dưới.
    # Còn lại (loader, main.rb, App, updater, bất kỳ module Ruby khác) → cập nhật HỆ THỐNG: cài xong, chờ người dùng tự khởi động lại.
    # Không chạy lại main.rb ⇒ không trùng menu/toolbar/callback/timer/observer; không động tới plugin khác hay bản vẽ đang mở.
    module HotReload
      # file Ruby → các hằng sẽ được thay (remove_const rồi load lại file).
      RUBY = {
        'updater/version.rb' => %i[VERSION BUILD_DATE VersionUtil],
        'online/wp_sources.rb' => %i[WpSources],
        'sources/site_probe.rb' => %i[SiteProbe],
        'sources/link_import.rb' => %i[LinkImport],
        'search/query_normalizer.rb' => %i[QueryNormalizer],
        'search/categories.rb' => %i[Categories],
        'core/synonyms.rb' => %i[Synonyms],
        'updater/update_channel.rb' => %i[UpdateChannel]
      }.freeze
      HOT_EXT = /\.(html|css|js|json|png|svg|py|txt|md)\z/i.freeze

      module_function

      def hot_file?(rel)
        return false if rel == Paths::LOADER_NAME
        r = rel.sub(%r{\A#{Regexp.escape(Paths::CODE_DIR_NAME)}/}, '')
        return true if RUBY.key?(r)
        !r.end_with?('.rb') && r =~ HOT_EXT ? true : false
      end

      # installed_root: thư mục Plugins; package: { rel => sha256 } (rel tính từ gốc gói: mt_smart_library.rb, mt_smart_library/...)
      # → { 'type' => 'hot'|'system'|'none', 'changed' => [...], 'system_files' => [...], 'reason' => '...' }
      def classify(installed_root, package)
        changed = []
        package.each do |rel, sha|
          cur = File.join(installed_root, rel)
          changed << rel unless File.file?(cur) && Digest::SHA256.file(cur).hexdigest == sha
        end
        removed = []
        code = File.join(installed_root, Paths::CODE_DIR_NAME)
        if File.directory?(code)
          Dir.glob(File.join(code, '**', '*.rb')).each do |f| # file Ruby bị xóa trong bản mới luôn là thay đổi hệ thống
            rel = f[(installed_root.length + 1)..-1].tr('\\', '/')
            removed << rel unless package.key?(rel)
          end
        end
        changed += removed
        return { 'type' => 'none', 'changed' => [], 'system_files' => [], 'reason' => 'Không có file nào thay đổi.' } if changed.empty?
        sys = changed.reject { |r| hot_file?(r) && !removed.include?(r) }
        if sys.empty?
          { 'type' => 'hot', 'changed' => changed, 'system_files' => [],
            'reason' => "Chỉ thay đổi #{describe(changed)} — áp dụng ngay, không cần khởi động lại SketchUp." }
        else
          { 'type' => 'system', 'changed' => changed, 'system_files' => sys.first(12),
            'reason' => "Thay đổi phần lõi (#{sys.first(4).map { |r| File.basename(r) }.join(', ')}#{sys.size > 4 ? '…' : ''}) — cần khởi động lại SketchUp." }
        end
      end

      def describe(changed)
        parts = []
        parts << 'giao diện' if changed.any? { |r| r =~ /\.(html|css|js)\z/ }
        parts << 'AI/trích xuất (Python)' if changed.any? { |r| r.end_with?('.py') }
        parts << 'cấu hình' if changed.any? { |r| r.end_with?('.json') }
        parts << 'module nạp lại được' if changed.any? { |r| r.end_with?('.rb') }
        parts.empty? ? 'tài nguyên' : parts.join(', ')
      end

      # Nạp lại các module Ruby thuần hàm đã đổi (main thread). Trả danh sách đã nạp.
      def reload_ruby(changed, code_dir)
        done = []
        changed.each do |rel|
          r = rel.sub(%r{\A#{Regexp.escape(Paths::CODE_DIR_NAME)}/}, '')
          consts = RUBY[r]
          next unless consts
          path = File.join(code_dir, r)
          next unless File.file?(path)
          consts.each { |c| SmartLibrary.send(:remove_const, c) if SmartLibrary.const_defined?(c, false) }
          load path
          done << r
        end
        done
      end

      def sha_map_dir(root)
        out = {}
        [File.join(root, Paths::LOADER_NAME)].select { |f| File.file?(f) }.each { |f| out[Paths::LOADER_NAME] = Digest::SHA256.file(f).hexdigest }
        Dir.glob(File.join(root, Paths::CODE_DIR_NAME, '**', '*')).select { |f| File.file?(f) }.each do |f|
          out[f[(root.length + 1)..-1].tr('\\', '/')] = Digest::SHA256.file(f).hexdigest
        end
        out
      end
    end
  end
end
