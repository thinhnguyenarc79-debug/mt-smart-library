# frozen_string_literal: true

module MTDesign
  module SmartLibrary
    # Dữ liệu người dùng nằm TÁCH BIỆT khỏi thư mục mã nguồn plugin:
    #   %LOCALAPPDATA%\MT_Smart_Library\  (settings, chỉ mục, thumbnail, log, sao lưu, cập nhật)
    # Thư mục plugin (Plugins\mt_smart_library) chỉ chứa mã nguồn => cập nhật/khôi phục không đụng dữ liệu.
    module Paths
      DATA_DIR_NAME = 'MT_Smart_Library'
      CODE_DIR_NAME = 'mt_smart_library'
      LOADER_NAME = 'mt_smart_library.rb'

      module_function

      def data_root
        @data_root ||= begin
          override = Util.env_value('MT_SMART_LIBRARY_DATA')
          base = override && !override.empty? ? override : nil
          base ||= begin
            la = Util.env_value('LOCALAPPDATA')
            la && !la.empty? ? File.join(la, DATA_DIR_NAME) : nil
          end
          base ||= File.join(Util.utf8(Dir.home), DATA_DIR_NAME)
          Util.norm_path(base)
        end
      end

      def reset!
        @data_root = nil
        @code_dir = nil
      end

      def code_dir
        @code_dir ||= Util.norm_path(Util.utf8(File.expand_path('..', __dir__)))
      end

      def code_dir=(path)
        @code_dir = Util.norm_path(path)
      end

      def plugins_root
        File.dirname(code_dir)
      end

      def loader_path
        File.join(plugins_root, LOADER_NAME)
      end

      def sub(*parts)
        File.join(data_root, *parts)
      end
    end
  end
end
