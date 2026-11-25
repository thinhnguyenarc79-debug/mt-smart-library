# bpy GIẢ LẬP tối thiểu cho kiểm thử convert_model.py (không phải Blender thật).
import os, struct
from mathutils import Matrix
MODE = os.environ.get('FAKE_BLENDER_MODE', 'ok')
V5 = MODE == 'v5'

class _App:
    version = (5, 0, 0) if V5 else (4, 5, 3)
    version_string = '5.0.0' if V5 else '4.5.3 LTS'
app = _App()

class _Mesh:
    def __init__(self, n):
        self.polygons = list(range(n)); self.vertices = list(range(n + 2))
class _Obj:
    def __init__(self, name, type_, polys=0):
        self.name = name; self.type = type_; self.data = _Mesh(polys) if type_ == 'MESH' else None
        self.matrix_world = Matrix(1.0)
        self.bound_box = [(0, 0, 0), (1.2, 0.8, 0.75)]
        self.users_collection = []
    def evaluated_get(self, dg): return self
class _Img:
    def __init__(self, name, packed):
        self.name = name; self.source = 'FILE'; self.type = 'IMAGE'; self.filepath = '' if packed else '//textures/wood.jpg'
        self.packed_file = type('P', (), {'data': b'\x89PNG\r\n\x1a\n' + b'0' * 20})() if packed else None
        self.filepath_raw = ''; self.file_format = 'PNG'
    def save(self): open(self.filepath_raw, 'wb').write(b'\x89PNG')
class _Mat:
    users = 1
class _Coll:
    def __init__(self): self.items = []
    def __iter__(self): return iter(list(self.items))
    def __len__(self): return len(self.items)
class _Data:
    def __init__(self):
        self.images = []; self.materials = [_Mat(), _Mat()]
        self.meshes = type('M', (), {'new_from_object': staticmethod(lambda o: _Mesh(4))})()
        self.objects = type('O', (), {'new': staticmethod(lambda n, me: _Obj(n, 'MESH', 4)), 'remove': staticmethod(lambda o, do_unlink=True: None)})()
data = _Data()
class _Scene:
    def __init__(self):
        self.objects = []
        self.unit_settings = type('U', (), {'scale_length': 1.0})()
class _Ctx:
    scene = _Scene()
    def evaluated_depsgraph_get(self): return None
context = _Ctx()
class _Path:
    @staticmethod
    def abspath(p): return p
path = _Path()

def _import(filepath, **kw):
    if MODE != 'nogeom':
        context.scene.objects.append(_Obj('Sofa', 'MESH', 1200))
        context.scene.objects.append(_Obj('Empty', 'EMPTY'))
        data.images.append(_Img('base color', True))
        data.images.append(_Img('rough', False))
def _export(filepath, **kw):
    with open(filepath, 'w') as f:
        f.write('<?xml version="1.0"?><COLLADA><asset><unit meter="1"/><up_axis>Z_UP</up_axis></asset></COLLADA>')
class _Ops:
    def __init__(self, names): self._n = names
    def __dir__(self): return list(self._n)
    def __getattr__(self, k):
        if k.startswith('_'): raise AttributeError(k)
        return self._n[k]
wm_ops = {'read_factory_settings': lambda use_empty=True: None, 'obj_import': _import, 'usd_import': _import,
          'stl_import': _import, 'ply_import': _import, 'collada_import': _import, 'open_mainfile': lambda **k: _import('')}
if not V5:
    wm_ops['collada_export'] = _export
class ops:
    wm = _Ops(wm_ops)
    import_scene = _Ops({'gltf': _import, 'fbx': _import})
    import_mesh = _Ops({'stl': _import, 'ply': _import})
