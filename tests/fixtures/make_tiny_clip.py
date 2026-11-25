# -*- coding: utf-8 -*-
"""Tạo bộ mô hình ONNX NHỎ có cùng giao diện với CLIP (pixel_values → image_embeds, input_ids → text_embeds)
để kiểm thử thật đường ống ONNX Runtime của inference_worker.py khi máy test không tải được CLIP thật.
Vector ảnh = màu trung bình trên lưới 4×4 (48 chiều): phân biệt được hình dáng (tròn/vuông) và màu — KHÔNG phải CLIP.
Mã hóa protobuf ONNX bằng tay (không cần gói onnx)."""
import json
import os
import struct
import sys


def varint(n):
    out = b''
    while True:
        b = n & 0x7F
        n >>= 7
        out += bytes([b | (0x80 if n else 0)])
        if not n:
            return out


def key(field, wt):
    return varint((field << 3) | wt)


def ln(field, data):
    if isinstance(data, str):
        data = data.encode()
    return key(field, 2) + varint(len(data)) + data


def vi(field, n):
    return key(field, 0) + varint(n)


def attr_ints(name, vals):
    return ln(1, name) + b''.join(vi(8, v) for v in vals) + vi(20, 7)


def attr_int(name, v):
    return ln(1, name) + vi(3, v) + vi(20, 2)


def node(op, ins, outs, attrs=()):
    return b''.join(ln(1, i) for i in ins) + b''.join(ln(2, o) for o in outs) + ln(4, op) + b''.join(ln(5, a) for a in attrs)


def dim(v):
    return ln(1, vi(1, v) if isinstance(v, int) else ln(2, v))


def value_info(name, elem, dims):
    shape = b''.join(dim(d) for d in dims)
    tt = vi(1, elem) + ln(2, shape)
    return ln(1, name) + ln(2, ln(1, tt))


def tensor(name, dims, floats):
    raw = struct.pack('<%df' % len(floats), *floats)
    return b''.join(vi(1, d) for d in dims) + vi(2, 1) + ln(8, name) + ln(9, raw)


def model(nodes, inputs, outputs, inits=()):
    g = b''.join(ln(1, n) for n in nodes) + ln(2, 'g') + b''.join(ln(5, t) for t in inits) + \
        b''.join(ln(11, i) for i in inputs) + b''.join(ln(12, o) for o in outputs)
    return vi(1, 8) + ln(8, ln(1, '') + vi(2, 13)) + ln(7, g)


def main(out):
    os.makedirs(out, exist_ok=True)
    vis = model(
        [node('AveragePool', ['pixel_values'], ['p'], [attr_ints('kernel_shape', [56, 56]), attr_ints('strides', [56, 56])]),
         node('Flatten', ['p'], ['image_embeds'], [attr_int('axis', 1)])],
        [value_info('pixel_values', 1, ['batch', 3, 224, 224])],
        [value_info('image_embeds', 1, ['batch', 48])])
    open(os.path.join(out, 'vision_model.onnx'), 'wb').write(vis)
    txt = model(
        [node('Cast', ['input_ids'], ['f'], [attr_int('to', 1)]),
         node('ReduceMean', ['f'], ['m'], [attr_ints('axes', [1]), attr_int('keepdims', 1)]),
         node('MatMul', ['m', 'W'], ['text_embeds'])],
        [value_info('input_ids', 7, ['batch', 'seq'])],
        [value_info('text_embeds', 1, ['batch', 48])],
        [tensor('W', [1, 48], [((i * 37) % 11 - 5) / 5.0 for i in range(48)])])
    open(os.path.join(out, 'text_model.onnx'), 'wb').write(txt)
    vocab = {'<|startoftext|>': 49406, '<|endoftext|>': 49407, 'a</w>': 320, 'sofa</w>': 15723, 'chair</w>': 4269}
    json.dump(vocab, open(os.path.join(out, 'vocab.json'), 'w'))
    open(os.path.join(out, 'merges.txt'), 'w').write('#version: 0.2\ns o\nso f\nsof a</w>\n')
    json.dump({'vision_file': 'vision_model.onnx', 'text_file': 'text_model.onnx', 'test_model': True},
              open(os.path.join(out, 'model_config.json'), 'w'))


if __name__ == '__main__':
    main(sys.argv[1])
