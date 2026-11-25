# -*- coding: utf-8 -*-
"""MT VISUAL SEARCH ENGINE — tiến trình AI độc lập (chạy bằng Python riêng của plugin, không chạy trong SketchUp).

Mô hình: CLIP ViT-B/32 dạng ONNX (vision + text), chạy bằng ONNX Runtime trên CPU (DirectML nếu có GPU tương thích).
Giao tiếp với Ruby qua thư mục công việc (không shell, không cổng mạng):
  <jobs>/<id>.job.json   Ruby ghi (atomic)        → worker đọc, xóa
  <jobs>/<id>.prog.json  worker ghi tiến trình
  <jobs>/<id>.out.json   worker ghi kết quả (atomic)
  <jobs>/<id>.cancel     Ruby yêu cầu hủy
  <jobs>/heartbeat       Ruby chạm mỗi vài giây; worker tự thoát khi Ruby (SketchUp) không còn chạy.

Công việc:
  probe        nạp mô hình, trả thiết bị và số chiều vector
  embed_query  ảnh mẫu (+ vùng cắt) → vector (lưu .npy) + nhóm đồ vật dự đoán (so với vector văn bản)
  search_local so vector ảnh mẫu với chỉ mục thumbnail thư viện máy tính
  index_sync   cập nhật chỉ mục: chỉ tính model mới/đổi, xóa model không còn
  rank_urls    tải thumbnail kết quả online (chỉ host được phép), tính vector, xếp hạng
"""
import faulthandler
import io
import json
import os
import re
import sys
import time
import hashlib
import traceback
import urllib.request
import urllib.error
import urllib.parse


def _early_log():
    """Ghi stdout + stderr + faulthandler (lỗi native như access violation) ra file log ngay từ đầu,
    vì trên Windows tiến trình chạy không cửa sổ, không có console."""
    if '--log' not in sys.argv:
        faulthandler.enable()
        return None
    try:
        f = open(sys.argv[sys.argv.index('--log') + 1], 'a', encoding='utf-8', buffering=1)
    except OSError:
        faulthandler.enable()
        return None
    sys.stdout = f
    sys.stderr = f
    faulthandler.enable(file=f, all_threads=True)
    f.write('\n=== worker start %s pid=%d argv=%s python=%s\n' % (time.strftime('%Y-%m-%d %H:%M:%S'), os.getpid(),
                                                               sys.argv[1:], sys.version.split()[0]))
    return f


_LOGF = _early_log()

try:
    import numpy as np
    from PIL import Image
    _IMPORT_ERR = None
except Exception:  # thiếu thư viện: báo rõ cho Ruby thay vì chết im lặng
    _IMPORT_ERR = traceback.format_exc()
    np = None
    Image = None

MEAN = np.array([0.48145466, 0.4578275, 0.40821073], dtype=np.float32) if np else None
STD = np.array([0.26862954, 0.26130258, 0.27577711], dtype=np.float32) if np else None
PNG_SIG = b'\x89PNG\r\n\x1a\n'
PNG_END = b'IEND\xaeB`\x82'
IMG_EXTS = ('.png', '.jpg', '.jpeg', '.webp')
UA = 'MT-Smart-Library-Pro/visual-search (SketchUp plugin; MT Design)'

