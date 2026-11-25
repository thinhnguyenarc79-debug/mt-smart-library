# frozen_string_literal: true
require 'fileutils'

module MTDesign
  module SmartLibrary
    # Chọn cách đưa một file model vào SketchUp 2022:
    #   SKP  -> nạp trực tiếp            GLB/glTF -> bộ đọc glTF tích hợp (dự phòng: Blender)
    #   DAE  -> DefinitionList#import    3DS/KMZ/DWG/DXF/STL -> importer có sẵn của SketchUp (dự phòng STL: Blender)
    #   FBX/OBJ/USD/USDZ/PLY/BLEND -> Blender chạy nền -> DAE -> DefinitionList#import
    #   ZIP  -> giải nén an toàn, tự nhận file model chính + texture.
    module ImportManager
      PRIORITY = %w[.skp .glb .gltf .dae .fbx .obj .usdz .usd .usdc .usda .blend .3ds .kmz .stl .ply .dwg .dxf].freeze
      CONVERT = %w[.fbx .obj .usdz .usd .usdc .usda .ply .blend].freeze
      NATIVE = %w[.3ds .kmz .dwg .dxf .stl .ifc].freeze

      module_function

      def route(path)
        ext = File.extname(path).downcase
        return :skp if ext == '.skp'
        return :gltf if %w[.glb .gltf].include?(ext)
        return :dae if ext == '.dae'
        return :zip if ext == '.zip'
        return :convert if CONVERT.include?(ext)
        return :native if NATIVE.include?(ext)
        :unsupported
      end

      def kind_label(path)
        { skp: 'skp', gltf: 'gltf', dae: 'import', native: 'import', convert: 'convert' }[route(path)] || 'other'
      end

      # Giải nén ZIP an toàn (chặn ../, đường dẫn tuyệt đối, symlink, ZIP64) — thuần Ruby, chạy được ở luồng nền.
      # passwords: mật khẩu giải nén do trang nguồn công bố công khai (ví dụ SketchUp CGTips).
      def extract_zip(zip_path, dest, passwords: [])
        zip = ZipReader.new(zip_path, password: passwords.first, lenient: true, max_total: 2 * 1024 * 1024 * 1024)
        if zip.encrypted? && passwords.size > 1
          ok = passwords.find do |pw|
            z = ZipReader.new(zip_path, password: pw, lenient: true, max_total: 2 * 1024 * 1024 * 1024)
            e = z.entries.reject(&:directory?).min_by(&:csize)
            begin
              e.nil? || z.read(e) && true
            rescue ZipReader::Error
              false
            end
          end
          raise ZipReader::Error, 'File nén có mật khẩu chưa biết — giải nén thủ công rồi dùng “Chèn file từ máy…”.' unless ok
          zip = ZipReader.new(zip_path, password: ok, lenient: true, max_total: 2 * 1024 * 1024 * 1024)
        end
        FileUtils.mkdir_p(dest)
        real = File.expand_path(dest)
        zip.entries.reject(&:directory?).each do |e|
          next if e.name.start_with?('__MACOSX/') || File.basename(e.name).start_with?('._')
          target = File.expand_path(File.join(dest, e.name))
          raise "Đường dẫn nguy hiểm trong ZIP: #{e.name}" unless target.start_with?(real + '/')
          FileUtils.mkdir_p(File.dirname(target))
          File.open(target, 'wb') { |f| f.write(zip.read(e)) }
        end
        dest
      end

      # File model chính trong thư mục (ưu tiên định dạng chèn tốt nhất, rồi file lớn nhất).
      def pick_model(dir)
        files = Dir.glob(File.join(dir, '**', '*')).select { |f| File.file?(f) }
        files = files.reject { |f| f =~ %r{/(__MACOSX|textures_su)/}i }
        best = files.select { |f| PRIORITY.include?(File.extname(f).downcase) }
                    .min_by { |f| [PRIORITY.index(File.extname(f).downcase), -File.size(f)] }
        return best if best
        z = files.find { |f| f =~ /\.zip\z/i }
        z
      end

      # ---------------- Main thread (SketchUp API) ----------------
      # Nhập DAE/định dạng SketchUp đọc được thành component definition rồi cho đặt bằng chuột. 1 bước Undo.
      def import_component(path, name: nil, expected_m: nil)
        model = Sketchup.active_model
        raise 'Không có công trình đang mở.' unless model
        defs = model.definitions
        unless defs.respond_to?(:import)
          ok = model.import(path, false)
          raise 'SketchUp không nhập được file này.' unless ok
          return [nil, []]
        end
        definition = nil
        model.start_operation('MT Smart Library: chèn model', true)
        begin
          definition = defs.import(path)
          raise 'SketchUp không nhập được file này.' unless definition
          if name && !name.to_s.strip.empty?
            nm = Util.safe_filename(name, 60)
            definition.name = defs.respond_to?(:unique_name) ? defs.unique_name(nm) : nm
          end
          model.commit_operation
        rescue StandardError
          model.abort_operation # hoàn tác: không để lại definition/vật liệu rác
          raise
        end
        warnings = size_warnings(definition, expected_m)
        model.place_component(definition, false)
        [definition, warnings]
      end

      INCH_TO_M = 0.0254

      def size_warnings(definition, expected_m)
        b = definition.bounds
        dims = [b.width, b.height, b.depth].map { |v| v.to_f * INCH_TO_M }
        w = []
        mx = dims.max
        w << 'Model rất nhỏ (< 5 mm) — có thể sai đơn vị.' if mx < 0.005
        w << "Model rất lớn (#{mx.round} m) — có thể sai đơn vị." if mx > 300
        if expected_m.is_a?(Array) && expected_m.size == 3 && expected_m.max.to_f.positive? && mx.positive?
          ratio = mx / expected_m.map(&:to_f).max
          w << "Kích thước sau nhập lệch #{((ratio - 1) * 100).round}% so với file gốc." if (ratio - 1).abs > 0.05
        end
        w
      rescue StandardError
        []
      end
    end
  end
end
