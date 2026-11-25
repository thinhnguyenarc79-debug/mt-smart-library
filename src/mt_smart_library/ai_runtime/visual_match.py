# -*- coding: utf-8 -*-
"""MT VISUAL MATCH (V1.0.13) — so khớp ảnh mẫu với ảnh preview model theo DANH MỤC + HÌNH DÁNG.

Điểm tương đồng (tính thật trên từng ảnh preview, không ước lượng):
  struct  cosine CLIP giữa hai ảnh đã bỏ màu (xám)  → hình khối, cấu trúc (không phụ thuộc màu)
  style   độ trùng phân bố phong cách (zero-shot CLIP: hiện đại tối giản, tân cổ điển, Nhật, cong mềm…) → phong cách
  shape   bóng/viền thật của đồ vật: lược đồ hướng cạnh (HOG 4x4x8) + mặt nạ bóng 16x16 + tỉ lệ khung
  full    cosine CLIP ảnh màu gốc                     → vật liệu, màu sắc
  score = 0.35*struct + 0.35*style + 0.15*shape + 0.15*full   (hình dáng/cấu trúc/phong cách 85%, màu 15%)
  Trọng số chọn theo kiểm thử ảnh sofa thật của người dùng trên kho 84 ảnh preview thật (docs/BAO_CAO_KIEM_THU.md).

Danh mục: zero-shot CLIP trên chính ảnh preview (+ tên model nếu có) → bộ lọc cứng theo chế độ:
  exact    chỉ cùng danh mục (sofa ↔ sofa góc)        similar  cùng họ (sofa/sofa góc/ghế bành/đôn)
  wide     không lọc danh mục (hành vi cũ)
"""
import hashlib
import json
import os
import re
import sqlite3
import threading
import unicodedata

import numpy as np
from PIL import Image, ImageFilter

FEAT_VER = 2
W_STRUCT, W_STYLE, W_SHAPE, W_FULL = 0.35, 0.35, 0.15, 0.15
STYLES = ['modern minimalist', 'classic neoclassical', 'chesterfield tufted', 'scandinavian', 'japanese', 'industrial', 'mid-century modern',
          'luxury baroque', 'rustic wooden', 'curved organic', 'boxy rectangular', 'low platform', 'tall wooden legs', 'L-shaped sectional',
          'leather', 'fabric upholstered', 'carved wood frame', 'contemporary', 'rattan woven', 'metal frame']
TEMPLATES = ['a photo of a {}.', 'a 3d render of a {}, furniture model.', 'a product photo of a {} on a white background.']

# Họ danh mục cho chế độ “Tương tự” (một danh mục có thể thuộc nhiều họ).
FAMILIES = {
    'upholstered': ['sofa', 'sectional sofa', 'armchair', 'ottoman'],
    'chair': ['armchair', 'dining chair', 'office chair', 'bar stool', 'bench', 'outdoor furniture'],
    'table': ['dining table', 'coffee table', 'side table', 'desk', 'dressing table', 'nightstand'],
    'storage': ['wardrobe', 'kitchen cabinet', 'tv cabinet', 'bookshelf', 'sideboard', 'chest of drawers', 'nightstand'],
    'bed': ['bed', 'bunk bed'],
    'lamp': ['pendant lamp', 'chandelier', 'floor lamp', 'table lamp', 'ceiling light', 'wall lamp'],
    'plant': ['potted plant', 'tree'],
    'decor': ['vase decor', 'wall art', 'mirror', 'rug'],
    'bath': ['bathtub', 'toilet', 'washbasin'],
    'opening': ['door', 'window'],
}
# Danh mục coi là “cùng loại” trong chế độ Chính xác.
SAME = [['sofa', 'sectional sofa'], ['pendant lamp', 'chandelier'], ['bed', 'bunk bed']]

