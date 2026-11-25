/* MT SMART LIBRARY PRO V1.0.2 — giao diện tìm kiếm tổng hợp.
   Không tải JS ngoài; mọi dữ liệu hiển thị qua textContent; ảnh chỉ nhận data: hoặc ảnh https từ host nguồn đã tích hợp (IMG_HOSTS). */
(function () {
  'use strict';
  var $ = function (id) { return document.getElementById(id); };
  var S = {
    sid: 0, items: [], byKey: new Map(), cards: new Map(), loading: false, hasMore: false, filter: 'all', category: 'all',
    anyOf: null, settings: null, secrets: null, categories: [], localThumbs: new Map(), thumbWant: new Set(), thumbTimer: null,
    observer: null, debounce: null, composing: false, detailKey: null, dl: new Map(), ai: { src: null, mime: null, busy: false },
    newerId: null, editCat: null, moreAsked: false, lastQuery: '', beginInfo: '', vs: { on: false, src: null }
  };

  function call(name) {
    var args = Array.prototype.slice.call(arguments, 1);
    if (window.sketchup && typeof window.sketchup[name] === 'function') { window.sketchup[name].apply(window.sketchup, args); return true; }
    if (window.MT_DEV_BRIDGE) { window.MT_DEV_BRIDGE(name, args); return true; }
    return false;
  }
  function callJ(name, obj) { return call(name, JSON.stringify(obj)); }
  function el(tag, text, cls) { var e = document.createElement(tag); if (text !== undefined && text !== null) e.textContent = String(text); if (cls) e.className = cls; return e; }
  function btn(text, fn, cls, title) { var b = el('button', text, cls); b.type = 'button'; b.addEventListener('click', fn); if (title) b.title = title; return b; }
  function fmtSize(b) { b = Number(b) || 0; if (b < 1024) return b + ' B'; if (b < 1048576) return (b / 1024).toFixed(0) + ' KB'; if (b < 1073741824) return (b / 1048576).toFixed(1) + ' MB'; return (b / 1073741824).toFixed(2) + ' GB'; }
  function fmtDate(t) { if (!t) return ''; var d = new Date(t * 1000); return ('0' + d.getDate()).slice(-2) + '/' + ('0' + (d.getMonth() + 1)).slice(-2) + '/' + d.getFullYear(); }
  var IMG_HOSTS = /^https:\/\/(media\.sketchfab\.com|cdn\.polyhaven\.com|sketchup\.cgtips\.org|img\.sketchupfree\.com|sketchupfree\.com|thuviensketchup\.vn)\//;
  // Ảnh từ nguồn người dùng thêm: chỉ nhận tên miền của chính nguồn đó (và tên miền con).
  function customImg(u) {
    var m = /^https:\/\/([a-z0-9.-]+)\//i.exec(u); if (!m) return false; var h = m[1].toLowerCase();
    return (S.imgDomains || []).some(function (d) { return h === d || h.slice(-(d.length + 1)) === '.' + d; });
  }
  function isSafeImg(u) { return typeof u === 'string' && (IMG_HOSTS.test(u) || customImg(u) || /^data:image\/(png|jpeg|webp|gif);base64,/.test(u)); }
  function setStatus(msg, kind, hint) { $('statusMsg').textContent = msg || ''; $('statusHint').textContent = hint || ''; $('statusBar').className = 'status ' + (kind || ''); }
  function show(id) { $(id).hidden = false; }
  function hide(id) { $(id).hidden = true; }

  // ================================================================ Tìm kiếm
  function startSearch() {
    clearTimeout(S.debounce);
    if (S.vs.on) return; // đang xem kết quả tìm bằng ảnh: không tự làm mới bằng từ khóa
    S.kwSeq = (S.kwSeq || 0) + 1; S.sid = S.kwSeq; S.moreAsked = false; S.loading = true; S.lastQuery = $('q').value.trim(); S.beginInfo = '';
    $('loading').hidden = false;
    callJ('sr_start', { sid: S.sid, q: S.lastQuery, category: S.category, filter: S.filter, any_of: S.anyOf || [] });
  }
  function searchSoon() { clearTimeout(S.debounce); S.debounce = setTimeout(kwSearch, 350); }
  function kwSearch() { if (S.vs.on) vsClear(); startSearch(); } // người dùng tìm bằng từ khóa: bỏ ảnh mẫu
  function onQueryChanged() { if (S.anyOf) S.anyOf = null; searchSoon(); }

  function onBegin(d) {
    if (d.sid !== S.sid) return;
    if (d.any_of && d.any_of.length) S.beginInfo = 'Từ khóa AI: ' + d.any_of.slice(0, 4).join(' · ');
    else if (d.expansions && d.expansions.length > 1) S.beginInfo = 'Tìm cả: ' + d.expansions.slice(0, 5).join(', ');
    else S.beginInfo = '';
  }

  function onUpdate(d) {
    if (d.sid !== S.sid) return; // kết quả của truy vấn cũ: bỏ qua
    S.items = d.items; S.loading = d.loading; S.hasMore = d.has_more; S.filter = d.filter;
    S.byKey = new Map(); d.items.forEach(function (it) { S.byKey.set(it.key, it); });
    renderGrid();
    document.querySelectorAll('#filters [data-f]').forEach(function (b) {
      b.classList.toggle('on', b.dataset.f === d.filter);
      b.querySelector('i').textContent = d.counts[b.dataset.f] !== undefined ? d.counts[b.dataset.f] : '';
    });
    var parts = [d.items.length + (d.truncated ? '+' : '') + ' model'];
    var bad = (d.sources || []).filter(function (s) { return s.state === 'error'; });
    if (bad.length) parts.push('⚠ ' + bad.map(function (s) { return s.label + (s.offline ? ' không kết nối được' : ' tạm thời lỗi'); }).join('; '));
    if (S.beginInfo) parts.push(S.beginInfo);
    $('resInfo').textContent = parts.join('  ·  ');
    $('resInfo').title = (d.sources || []).map(function (s) { return s.label + ': ' + s.count + ' kết quả' + (s.error ? ' — ' + s.error : ''); }).join('\n') +
      (d.hidden ? '\nĐã ẩn ' + d.hidden + ' kết quả online không liên quan.' : '');
    $('loading').hidden = !d.loading;
    S.moreAsked = false;
    renderEmpty(d);
    if (S.detailKey && S.byKey.has(S.detailKey)) renderDetail(S.byKey.get(S.detailKey));
    setTimeout(maybeMore, 50);
  }

  function renderEmpty(d) {
    var e = $('empty');
    if (S.items.length || d.loading) { e.hidden = true; return; }
    e.hidden = false; e.replaceChildren();
    var noRoots = S.settings && S.settings.roots.length === 0;
    if (S.category === 'favorites') e.appendChild(el('div', 'Chưa có model yêu thích. Bấm ♡ trên ảnh model để lưu lại.'));
    else if (S.category === 'history') e.appendChild(el('div', 'Chưa có model nào được chèn.'));
    else if (noRoots && (S.category === 'personal' || !$('q').value.trim())) e.appendChild(el('div', 'Thêm thư mục chứa file .skp để xem thư viện của bạn, hoặc gõ từ khóa để tìm model online.'));
    else e.appendChild(el('div', 'Không tìm thấy model phù hợp. Thử từ khóa ngắn hơn, tiếng Anh, hoặc chọn danh mục khác.'));
    if (noRoots) e.appendChild(btn('+ Thêm thư mục thư viện', function () { call('add_root'); }, 'primary'));
  }

  // Lưới theo khóa: giữ nguyên thẻ (và ảnh) khi có đợt kết quả mới, chỉ sắp lại vị trí.
  function renderGrid() {
    var want = new Set();
    var frag = document.createDocumentFragment();
    S.items.forEach(function (it) {
      want.add(it.key);
      var c = S.cards.get(it.key);
      if (!c) { c = card(it); S.cards.set(it.key, c); } else updateCard(c, it);
      frag.appendChild(c);
    });
    S.cards.forEach(function (c, k) { if (!want.has(k)) { S.cards.delete(k); if (S.observer) S.observer.unobserve(c.querySelector('.thumb')); } });
    $('grid').replaceChildren(frag);
  }

  function card(it) {
    var c = el('div', null, 'card'); c.dataset.key = it.key;
    var th = el('div', null, 'thumb'); th.dataset.key = it.key; if (it.id) th.dataset.id = it.id;
    th.title = 'Xem chi tiết';
    th.addEventListener('click', function (e) { if (e.target.closest('.heart')) return; openDetail(it.key); });
    paintThumb(th, it);
    var heart = btn('♡', function () { call('fav_item', it.key); }, 'heart', 'Yêu thích');
    th.appendChild(heart);
    var sb = el('span', it.source === 'local' ? '💻' : '☁', 'src'); sb.title = 'Nguồn: ' + (it.source_label || ''); th.appendChild(sb);
    var bar = el('div', null, 'cardbar');
    var t = el('div', shortName(it.title), 'title'); t.title = it.title;
    bar.appendChild(t);
    bar.appendChild(btn(insLabel(it), function () { doInsert(it.key); }, 'ins' + (canInsertish(it) ? '' : ' web'), insTitle(it)));
    c.appendChild(th); c.appendChild(bar);
    updateCard(c, it);
    if (it.source === 'local' && !S.localThumbs.has(it.id)) observe(th);
    return c;
  }
  function updateCard(c, it) {
    var h = c.querySelector('.heart'); h.textContent = it.fav ? '♥' : '♡'; h.classList.toggle('on', !!it.fav);
    var st = it.uid && S.dl.get(it.uid); var th = c.querySelector('.thumb'); var pr = th.querySelector('.prog');
    if (st && (st.state === 'downloading' || st.state === 'requesting')) {
      if (!pr) { pr = el('div', null, 'prog'); pr.appendChild(el('i')); th.appendChild(pr); }
      pr.firstChild.style.width = (st.total ? Math.round((st.bytes || 0) * 100 / st.total) : 5) + '%';
    } else if (pr) pr.remove();
  }
  function shortName(s) { s = String(s || ''); return s.length > 60 ? s.slice(0, 57) + '…' : s; }
  function canInsertish(it) { return it.source === 'local' || it.downloadable; }
  function insLabel(it) { return canInsertish(it) ? 'CHÈN' : 'XEM'; }
  function insTitle(it) {
    if (it.source === 'local') return 'Chèn ngay vào công trình';
    if (it.web_only) return it.download_note || 'Mở trang tải chính thức';
    if (it.downloadable) return 'Tải và chèn (nếu định dạng tương thích)';
    return 'Tác giả không cho phép tải — mở trang nguồn';
  }
  function paintThumb(th, it) {
    var src = it.source === 'local' ? S.localThumbs.get(it.id) : it.thumb;
    var old = th.querySelector('img, .ph'); if (old) old.remove();
    if (src && isSafeImg(src)) { var i = el('img'); i.alt = ''; i.loading = 'lazy'; i.referrerPolicy = 'no-referrer'; i.src = src; th.insertBefore(i, th.firstChild); }
    else th.insertBefore(el('span', it.source === 'local' && !S.localThumbs.has(it.id) ? '…' : '◇', 'ph'), th.firstChild);
  }
  function observe(th) {
    if (!('IntersectionObserver' in window)) { wantThumb(th.dataset.id); return; }
    if (!S.observer) {
      S.observer = new IntersectionObserver(function (ents) {
        ents.forEach(function (en) { if (en.isIntersecting) { wantThumb(en.target.dataset.id); S.observer.unobserve(en.target); } });
      }, { root: $('content'), rootMargin: '300px' });
    }
    S.observer.observe(th);
  }
  function wantThumb(id) {
    if (!id) return;
    S.thumbWant.add(id);
    if (S.thumbTimer) return;
    S.thumbTimer = setTimeout(function () { var ids = Array.from(S.thumbWant); S.thumbWant.clear(); S.thumbTimer = null; if (ids.length) callJ('thumbs', ids); }, 80);
  }
  // Tải thêm khi gần cuối lưới.
  function maybeMore() {
    if (!S.hasMore || S.loading || S.moreAsked) return;
    var c = $('content');
    if (c.scrollTop + c.clientHeight > c.scrollHeight - 600) { S.moreAsked = true; S.loading = true; $('loading').hidden = false; call('sr_more', S.sid); }
  }

  function doInsert(key) {
    var it = S.byKey.get(key);
    if (it && it.source !== 'local' && it.downloadable) setStatus('Đang tải “' + it.title + '”…');
    call('insert_item', key);
  }

  // ================================================================ Chi tiết
  function openDetail(key) { var it = S.byKey.get(key); if (!it) return; S.detailKey = key; renderDetail(it); show('detailModal'); }
  function renderDetail(it) {
    var img = $('dImg'); img.replaceChildren();
    var src = it.source === 'local' ? S.localThumbs.get(it.id) : (it.thumb_large || it.thumb);
    if (src && isSafeImg(src)) { var i = el('img'); i.alt = ''; i.referrerPolicy = 'no-referrer'; i.src = src; img.appendChild(i); } else img.textContent = '◇';
    $('dTitle').textContent = it.title;
    var dl = $('dMeta'); dl.replaceChildren();
    function row(k, v) { if (v === undefined || v === null || v === '') return; dl.appendChild(el('dt', k)); dl.appendChild(el('dd', v)); }
    if (it.source === 'local') {
      row('Nguồn', 'Thư viện trên máy tính'); row('Thư mục', it.folder); row('Dung lượng', fmtSize(it.size)); row('Ngày sửa', fmtDate(it.mtime));
      row('Định dạng', 'SketchUp (.skp) — chèn trực tiếp'); row('Đường dẫn', it.path);
    } else {
      row('Nguồn', it.source_label); row('Tác giả', it.author); row('Giấy phép', it.license || 'Không rõ');
      row('Tải về', it.web_only ? it.download_note : (it.downloadable ? 'Được phép' : 'Tác giả không cho phép tải'));
      row('Định dạng', (it.formats || []).map(function (f) { return f.type.toUpperCase() + (f.size ? ' ' + fmtSize(f.size) : ''); }).join(', '));
      if (it.faces) row('Số mặt', Number(it.faces).toLocaleString('vi-VN'));
    }
    if (it.vscore !== undefined) {
      row('Tương đồng ảnh', Number(it.vscore).toFixed(2) + ' (cosine CLIP, không phải xác suất)');
    }
    var attr = $('dAttr');
    if (it.source !== 'local') {
      attr.hidden = false;
      $('dAttrText').textContent = '“' + it.title + '” của ' + (it.author || '?') + ' — ' + (it.license || 'giấy phép chưa rõ') + ' — nguồn ' + it.source_label + (it.url ? ' (' + it.url + ')' : '') + '.';
    } else attr.hidden = true;
    $('dInsert').textContent = it.source === 'local' ? 'CHÈN MODEL' : (it.downloadable ? 'TẢI & CHÈN MODEL' : (it.web_only ? 'MỞ TRANG TẢI' : 'XEM TRÊN TRANG NGUỒN'));
    $('dFav').textContent = it.fav ? '♥ Đã yêu thích' : '♡ Yêu thích';
    $('dOpen').textContent = it.source === 'local' ? 'Mở thư mục' : 'Xem trang nguồn';
    $('dNote').textContent = '';
    renderDl(it.uid);
  }
  function renderDl(uid) {
    var box = $('dDl'); var st = uid && S.dl.get(uid);
    if (!st) { box.hidden = true; return; }
    box.hidden = false; box.replaceChildren();
    if (st.state === 'requesting') box.appendChild(el('span', 'Đang chuẩn bị tải…'));
    else if (st.state === 'downloading') {
      var pct = st.total ? Math.min(100, Math.round((st.bytes || 0) * 100 / st.total)) : 0;
      box.appendChild(el('span', 'Đang tải… ' + (st.total ? pct + '% (' + fmtSize(st.bytes || 0) + ' / ' + fmtSize(st.total) + ')' : fmtSize(st.bytes || 0))));
      var b = el('div', null, 'bar2'), f = el('i'); f.style.width = pct + '%'; b.appendChild(f); box.appendChild(b);
    } else if (st.state === 'error') { var e = el('span', '✗ ' + (st.msg || 'Lỗi tải')); e.style.color = 'var(--err)'; box.appendChild(e); }
    else if (st.state === 'done') {
      box.appendChild(el('div', st.note || 'Đã tải.'));
      (st.files || []).filter(function (f) { return f.kind !== 'other'; }).forEach(function (f) {
        var r = el('div', null, 'file'); r.appendChild(el('span', f.name));
        r.appendChild(btn('Chèn', function () { call('insert_path', f.path); }, 'primary')); box.appendChild(r);
      });
      box.appendChild(btn('Mở thư mục tải về', function () { call('dl_open', uid); }, 'link'));
    }
  }

  // ================================================================ Danh mục
  function renderCats() {
    var nav = $('cats'); nav.replaceChildren();
    S.categories.forEach(function (c) {
      if (c.id === 'personal') nav.appendChild(el('div', null, 'sep'));
      var b = el('button', null, 'cat' + (c.id === S.category ? ' on' : '')); b.type = 'button'; b.dataset.cat = c.id;
      b.appendChild(el('span', c.icon || '◆', 'ic')); b.appendChild(el('span', c.name, 'nm'));
      if (c.custom) { var ed = el('span', '✎', 'ed'); ed.title = 'Sửa danh mục'; ed.addEventListener('click', function (e) { e.stopPropagation(); editCat(c); }); b.appendChild(ed); }
      b.addEventListener('click', function () { selectCat(c.id); });
      nav.appendChild(b);
    });
  }
  function selectCat(id) {
    S.category = id;
    document.querySelectorAll('#cats .cat').forEach(function (b) { b.classList.toggle('on', b.dataset.cat === id); });
    $('content').scrollTop = 0;
    callJ('save_settings', { ui: { category: id } });
    kwSearch();
  }
  function editCat(c) {
    S.editCat = c || null;
    $('catTitle').textContent = c ? 'Sửa danh mục' : 'Thêm danh mục';
    $('catName').value = c ? c.name : ''; $('catKw').value = c ? (c.keywords || []).join(', ') : '';
    $('catDelete').hidden = !c; show('catModal'); $('catName').focus();
  }

  // ================================================================ AI
  function aiPreview(p) {
    show('aiModal'); S.ai.src = p.src; S.ai.mime = p.mime;
    var img = $('aiImg'); img.src = isSafeImg(p.src) ? p.src : ''; img.hidden = false; $('aiNoImg').hidden = true;
    $('aiFileInfo').textContent = p.name + ' · ' + fmtSize(p.size);
    $('aiEndpoint').textContent = p.endpoint; $('aiModelName').textContent = p.model;
    $('aiConsent').hidden = false; $('aiSend').disabled = false; $('aiState').textContent = ''; $('aiResult').hidden = true;
  }
  // ================================================================ Tìm bằng ảnh (AI cục bộ)
  function vsShow(src) {
    S.vs.on = true; if (src) { S.vs.src = src; $('vsThumb').src = src; } $('q').value = '';
    $('vsBar').hidden = false; $('vsBar').classList.remove('err');
  }
  function vsClear() {
    S.vs.on = false; S.vs.src = null; $('vsBar').hidden = true; $('vsThumb').removeAttribute('src'); call('vs_clear');
  }
  function vsFromDataUrl(src) {
    if (!/^data:image\/(png|jpeg|webp);base64,/.test(src)) { setStatus('Chỉ nhận ảnh JPG, PNG, WEBP.', 'warn'); return; }
    vsShow(src); $('vsMsg').textContent = 'Đang gửi ảnh…';
    shrinkImage(src, function (b64, mime) { callJ('vs_start', { b64: b64, mime: mime }); });
  }
  function vsFromBlob(blob) {
    if (!blob || !/^image\/(png|jpeg|webp)$/.test(blob.type)) { setStatus('Chỉ nhận ảnh JPG, PNG, WEBP.', 'warn'); return; }
    var r = new FileReader(); r.onload = function () { vsFromDataUrl(r.result); }; r.readAsDataURL(blob);
  }
  function vsPaste() {
    if (navigator.clipboard && navigator.clipboard.read) {
      navigator.clipboard.read().then(function (items) {
        for (var i = 0; i < items.length; i++) {
          var t = items[i].types.find(function (x) { return /^image\//.test(x); });
          if (t) return items[i].getType(t).then(vsFromBlob);
        }
        setStatus('Clipboard không có ảnh. Hãy sao chép ảnh rồi nhấn Ctrl+V.', 'warn');
      }).catch(function () { setStatus('Nhấn Ctrl+V để dán ảnh.', 'info'); });
    } else setStatus('Nhấn Ctrl+V để dán ảnh.', 'info');
  }
  var crop = { box: null, drag: null };
  function openCrop() {
    if (!S.vs.src) return;
    $('cropImg').src = S.vs.src; $('cropSel').hidden = true; crop.box = null; $('cropOk').disabled = true; show('cropModal');
  }
  function cropRel(e) {
    var r = $('cropImg').getBoundingClientRect();
    return [Math.min(1, Math.max(0, (e.clientX - r.left) / r.width)), Math.min(1, Math.max(0, (e.clientY - r.top) / r.height))];
  }
  function drawCrop() {
    var b = crop.box; if (!b) return; var s = $('cropSel'); s.hidden = false;
    s.style.left = (b[0] * 100) + '%'; s.style.top = (b[1] * 100) + '%'; s.style.width = ((b[2] - b[0]) * 100) + '%'; s.style.height = ((b[3] - b[1]) * 100) + '%';
  }
  function bindVisual() {
    $('btnAi').onclick = function () { if (S.vs.src) { vsShow(); } else { vsShow(); $('vsMsg').textContent = 'Chọn ảnh, dán ảnh (Ctrl+V) hoặc kéo thả ảnh vào đây.'; call('vs_pick'); } };
    $('vsPick').onclick = function () { call('vs_pick'); };
    $('vsPaste').onclick = vsPaste;
    $('vsCropBtn').onclick = openCrop;
    $('vsCancel').onclick = function () { call('vs_cancel'); };
    $('vsClear').onclick = function () { kwSearch(); };
    $('vsInstallOk').onclick = function () { hide('vsInstallModal'); call('vs_install'); };
    document.addEventListener('paste', function (e) {
      var t = e.target; if (t && (t.tagName === 'INPUT' || t.tagName === 'TEXTAREA')) return;
      var items = (e.clipboardData && e.clipboardData.items) || [];
      for (var i = 0; i < items.length; i++) if (items[i].kind === 'file' && /^image\//.test(items[i].type)) { e.preventDefault(); vsFromBlob(items[i].getAsFile()); return; }
    });
    var main = $('content');
    main.addEventListener('dragover', function (e) { if (e.dataTransfer && Array.prototype.some.call(e.dataTransfer.types, function (x) { return x === 'Files'; })) { e.preventDefault(); main.classList.add('dropping'); } });
    main.addEventListener('dragleave', function () { main.classList.remove('dropping'); });
    main.addEventListener('drop', function (e) { main.classList.remove('dropping'); var f = e.dataTransfer && e.dataTransfer.files[0]; if (f) { e.preventDefault(); vsFromBlob(f); } });
    var box = $('cropBox');
    box.addEventListener('mousedown', function (e) { e.preventDefault(); crop.drag = cropRel(e); crop.box = null; });
    window.addEventListener('mousemove', function (e) {
      if (!crop.drag) return; var p = cropRel(e), a = crop.drag;
      crop.box = [Math.min(a[0], p[0]), Math.min(a[1], p[1]), Math.max(a[0], p[0]), Math.max(a[1], p[1])]; drawCrop();
    });
    window.addEventListener('mouseup', function () {
      if (!crop.drag) return; crop.drag = null;
      var b = crop.box; $('cropOk').disabled = !(b && b[2] - b[0] > 0.03 && b[3] - b[1] > 0.03);
    });
    $('cropOk').onclick = function () { hide('cropModal'); $('vsMsg').textContent = 'Đang tìm theo vùng đã chọn…'; callJ('vs_crop', { crop: crop.box }); };
    $('cropAll').onclick = function () { hide('cropModal'); callJ('vs_crop', { crop: null }); };
  }

  function shrinkImage(src, cb) {
    var img = new Image();
    img.onload = function () {
      try {
        var max = 1280, w = img.naturalWidth, h = img.naturalHeight, k = Math.min(1, max / Math.max(w, h));
        var cv = document.createElement('canvas'); cv.width = Math.max(1, Math.round(w * k)); cv.height = Math.max(1, Math.round(h * k));
        var ctx = cv.getContext('2d'); ctx.fillStyle = '#fff'; ctx.fillRect(0, 0, cv.width, cv.height); ctx.drawImage(img, 0, 0, cv.width, cv.height);
        cb(cv.toDataURL('image/jpeg', 0.86).split(',')[1], 'image/jpeg');
      } catch (e) { cb(src.split(',')[1], S.ai.mime); }
    };
    img.onerror = function () { cb(src.split(',')[1], S.ai.mime); };
    img.src = src;
  }
  function aiSend() {
    if (!S.ai.src || S.ai.busy) return;
    S.ai.busy = true; $('aiSend').disabled = true; $('aiCancel').hidden = false; $('aiState').textContent = 'Đang chuẩn bị ảnh…';
    shrinkImage(S.ai.src, function (b64, mime) { $('aiState').textContent = 'Đang phân tích…'; callJ('ai_send', { b64: b64, mime: mime }); });
  }
  function aiDone() { S.ai.busy = false; $('aiSend').disabled = !S.ai.src; $('aiCancel').hidden = true; }
  function lines(id) { return $(id).value.split(/\r?\n/).map(function (s) { return s.trim(); }).filter(Boolean); }
  function aiResult(r) {
    aiDone(); $('aiState').textContent = '✓ Hoàn tất.'; $('aiResult').hidden = false;
    $('rType').value = r.object_type || ''; $('rStyle').value = r.style || ''; $('rMat').value = r.material || ''; $('rColor').value = r.color || '';
    $('rVi').value = (r.queries_vi || []).join('\n'); $('rEn').value = (r.queries_en || []).join('\n'); renderChips();
  }
  function renderChips() {
    var box = $('rChips'); box.replaceChildren();
    lines('rVi').concat(lines('rEn')).forEach(function (q) {
      box.appendChild(btn(q, function () { S.anyOf = null; $('q').value = q; hide('aiModal'); startSearch(); }, '', 'Tìm với cụm này'));
    });
  }
  function aiSearch() {
    var qs = lines('rEn').concat(lines('rVi')); var t = $('rType').value.trim(); if (t) qs.push(t);
    qs = qs.filter(function (v, i, a) { return a.indexOf(v) === i; }).slice(0, 12);
    if (!qs.length) return;
    S.anyOf = qs; $('q').value = lines('rVi')[0] || qs[0]; hide('aiModal'); startSearch();
  }

  // ================================================================ Cài đặt
  function saveSettings(patch) { callJ('save_settings', patch); }
  function applySettings(s) {
    S.settings = s;
    $('sQuick').checked = !!s.quick_scan; $('sScanOpen').checked = !!s.scan_on_open;
    if (document.activeElement !== $('sModel')) $('sModel').value = s.ai.model;
    if (document.activeElement !== $('sBase')) $('sBase').value = s.ai.base_url;
    $('sDetail').value = s.ai.detail; $('sDevice').value = s.ai.device || 'cpu'; $('sSfType').value = s.sketchfab.token_type;
    $('sfDownloadable').checked = !!s.sketchfab.downloadable_only;
    $('sAutoSave').checked = !!s.auto_save_downloads;
    $('sRememberKey').checked = !!s.ai.remember_key; $('sRememberSf').checked = !!s.sketchfab.remember_token;
    if (document.activeElement !== $('thumbSize')) setThumbSize(s.ui.thumb_size);
    renderRoots();
  }
  function setThumbSize(px) { px = Number(px) || 200; document.documentElement.style.setProperty('--tw', px + 'px'); $('thumbSize').value = px; }
  function renderRoots() {
    var box = $('rootList'); box.replaceChildren();
    if (!S.settings.roots.length) { box.appendChild(el('p', 'Chưa có thư mục nào. Thêm thư mục chứa file .skp (ổ cứng, ổ ngoài, ổ mạng).', 'muted')); return; }
    S.settings.roots.forEach(function (r) {
      var row = el('div', null, 'item'); row.appendChild(el('span', r, 'p'));
      var st = S.rootsState && S.rootsState[r];
      if (st) row.appendChild(el('span', st === 'ok' ? 'Đã quét' : 'Không truy cập được', 'tag' + (st === 'ok' ? '' : ' err')));
      row.appendChild(btn('Bỏ', function () { call('remove_root', r); }, '', 'Bỏ thư mục khỏi thư viện (không xóa file)'));
      box.appendChild(row);
    });
  }
  var SRC_STATUS = { ok: 'Hoạt động', checking: 'Đang kiểm tra…', blocked: 'robots.txt không cho phép', no_api: 'Không có API — mở nguồn + nhập link',
    login: 'Cần đăng nhập trên trình duyệt', error: 'Lỗi kết nối', unchecked: 'Chưa kiểm tra' };
  function renderSources(list) { /* tương thích bản cũ: danh sách nguồn nay do src_list gửi */ }
  function renderSrcList(d) {
    if (!d) return;
    S.src = d;
    S.imgDomains = (d.list || []).filter(function (s) { return !s.builtin && s.method === 'wp_rest' && s.enabled; })
      .map(function (s) { return String(s.img_domain || (/^https:\/\/([^/]+)/.exec(s.url || '') || [])[1] || '').toLowerCase(); }).filter(Boolean);
    var sel = $('srcType');
    if (sel && sel.options.length !== Object.keys(d.types || {}).length + 1) {
      var keep = sel.value; sel.replaceChildren();
      sel.appendChild(new Option('Tự nhận diện loại', ''));
      Object.keys(d.types || {}).forEach(function (k) { sel.appendChild(new Option(d.types[k], k)); });
      sel.value = keep;
    }
    var box = $('srcList'); box.replaceChildren();
    (d.list || []).forEach(function (s) {
      var row = el('div', null, 'item src'); var p = el('div', null, 'p');
      var head = el('b', s.name); p.appendChild(head);
      p.appendChild(el('span', ' ' + (s.type_label || '') + ' · ' + (s.method_label || ''), 'muted small'));
      p.appendChild(el('span', s.note || '', 'note'));
      var stt = s.stats || {};
      if (s.scannable) {
        var line = (stt.indexed || 0) + ' model đã lập chỉ mục · ' + (stt.with_links || 0) + ' có link tải · ' + (stt.with_vec || 0) + ' có vector ảnh';
        line += stt.last_sync ? ' · đồng bộ ' + fmtTime(stt.last_sync) : ' · chưa đồng bộ';
        p.appendChild(el('span', line, 'stat'));
      }
      var sy = s.sync || {};
      if (sy.phase) p.appendChild(el('span', sy.phase + (sy.running && sy.total ? ' (' + sy.done + '/' + sy.total + ')' : ''), 'prog2'));
      row.appendChild(p);
      var st = s.builtin ? (s.integrated ? 'Đã tích hợp' : 'Chưa tích hợp') : (SRC_STATUS[s.status] || s.status || '');
      row.appendChild(el('span', st, 'tag' + ((s.integrated || s.status === 'ok') ? '' : ' off')));
      var acts = el('div', null, 'acts');
      if ((s.integrated || !s.builtin) && s.id !== 'local') {
        var lb = el('label', null, 'check'); var cb = el('input'); cb.type = 'checkbox'; cb.checked = !!s.enabled; cb.dataset.src = s.id;
        cb.onchange = function () { call('src_toggle', s.id, cb.checked); setTimeout(startSearch, 80); };
        lb.appendChild(cb); lb.appendChild(document.createTextNode(' Bật')); acts.appendChild(lb);
      }
      if (/^https:\/\//.test(s.url || '')) acts.appendChild(btn('Mở', function () { call('src_open', s.id); }, '', 'Mở nguồn trên trình duyệt (đăng nhập thủ công nếu cần)'));
      if (s.scannable) {
        if (sy.running) acts.appendChild(btn('Dừng', function () { call('src_stop', s.id); }, 'danger'));
        else {
          acts.appendChild(btn('Đồng bộ', function () { call('src_scan', s.id, 'sync'); }, 'primary', 'Chỉ lấy nội dung mới/thay đổi'));
          acts.appendChild(btn('Quét', function () { call('src_scan', s.id, 'full'); }, '', 'Quét lại toàn bộ nguồn'));
        }
        acts.appendChild(btn('Nhật ký', function () { call('src_log', s.id); }));
      }
      if (!s.builtin) {
        acts.appendChild(btn('Kiểm tra kết nối', function () { call('src_check', s.id); }));
        acts.appendChild(btn('Sửa', function () { S.editSrc = s.id; $('srcName').value = s.name; $('srcType').value = s.type; $('srcUrl').value = s.url; $('srcAddBtn').textContent = 'Lưu'; $('srcCancelEdit').hidden = false; }));
        acts.appendChild(btn('Xóa', function () { call('src_delete', s.id); }, 'danger'));
      }
      row.appendChild(acts); box.appendChild(row);
    });
  }
  function fmtTime(t) { var d = new Date(t * 1000); return ('0' + d.getHours()).slice(-2) + ':' + ('0' + d.getMinutes()).slice(-2) + ' ' + fmtDate(t); }
  function srcResetForm() { S.editSrc = null; $('srcName').value = ''; $('srcUrl').value = ''; $('srcType').value = ''; $('srcAddBtn').textContent = 'Thêm nguồn'; $('srcCancelEdit').hidden = true; }
  function renderCat(d) {
    var t;
    if (!d || d.available === false) t = 'Kho dữ liệu dùng chung bộ AI tìm bằng ảnh — cài bộ AI để bật.';
    else if (d.error) t = 'Kho dữ liệu: ' + d.error;
    else t = d.total + ' model đã lưu (metadata + ảnh xem trước) · ' + d.with_vec + ' có vector ảnh · ' + d.dup + ' trùng lặp · ' +
      d.dead + ' link đã mất (' + d.checked + ' đã kiểm tra)';
    $('catInfo').textContent = t;
  }
  function renderAccounts(list) {
    var box = $('accList'); if (!box) return; box.replaceChildren();
    var names = { login: 'ĐĂNG NHẬP', logout: 'Đăng xuất', reconnect: 'Kết nối lại', open: 'Mở trang' };
    (list || []).forEach(function (a) {
      var row = el('div', null, 'item acc'); var p = el('div', null, 'p');
      p.appendChild(el('b', a.name)); p.appendChild(el('span', a.note, 'note')); row.appendChild(p);
      row.appendChild(el('span', a.status_label, 'st ' + a.status));
      var acts = el('div', null, 'acts');
      (a.actions || []).forEach(function (k) { acts.appendChild(btn(names[k] || k, function () { call('acct_action', a.id, k); }, k === 'login' ? 'primary' : '')); });
      row.appendChild(acts); box.appendChild(row);
    });
  }
  function renderSecrets(s) {
    S.secrets = s;
    function txt(x, what) { if (x.session) return '✓ Đã có ' + what + (x.stored ? ' (lưu mã hóa trên máy).' : ' trong phiên này.'); if (x.env) return '✓ Dùng ' + what + ' từ biến môi trường.'; return '✗ Chưa có ' + what + '.'; }
    $('keyState').textContent = txt(s.openai || {}, 'OpenAI API key'); $('sfState').textContent = txt(s.sketchfab || {}, 'Sketchfab token');
    $('kGoogleState').textContent = (s.google || {}).session ? '✓ Đã có' : 'Chưa có'; $('kBraveState').textContent = (s.brave || {}).session ? '✓ Đã có' : 'Chưa có';
  }
  function renderSummary(sm) {
    if (!sm || sm.cancelled || sm.failed) return;
    if (sm.roots_state) { S.rootsState = sm.roots_state; renderRoots(); }
    $('scanSummary').textContent = 'Lần quét gần nhất: ' + sm.models + ' model, ' + sm.errors + ' lỗi, ' + sm.seconds + ' giây.';
    var list = $('scanErrList'); list.replaceChildren();
    (sm.error_samples || []).forEach(function (e) { list.appendChild(el('div', e.path + ' — ' + e.msg)); });
    $('scanErrors').hidden = !(sm.error_samples && sm.error_samples.length);
  }
  function renderBlender(b) {
    if (!b) return;
    $('bPath').textContent = b.path || '—';
    $('bStatus').textContent = b.checking ? 'Đang kiểm tra Blender…' : (b.ok ? '✓ Sẵn sàng: Blender ' + b.version + ' (xuất được DAE).' : '✗ ' + (b.reason || 'Chưa kiểm tra Blender. Bấm “Tự tìm Blender”.'));
  }
  function openSettings(tab) {
    show('settingsModal');
    document.querySelectorAll('#stabs [data-s]').forEach(function (b) { b.classList.toggle('on', b.dataset.s === tab); });
    document.querySelectorAll('#settingsModal section[data-p]').forEach(function (s) { s.hidden = s.dataset.p !== tab; });
  }

  // ================================================================ Nhận dữ liệu từ Ruby
  var H = {
    init: function (d) {
      $('verLabel').textContent = 'PRO · V' + d.version;
      $('verInfo').textContent = 'MT SMART LIBRARY PRO ' + d.version + ' (' + d.build + ') · SketchUp ' + d.su;
      $('verInfo2').textContent = 'ID ' + d.plugin_id + ' · log: ' + (d.log || '');
      $('dataRoot').textContent = d.data_root;
      renderSecrets(d.secrets); S.rootsState = d.roots_state; applySettings(d.settings);
      $('rememberKeyWrap').hidden = $('rememberSfWrap').hidden = !d.secret_store;
      S.categories = d.categories || []; S.filter = d.settings.ui.filter || 'all';
      S.category = S.categories.some(function (c) { return c.id === d.settings.ui.category; }) ? d.settings.ui.category : 'all';
      if (d.visual && d.visual.gpu_probe && d.visual.gpu_probe.ok === false) $('gpuState').textContent = d.visual.gpu_probe.reason || '';
      renderSrcList(d.src);
      renderCats(); renderSources(d.sources_status || []); renderBlender(d.blender); renderAccounts(d.accounts);
      if (d.summary) renderSummary(d.summary);
      if (d.update_available) H.update_available(d.update_available);
      if (d.pending_restart) setStatus('Đã cài bản ' + d.pending_restart + ' — khởi động lại SketchUp để áp dụng.', 'ok');
      else if (d.settings_warning) setStatus(d.settings_warning, 'warn');
      else if (d.startup) setStatus(d.startup, 'ok');
      else setStatus(d.loaded ? 'Sẵn sàng.' : 'Đang nạp thư viện…');
      if (d.scan && d.scan.running) H.scan_progress(d.scan);
      startSearch();
    },
    status: function (d) { setStatus(d.msg, d.kind, d.hint); },
    settings: applySettings,
    secrets: renderSecrets,
    library: function () { startSearch(); },
    refresh: function () { startSearch(); },
    sr_begin: onBegin,
    sr_update: onUpdate,
    categories: function (d) { S.categories = d.list; hide('catModal'); if (d.select) S.category = d.select; renderCats(); startSearch(); },
    thumb: function (d) {
      S.localThumbs.set(d.id, d.src);
      if (S.localThumbs.size > 4000) S.localThumbs.delete(S.localThumbs.keys().next().value);
      document.querySelectorAll('.thumb[data-id="' + d.id + '"]').forEach(function (t) { var it = S.byKey.get(t.dataset.key); if (it) paintThumb(t, it); });
      if (S.detailKey) { var it = S.byKey.get(S.detailKey); if (it && it.id === d.id) renderDetail(it); }
    },
    fav: function (d) {
      var key = d.key || ('local:' + d.id);
      var it = S.byKey.get(key); if (it) it.fav = d.on;
      var c = S.cards.get(key); if (c && it) updateCard(c, it);
      if (S.detailKey === key && it) renderDetail(it);
      if (S.category === 'favorites') startSearch();
    },
    scan_progress: function (p) { $('scanMini').hidden = !p.running; $('scanText').textContent = 'Đang quét ' + p.files + ' file…'; $('scanText').title = p.current || ''; },
    scan_done: function (d) { $('scanMini').hidden = true; renderSummary(d); },
    inserted: function () { if (S.category === 'history') startSearch(); },
    confirm_newer: function (d) { S.newerId = d.id; $('newerText').textContent = '“' + d.name + '”: ' + d.msg; show('newerModal'); },
    blender: function (b) { renderBlender(b); if (b && b.ok) hide('blenderModal'); else if (b && !b.checking && !$('blenderModal').hidden) $('bmReason').textContent = b.reason || ''; },
    need_blender: function (d) { $('bmReason').textContent = d.reason || ''; renderBlender(d.blender); show('blenderModal'); },
    sources_status: function (l) { renderSources(l || []); },
    src_list: function (d) { renderSrcList(d); },
    src_progress: function (p) {
      if (!S.src) return; var s = (S.src.list || []).find(function (x) { return x.id === p.id; });
      if (s) { s.sync = p; renderSrcList(S.src); }
    },
    src_log: function (d) { $('srcLogText').textContent = d.text || 'Chưa có nhật ký.'; show('srcLogModal'); },
    cat_stats: function (d) { renderCat(d); },
    cat_progress: function (p) { $('catInfo').textContent = 'Đang kiểm tra link… ' + p.done + '/' + p.total; },
    vs_image: function (d) { vsShow(d.src); $('vsMsg').textContent = 'Đang nhận diện ảnh…'; },
    vs_state: function (d) {
      if (d.sid) { S.sid = d.sid; }
      var busy = ['recognizing', 'searching', 'comparing', 'installing'].indexOf(d.state) >= 0;
      $('vsCancel').hidden = !busy || d.state === 'installing'; $('vsBar').classList.toggle('err', d.state === 'error');
      if (d.msg) $('vsMsg').textContent = d.msg;
      var p = $('vsProg'); p.hidden = !(d.state === 'installing' && d.progress !== undefined && d.progress !== null);
      if (!p.hidden) p.firstChild.style.width = d.progress + '%';
      if (busy && d.state !== 'installing') { $('loading').hidden = false; }
      if (d.state === 'need_runtime') {
        $('vsMsg').textContent = 'Cần cài bộ AI tìm bằng ảnh (một lần).';
        $('vsDlMb').textContent = d.download_mb || 330; $('vsModel').textContent = d.model || 'CLIP'; $('vsLic').textContent = d.license || '';
        show('vsInstallModal');
      }
      if (d.state === 'cancelled' || d.state === 'error') $('loading').hidden = true;
      if (d.categories && d.categories.length) $('vsMsg').textContent = (d.msg || '') + ' Nhận diện: ' + d.categories.map(function (c) { return c.vi; }).join(', ');
    },
    vs_index: function (d) {
      if (d.error) { $('vsIndex').textContent = 'Chỉ mục ảnh thư viện: ' + d.error; return; }
      var t = d.running ? 'Đang lập chỉ mục ảnh thư viện máy tính… ' + ((d.base || 0) + (d.done || 0)) + (d.library ? '/' + d.library : '') : 'Thư viện máy tính: ' + (d.indexed || 0) + ' ảnh đã lập chỉ mục';
      if (d.no_thumb) t += ' · ' + d.no_thumb + ' model chưa có thumbnail (không so sánh)';
      $('vsIndex').textContent = t;
    },
    accounts: function (l) { renderAccounts(l); },
    dl_found: function (d) { $('foundText').textContent = 'Đã nhận file vừa tải “' + d.name + '” (' + d.source + '). Chèn vào SketchUp?'; $('foundBar').hidden = false; },
    open_support: function () { hide('settingsModal'); show('supportModal'); },
    convert_state: function (d) { var on = d.state === 'running'; $('convCancel').hidden = !on; $('convSpin').hidden = !on; },
    need_token: function (d) { S.tokenKey = d && d.key; $('tkInput').value = ''; show('tokenModal'); $('tkInput').focus(); },
    net: function (d) { $('netText').textContent = d.state === 'online' ? '✓ Đang trực tuyến' + (d.ms ? ' (' + d.ms + ' ms)' : '') : d.state === 'checking' ? 'Đang kiểm tra…' : '✗ ' + (d.msg || 'Mất kết nối'); },
    dl_state: function (d) {
      S.dl.set(d.uid, Object.assign(S.dl.get(d.uid) || {}, d));
      S.cards.forEach(function (c, k) { var it = S.byKey.get(k); if (it && it.uid === d.uid) updateCard(c, it); });
      var cur = S.detailKey && S.byKey.get(S.detailKey); if (cur && cur.uid === d.uid) renderDl(d.uid);
      if (d.state === 'error') setStatus(d.msg, 'error');
    },
    dl_progress: function (d) { H.dl_state({ uid: d.uid, state: 'downloading', bytes: d.bytes, total: d.total }); },
    ai_need_key: function () { hide('aiModal'); openSettings('ai'); $('sKey').focus(); },
    ai_preview: aiPreview,
    ai_state: function (d) { if (d.state === 'error') { aiDone(); $('aiState').textContent = '✗ ' + d.msg; } },
    ai_result: aiResult,
    ai_check: function (d) { $('aiCheck').textContent = d.state === 'checking' ? 'Đang kiểm tra…' : (d.state === 'ok' ? '✓ ' : '✗ ') + d.msg; },
    update_available: function (v) { var b = $('btnUpdate'); b.classList.add('has'); b.textContent = '⟳ Có bản ' + v; },
    update_installed: function (v) { var b = $('btnUpdate'); b.classList.remove('has'); b.textContent = '⟳ Cập nhật'; setStatus('Đã cài phiên bản ' + v + ' — lưu bản vẽ rồi khởi động lại SketchUp để áp dụng.', 'ok'); }
  };
  window.MT = { receive: function (type, payload) { var h = H[type]; if (!h) return; try { h(payload); } catch (e) { setStatus('Lỗi giao diện (' + type + '): ' + e.message, 'error'); } } };

  // ================================================================ Sự kiện
  function bind() {
    var q = $('q');
    q.addEventListener('compositionstart', function () { S.composing = true; });
    q.addEventListener('compositionend', function () { S.composing = false; onQueryChanged(); });
    q.addEventListener('input', function (e) { if (e.isComposing || S.composing) return; onQueryChanged(); });
    q.addEventListener('keydown', function (e) {
      if (e.isComposing || S.composing || e.keyCode === 229) return;
      if (e.key === 'Enter') { e.preventDefault(); kwSearch(); }
      else if (e.key === 'Escape' && q.value) { e.stopPropagation(); q.value = ''; onQueryChanged(); }
    });
    document.querySelector('.search').addEventListener('mousedown', function (e) { if (e.target === q || e.target.closest('button')) return; e.preventDefault(); q.focus(); });
    $('btnSearch').onclick = function () { kwSearch(); q.focus(); };
    $('content').addEventListener('scroll', maybeMore, { passive: true });
    window.addEventListener('resize', maybeMore);
    document.querySelectorAll('#filters [data-f]').forEach(function (b) { b.addEventListener('click', function () { S.filter = b.dataset.f; call('sr_filter', S.sid, S.filter); }); });
    $('thumbSize').addEventListener('input', function () { setThumbSize($('thumbSize').value); });
    $('thumbSize').addEventListener('change', function () { saveSettings({ ui: { thumb_size: Number($('thumbSize').value) } }); maybeMore(); });
    bindVisual();
    $('btnAiOpenAI').onclick = function () { hide('settingsModal'); show('aiModal'); if (!S.ai.src) call('ai_pick'); };
    $('btnUpdate').onclick = function () { call('open_updater'); };
    $('btnSettings').onclick = function () { openSettings('lib'); };
    $('btnAddRoot').onclick = $('btnAddRoot2').onclick = function () { call('add_root'); };
    $('btnAddCat').onclick = function () { editCat(null); };
    $('btnCancelScan').onclick = function () { call('cancel_scan'); };
    $('dInsert').onclick = function () { if (S.detailKey) doInsert(S.detailKey); };
    $('dFav').onclick = function () { if (S.detailKey) call('fav_item', S.detailKey); };
    $('dOpen').onclick = function () { if (S.detailKey) call('open_source', S.detailKey); };
    $('dCopyAttr').onclick = function () { var t = $('dAttrText').textContent; if (navigator.clipboard) navigator.clipboard.writeText(t).then(function () { setStatus('Đã sao chép thông tin ghi công.', 'ok'); }, function () {}); };
    $('catSave').onclick = function () { callJ('cat_save', { id: S.editCat ? S.editCat.id : '', name: $('catName').value, keywords: $('catKw').value }); };
    $('catDelete').onclick = function () { if (S.editCat) call('cat_delete', S.editCat.id); hide('catModal'); };
    document.querySelectorAll('[data-close]').forEach(function (b) { b.addEventListener('click', function () { hide(b.dataset.close); if (b.dataset.close === 'detailModal') S.detailKey = null; }); });
    document.querySelectorAll('.modal').forEach(function (m) { m.addEventListener('mousedown', function (e) { if (e.target === m) { m.hidden = true; if (m.id === 'detailModal') S.detailKey = null; } }); });
    document.addEventListener('keydown', function (e) {
      if (e.key !== 'Escape' || e.target === q) return;
      ['detailModal', 'catModal', 'aiModal', 'newerModal', 'settingsModal', 'tokenModal', 'blenderModal', 'cropModal', 'vsInstallModal', 'supportModal', 'srcLogModal'].forEach(function (id) { if (!$(id).hidden) { hide(id); if (id === 'detailModal') S.detailKey = null; } });
    });
    $('srcAddBtn').onclick = function () {
      var o = { name: $('srcName').value.trim(), type: $('srcType').value, url: $('srcUrl').value.trim() };
      if (!o.url) { setStatus('Nhập link hoặc đường dẫn nguồn.', 'warn'); return; }
      if (S.editSrc) { o.id = S.editSrc; callJ('src_update', o); } else callJ('src_add', o);
      srcResetForm();
    };
    $('srcCancelEdit').onclick = srcResetForm;
    $('srcExport').onclick = function () { call('src_export'); };
    ['Google', 'Brave'].forEach(function (k) {
      var kind = k.toLowerCase();
      $('k' + k + 'Save').onclick = function () { var v = $('k' + k).value.trim(); if (!v) return; callJ('set_secret', { kind: kind, value: v, remember: true }); $('k' + k).value = ''; };
      $('k' + k + 'Clear').onclick = function () { call('clear_secret', kind); };
    });
    $('srcImport').onclick = function () { call('src_import'); };
    $('linkGo').onclick = function () { var u = $('linkUrl').value.trim(); if (!u) return; call('link_import', u); $('linkUrl').value = ''; };
    $('catCheck').onclick = function () { call('cat_check_links'); };
    $('catClear').onclick = function () { call('cat_clear'); };
    document.querySelectorAll('#stabs [data-s]').forEach(function (b) { b.addEventListener('click', function () { if (b.dataset.s === 'src') { call('cat_stats'); call('src_stats'); } }); });
    $('foundIns').onclick = function () { $('foundBar').hidden = true; call('insert_found'); };
    $('foundX').onclick = function () { $('foundBar').hidden = true; call('found_dismiss'); };
    $('bDetect').onclick = $('bmDetect').onclick = function () { call('blender_detect'); };
    $('bPick').onclick = $('bmPick').onclick = function () { call('blender_pick'); };
    $('bGet').onclick = $('bmGet').onclick = function () { call('open_url', 'https://www.blender.org/download/'); };
    $('cClear').onclick = function () { call('convert_clear_cache'); };
    $('convCancel').onclick = function () { call('convert_cancel'); };
    $('tkOpen').onclick = function () { call('open_url', 'https://sketchfab.com/settings/password'); };
    function tkSave() {
      var v = $('tkInput').value.trim(); if (!v) { $('tkInput').focus(); return; }
      callJ('set_secret', { kind: 'sketchfab', value: v, remember: true }); $('tkInput').value = ''; hide('tokenModal');
      if (S.tokenKey) doInsert(S.tokenKey);
    }
    $('tkSave').onclick = tkSave;
    $('tkInput').addEventListener('keydown', function (e) { if (e.key === 'Enter') tkSave(); });
    $('newerYes').onclick = function () { hide('newerModal'); if (S.newerId) call('insert', S.newerId, true); };
    $('aiPick').onclick = function () { call('ai_pick'); };
    $('aiSend').onclick = aiSend;
    $('aiCancel').onclick = function () { call('ai_cancel'); aiDone(); $('aiState').textContent = 'Đã hủy.'; };
    $('aiClose').onclick = function () { hide('aiModal'); };
    $('rVi').addEventListener('input', renderChips); $('rEn').addEventListener('input', renderChips);
    $('rSearch').onclick = aiSearch;
    document.querySelectorAll('#stabs [data-s]').forEach(function (b) { b.addEventListener('click', function () { openSettings(b.dataset.s); }); });
    $('btnScanQuick').onclick = function () { call('scan', 'quick'); };
    $('btnScanFull').onclick = function () { call('scan', 'full'); };
    $('sQuick').onchange = function () { saveSettings({ quick_scan: $('sQuick').checked }); };
    $('sScanOpen').onchange = function () { saveSettings({ scan_on_open: $('sScanOpen').checked }); };
    $('sfDownloadable').onchange = function () { saveSettings({ sketchfab: { downloadable_only: $('sfDownloadable').checked } }); setTimeout(startSearch, 50); };
    $('sAutoSave').onchange = function () { saveSettings({ auto_save_downloads: $('sAutoSave').checked }); };
    $('sModel').onchange = function () { saveSettings({ ai: { model: $('sModel').value.trim() }, _notify: true }); };
    $('sBase').onchange = function () { saveSettings({ ai: { base_url: $('sBase').value.trim() }, _notify: true }); };
    $('sDetail').onchange = function () { saveSettings({ ai: { detail: $('sDetail').value } }); };
    $('sDevice').onchange = function () { saveSettings({ ai: { device: $('sDevice').value }, _notify: true }); };
    $('vsRepair').onclick = function () { hide('supportModal'); vsShow(); call('vs_repair'); };
    $('vsLog').onclick = function () { call('vs_open_log'); };
    $('sSfType').onchange = function () { saveSettings({ sketchfab: { token_type: $('sSfType').value } }); };
    $('btnSaveKey').onclick = function () { var v = $('sKey').value.trim(); if (!v) return; callJ('set_secret', { kind: 'openai', value: v, remember: $('sRememberKey').checked }); $('sKey').value = ''; };
    $('btnClearKey').onclick = function () { call('clear_secret', 'openai'); };
    $('btnSaveSf').onclick = function () { var v = $('sSfToken').value.trim(); if (!v) return; callJ('set_secret', { kind: 'sketchfab', value: v, remember: $('sRememberSf').checked }); $('sSfToken').value = ''; };
    $('btnClearSf').onclick = function () { call('clear_secret', 'sketchfab'); };
    $('btnSfTokenPage').onclick = function () { call('open_url', 'https://sketchfab.com/settings/password'); };
    $('btnCheckAi').onclick = function () { call('check_openai'); };
    $('btnCheckNet').onclick = function () { call('check_network'); };
    $('btnOpenData').onclick = function () { call('open_data_dir'); };
    $('btnOpenLog').onclick = function () { call('open_log'); };
    $('btnClearThumbs').onclick = function () { S.localThumbs.clear(); call('clear_thumbs'); };
    $('btnImport3d').onclick = function () { call('import_3d'); };
  }

  function start() { bind(); if (!call('ready')) setStatus('Giao diện chạy ngoài SketchUp (không có cầu nối sketchup).', 'warn'); }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start); else start();
})();
