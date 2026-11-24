/* MT SMART LIBRARY PRO V1.0.2 — giao diện tìm kiếm tổng hợp.
   Không tải JS ngoài; mọi dữ liệu hiển thị qua textContent; ảnh chỉ nhận data: hoặc https://media.sketchfab.com. */
(function () {
  'use strict';
  var $ = function (id) { return document.getElementById(id); };
  var S = {
    sid: 0, items: [], byKey: new Map(), cards: new Map(), loading: false, hasMore: false, filter: 'all', category: 'all',
    anyOf: null, settings: null, secrets: null, categories: [], localThumbs: new Map(), thumbWant: new Set(), thumbTimer: null,
    observer: null, debounce: null, composing: false, detailKey: null, dl: new Map(), ai: { src: null, mime: null, busy: false },
    newerId: null, editCat: null, moreAsked: false, lastQuery: '', beginInfo: ''
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
  function isSafeImg(u) { return typeof u === 'string' && (/^https:\/\/media\.sketchfab\.com\//.test(u) || /^data:image\/(png|jpeg|webp|gif);base64,/.test(u)); }
  function setStatus(msg, kind, hint) { $('statusMsg').textContent = msg || ''; $('statusHint').textContent = hint || ''; $('statusBar').className = 'status ' + (kind || ''); }
  function show(id) { $(id).hidden = false; }
  function hide(id) { $(id).hidden = true; }

  // ================================================================ Tìm kiếm
  function startSearch() {
    clearTimeout(S.debounce);
    S.sid += 1; S.moreAsked = false; S.loading = true; S.lastQuery = $('q').value.trim(); S.beginInfo = '';
    $('loading').hidden = false;
    callJ('sr_start', { sid: S.sid, q: S.lastQuery, category: S.category, filter: S.filter, any_of: S.anyOf || [] });
  }
  function searchSoon() { clearTimeout(S.debounce); S.debounce = setTimeout(startSearch, 350); }
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
    th.appendChild(el('span', it.source === 'local' ? '💻' : '☁', 'src'));
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
      row('Tải về', it.downloadable ? 'Được phép' : 'Tác giả không cho phép tải');
      row('Định dạng', (it.formats || []).map(function (f) { return f.type.toUpperCase() + (f.size ? ' ' + fmtSize(f.size) : ''); }).join(', '));
      if (it.faces) row('Số mặt', Number(it.faces).toLocaleString('vi-VN'));
    }
    var attr = $('dAttr');
    if (it.source !== 'local') {
      attr.hidden = false;
      $('dAttrText').textContent = '“' + it.title + '” của ' + (it.author || '?') + ' — ' + (it.license || 'giấy phép chưa rõ') + ' — nguồn ' + it.source_label + (it.url ? ' (' + it.url + ')' : '') + '.';
    } else attr.hidden = true;
    $('dInsert').textContent = it.source === 'local' ? 'CHÈN MODEL' : (it.downloadable ? 'TẢI & CHÈN MODEL' : 'XEM TRÊN TRANG NGUỒN');
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
    startSearch();
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
    $('sDetail').value = s.ai.detail; $('sSfType').value = s.sketchfab.token_type;
    $('sfDownloadable').checked = !!s.sketchfab.downloadable_only; $('sSfOn').checked = s.sources.sketchfab !== false;
    $('sAutoSave').checked = !!s.auto_save_downloads; $('sTimeout').value = s.net.timeout;
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
  function renderSources(list) {
    var box = $('srcList'); box.replaceChildren();
    list.forEach(function (s) {
      var row = el('div', null, 'item'); var p = el('div', null, 'p');
      p.appendChild(el('b', s.name)); p.appendChild(el('span', s.note, 'note')); row.appendChild(p);
      row.appendChild(el('span', !s.integrated ? 'Chưa tích hợp' : (s.enabled ? 'Đang dùng' : 'Đã tắt'), 'tag' + (s.integrated && s.enabled ? '' : ' off')));
      box.appendChild(row);
    });
  }
  function renderSecrets(s) {
    S.secrets = s;
    function txt(x, what) { if (x.session) return '✓ Đã có ' + what + (x.stored ? ' (lưu mã hóa trên máy).' : ' trong phiên này.'); if (x.env) return '✓ Dùng ' + what + ' từ biến môi trường.'; return '✗ Chưa có ' + what + '.'; }
    $('keyState').textContent = txt(s.openai || {}, 'OpenAI API key'); $('sfState').textContent = txt(s.sketchfab || {}, 'Sketchfab token');
  }
  function renderSummary(sm) {
    if (!sm || sm.cancelled || sm.failed) return;
    if (sm.roots_state) { S.rootsState = sm.roots_state; renderRoots(); }
    $('scanSummary').textContent = 'Lần quét gần nhất: ' + sm.models + ' model, ' + sm.errors + ' lỗi, ' + sm.seconds + ' giây.';
    var list = $('scanErrList'); list.replaceChildren();
    (sm.error_samples || []).forEach(function (e) { list.appendChild(el('div', e.path + ' — ' + e.msg)); });
    $('scanErrors').hidden = !(sm.error_samples && sm.error_samples.length);
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
      $('verInfo').textContent = 'MT SMART LIBRARY PRO ' + d.version + ' (' + d.build + ') · SketchUp ' + d.su + ' · ID ' + d.plugin_id;
      $('dataRoot').textContent = d.data_root;
      renderSecrets(d.secrets); S.rootsState = d.roots_state; applySettings(d.settings);
      $('rememberKeyWrap').hidden = $('rememberSfWrap').hidden = !d.secret_store;
      S.categories = d.categories || []; S.filter = d.settings.ui.filter || 'all';
      S.category = S.categories.some(function (c) { return c.id === d.settings.ui.category; }) ? d.settings.ui.category : 'all';
      renderCats(); renderSources(d.sources_status || []);
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
      if (e.key === 'Enter') { e.preventDefault(); startSearch(); }
      else if (e.key === 'Escape' && q.value) { e.stopPropagation(); q.value = ''; onQueryChanged(); }
    });
    document.querySelector('.search').addEventListener('mousedown', function (e) { if (e.target === q || e.target.closest('button')) return; e.preventDefault(); q.focus(); });
    $('btnSearch').onclick = function () { startSearch(); q.focus(); };
    $('content').addEventListener('scroll', maybeMore, { passive: true });
    window.addEventListener('resize', maybeMore);
    document.querySelectorAll('#filters [data-f]').forEach(function (b) { b.addEventListener('click', function () { S.filter = b.dataset.f; call('sr_filter', S.sid, S.filter); }); });
    $('thumbSize').addEventListener('input', function () { setThumbSize($('thumbSize').value); });
    $('thumbSize').addEventListener('change', function () { saveSettings({ ui: { thumb_size: Number($('thumbSize').value) } }); maybeMore(); });
    $('btnAi').onclick = function () { show('aiModal'); if (!S.ai.src) call('ai_pick'); };
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
      ['detailModal', 'catModal', 'aiModal', 'newerModal', 'settingsModal', 'tokenModal'].forEach(function (id) { if (!$(id).hidden) { hide(id); if (id === 'detailModal') S.detailKey = null; } });
    });
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
    $('sSfOn').onchange = function () { saveSettings({ sources: { sketchfab: $('sSfOn').checked } }); setTimeout(startSearch, 50); };
    $('sfDownloadable').onchange = function () { saveSettings({ sketchfab: { downloadable_only: $('sfDownloadable').checked } }); setTimeout(startSearch, 50); };
    $('sAutoSave').onchange = function () { saveSettings({ auto_save_downloads: $('sAutoSave').checked }); };
    $('sModel').onchange = function () { saveSettings({ ai: { model: $('sModel').value.trim() }, _notify: true }); };
    $('sBase').onchange = function () { saveSettings({ ai: { base_url: $('sBase').value.trim() }, _notify: true }); };
    $('sDetail').onchange = function () { saveSettings({ ai: { detail: $('sDetail').value } }); };
    $('sSfType').onchange = function () { saveSettings({ sketchfab: { token_type: $('sSfType').value } }); };
    $('sTimeout').onchange = function () { saveSettings({ net: { timeout: Number($('sTimeout').value) }, _notify: true }); };
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
    $('btnImportSkp').onclick = function () { call('import_skp'); };
    $('btnImport3d').onclick = function () { call('import_3d'); };
  }

  function start() { bind(); if (!call('ready')) setStatus('Giao diện chạy ngoài SketchUp (không có cầu nối sketchup).', 'warn'); }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start); else start();
})();