# Từ khóa trong TÊN model (đã bỏ dấu) → danh mục. Cụm dài khớp trước; “chair/ghe” chung chung không quyết định.
TITLE_KW = [
    ('sectional sofa', ['sectional sofa', 'corner sofa', 'l shaped sofa', 'sofa goc', 'sofa chu l']),
    ('sofa', ['sofa', 'couch', 'settee', 'sopha', 'so pha', 'sofa bed', 'loveseat', 'ghe sofa', 'van go']),
    ('armchair', ['armchair', 'arm chair', 'lounge chair', 'accent chair', 'wing chair', 'club chair', 'ghe banh', 'ghe thu gian', 'recliner']),
    ('dining chair', ['dining chair', 'ghe an', 'side chair', 'cafe chair', 'ghe cafe']),
    ('office chair', ['office chair', 'ghe van phong', 'task chair', 'gaming chair']),
    ('bar stool', ['bar stool', 'barstool', 'ghe bar', 'ghe quay bar', 'stool']),
    ('bench', ['bench', 'ghe bang', 'ghe dai']),
    ('ottoman', ['ottoman', 'pouf', 'pouffe', 'don sofa', 'ghe don']),
    ('dining table', ['dining table', 'ban an', 'dining set', 'bo ban an']),
    ('coffee table', ['coffee table', 'ban tra', 'ban sofa', 'center table', 'cocktail table']),
    ('side table', ['side table', 'end table', 'ban goc', 'ban canh']),
    ('desk', ['desk', 'ban lam viec', 'ban hoc', 'work table', 'office table']),
    ('bed', ['bed', 'giuong']),
    ('wardrobe', ['wardrobe', 'closet', 'tu ao', 'tu quan ao']),
    ('kitchen cabinet', ['kitchen cabinet', 'tu bep', 'kitchen']),
    ('tv cabinet', ['tv cabinet', 'tv stand', 'ke tivi', 'ke tv', 'tu tivi']),
    ('bookshelf', ['bookshelf', 'bookcase', 'ke sach', 'shelf']),
    ('sideboard', ['sideboard', 'buffet', 'credenza']),
    ('chest of drawers', ['chest of drawers', 'dresser', 'tu ngan keo']),
    ('nightstand', ['nightstand', 'bedside table', 'tab dau giuong']),
    ('dressing table', ['dressing table', 'vanity', 'ban trang diem']),
    ('pendant lamp', ['pendant', 'den tha']),
    ('chandelier', ['chandelier', 'den chum']),
    ('floor lamp', ['floor lamp', 'den cay', 'den dung']),
    ('table lamp', ['table lamp', 'den ban']),
    ('ceiling light', ['ceiling light', 'downlight', 'den tran', 'den ap tran']),
    ('wall lamp', ['wall lamp', 'sconce', 'den tuong']),
    ('curtain', ['curtain', 'drape', 'rem']),
    ('rug', ['rug', 'carpet', 'tham']),
    ('potted plant', ['plant', 'chau cay', 'cay canh']),
    ('wall art', ['painting', 'wall art', 'tranh']),
    ('mirror', ['mirror', 'guong']),
    ('bathtub', ['bathtub', 'bon tam']),
    ('toilet', ['toilet', 'bon cau']),
    ('washbasin', ['washbasin', 'lavabo', 'basin']),
    ('door', ['door', 'cua di']),
    ('window', ['window', 'cua so']),
    ('staircase', ['stair', 'cau thang']),
    ('car', [' car ', 'oto', 'o to']),
]
_TITLE_RX = [(c, re.compile(r'(?<![a-z0-9])(' + '|'.join(re.escape(k.strip()) for k in sorted(ks, key=len, reverse=True)) + r')(?![a-z0-9])'))
             for c, ks in TITLE_KW]


def fold(s):
    s = unicodedata.normalize('NFD', s or '').replace('đ', 'd').replace('Đ', 'D')
    s = ''.join(c for c in s if unicodedata.category(c) != 'Mn').lower()
    return re.sub(r'\s+', ' ', re.sub(r'[^a-z0-9]+', ' ', s)).strip()


def title_cats(title):
    """Danh mục nêu rõ trong tên model. Khớp dài nhất trước trên toàn bộ từ khóa:
    “sofa bed” → sofa (không thành giường), “bàn sofa” → bàn trà (không thành sofa)."""
    t = ' ' + fold(title) + ' '
    hits = []
    for cat, rx in _TITLE_RX:
        for m in rx.finditer(t):
            hits.append((m.end() - m.start(), m.start(), m.end(), cat))
    hits.sort(key=lambda h: (-h[0], h[1]))
    taken, found = [], []
    for _, a, b, cat in hits:
        if any(a < y and x < b for x, y in taken):
            continue
        taken.append((a, b))
        if cat not in found:
            found.append(cat)
    return found