# Nhóm đồ vật kiến trúc – nội thất cho phân loại zero-shot (từ khóa Anh để lấy ứng viên online + tiếng Việt để hiển thị).
CATEGORIES = [
    ('sofa', 'sofa', ['sofa', 'couch']), ('sectional sofa', 'sofa góc', ['sectional sofa', 'corner sofa']),
    ('armchair', 'ghế bành', ['armchair', 'lounge chair']), ('dining chair', 'ghế ăn', ['dining chair', 'chair']),
    ('office chair', 'ghế văn phòng', ['office chair']), ('bar stool', 'ghế quầy bar', ['bar stool', 'stool']),
    ('bench', 'ghế băng', ['bench']), ('ottoman', 'đôn', ['ottoman', 'pouf']),
    ('dining table', 'bàn ăn', ['dining table', 'table']), ('coffee table', 'bàn trà', ['coffee table']),
    ('side table', 'bàn góc', ['side table', 'end table']), ('desk', 'bàn làm việc', ['desk', 'work desk']),
    ('bed', 'giường', ['bed', 'double bed']), ('bunk bed', 'giường tầng', ['bunk bed']),
    ('wardrobe', 'tủ quần áo', ['wardrobe', 'closet']), ('kitchen cabinet', 'tủ bếp', ['kitchen cabinet', 'kitchen']),
    ('tv cabinet', 'kệ tivi', ['tv cabinet', 'tv stand']), ('bookshelf', 'kệ sách', ['bookshelf', 'shelf']),
    ('sideboard', 'tủ trang trí', ['sideboard', 'cabinet']), ('chest of drawers', 'tủ ngăn kéo', ['chest of drawers', 'dresser']),
    ('nightstand', 'tab đầu giường', ['nightstand', 'bedside table']), ('dressing table', 'bàn trang điểm', ['dressing table', 'vanity']),
    ('pendant lamp', 'đèn thả', ['pendant lamp', 'pendant light']), ('chandelier', 'đèn chùm', ['chandelier']),
    ('floor lamp', 'đèn cây', ['floor lamp']), ('table lamp', 'đèn bàn', ['table lamp']),
    ('ceiling light', 'đèn trần', ['ceiling light', 'downlight']), ('wall lamp', 'đèn tường', ['wall lamp', 'sconce']),
    ('curtain', 'rèm cửa', ['curtain', 'drapes']), ('rug', 'thảm', ['rug', 'carpet']),
    ('potted plant', 'cây cảnh', ['potted plant', 'plant']), ('tree', 'cây xanh', ['tree']),
    ('vase decor', 'đồ trang trí', ['vase', 'decor']), ('wall art', 'tranh treo tường', ['wall art', 'painting']),
    ('mirror', 'gương', ['mirror']), ('bathtub', 'bồn tắm', ['bathtub']), ('toilet', 'bồn cầu', ['toilet']),
    ('washbasin', 'lavabo', ['washbasin', 'sink']), ('door', 'cửa đi', ['door']), ('window', 'cửa sổ', ['window']),
    ('staircase', 'cầu thang', ['staircase', 'stairs']), ('kitchen appliance', 'thiết bị bếp', ['refrigerator', 'oven']),
    ('car', 'ô tô', ['car']), ('outdoor furniture', 'bàn ghế sân vườn', ['outdoor furniture', 'garden chair']),
    ('ceiling', 'trần', ['ceiling']), ('altar', 'bàn thờ', ['altar']), ('piano', 'đàn piano', ['piano']),
    ('fireplace', 'lò sưởi', ['fireplace']),
]


def log(msg):
    sys.stderr.write(time.strftime('%H:%M:%S ') + str(msg) + '\n')
    sys.stderr.flush()


def write_json(path, obj):
    tmp = path + '.tmp%d' % os.getpid()
    with open(tmp, 'w', encoding='utf-8') as f:
        json.dump(obj, f, ensure_ascii=False)
    os.replace(tmp, path)


class Cancelled(Exception):
    pass


# --------------------------------------------------------------------------- CLIP tokenizer (BPE)
def bytes_to_unicode():
    bs = list(range(ord('!'), ord('~') + 1)) + list(range(ord('¡'), ord('¬') + 1)) + list(range(ord('®'), ord('ÿ') + 1))
    cs = bs[:]
    n = 0
    for b in range(256):
        if b not in bs:
            bs.append(b)
            cs.append(256 + n)
            n += 1
    return dict(zip(bs, [chr(c) for c in cs]))


class ClipTokenizer:
    SOT = '<|startoftext|>'
    EOT = '<|endoftext|>'

    def __init__(self, vocab_path, merges_path):
        with open(vocab_path, encoding='utf-8') as f:
            self.encoder = json.load(f)
        with open(merges_path, encoding='utf-8') as f:
            lines = f.read().split('\n')
        merges = [tuple(l.split()) for l in lines[1:] if l and not l.startswith('#') and len(l.split()) == 2]
        self.ranks = dict(zip(merges, range(len(merges))))
        self.byte_encoder = bytes_to_unicode()
        self.cache = {}
        self.pat = re.compile(r"'s|'t|'re|'ve|'m|'ll|'d|[a-z]+|[0-9]|[^\sa-z0-9]+")

    def bpe(self, token):
        if token in self.cache:
            return self.cache[token]
        word = tuple(token[:-1]) + (token[-1] + '</w>',)
        while len(word) > 1:
            pairs = set(zip(word, word[1:]))
            best = min(pairs, key=lambda p: self.ranks.get(p, 1e12))
            if best not in self.ranks:
                break
            a, b = best
            out, i = [], 0
            while i < len(word):
                if i < len(word) - 1 and word[i] == a and word[i + 1] == b:
                    out.append(a + b)
                    i += 2
                else:
                    out.append(word[i])
                    i += 1
            word = tuple(out)
        self.cache[token] = word
        return word

    def encode(self, text, max_len=77):
        text = re.sub(r'\s+', ' ', text.strip().lower())
        ids = [self.encoder[self.SOT]]
        for tok in self.pat.findall(text):
            t = ''.join(self.byte_encoder[b] for b in tok.encode('utf-8'))
            ids.extend(self.encoder[p] for p in self.bpe(t) if p in self.encoder)
        ids = ids[:max_len - 1] + [self.encoder[self.EOT]]
        return ids


