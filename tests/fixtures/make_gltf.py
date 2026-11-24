# Tạo file glTF 2.0 kiểm thử (không dùng dữ liệu demo trong sản phẩm — chỉ cho test).
import json, struct, sys, os, base64, zlib

def png_1x1(rgb):
    def chunk(t, d):
        return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    raw = b'\x00' + bytes(rgb)
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 1, 1, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b'')

def pad4(b, fill=b'\x00'):
    return b + fill * ((4 - len(b) % 4) % 4)

def build(out_dir):
    os.makedirs(out_dir, exist_ok=True)
    bin_ = b''
    views, accs = [], []
    def add_view(data, stride=None):
        nonlocal bin_
        off = len(bin_)
        bin_ += pad4(data)
        v = {'buffer': 0, 'byteOffset': off, 'byteLength': len(data)}
        if stride: v['byteStride'] = stride
        views.append(v); return len(views) - 1
    # Quad 1m x 1m trên mặt XZ (sàn), dữ liệu xen kẽ POSITION(12) + TEXCOORD(8) => stride 20
    verts = [(0,0,0, 0,0), (1,0,0, 1,0), (1,0,-1, 1,1), (0,0,-1, 0,1)]
    inter = b''.join(struct.pack('<3f2f', *v) for v in verts)
    vi = add_view(inter, 20)
    accs.append({'bufferView': vi, 'byteOffset': 0, 'componentType': 5126, 'count': 4, 'type': 'VEC3', 'min': [0,0,-1], 'max': [1,0,0]})
    accs.append({'bufferView': vi, 'byteOffset': 12, 'componentType': 5126, 'count': 4, 'type': 'VEC2'})
    ii = add_view(struct.pack('<6H', 0, 1, 2, 0, 2, 3))
    accs.append({'bufferView': ii, 'componentType': 5123, 'count': 6, 'type': 'SCALAR'})
    # Dải tam giác (mode 5) 4 điểm, chỉ số uint8, cột đứng cao 2m
    strip = struct.pack('<12f', 0,0,0, 0,2,0, 0.1,0,0, 0.1,2,0)
    si = add_view(strip)
    accs.append({'bufferView': si, 'componentType': 5126, 'count': 4, 'type': 'VEC3', 'min': [0,0,0], 'max': [0.1,2,0]})
    ui8 = add_view(bytes([0, 1, 2, 3]))
    accs.append({'bufferView': ui8, 'componentType': 5121, 'count': 4, 'type': 'SCALAR'})
    img = add_view(png_1x1((200, 30, 30)))
    doc = {
        'asset': {'version': '2.0', 'generator': 'mt-test'},
        'scene': 0, 'scenes': [{'nodes': [0]}],
        'nodes': [{'name': 'root', 'children': [1, 2], 'scale': [2, 2, 2]},
                  {'name': 'floor', 'mesh': 0},
                  {'name': 'post', 'mesh': 1, 'translation': [1, 0, 0], 'rotation': [0, 0.7071068, 0, 0.7071068]}],
        'meshes': [{'primitives': [{'attributes': {'POSITION': 0, 'TEXCOORD_0': 1}, 'indices': 2, 'material': 0}]},
                   {'primitives': [{'attributes': {'POSITION': 3}, 'indices': 4, 'mode': 5, 'material': 1},
                                   {'attributes': {'POSITION': 3}, 'mode': 1}]}],
        'materials': [{'name': 'Gỗ sồi', 'pbrMetallicRoughness': {'baseColorTexture': {'index': 0}, 'baseColorFactor': [1, 1, 1, 1]}},
                      {'name': 'Kính', 'alphaMode': 'BLEND', 'pbrMetallicRoughness': {'baseColorFactor': [0.2, 0.4, 0.6, 0.5]}}],
        'textures': [{'source': 0}], 'images': [{'bufferView': img, 'mimeType': 'image/png'}],
        'accessors': accs, 'bufferViews': views,
        'buffers': [{'byteLength': len(bin_)}]
    }
    js = pad4(json.dumps(doc).encode(), b' ')
    glb = struct.pack('<4sII', b'glTF', 2, 12 + 8 + len(js) + 8 + len(bin_)) + struct.pack('<II', len(js), 0x4E4F534A) + js + struct.pack('<II', len(bin_), 0x004E4942) + bin_
    open(os.path.join(out_dir, 'test.glb'), 'wb').write(glb)
    # Bản .gltf + .bin + texture rời (giống gói gltf của Sketchfab)
    d2 = dict(doc); d2['buffers'] = [{'byteLength': len(bin_), 'uri': 'scene.bin'}]
    d2['images'] = [{'uri': 'textures/wood.png'}]
    os.makedirs(os.path.join(out_dir, 'textures'), exist_ok=True)
    open(os.path.join(out_dir, 'textures', 'wood.png'), 'wb').write(png_1x1((10, 200, 10)))
    open(os.path.join(out_dir, 'scene.bin'), 'wb').write(bin_)
    open(os.path.join(out_dir, 'scene.gltf'), 'w').write(json.dumps(d2))
    # Bản nén Draco (không hỗ trợ) và bản đường dẫn nguy hiểm
    d3 = dict(doc); d3['extensionsRequired'] = ['KHR_draco_mesh_compression']; d3['buffers'] = d2['buffers']
    open(os.path.join(out_dir, 'draco.gltf'), 'w').write(json.dumps(d3))
    d4 = dict(doc); d4['buffers'] = [{'byteLength': 10, 'uri': '../../etc/passwd'}]
    open(os.path.join(out_dir, 'evil.gltf'), 'w').write(json.dumps(d4))

if __name__ == '__main__':
    build(sys.argv[1])