def allowed_sets(cats_ranked, probs):
    """cats_ranked: danh mục ảnh mẫu theo xác suất giảm dần; probs: xác suất tương ứng.
    → {'exact': [...], 'similar': [...]}"""
    if not cats_ranked:
        return {'exact': [], 'similar': []}
    top = cats_ranked[0]
    exact = [top]
    for g in SAME:
        if top in g:
            exact = list(g)
    fam = [f for f, members in FAMILIES.items() if top in members]
    # Ảnh mẫu mơ hồ giữa 2 danh mục CÙNG HỌ (vd. sofa ↔ ghế bành): chấp nhận cả hai ở chế độ Chính xác.
    if len(cats_ranked) > 1 and probs[1] >= 0.6 * probs[0]:
        second = cats_ranked[1]
        if any(second in FAMILIES[f] for f in fam) and second not in exact:
            exact.append(second)
    similar = list(exact)
    for f in fam:
        for c in FAMILIES[f]:
            if c not in similar:
                similar.append(c)
    return {'exact': exact, 'similar': similar}


def judge(img_probs, cat_names, tcats, allowed):
    """Bộ lọc cứng cho 1 ứng viên. img_probs: xác suất zero-shot trên ảnh preview của ứng viên."""
    out = {}
    top = cat_names[int(np.argmax(img_probs))]
    for mode in ('exact', 'similar'):
        al = allowed.get(mode) or []
        if not al:
            out[mode] = True
            continue
        p_al = float(sum(img_probs[cat_names.index(c)] for c in al if c in cat_names))
        img_ok = top in al or p_al >= 0.40
        title_ok = (not tcats) or any(c in al for c in tcats)
        # Tên nói rõ là danh mục khác (vd. “Dining chair …”) → loại, kể cả khi ảnh mơ hồ.
        out[mode] = bool(img_ok and title_ok)
    return top, out


# --------------------------------------------------------------------------- Hình dáng thật (không phụ thuộc màu)
def _bg_mask(g):
    """g: ảnh xám float 0..1. Nền = màu viền ảnh (ảnh preview model thường nền đơn sắc)."""
    border = np.concatenate([g[0, :], g[-1, :], g[:, 0], g[:, -1]])
    bg = float(np.median(border))
    uniform = float(np.clip(1.0 - np.std(border) * 6.0, 0.0, 1.0))
    mask = np.abs(g - bg) > 0.06
    return mask, uniform


def shape_feat(im):
    """Vector hình dáng 386 chiều: HOG(128) | bóng 16x16 (256) | tỉ lệ khung | độ đồng đều nền."""
    g = np.asarray(im.convert('L').resize((128, 128), Image.BILINEAR), dtype=np.float32) / 255.0
    mask, uniform = _bg_mask(g)
    ys, xs = np.nonzero(mask)
    if len(xs) > 64 and uniform > 0.3:
        x0, x1, y0, y1 = xs.min(), xs.max() + 1, ys.min(), ys.max() + 1
    else:  # ảnh chụp có nền phức tạp: dùng cả khung
        x0, x1, y0, y1 = 0, 128, 0, 128
    ar = float((x1 - x0) / max(1, (y1 - y0)))
    crop = g[y0:y1, x0:x1]
    cm = mask[y0:y1, x0:x1].astype(np.float32)
    c = np.asarray(Image.fromarray((crop * 255).astype(np.uint8)).resize((64, 64), Image.BILINEAR), dtype=np.float32) / 255.0
    m16 = np.asarray(Image.fromarray((cm * 255).astype(np.uint8)).resize((16, 16), Image.BILINEAR), dtype=np.float32) / 255.0
    gx = np.zeros_like(c)
    gy = np.zeros_like(c)
    gx[:, 1:-1] = c[:, 2:] - c[:, :-2]
    gy[1:-1, :] = c[2:, :] - c[:-2, :]
    mag = np.hypot(gx, gy)
    ang = (np.arctan2(gy, gx) % np.pi) / np.pi * 8.0
    b = np.minimum(ang.astype(np.int32), 7)
    hog = np.zeros((4, 4, 8), dtype=np.float32)
    for i in range(4):
        for j in range(4):
            sl = (slice(i * 16, (i + 1) * 16), slice(j * 16, (j + 1) * 16))
            hog[i, j] = np.bincount(b[sl].ravel(), weights=mag[sl].ravel(), minlength=8)[:8]
    hog = hog.ravel()
    n = np.linalg.norm(hog)
    hog = hog / n if n > 0 else hog
    return np.concatenate([hog, m16.ravel(), [ar, uniform]]).astype(np.float32)


