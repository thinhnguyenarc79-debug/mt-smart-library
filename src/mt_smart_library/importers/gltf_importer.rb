# frozen_string_literal: true
require 'json'
require 'base64'
require 'fileutils'

module MTDesign
  module SmartLibrary
    # Nhập glTF 2.0 (.glb / .gltf) trực tiếp vào SketchUp 2022 (SketchUp 2022 không có importer glTF).
    # - GltfParser: thuần Ruby, có thể chạy luồng nền — đọc lưới tam giác, ma trận node, UV, vật liệu, ảnh texture.
    # - GltfBuilder: chạy main thread — tạo component bằng PolygonMesh (nhanh), gán vật liệu/texture.
    # Đơn vị glTF là mét, trục Y hướng lên → đổi sang inch và trục Z hướng lên của SketchUp.
    module Gltf
      class Error < StandardError; end
      M_TO_INCH = 39.37007874015748
      COMP = { 5120 => ['c', 1], 5121 => ['C', 1], 5122 => ['s<', 2], 5123 => ['S<', 2], 5125 => ['L<', 4], 5126 => ['e', 4] }.freeze
      NCOMP = { 'SCALAR' => 1, 'VEC2' => 2, 'VEC3' => 3, 'VEC4' => 4, 'MAT4' => 16 }.freeze
      UNSUPPORTED_EXT = %w[KHR_draco_mesh_compression EXT_meshopt_compression KHR_mesh_quantization].freeze
      MAX_TRIANGLES = 3_000_000

      Primitive = Struct.new(:points, :uvs, :tris, :material)
      Material = Struct.new(:name, :color, :alpha, :image_path)
      Model = Struct.new(:name, :primitives, :materials, :triangles, :warnings)

      class Parser
        def initialize(path, tex_dir)
          @path = path
          @tex_dir = tex_dir
          @warnings = []
        end

        def parse
          load_doc
          req = Array(@doc['extensionsRequired']) & UNSUPPORTED_EXT
          raise Error, "Model dùng định dạng nén chưa hỗ trợ (#{req.join(', ')})." unless req.empty?
          @materials = Array(@doc['materials']).each_with_index.map { |m, i| material(m, i) }
          prims = []
          scene = @doc['scenes'] && @doc['scenes'][@doc['scene'].to_i]
          roots = scene ? Array(scene['nodes']) : (0...Array(@doc['nodes']).size).to_a
          roots.each { |n| walk(n, axis_matrix, prims, 0) }
          if prims.empty? && Array(@doc['meshes']).any? && Array(@doc['nodes']).empty?
            Array(@doc['meshes']).each_index { |mi| add_mesh(mi, axis_matrix, prims) }
          end
          raise Error, 'File không có lưới tam giác nào để chèn.' if prims.empty?
          tris = prims.sum { |p| p.tris.size / 3 }
          raise Error, "Model quá nặng (#{tris} tam giác) — vượt giới hạn #{MAX_TRIANGLES}." if tris > MAX_TRIANGLES
          Model.new(File.basename(@path, '.*'), prims, @materials, tris, @warnings)
        rescue Error
          raise
        rescue StandardError => e
          raise Error, "File glTF hỏng hoặc chưa hỗ trợ (#{e.class.name.split('::').last})."
        end

        private

        def load_doc
          raw = File.binread(@path)
          if raw.byteslice(0, 4) == 'glTF'.b
            raise Error, 'File GLB bị hỏng hoặc tải chưa xong.' if raw.bytesize < 20
            _magic, ver, len = raw.unpack('a4L<L<')
            raise Error, "GLB phiên bản #{ver} không hỗ trợ." unless ver == 2
            off = 12
            @glb_bin = nil
            while off + 8 <= [len, raw.bytesize].min
              clen, ctype = raw.byteslice(off, 8).unpack('L<L<')
              data = raw.byteslice(off + 8, clen)
              if ctype == 0x4E4F534A then @doc = JSON.parse(Util.utf8(data))
              elsif ctype == 0x004E4942 then @glb_bin = data
              end
              off += 8 + clen
            end
            raise Error, 'GLB thiếu phần JSON.' unless @doc
          else
            @doc = JSON.parse(Util.utf8(raw))
          end
          raise Error, 'Không phải file glTF 2.0.' unless @doc.is_a?(Hash) && @doc.dig('asset', 'version').to_s.start_with?('2')
          @buffers = Array(@doc['buffers']).each_with_index.map { |b, i| load_buffer(b, i) }
        rescue JSON::ParserError => e
          raise Error, "glTF hỏng: #{e.message[0, 100]}"
        end

        def load_buffer(b, i)
          uri = b['uri']
          return @glb_bin || raise(Error, 'GLB thiếu dữ liệu nhị phân.') if uri.nil? && i.zero?
          return Base64.decode64(uri.split(',', 2)[1].to_s) if uri.to_s.start_with?('data:')
          f = safe_rel(uri)
          raise Error, "Thiếu file dữ liệu #{uri}." unless f && File.file?(f)
          File.binread(f)
        end

        # Chỉ cho đọc file nằm cùng thư mục model (chặn ../).
        def safe_rel(uri)
          rel = uri.to_s.gsub('%20', ' ')
          return nil if rel.include?('..') || rel.start_with?('/') || rel =~ /\A[a-z]+:/i
          File.join(File.dirname(@path), rel)
        end

        def accessor(idx)
          a = @doc['accessors'][idx]
          raise Error, 'Accessor không hợp lệ.' unless a
          fmt, size = COMP[a['componentType']]
          raise Error, "Kiểu dữ liệu #{a['componentType']} không hỗ trợ." unless fmt
          n = NCOMP[a['type']] || 1
          count = a['count'].to_i
          return Array.new(count) { Array.new(n, 0) } unless a['bufferView'] # accessor rỗng (sparse) -> 0
          bv = @doc['bufferViews'][a['bufferView']]
          buf = @buffers[bv['buffer']]
          base = bv['byteOffset'].to_i + a['byteOffset'].to_i
          elem = size * n
          stride = bv['byteStride'].to_i.positive? ? bv['byteStride'].to_i : elem
          vals = if stride == elem
                   buf.byteslice(base, count * elem).to_s.unpack("#{fmt}*")
                 else
                   (0...count).flat_map { |k| buf.byteslice(base + k * stride, elem).to_s.unpack("#{fmt}#{n}") }
                 end
          raise Error, 'Dữ liệu lưới bị thiếu.' if vals.size < count * n
          if a['normalized'] && fmt != 'e'
            div = { 'C' => 255.0, 'S<' => 65_535.0, 'c' => 127.0, 's<' => 32_767.0 }[fmt]
            vals = vals.map { |v| v / div } if div
          end
          vals.each_slice(n).to_a
        end

        def walk(ni, parent, prims, depth)
          raise Error, 'Cây node quá sâu.' if depth > 64
          node = @doc['nodes'][ni]
          return unless node
          m = mul(parent, local_matrix(node))
          add_mesh(node['mesh'], m, prims) if node['mesh']
          Array(node['children']).each { |c| walk(c, m, prims, depth + 1) }
        end

        def add_mesh(mi, m, prims)
          mesh = @doc['meshes'][mi]
          return unless mesh
          flip = det3(m) < 0
          Array(mesh['primitives']).each do |pr|
            mode = (pr['mode'] || 4).to_i
            unless [4, 5, 6].include?(mode)
              @warnings << 'Bỏ qua phần đường/điểm (không phải mặt).'
              next
            end
            pos_i = pr.dig('attributes', 'POSITION')
            next unless pos_i
            pos = accessor(pos_i)
            pts = pos.map { |p| xform(m, p) }
            uv_i = pr.dig('attributes', 'TEXCOORD_0')
            uvs = uv_i ? accessor(uv_i).map { |u| [u[0].to_f, 1.0 - u[1].to_f] } : nil
            idx = pr['indices'] ? accessor(pr['indices']).flatten : (0...pts.size).to_a
            tris = triangles(idx, mode)
            tris = tris.each_slice(3).flat_map { |a, b, c| [a, c, b] } if flip
            tris = tris.each_slice(3).select { |a, b, c| c && a < pts.size && b < pts.size && c < pts.size && a != b && b != c && a != c }.flatten
            next if tris.empty?
            prims << Primitive.new(pts, uvs, tris, pr['material'])
          end
        end

        def triangles(idx, mode)
          return idx if mode == 4
          out = []
          if mode == 5
            (0...(idx.size - 2)).each { |i| out.concat(i.even? ? [idx[i], idx[i + 1], idx[i + 2]] : [idx[i + 1], idx[i], idx[i + 2]]) }
          else
            (1...(idx.size - 1)).each { |i| out.concat([idx[0], idx[i], idx[i + 1]]) }
          end
          out
        end

        def material(m, i)
          pbr = m['pbrMetallicRoughness'] || {}
          f = pbr['baseColorFactor'] || [1, 1, 1, 1]
          color = f.first(3).map { |c| (c.to_f.clamp(0, 1) * 255).round }
          alpha = f[3].nil? ? 1.0 : f[3].to_f.clamp(0, 1)
          alpha = 1.0 if m['alphaMode'].to_s == 'OPAQUE' || m['alphaMode'].nil?
          img = nil
          ti = pbr.dig('baseColorTexture', 'index')
          img = extract_image(ti, i) if ti
          Material.new(Util.safe_filename(m['name'] || "Vat lieu #{i + 1}", 60), color, alpha, img)
        rescue StandardError => e
          @warnings << "Vật liệu #{i}: #{e.message}"
          Material.new("Vat lieu #{i + 1}", [200, 200, 200], 1.0, nil)
        end

        def extract_image(tex_index, mat_index)
          tex = @doc['textures'] && @doc['textures'][tex_index]
          return nil unless tex && tex['source']
          img = @doc['images'][tex['source']]
          return nil unless img
          data, mime = if img['bufferView']
                         bv = @doc['bufferViews'][img['bufferView']]
                         [@buffers[bv['buffer']].byteslice(bv['byteOffset'].to_i, bv['byteLength'].to_i), img['mimeType']]
                       elsif img['uri'].to_s.start_with?('data:')
                         head, b64 = img['uri'].split(',', 2)
                         [Base64.decode64(b64.to_s), head[/data:([^;]+)/, 1]]
                       else
                         f = safe_rel(img['uri'])
                         return nil unless f && File.file?(f)
                         [File.binread(f), nil]
                       end
          ext = if data.to_s.start_with?("\x89PNG".b) then '.png'
                elsif data.to_s.start_with?("\xFF\xD8".b) then '.jpg'
                end
          unless ext
            @warnings << "Bỏ qua texture định dạng #{mime || 'không rõ'} (SketchUp chỉ đọc PNG/JPG)."
            return nil
          end
          FileUtils.mkdir_p(@tex_dir)
          out = File.join(@tex_dir, "tex_#{mat_index}_#{tex['source']}#{ext}")
          File.binwrite(out, data)
          out
        end

        # ---- Ma trận 4x4 (mảng 16 phần tử, cột chính như glTF) ----
        def axis_matrix
          s = M_TO_INCH # (x, y, z)_glTF -> (x, -z, y)_SketchUp, mét -> inch
          [s, 0, 0, 0, 0, 0, s, 0, 0, -s, 0, 0, 0, 0, 0, 1]
        end

        def local_matrix(node)
          return node['matrix'].map(&:to_f) if node['matrix'].is_a?(Array) && node['matrix'].size == 16
          t = node['translation'] || [0, 0, 0]
          r = node['rotation'] || [0, 0, 0, 1]
          sc = node['scale'] || [1, 1, 1]
          x, y, z, w = r.map(&:to_f)
          rm = [1 - 2 * (y * y + z * z), 2 * (x * y + z * w), 2 * (x * z - y * w),
                2 * (x * y - z * w), 1 - 2 * (x * x + z * z), 2 * (y * z + x * w),
                2 * (x * z + y * w), 2 * (y * z - x * w), 1 - 2 * (x * x + y * y)]
          [rm[0] * sc[0], rm[1] * sc[0], rm[2] * sc[0], 0,
           rm[3] * sc[1], rm[4] * sc[1], rm[5] * sc[1], 0,
           rm[6] * sc[2], rm[7] * sc[2], rm[8] * sc[2], 0,
           t[0].to_f, t[1].to_f, t[2].to_f, 1]
        end

        def mul(a, b)
          out = Array.new(16, 0.0)
          4.times do |c|
            4.times do |r|
              out[c * 4 + r] = a[r] * b[c * 4] + a[4 + r] * b[c * 4 + 1] + a[8 + r] * b[c * 4 + 2] + a[12 + r] * b[c * 4 + 3]
            end
          end
          out
        end

        def xform(m, p)
          x = p[0].to_f
          y = p[1].to_f
          z = p[2].to_f
          [m[0] * x + m[4] * y + m[8] * z + m[12], m[1] * x + m[5] * y + m[9] * z + m[13], m[2] * x + m[6] * y + m[10] * z + m[14]]
        end

        def det3(m)
          m[0] * (m[5] * m[10] - m[9] * m[6]) - m[4] * (m[1] * m[10] - m[9] * m[2]) + m[8] * (m[1] * m[6] - m[5] * m[2])
        end
      end

      # Dựng hình trong SketchUp (main thread). Trả ComponentDefinition.
      module Builder
        module_function

        def build(model_data, su_model)
          defs = su_model.definitions
          dname = defs.respond_to?(:unique_name) ? defs.unique_name(model_data.name) : model_data.name
          su_model.start_operation('MT Smart Library: chèn model glTF', true)
          begin
            definition = defs.add(dname)
            mats = model_data.materials.map { |m| make_material(su_model, m) }
            model_data.primitives.each do |pr|
              mat = pr.material ? mats[pr.material] : nil
              add_primitive(definition.entities, pr, mat)
            end
            su_model.commit_operation
            definition
          rescue StandardError
            su_model.abort_operation
            raise
          end
        end

        def make_material(su_model, m)
          mat = su_model.materials.add("MT_#{m.name}")
          mat.color = Sketchup::Color.new(*m.color)
          mat.alpha = m.alpha if m.alpha < 1.0
          if m.image_path && File.file?(m.image_path)
            begin
              mat.texture = m.image_path
            rescue StandardError
              nil
            end
          end
          mat
        end

        def add_primitive(entities, pr, mat)
          tris = pr.tris
          ntri = tris.size / 3
          return if ntri.zero?
          mesh = Geom::PolygonMesh.new(pr.points.size, ntri)
          map = {}
          pr.points.each_with_index { |p, i| map[i] = mesh.add_point(Geom::Point3d.new(p[0], p[1], p[2])) }
          tris.each_slice(3) do |a, b, c|
            ia = map[a]
            ib = map[b]
            ic = map[c]
            next if ia == ib || ib == ic || ia == ic # mặt suy biến sau khi gộp điểm trùng
            mesh.add_polygon(ia, ib, ic)
          end
          if pr.uvs && mesh.respond_to?(:set_uv)
            pr.uvs.each_with_index do |uv, i|
              mesh.set_uv(map[i], Geom::Point3d.new(uv[0], uv[1], 1), true)
            rescue StandardError
              nil
            end
          end
          flags = Geom::PolygonMesh::AUTO_SOFTEN | Geom::PolygonMesh::SMOOTH_SOFT_EDGES
          grp = entities.add_group
          grp.entities.add_faces_from_mesh(mesh, flags, mat, mat)
          grp
        end
      end

      module_function

      def parse(path, tex_dir)
        Parser.new(path, tex_dir).parse
      end
    end
  end
end