# --------------------------------------------------------------------------- Ảnh
def open_image(src):
    """src: đường dẫn ảnh, bytes, hoặc file .skp (lấy ảnh xem trước nhúng)."""
    if isinstance(src, (bytes, bytearray)):
        im = Image.open(io.BytesIO(src))
    elif src.lower().endswith('.skp'):
        data = skp_preview(src)
        if data is None:
            return None
        im = Image.open(io.BytesIO(data))
    else:
        im = Image.open(src)
    im.load()
    if im.mode in ('RGBA', 'LA', 'P'):
        im = im.convert('RGBA')
        bg = Image.new('RGB', im.size, (255, 255, 255))  # nền trong suốt → trắng (giống thumbnail model)
        bg.paste(im, mask=im.split()[-1])
        return bg
    return im.convert('RGB')


def skp_preview(path):
    """Ảnh PNG xem trước nhúng trong file SKP (đọc phần đầu file, không mở SketchUp)."""
    try:
        with open(path, 'rb') as f:
            head = f.read(8 * 1024 * 1024)
        s = head.find(PNG_SIG)
        if s < 0:
            return None
        e = head.find(PNG_END, s)
        if e < 0:
            return None
        return head[s:e + len(PNG_END)]
    except OSError:
        return None


def crop_box(im, box):
    if not box:
        return im
    w, h = im.size
    x0 = max(0.0, min(1.0, float(box[0]))) * w
    y0 = max(0.0, min(1.0, float(box[1]))) * h
    x1 = max(0.0, min(1.0, float(box[2]))) * w
    y1 = max(0.0, min(1.0, float(box[3]))) * h
    if x1 - x0 < 8 or y1 - y0 < 8:
        return im
    return im.crop((int(x0), int(y0), int(x1), int(y1)))


def preprocess(im, size=224):
    w, h = im.size
    s = size / min(w, h)
    im = im.resize((max(size, round(w * s)), max(size, round(h * s))), Image.BICUBIC)
    w, h = im.size
    l, t = (w - size) // 2, (h - size) // 2
    im = im.crop((l, t, l + size, t + size))
    a = np.asarray(im, dtype=np.float32) / 255.0
    a = (a - MEAN) / STD
    return a.transpose(2, 0, 1)


def l2n(v):
    v = np.asarray(v, dtype=np.float32)
    n = np.linalg.norm(v, axis=-1, keepdims=True)
    n[n == 0] = 1.0
    return v / n


