# -*- coding: utf-8 -*-
"""Đo thật thuật toán tìm bằng ảnh: V1.0.12 (cosine màu, không lọc) so với V1.0.13 (lọc danh mục + hình dáng/phong cách).
Dùng: python tools/visual_benchmark.py <ảnh mẫu> — biến MT_MODELS (thư mục CLIP), MT_WORK (thư mục work có catalog.sqlite + online_thumbs).
Nhãn “đúng/sai” chỉ lấy theo TÊN model để thống kê; thuật toán không dùng nhãn này."""
import sys, json, time, re
import os
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'src', 'mt_smart_library', 'ai_runtime'))
import numpy as np
import inference_worker as w
M = os.environ['MT_MODELS']
D = os.environ['MT_WORK']
eng = w.Engine(M, D)

def label(t):
    t = t.lower()
    if re.search(r'dining|table|desk|stool|kitchen|office|outdoor', t) and not re.search(r'sofa', t): return 'KHÁC (bàn/ghế ăn…)'
    if re.search(r'sofa|couch|day ?bed', t): return 'sofa'
    if re.search(r'armchair|lounge chair|arm chair', t): return 'ghế bành'
    if re.search(r'chair', t): return 'ghế khác'
    return 'khác'

q = sys.argv[1]
t0 = time.time()
r = w.job_embed_query(eng, {'image': q, 'out_vec': os.path.join(D, 'bench_q.npy')}, lambda p: None)
print('Nhận diện ảnh mẫu (%.1fs):' % (time.time() - t0), [(c['en'], c['prob']) for c in r['categories'][:4]])
print('allowed', r['allowed'])
# ---- V1.0.12 (cũ): cosine CLIP màu trên toàn kho, min 0.55, spread 0.18, giữ tối thiểu 8
qv = np.load(os.path.join(D, 'bench_q.npy'))
old = w.catalog(eng).search(qv, 60)
old = sorted(old, key=lambda i: -i['vscore'])
best = old[0]['vscore']
old_kept = [i for n, i in enumerate(old) if i['vscore'] >= 0.55 and (n < 8 or i['vscore'] >= best - 0.18)]
def summary(name, items, key):
    from collections import Counter
    c = Counter(label(i['title']) for i in items)
    print('\n== %s: %d kết quả — %s' % (name, len(items), dict(c)))
    for i in items[:60]:
        print('  %5.1f%%  %-16s %s' % (i[key] * 100, label(i['title']), i['title'][:70]))
summary('V1.0.12 (cosine màu, không lọc danh mục)', old_kept, 'vscore')
# ---- V1.0.13
for mode in ('exact', 'similar', 'wide'):
    t0 = time.time()
    res = w.job_catalog_search(eng, {'vec': os.path.join(D, 'bench_q.npy'), 'k': 60, 'mode': mode, 'allowed': r['allowed']}, lambda p: None)['items']
    th = {'exact': (0.55, 0.20, 0), 'similar': (0.52, 0.25, 4), 'wide': (0.50, 0.30, 8)}[mode]
    ok = [i for i in res if mode == 'wide' or i['ok'][mode]]
    rej = [i for i in res if not (mode == 'wide' or i['ok'][mode])]
    ok.sort(key=lambda i: -i['score'])
    b = ok[0]['score'] if ok else 0
    kept = [i for n, i in enumerate(ok) if i['score'] >= th[0] and (n < th[2] or i['score'] >= b - th[1])]
    summary('V1.0.13 %s (%.1fs) — loại %d khác danh mục' % (mode, time.time() - t0, len(rej)), kept, 'score')
    if mode == 'exact':
        print('  -- ví dụ bị loại:')
        for i in rej[:12]:
            print('     %-12s p=%.2f tên=%s | %s' % (i['cat'], i['cat_p'], i['title_cats'], i['title'][:60]))
        print('  -- điểm thành phần top 5:')
        for i in kept[:5]:
            print('     %s struct=%.3f shape=%s full=%.3f → %.3f' % (i['title'][:40], i['parts']['struct'], i['parts']['shape'], i['parts']['full'], i['score']))
