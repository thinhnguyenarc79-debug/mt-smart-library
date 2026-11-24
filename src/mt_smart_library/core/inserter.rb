# frozen_string_literal: true

module MTDesign
  module SmartLibrary
    # Chèn model vào công trình. CHỈ gọi ở main thread.
    module Inserter
      class NewerVersionError < StandardError; end
      IMPORT_EXT = %w[.dae .3ds .kmz .dwg .dxf .stl .ifc .obj .fbx].freeze

      module_function

      def check_file!(path, exts)
        raise "File không tồn tại hoặc ổ đĩa chưa kết nối:\n#{path}" unless File.file?(path)
        ext = File.extname(path).downcase
        raise "Định dạng #{ext} không được hỗ trợ ở đây." unless exts.include?(ext)
        raise 'File rỗng (0 byte) — có thể tải chưa xong hoặc bị hỏng.' if File.size(path).zero?
      end

      # Nạp SKP thành component rồi cho người dùng đặt bằng chuột (giữ vật liệu/tỉ lệ gốc).
      def place_skp(path, allow_newer: false)
        check_file!(path, ['.skp'])
        model = Sketchup.active_model
        raise 'Không có công trình đang mở.' unless model
        definition = nil
        model.start_operation('MT Smart Library: nạp model', true)
        begin
          definition = if allow_newer
                         model.definitions.load(path, allow_newer: true)
                       else
                         model.definitions.load(path)
                       end
          model.commit_operation
        rescue StandardError => e
          model.abort_operation
          msg = e.message.to_s
          if !allow_newer && msg =~ /newer|version|phiên bản/i
            raise NewerVersionError, 'File được lưu bằng phiên bản SketchUp mới hơn SketchUp đang dùng.'
          end
          raise "Không đọc được file SKP (có thể hỏng hoặc phiên bản không tương thích): #{msg}"
        end
        raise 'SketchUp không trả về component cho file này.' unless definition
        model.place_component(definition, false)
        definition
      end

      # Nhập file 3D khác (DAE/3DS/KMZ...) bằng importer có sẵn của SketchUp.
      def import_3d(path)
        check_file!(path, IMPORT_EXT)
        model = Sketchup.active_model
        raise 'Không có công trình đang mở.' unless model
        ok = model.import(path, false)
        raise "SketchUp không nhập được #{File.extname(path)} (bản SketchUp này có thể không có importer cho định dạng này)." unless ok
        true
      end
    end
  end
end