# --------------------------------------------------------------------------- Bộ máy
class Engine:
    THREADS = 0
    def __init__(self, model_dir, data_dir, device='cpu'):
        import onnxruntime as ort
        self.want_device = device
        self.ort = ort
        self.model_dir = model_dir
        self.data_dir = data_dir
        cfg_path = os.path.join(model_dir, 'model_config.json')
        self.cfg = json.load(open(cfg_path, encoding='utf-8')) if os.path.exists(cfg_path) else {}
        so = ort.SessionOptions()
        so.intra_op_num_threads = self.THREADS or max(1, min(4, (os.cpu_count() or 2) - 1))  # chừa CPU cho SketchUp
        self.device = 'CPU'
        self.vision = self._session(os.path.join(model_dir, self.cfg.get('vision_file', 'vision_model.onnx')), so)
        self.text = None
        self.so = so
        self.v_in = self.vision.get_inputs()[0].name
        self.v_out = self._pick_out(self.vision, 'image_embeds')
        self.index_dir = os.path.join(data_dir, 'index')
        os.makedirs(self.index_dir, exist_ok=True)
        self._index = None
        self._protos = None

    def _session(self, path, so):
        # Mặc định CPU. DirectML chỉ dùng khi người dùng chọn GPU VÀ đã qua bài kiểm tra trong tiến trình riêng
        # (--probe-gpu): DirectML có thể làm sập cả tiến trình (access violation) khi nạp vision model — không bắt được bằng try.
        if os.environ.get('MT_AI_TEST_CRASH') == self.want_device:  # chỉ dùng trong kiểm thử: giả lập lỗi native khi nạp mô hình
            faulthandler._sigsegv()
        if self.want_device == 'gpu' and 'DmlExecutionProvider' in self.ort.get_available_providers():
            gso = self.ort.SessionOptions()
            gso.enable_mem_pattern = False  # yêu cầu của DirectML
            gso.execution_mode = self.ort.ExecutionMode.ORT_SEQUENTIAL
            gso.intra_op_num_threads = so.intra_op_num_threads
            try:
                s = self.ort.InferenceSession(path, gso, providers=['DmlExecutionProvider', 'CPUExecutionProvider'])
                self.device = 'GPU (DirectML)'
                log('nạp %s bằng DirectML' % os.path.basename(path))
                return s
            except Exception as e:  # lỗi Python thông thường → CPU
                log('DirectML lỗi, dùng CPU: %s' % e)
        s = self.ort.InferenceSession(path, so, providers=['CPUExecutionProvider'])
        log('nạp %s bằng CPUExecutionProvider' % os.path.basename(path))
        return s

    @staticmethod
    def _pick_out(sess, prefer):
        outs = sess.get_outputs()
        for o in outs:
            if o.name == prefer:
                return o.name
        for o in outs:
            if len(o.shape) == 2:
                return o.name
        return outs[0].name

    def embed_images(self, arrays):
        if not arrays:
            return np.zeros((0, self.dim), dtype=np.float32)
        x = np.stack(arrays).astype(np.float32)
        out = self.vision.run([self.v_out], {self.v_in: x})[0]
        out = out.reshape(out.shape[0], -1)
        return l2n(out)

    @property
    def dim(self):
        shp = [o for o in self.vision.get_outputs() if o.name == self.v_out][0].shape
        return shp[-1] if isinstance(shp[-1], int) else 512

    # ---- văn bản (zero-shot nhóm đồ vật)
    def text_embed(self, prompts):
        if self.text is None:
            self.text = self._session(os.path.join(self.model_dir, self.cfg.get('text_file', 'text_model.onnx')), self.so)
            self.tok = ClipTokenizer(os.path.join(self.model_dir, 'vocab.json'), os.path.join(self.model_dir, 'merges.txt'))
            self.t_inputs = [i.name for i in self.text.get_inputs()]
            self.t_out = self._pick_out(self.text, 'text_embeds')
        res = []
        for p in prompts:
            ids = np.array([self.tok.encode(p)], dtype=np.int64)
            feed = {}
            for n in self.t_inputs:
                feed[n] = ids if 'mask' not in n else np.ones_like(ids)
            o = self.text.run([self.t_out], feed)[0].reshape(1, -1)
            res.append(o[0])
        return l2n(np.stack(res))

    def protos(self):
        if self._protos is None:
            path = os.path.join(self.data_dir, 'text_protos.npy')
            key = hashlib.sha1(json.dumps([c[0] for c in CATEGORIES]).encode()).hexdigest()
            meta = path + '.key'
            if os.path.exists(path) and os.path.exists(meta) and open(meta).read() == key:
                self._protos = np.load(path)
            else:
                self._protos = self.text_embed(['a photo of a %s, furniture 3d model' % c[0] for c in CATEGORIES])
                np.save(path, self._protos)
                open(meta, 'w').write(key)
        return self._protos

    # ---- chỉ mục thư viện máy tính
    def index(self):
        mp = os.path.join(self.index_dir, 'ids.json')
        # Làn tìm kiếm đọc chỉ mục do làn lập chỉ mục ghi: nạp lại khi file đổi.
        mt = os.path.getmtime(mp) if os.path.exists(mp) else 0
        if self._index is not None and getattr(self, '_index_mtime', None) != mt and not getattr(self, '_index_owner', False):
            self._index = None
        self._index_mtime = mt
        if self._index is None:
            vp = os.path.join(self.index_dir, 'vectors.npy')
            if os.path.exists(vp) and os.path.exists(mp):
                meta = json.load(open(mp, encoding='utf-8'))
                vec = np.load(vp)
                if len(meta.get('ids', [])) == vec.shape[0]:
                    self._index = {'ids': meta['ids'], 'keys': meta['keys'], 'vec': vec, 'nothumb': meta.get('nothumb', {})}
            if self._index is None:
                self._index = {'ids': [], 'keys': [], 'vec': np.zeros((0, self.dim), dtype=np.float16), 'nothumb': {}}
        return self._index

    def save_index(self):
        ix = self.index()
        vp = os.path.join(self.index_dir, 'vectors.npy')
        tmp = vp + '.tmp.npy'
        np.save(tmp, ix['vec'].astype(np.float16))
        os.replace(tmp, vp)
        write_json(os.path.join(self.index_dir, 'ids.json'), {'ids': ix['ids'], 'keys': ix['keys'], 'nothumb': ix['nothumb']})


# --------------------------------------------------------------------------- Công việc
def job_probe(eng, job, prog):
    return {'device': eng.device, 'dim': int(eng.dim), 'indexed': len(eng.index()['ids'])}


