# MT SMART LIBRARY PRO — chuyển đổi model 3D sang COLLADA (.dae) để SketchUp 2022 nhập được.
# Chạy bởi Blender ở chế độ nền (không mở cửa sổ):
#   blender --background --factory-startup --disable-autoexec --python-exit-code 1 --python convert_model.py -- <vào> <ra.dae> <report.json>
# Mã thoát: 0 = thành công; 2 = định dạng không hỗ trợ; 3 = không có hình học; 4 = xuất DAE thất bại; 1 = lỗi khác.
import bpy
import json
import os
import re
import sys
import traceback

argv = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else []
if len(argv) < 3:
    print('MT: thiếu tham số')
    sys.exit(1)
SRC, OUT, REPORT = argv[0], argv[1], argv[2]
OUT_DIR = os.path.dirname(OUT)
TEX_DIR = os.path.join(OUT_DIR, 'textures')
rep = {'ok': False, 'blender': bpy.app.version_string, 'input': os.path.basename(SRC), 'warnings': []}


def finish(code, error=None):
    if error:
        rep['error'] = error
    rep['ok'] = code == 0
    with open(REPORT, 'w', encoding='utf-8') as f:
        json.dump(rep, f, ensure_ascii=False)
    sys.stdout.flush()
    sys.exit(code)


def ops_has(mod, name):
    try:
        return name in dir(mod)
    except Exception:
        return False


def do_import(path):
    ext = os.path.splitext(path)[1].lower()
    wm = bpy.ops.wm
    if ext in ('.glb', '.gltf'):
        bpy.ops.import_scene.gltf(filepath=path)
    elif ext == '.fbx':
        bpy.ops.import_scene.fbx(filepath=path, use_image_search=True)
    elif ext == '.obj':
        if ops_has(wm, 'obj_import'):
            wm.obj_import(filepath=path)
        else:
            bpy.ops.import_scene.obj(filepath=path)
    elif ext in ('.usd', '.usdz', '.usda', '.usdc'):
        wm.usd_import(filepath=path)
    elif ext == '.stl':
        if ops_has(wm, 'stl_import'):
            wm.stl_import(filepath=path)
        else:
            bpy.ops.import_mesh.stl(filepath=path)
    elif ext == '.ply':
        if ops_has(wm, 'ply_import'):
            wm.ply_import(filepath=path)
        else:
            bpy.ops.import_mesh.ply(filepath=path)
    elif ext == '.dae':
        wm.collada_import(filepath=path)
    elif ext == '.blend':
        wm.open_mainfile(filepath=path, load_ui=False)
    else:
        finish(2, 'Định dạng %s chưa hỗ trợ chuyển đổi.' % ext)


def curves_to_mesh():
    # Chữ, đường cong, bề mặt -> lưới (không đổi hình dạng)
    dg = bpy.context.evaluated_depsgraph_get()
    for ob in list(bpy.context.scene.objects):
        if ob.type in ('CURVE', 'SURFACE', 'META', 'FONT'):
            try:
                me = bpy.data.meshes.new_from_object(ob.evaluated_get(dg))
                new = bpy.data.objects.new(ob.name + '_mesh', me)
                new.matrix_world = ob.matrix_world.copy()
                for col in ob.users_collection:
                    col.objects.link(new)
                bpy.data.objects.remove(ob, do_unlink=True)
            except Exception as e:  # noqa
                rep['warnings'].append('Bỏ qua đối tượng %s: %s' % (ob.name, e))


def safe_name(s):
    s = re.sub(r'[^A-Za-z0-9._-]+', '_', s or 'tex').strip('._') or 'tex'
    return s[:60]


def export_textures():
    # Texture nhúng (GLB/FBX/USDZ) -> ghi ra file PNG/JPG cạnh file DAE; texture rời -> giữ đường dẫn tuyệt đối.
    os.makedirs(TEX_DIR, exist_ok=True)
    n = 0
    used = set()
    for img in bpy.data.images:
        if img.source not in ('FILE', 'GENERATED') or img.type != 'IMAGE':
            continue
        try:
            if img.packed_file is not None:
                data = bytes(img.packed_file.data)
                ext = '.png' if data[:4] == b'\x89PNG' else ('.jpg' if data[:2] == b'\xff\xd8' else '.png')
                base = safe_name(os.path.splitext(img.name)[0])
                name = base + ext
                k = 1
                while name.lower() in used:
                    name = '%s_%d%s' % (base, k, ext)
                    k += 1
                used.add(name.lower())
                path = os.path.join(TEX_DIR, name)
                if ext == '.png' and data[:4] != b'\x89PNG':
                    img.filepath_raw = path
                    img.file_format = 'PNG'
                    img.save()
                else:
                    with open(path, 'wb') as f:
                        f.write(data)
                img.filepath = path
                n += 1
            else:
                p = bpy.path.abspath(img.filepath)
                if p and os.path.isfile(p):
                    img.filepath = p
                    n += 1
                else:
                    rep['warnings'].append('Thiếu file texture: %s' % img.filepath)
        except Exception as e:  # noqa
            rep['warnings'].append('Texture %s: %s' % (img.name, e))
    rep['textures'] = n


def stats():
    meshes = [o for o in bpy.context.scene.objects if o.type == 'MESH']
    polys = sum(len(o.data.polygons) for o in meshes)
    verts = sum(len(o.data.vertices) for o in meshes)
    lo = [float('inf')] * 3
    hi = [float('-inf')] * 3
    for o in meshes:
        for c in o.bound_box:
            w = o.matrix_world @ __import__('mathutils').Vector(c)
            for i in range(3):
                lo[i] = min(lo[i], w[i])
                hi[i] = max(hi[i], w[i])
    dims = [round(hi[i] - lo[i], 4) if meshes else 0 for i in range(3)]
    return meshes, polys, verts, dims


def export_dae():
    full = dict(filepath=OUT, apply_modifiers=True, selected=False, include_children=True, include_armatures=False,
                include_animations=False, use_texture_copies=True, triangulate=False, active_uv_only=True,
                export_global_forward_selection='Y', export_global_up_selection='Z', apply_global_orientation=False)
    try:
        bpy.ops.wm.collada_export(**full)
    except TypeError:
        # Phiên bản Blender khác tên tham số -> dùng bộ tối thiểu
        bpy.ops.wm.collada_export(filepath=OUT, apply_modifiers=True, use_texture_copies=True)


try:
    if not ops_has(bpy.ops.wm, 'collada_export'):
        finish(4, 'Blender %s không có chức năng xuất DAE (cần Blender 4.5 LTS hoặc 3.x–4.x).' % bpy.app.version_string)
    bpy.ops.wm.read_factory_settings(use_empty=True)
    do_import(SRC)
    curves_to_mesh()
    meshes, polys, verts, dims = stats()
    rep.update({'objects': len(meshes), 'polygons': polys, 'vertices': verts, 'dimensions_m': dims,
                'materials': len([m for m in bpy.data.materials if m.users > 0])})
    if polys == 0:
        finish(3, 'File không có mặt (polygon) nào để chèn.')
    unit = bpy.context.scene.unit_settings
    rep['unit_scale'] = unit.scale_length
    export_textures()
    os.makedirs(OUT_DIR, exist_ok=True)
    export_dae()
    if not os.path.isfile(OUT) or os.path.getsize(OUT) == 0:
        finish(4, 'Blender không tạo được file DAE.')
    rep['dae_bytes'] = os.path.getsize(OUT)
    finish(0)
except SystemExit:
    raise
except Exception as e:  # noqa
    traceback.print_exc()
    finish(1, '%s: %s' % (type(e).__name__, e))
