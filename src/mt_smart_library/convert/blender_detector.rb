# frozen_string_literal: true
require 'json'

module MTDesign
  module SmartLibrary
    # Tìm Blender trên máy (bản cài, Steam, Portable, PATH, đường dẫn người dùng chọn) và kiểm tra khả năng xuất DAE.
    # Blender 5.x đã bỏ COLLADA -> không dùng để xuất DAE. Ưu tiên 4.5 LTS.
    module BlenderDetector
      MIN = [2, 93].freeze
      MAX_EXCLUSIVE = [5, 0].freeze

      module_function

      def candidates(user_path = nil)
        list = []
        list << user_path if user_path && !user_path.to_s.empty?
        env = Util.env_value('MT_BLENDER_PATH')
        list << env if env && !env.empty?
        if Util::WINDOWS
          %w[ProgramFiles ProgramW6432 ProgramFiles(x86) LOCALAPPDATA].each do |k|
            base = Util.env_value(k)
            next unless base && !base.empty?
            b = Util.norm_path(base)
            list.concat(Dir.glob("#{b}/Blender Foundation/*/blender.exe"))
            list.concat(Dir.glob("#{b}/Programs/Blender Foundation/*/blender.exe"))
            list << "#{b}/Steam/steamapps/common/Blender/blender.exe"
          end
          %w[C D E].each do |d|
            list.concat(Dir.glob("#{d}:/Blender*/blender.exe"))
            list.concat(Dir.glob("#{d}:/Blender*/*/blender.exe"))
          end
        end
        ENV['PATH'].to_s.split(File::PATH_SEPARATOR).each do |dir|
          %w[blender.exe blender].each { |n| list << File.join(dir, n) }
        end
        list.map { |p| Util.norm_path(p) }.uniq { |p| Util.path_key(p) }.select { |p| File.file?(p) }
      end

      # Phiên bản ước đoán từ tên thư mục (để sắp xếp trước khi kiểm tra thật).
      def guess_version(path)
        m = path.to_s.match(/Blender[ _-]?(\d+)\.(\d+)/i)
        m ? [m[1].to_i, m[2].to_i] : nil
      end

      def supported_version?(ver)
        return false unless ver
        (ver <=> MIN) >= 0 && (ver <=> MAX_EXCLUSIVE) < 0
      end

      # Ưu tiên: 4.5 > 4.x > 3.x; bản >= 5.0 xếp cuối (thường không xuất được DAE).
      def sort(paths)
        paths.sort_by do |p|
          v = guess_version(p)
          if v.nil? then [1, 0, 0]
          elsif !supported_version?(v) then [2, 0, 0]
          else [0, -(v == [4, 5] ? 99 : v[0]), -v[1]]
          end
        end
      end

      # Đối số kiểm tra: Blender ghi khả năng ra file JSON (không cần đọc stdout).
      def probe_args(exe, out_json)
        code = 'import bpy,json,sys,os' \
               ";w=dir(bpy.ops.wm);s=dir(bpy.ops.import_scene)" \
               ";d={'version':list(bpy.app.version),'version_string':bpy.app.version_string" \
               ",'collada_export':'collada_export' in w,'gltf':'gltf' in s,'fbx':'fbx' in s" \
               ",'obj':('obj_import' in w) or ('obj' in s),'usd':'usd_import' in w" \
               ",'stl':('stl_import' in w) or ('stl' in dir(bpy.ops.import_mesh))" \
               ",'ply':('ply_import' in w) or ('ply' in dir(bpy.ops.import_mesh))}" \
               ";open(#{JSON.generate(out_json)},'w',encoding='utf-8').write(json.dumps(d))"
        [exe, '--background', '--factory-startup', '--disable-autoexec', '--python-exit-code', '1', '--python-expr', code]
      end

      def read_probe(out_json)
        d = JSON.parse(File.read(out_json, encoding: 'UTF-8'))
        ver = Array(d['version']).first(2).map(&:to_i)
        ok = d['collada_export'] == true && supported_version?(ver)
        why = if !supported_version?(ver) && (ver <=> MAX_EXCLUSIVE) >= 0
                "Blender #{d['version_string']} không còn hỗ trợ xuất DAE. Cần Blender 4.5 LTS (hoặc 3.x–4.x)."
              elsif !supported_version?(ver)
                "Blender #{d['version_string']} quá cũ. Cần Blender 4.5 LTS (hoặc 3.x–4.x)."
              elsif d['collada_export'] != true
                "Blender #{d['version_string']} không có chức năng xuất DAE."
              end
        d.merge('ok' => ok, 'reason' => why)
      rescue StandardError => e
        { 'ok' => false, 'reason' => "Không đọc được kết quả kiểm tra Blender: #{e.message}" }
      end
    end
  end
end