def job_embed_query(eng, job, prog):
    im = open_image(job['image'])
    if im is None:
        raise ValueError('Không đọc được ảnh mẫu.')
    im = crop_box(im, job.get('crop'))
    v = eng.embed_images([preprocess(im)])[0]
    np.save(job['out_vec'], v)
    cats = []
    try:
        sims = eng.protos() @ v
        order = np.argsort(-sims)[:5]
        for i in order:
            c = CATEGORIES[int(i)]
            cats.append({'en': c[0], 'vi': c[1], 'keywords': c[2], 'score': round(float(sims[i]), 4)})
    except Exception as e:  # thiếu mô hình văn bản: vẫn tìm được trong máy bằng vector ảnh
        log('zero-shot lỗi: %s' % e)
    return {'categories': cats, 'dim': int(v.shape[0])}


def job_search_local(eng, job, prog):
    ix = eng.index()
    if not ix['ids']:
        return {'hits': [], 'indexed': 0}
    q = np.load(job['vec']).astype(np.float32)
    sims = ix['vec'].astype(np.float32) @ q
    k = int(job.get('k', 200))
    order = np.argsort(-sims)[:k]
    return {'hits': [{'id': ix['ids'][int(i)], 'score': round(float(sims[i]), 4)} for i in order], 'indexed': len(ix['ids'])}


def thumb_source(item):
    t = item.get('thumb')
    if t and os.path.exists(t):
        return t
    p = item.get('path')
    if p and os.path.exists(p):
        if open_image_ok(p):
            return p
        base = os.path.splitext(p)[0]
        for ext in IMG_EXTS:  # ảnh cùng tên đặt cạnh file SKP
            if os.path.exists(base + ext):
                return base + ext
    return None


def open_image_ok(p):
    return skp_preview(p) is not None


_LIB = {'path': None, 'mtime': None, 'items': None}


def library_items(job):
    if 'items' in job:
        return job['items']
    p = job['items_file']
    m = os.path.getmtime(p)
    if _LIB['path'] != p or _LIB['mtime'] != m:
        _LIB.update(path=p, mtime=m, items=json.load(open(p, encoding='utf-8')))
    return _LIB['items']


def job_index_sync(eng, job, prog):
    eng._index_owner = True  # làn lập chỉ mục giữ bản trong bộ nhớ
    ix = eng.index()
    items = library_items(job)
    want = {it['id']: it for it in items}
    keep = [i for i, mid in enumerate(ix['ids']) if mid in want and ix['keys'][i] == want[mid]['key']]
    removed = len(ix['ids']) - len(keep)
    ix['vec'] = ix['vec'][keep]
    ix['ids'] = [ix['ids'][i] for i in keep]
    ix['keys'] = [ix['keys'][i] for i in keep]
    have = set(ix['ids'])
    todo_all = [it for it in items if it['id'] not in have and ix['nothumb'].get(it['id']) != it['key']]
    limit = int(job.get('limit', 0)) or len(todo_all)
    todo = todo_all[:limit]  # xử lý theo đợt để câu tìm kiếm không phải chờ cả thư viện
    total, done, nothumb, batch, bids, bkeys = len(todo), 0, 0, [], [], []
    last_save = time.time()

    def flush():
        nonlocal batch, bids, bkeys
        if batch:
            v = eng.embed_images(batch).astype(np.float16)
            ix['vec'] = np.concatenate([ix['vec'], v]) if len(ix['vec']) else v
            ix['ids'].extend(bids)
            ix['keys'].extend(bkeys)
        batch, bids, bkeys = [], [], []

    for it in todo:
        prog({'done': done, 'total': total})
        src = thumb_source(it)
        im = None
        if src:
            try:
                im = open_image(src)
            except Exception:
                im = None
        if im is None:
            ix['nothumb'][it['id']] = it['key']  # xử lý riêng: không có ảnh → không đưa vào so sánh
            nothumb += 1
        else:
            batch.append(preprocess(im))
            bids.append(it['id'])
            bkeys.append(it['key'])
            if len(batch) >= 16:
                flush()
        done += 1
        if time.time() - last_save > 60:
            flush()
            eng.save_index()
            last_save = time.time()
    flush()
    eng.save_index()
    return {'indexed': len(ix['ids']), 'added': total - nothumb, 'removed': removed, 'library': len(items),
            'remaining': len(todo_all) - len(todo), 'no_thumb': len([k for k in ix['nothumb'] if k in want])}