def shape_sim(a, b):
    """0..1. Bóng chỉ được tính khi CẢ HAI ảnh có nền đồng đều (preview model); ảnh chụp thực tế dựa vào HOG."""
    if a is None or b is None:
        return None
    hog = float(np.dot(a[:128], b[:128]))
    ma, mb = a[128:384], b[128:384]
    u = min(float(a[385]), float(b[385]))
    inter = float(np.minimum(ma, mb).sum())
    union = float(np.maximum(ma, mb).sum()) or 1.0
    iou = inter / union
    ra, rb = max(1e-3, float(a[384])), max(1e-3, float(b[384]))
    arsim = max(0.0, 1.0 - abs(np.log(ra / rb)) / np.log(3.0))
    w_sil = 0.35 * u
    return (1.0 - w_sil - 0.15) * hog + w_sil * iou + 0.15 * arsim


def combine(struct, shape, full, style):
    if shape is None:  # không có ảnh để đo hình dáng (chỉ có vector cũ): chia lại trọng số, đánh dấu ước lượng
        return (W_STRUCT * struct + W_STYLE * style + W_FULL * full) / (W_STRUCT + W_STYLE + W_FULL)
    return W_STRUCT * struct + W_STYLE * style + W_SHAPE * shape + W_FULL * full


def style_protos(eng, cat=None):
    """Nguyên mẫu phong cách theo danh mục ảnh mẫu (“a japanese sofa”, “a classic neoclassical sofa”…) — phân biệt rõ hơn câu chung."""
    noun = cat or 'piece of furniture'
    cache = getattr(eng, '_style', None)
    if cache is None:
        cache = eng._style = {}
    if noun not in cache:
        key = hashlib.sha1(json.dumps([STYLES, noun]).encode()).hexdigest()
        path = os.path.join(eng.data_dir, 'style_%s.npy' % key[:16])
        if os.path.exists(path):
            cache[noun] = np.load(path)
        else:
            cache[noun] = eng.text_embed(['a photo of a %s %s, furniture.' % (x, noun) for x in STYLES])
            np.save(path, cache[noun])
    return cache[noun]


def style_probs(eng, vecs, cat=None):
    logits = 100.0 * (np.asarray(vecs, dtype=np.float32) @ style_protos(eng, cat).T)
    logits -= logits.max(axis=-1, keepdims=True)
    p = np.exp(logits)
    return p / p.sum(axis=-1, keepdims=True)


# --------------------------------------------------------------------------- Bộ nhớ đặc trưng (gray + shape) theo ảnh
class FeatCache:
    """features.sqlite: key = sha1(nguồn ảnh) → vector xám + vector hình dáng (FEAT_VER đổi → tính lại)."""

    def __init__(self, path):
        self.path = path
        self.lock = threading.Lock()
        db = self._db()
        db.execute('CREATE TABLE IF NOT EXISTS feat(k TEXT PRIMARY KEY, ver INTEGER, rgb BLOB, gray BLOB, shp BLOB)')
        db.commit()
        db.close()

    def _db(self):
        return sqlite3.connect(self.path, timeout=15)

    @staticmethod
    def key(src):
        return hashlib.sha1(src.encode('utf-8', 'replace')).hexdigest()

    def get_many(self, keys):
        out = {}
        if not keys:
            return out
        db = self._db()
        try:
            for i in range(0, len(keys), 400):
                part = keys[i:i + 400]
                q = 'SELECT k, rgb, gray, shp FROM feat WHERE ver=? AND k IN (%s)' % ','.join('?' * len(part))
                for k, rgb, gray, shp in db.execute(q, [FEAT_VER] + part):
                    out[k] = (np.frombuffer(rgb, dtype=np.float16).astype(np.float32),
                              np.frombuffer(gray, dtype=np.float16).astype(np.float32),
                              np.frombuffer(shp, dtype=np.float32))
        finally:
            db.close()
        return out

    def put_many(self, rows):
        if not rows:
            return
        with self.lock:
            db = self._db()
            try:
                db.executemany('INSERT OR REPLACE INTO feat(k, ver, rgb, gray, shp) VALUES(?,?,?,?,?)',
                               [(k, FEAT_VER, r.astype(np.float16).tobytes(), g.astype(np.float16).tobytes(), s.astype(np.float32).tobytes())
                                for k, (r, g, s) in rows.items()])
                db.commit()
            finally:
                db.close()