def fetch(url, hosts, cache_dir):
    u = urllib.parse.urlparse(url)
    if u.scheme != 'https' or (u.hostname or '').lower() not in hosts:
        raise ValueError('host không được phép')
    os.makedirs(cache_dir, exist_ok=True)
    cp = os.path.join(cache_dir, hashlib.sha1(url.encode('utf-8')).hexdigest() + '.img')
    if os.path.exists(cp):
        return open(cp, 'rb').read()
    req = urllib.request.Request(url, headers={'User-Agent': UA})
    with urllib.request.urlopen(req, timeout=12) as r:
        data = r.read(6 * 1024 * 1024 + 1)
    if len(data) > 6 * 1024 * 1024:
        raise ValueError('ảnh quá lớn')
    with open(cp + '.tmp', 'wb') as f:
        f.write(data)
    os.replace(cp + '.tmp', cp)
    return data


def job_rank_urls(eng, job, prog):
    q = np.load(job['vec']).astype(np.float32)
    hosts = set(h.lower() for h in job['hosts'])
    cache = os.path.join(eng.data_dir, 'online_thumbs')
    out, batch, keys, failed, vecs = [], [], [], 0, []
    items = job['items']
    for n, it in enumerate(items):
        prog({'done': n, 'total': len(items)})
        try:
            im = open_image(fetch(it['url'], hosts, cache))
            batch.append(preprocess(im))
            keys.append(it['key'])
        except Exception as e:
            failed += 1
            log('thumbnail lỗi %s: %s' % (it.get('url'), e))
        if len(batch) >= 16 or (n == len(items) - 1 and batch):
            v = eng.embed_images(batch)
            for k, s in zip(keys, v @ q):
                out.append({'key': k, 'score': round(float(s), 4)})
            vecs.extend(zip(keys, v))
            batch, keys = [], []
    dups = 0
    if job.get('store') and vecs:  # kho dữ liệu: lưu metadata + vector để lần sau tìm lại không cần tải ảnh
        try:
            cat = catalog(eng)
            cat.upsert(job['store'])
            dups = cat.set_vectors(vecs)
        except Exception as e:
            log('lưu kho dữ liệu lỗi: %s' % e)
    return {'scores': out, 'failed': failed, 'dups': dups}


# --------------------------------------------------------------------------- Kho dữ liệu tích lũy (SQLite)
# Lưu metadata kết quả online đã thấy (không tải file SKP), vector ảnh xem trước, trạng thái link, trùng lặp.
CAT_FIELDS = ('source', 'source_label', 'uid', 'title', 'thumb', 'thumb_large', 'author', 'author_url', 'license', 'url',
              'downloadable', 'free', 'insertable', 'web_only', 'download_note', 'format', 'formats', 'likes', 'faces')
DUP_COS = 0.97


class Catalog:
    def __init__(self, path):
        import sqlite3
        self.path = path
        self.db = sqlite3.connect(path, timeout=10)
        self.db.execute('PRAGMA journal_mode=WAL')
        self.db.execute('''CREATE TABLE IF NOT EXISTS items(
            key TEXT PRIMARY KEY, source TEXT, title TEXT, url TEXT, thumb TEXT, data TEXT,
            first_seen INTEGER, last_seen INTEGER, link_status TEXT, link_checked INTEGER DEFAULT 0,
            vec BLOB, dup_of TEXT)''')
        self.db.execute('CREATE INDEX IF NOT EXISTS ix_src ON items(source)')
        self.db.commit()
        self._mat = None

    def upsert(self, items):
        now = int(time.time())
        n = 0
        for it in items:
            k = it.get('key')
            if not k or not it.get('title'):
                continue
            data = json.dumps({f: it.get(f) for f in CAT_FIELDS if it.get(f) is not None}, ensure_ascii=False)
            cur = self.db.execute('UPDATE items SET title=?, url=?, thumb=?, data=?, last_seen=? WHERE key=?',
                                  (it.get('title'), it.get('url'), it.get('thumb'), data, now, k))
            if cur.rowcount == 0:
                self.db.execute('INSERT INTO items(key, source, title, url, thumb, data, first_seen, last_seen) VALUES(?,?,?,?,?,?,?,?)',
                                (k, it.get('source'), it.get('title'), it.get('url'), it.get('thumb'), data, now, now))
                n += 1
        self.db.commit()
        return n

    def matrix(self):
        if self._mat is None:
            rows = self.db.execute('SELECT key, vec FROM items WHERE vec IS NOT NULL AND dup_of IS NULL').fetchall()
            keys = [r[0] for r in rows]
            mat = np.stack([np.frombuffer(r[1], dtype=np.float16).astype(np.float32) for r in rows]) if rows else None
            self._mat = (keys, mat)
        return self._mat

    def set_vectors(self, pairs):
        # pairs: [(key, vec float32)] → lưu vector + đánh dấu trùng (ảnh gần như giống hệt một mục đã có từ nguồn khác)
        keys, mat = self.matrix()
        keys = list(keys)
        dups = 0
        for k, v in pairs:
            dup = None
            if mat is not None and len(keys):
                sims = mat @ v
                for i in np.argsort(-sims)[:3]:
                    if sims[i] >= DUP_COS and keys[int(i)] != k:
                        dup = keys[int(i)]
                        dups += 1
                        break
            self.db.execute('UPDATE items SET vec=?, dup_of=? WHERE key=?', (v.astype(np.float16).tobytes(), dup, k))
            if dup is None and k not in keys:  # so sánh cả với các mục mới trong cùng đợt
                keys.append(k)
                row = v.astype(np.float16).astype(np.float32)[None, :]
                mat = row if mat is None else np.concatenate([mat, row])
        self.db.commit()
        self._mat = None
        return dups

    def search(self, q, k, exclude_sources=()):
        keys, mat = self.matrix()
        if mat is None:
            return []
        sims = mat @ q
        order = np.argsort(-sims)[: k * 2]
        out = []
        for i in order:
            row = self.db.execute('SELECT data, link_status FROM items WHERE key=?', (keys[int(i)],)).fetchone()
            if not row or row[1] == 'dead':
                continue
            d = json.loads(row[0])
            if d.get('source') in exclude_sources:
                continue
            d['key'] = keys[int(i)]
            d['vscore'] = round(float(sims[i]), 4)
            d['from_catalog'] = True
            out.append(d)
            if len(out) >= k:
                break
        return out

    def stats(self):
        q = lambda sql: self.db.execute(sql).fetchone()[0]
        return {'total': q('SELECT COUNT(*) FROM items'), 'with_vec': q('SELECT COUNT(*) FROM items WHERE vec IS NOT NULL'),
                'dup': q('SELECT COUNT(*) FROM items WHERE dup_of IS NOT NULL'),
                'dead': q("SELECT COUNT(*) FROM items WHERE link_status='dead'"),
                'checked': q('SELECT COUNT(*) FROM items WHERE link_checked > 0')}

    def clear(self):
        self.db.execute('DELETE FROM items')
        self.db.commit()
        self.db.execute('VACUUM')
        self._mat = None


def catalog(eng):
    if getattr(eng, '_catalog', None) is None:
        eng._catalog = Catalog(os.path.join(eng.data_dir, 'catalog.sqlite'))
    return eng._catalog


def job_catalog_upsert(eng, job, prog):
    return {'added': catalog(eng).upsert(job.get('items', []))}


def job_catalog_search(eng, job, prog):
    q = np.load(job['vec']).astype(np.float32)
    return {'items': catalog(eng).search(q, int(job.get('k', 60)), tuple(job.get('exclude_sources', [])))}


def job_catalog_stats(eng, job, prog):
    return catalog(eng).stats()


def job_catalog_clear(eng, job, prog):
    catalog(eng).clear()
    cache = os.path.join(eng.data_dir, 'online_thumbs')
    n = 0
    if os.path.isdir(cache):
        for f in os.listdir(cache):
            try:
                os.remove(os.path.join(cache, f))
                n += 1
            except OSError:
                pass
    return {'cleared': True, 'thumbs_removed': n}


def check_url(url, hosts):
    u = urllib.parse.urlparse(url or '')
    if u.scheme != 'https':
        return 'error', 0
    for method in ('HEAD', 'GET'):
        try:
            req = urllib.request.Request(url, method=method, headers={'User-Agent': UA, 'Range': 'bytes=0-0'})
            with urllib.request.urlopen(req, timeout=10) as r:
                return 'ok', r.status
        except urllib.error.HTTPError as e:
            if e.code in (404, 410):
                return 'dead', e.code
            if method == 'GET':
                return 'error', e.code
        except Exception:
            if method == 'GET':
                return 'error', 0
    return 'error', 0


def job_catalog_check_links(eng, job, prog):
    from concurrent.futures import ThreadPoolExecutor
    cat = catalog(eng)
    limit = int(job.get('limit', 100))
    rows = cat.db.execute('SELECT key, url FROM items ORDER BY link_checked ASC LIMIT ?', (limit,)).fetchall()
    res = {'ok': 0, 'dead': 0, 'error': 0}
    done = 0
    with ThreadPoolExecutor(max_workers=int(job.get('concurrency', 4))) as ex:  # giới hạn đồng thời
        futs = {ex.submit(check_url, url, None): key for key, url in rows}
        for f in futs:
            st, code = f.result()
            res[st] += 1
            cat.db.execute('UPDATE items SET link_status=?, link_checked=? WHERE key=?', (st, int(time.time()), futs[f]))
            done += 1
            prog({'done': done, 'total': len(rows)})
    cat.db.commit()
    res['checked'] = len(rows)
    return res