def to_gray_rgb(im):
    return im.convert('L').convert('RGB')


def features(eng, ims, preprocess):
    """ims: list[PIL] → (rgb[N,D], gray[N,D], shape[N,386]) — tính thật trên ảnh."""
    if not ims:
        return [], [], []
    rgb, gray = [], []
    for i in range(0, len(ims), 16):
        part = ims[i:i + 16]
        rgb.append(eng.embed_images([preprocess(im) for im in part]))
        gray.append(eng.embed_images([preprocess(to_gray_rgb(im)) for im in part]))
    return np.concatenate(rgb), np.concatenate(gray), [shape_feat(im) for im in ims]


def zero_shot(eng, vecs, cat_names):
    """Xác suất danh mục (softmax, nhiệt độ CLIP 100) cho mỗi vector ảnh."""
    protos = eng.protos()
    logits = 100.0 * (np.asarray(vecs, dtype=np.float32) @ protos.T)
    logits -= logits.max(axis=-1, keepdims=True)
    p = np.exp(logits)
    return p / p.sum(axis=-1, keepdims=True)


def load_query(vec_path):
    base = vec_path[:-4] if vec_path.endswith('.npy') else vec_path
    rgb = np.load(vec_path).astype(np.float32)
    gp, sp = base + '.gray.npy', base + '.shape.npy'
    gray = np.load(gp).astype(np.float32) if os.path.exists(gp) else rgb
    shp = np.load(sp).astype(np.float32) if os.path.exists(sp) else None
    return rgb, gray, shp


def save_query(vec_path, rgb, gray, shp):
    base = vec_path[:-4] if vec_path.endswith('.npy') else vec_path
    np.save(vec_path, rgb)
    np.save(base + '.gray.npy', gray)
    np.save(base + '.shape.npy', shp)


def score_rows(q, rgb, gray, shp_list, probs, cat_names, titles, allowed, vi_names, approx=None, styles=None):
    """Chấm điểm + phán quyết danh mục cho N ứng viên. Trả list dict (thứ tự như đầu vào).
    styles: (phân bố phong cách ảnh mẫu, phân bố phong cách từng ứng viên) hoặc None."""
    qr, qg, qs = q
    out = []
    full = np.asarray(rgb) @ qr
    struct = np.asarray(gray) @ qg
    sty = np.sqrt(styles[1] * styles[0][None, :]).sum(axis=1) if styles is not None else struct
    for n in range(len(full)):
        sh = shape_sim(qs, shp_list[n]) if shp_list[n] is not None else None
        sc = combine(float(struct[n]), sh, float(full[n]), float(sty[n]))
        tc = title_cats(titles[n] or '')
        top, ok = judge(probs[n], cat_names, tc, allowed)
        out.append({'score': round(float(sc), 4),
                    'parts': {'struct': round(float(struct[n]), 4), 'shape': None if sh is None else round(float(sh), 4),
                              'full': round(float(full[n]), 4), 'style': round(float(sty[n]), 4)},
                    'cat': top, 'cat_vi': vi_names.get(top, top), 'cat_p': round(float(probs[n][cat_names.index(top)]), 3),
                    'title_cats': tc, 'ok': ok, 'approx': bool(approx[n]) if approx else sh is None})
    return out