JOBS = {'probe': job_probe, 'embed_query': job_embed_query, 'search_local': job_search_local,
        'index_sync': job_index_sync, 'rank_urls': job_rank_urls,
        'catalog_upsert': job_catalog_upsert, 'catalog_search': job_catalog_search, 'catalog_stats': job_catalog_stats,
        'catalog_clear': job_catalog_clear, 'catalog_check_links': job_catalog_check_links}


def probe_gpu(model_dir, data_dir, out):
    """Chạy trong tiến trình riêng: nạp cả 2 mô hình bằng DirectML và chạy thử 1 lần.
    Nếu DirectML làm sập tiến trình, Ruby nhận exit code khác 0 và giữ CPU — worker chính không bị ảnh hưởng."""
    eng = Engine(model_dir, data_dir, device='gpu')
    if eng.device != 'GPU (DirectML)':
        write_json(out, {'ok': False, 'reason': 'Máy không có DirectML khả dụng.'})
        return 5
    eng.embed_images([np.zeros((3, 224, 224), dtype=np.float32)])
    eng.text_embed(['a chair'])
    write_json(out, {'ok': True, 'device': eng.device})
    return 0


def main():
    args = sys.argv[1:]
    model_dir = args[args.index('--models') + 1]
    data_dir = args[args.index('--data') + 1]
    device = args[args.index('--device') + 1] if '--device' in args else 'cpu'
    jobs = args[args.index('--jobs') + 1] if '--jobs' in args else os.path.join(data_dir, 'jobs')
    os.makedirs(jobs, exist_ok=True)
    if '--threads' in args:
        Engine.THREADS = max(1, int(args[args.index('--threads') + 1]))
    if _IMPORT_ERR:
        write_json(os.path.join(jobs, 'worker.error.json'), {'error': 'Thiếu thư viện AI (numpy/Pillow).', 'kind': 'import',
                                                              'detail': _IMPORT_ERR[-1500:]})
        log(_IMPORT_ERR)
        return 4
    if '--probe-gpu' in args:
        return probe_gpu(model_dir, data_dir, args[args.index('--probe-gpu') + 1])
    idle_limit = 600
    hb = os.path.join(jobs, 'heartbeat')
    try:
        eng = Engine(model_dir, data_dir, device=device)
    except Exception as e:
        tb = traceback.format_exc()
        kind = 'dll' if 'DLL load failed' in tb else ('import' if 'No module named' in tb else 'model')
        write_json(os.path.join(jobs, 'worker.error.json'), {'error': 'Không nạp được mô hình AI: %s' % e, 'kind': kind,
                                                              'detail': tb[-1500:]})
        log(tb)
        return 3
    write_json(os.path.join(jobs, 'worker.ready.json'), {'pid': os.getpid(), 'device': eng.device, 'time': time.time()})
    last = time.time()
    while True:
        if os.path.exists(hb) and time.time() - os.path.getmtime(hb) > 90:
            log('SketchUp không còn chạy — thoát')
            return 0
        if time.time() - last > idle_limit:
            log('rảnh quá lâu — thoát')
            return 0
        names = sorted(n for n in os.listdir(jobs) if n.endswith('.job.json'))
        if not names:
            time.sleep(0.15)
            continue
        name = names[0]
        jid = name[:-len('.job.json')]
        path = os.path.join(jobs, name)
        try:
            job = json.load(open(path, encoding='utf-8'))
        except Exception:
            time.sleep(0.1)
            continue
        os.remove(path)
        cancel = os.path.join(jobs, jid + '.cancel')

        def prog(p, _jid=jid, _cancel=cancel):
            if os.path.exists(_cancel):
                raise Cancelled()
            write_json(os.path.join(jobs, _jid + '.prog.json'), p)

        t0 = time.time()
        try:
            fn = JOBS.get(job.get('type'))
            if fn is None:
                raise ValueError('loại công việc không hợp lệ')
            res = {'ok': True, 'result': fn(eng, job, prog), 'seconds': round(time.time() - t0, 3)}
        except Cancelled:
            res = {'ok': False, 'cancelled': True}
        except Exception as e:
            res = {'ok': False, 'error': str(e)}
            log('job %s lỗi: %s' % (jid, e))
        write_json(os.path.join(jobs, jid + '.out.json'), res)
        for p in (cancel, os.path.join(jobs, jid + '.prog.json')):
            if os.path.exists(p):
                os.remove(p)
        last = time.time()


if __name__ == '__main__':
    sys.exit(main() or 0)
