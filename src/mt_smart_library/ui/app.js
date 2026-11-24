/* MT SMART LIBRARY PRO — giao diện. Không tải JS ngoài; mọi dữ liệu hiển thị qua textContent. */
(function () {
  'use strict';
  var $ = function (id) { return document.getElementById(id); };
  var S = {
    tab: 'offline', page: 0, pages: 1, seq: 0, lastSeq: 0, anyOf: null, settings: null, secrets: null,
    thumbs: new Map(), thumbWant: new Set(), thumbTimer: null, observer: null,
    sf: { q: '', cursor: null, stack: [], next: null, seq: 0 }, sfItems: new Map(), dl: new Map(),
    ai: { src: null, mime: null, busy: false }, newerId: null, debounce: null, version: ''
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
  function fmtSize(b) { b = Number(b) || 0; if (b < 1024) return b + ' B'; if (b < 1048576) return (b / 1024).toFixed(0) + ' KB'; if (b < 1073741824) return (b / 1048576).toFixed(2) + ' MB'; return (b / 1073741824).toFixed(2) + ' GB'; }
  function fmtDate(t) { if (!t) return ''; var d = new Date(t * 1000); return ('0' + d.getDate()).slice(-2) + '/' + ('0' + (d.getMonth() + 1)).slice(-2) + '/' + d.getFullYear(); }
  function isSafeImg(u) { return typeof u === 'string' && (/^https:\/\/media\.sketchfab\.com\//.test(u) || /^data:image\/(png|jpeg|webp|gif);base64,/.test(u)); }

  function setStatus(msg, kind, hint) {
    $('statusMsg').textContent = msg || '';
    $('statusHint').textContent = hint || '';
    $('statusBar').className = 'status ' + (kind || '');
  }

  // ---------------------------------------------------------------- Tabs
  function setTab(t) {
    S.tab = t; S.page = 0;
    document.querySelectorAll('#tabs [data-tab]').forEach(function (b) { b.classList.toggle('active', b.dataset.tab === t); });
    var lib = (t === 'offline' || t === 'favorites' || t === 'history');
    $('viewLibrary').hidden = !lib; $('viewOnline').hidden = t !== 'online'; $('viewSettings').hidden = t !== 'settings';
    if (lib) search();
    if (S.settings) saveSettings({ ui: { tab: t } });
  }

  // ---------------------------------------------------------------- Tìm kiếm offline
  function search() {
    if (!(S.tab === 'offline' || S.tab === 'favorites' || S.tab === 'history')) return;
    S.seq += 1;
    callJ('search', {
      seq: S.seq, q: $('q').value, tab: S.tab, page: S.page, any_of: S.anyOf || [],
      sort: $('fSort').value, size_max_mb: Number($('fSize').value), root: $('fRoot').value,
      per_page: S.settings ? S.settings.ui.page_size : 48
    });
  }
  function searchSoon() { clearTimeout(S.debounce); S.debounce = setTimeout(function () { S.page = 0; search(); }, 220); }

  function renderResults(r) {
    if (r.seq && r.seq < S.seq) return; // kết quả cũ
    S.page = r.page; S.pages = r.pages;
    var grid = $('grid'); grid.replaceChildren();
    var label = r.total + ' model';
    if (r.library_size !== undefined && S.tab === 'offline') label += ' / ' + r.library_size + ' trong thư viện';
    $('count').textContent = label;
    $('pInfo').textContent = 'Trang ' + (r.page + 1) + ' / ' + r.pages;
    $('pFirst').disabled = $('pPrev').disabled = r.page <= 0;
    $('pNext').disabled = $('pLast').disabled = r.page >= r.pages - 1;
    $('pager').hidden = r.pages <= 1;
    var empty = $('empty');
    if (!r.items.length) {
      empty.hidden = false;
      var noRoots = S.settings && S.settings.roots.length === 0;
      if (S.tab === 'favorites') empty.textContent = 'Chưa có model yêu thích phù hợp. Bấm ☆ trên thẻ model để thêm.';
      else if (S.tab === 'history') empty.textContent = 'Chưa có lịch sử chèn model phù hợp.';
      else if (noRoots) empty.textContent = 'Chưa có thư mục thư viện. Bấm “+ Thêm thư mục” để chọn thư mục chứa file .skp (ổ cứng, ổ ngoài hoặc ổ mạng).';
      else empty.textContent = 'Không có model phù hợp. Thử từ khóa khác (có thể gõ không dấu, tiếng Việt hoặc tiếng Anh) hoặc bỏ bộ lọc.';
    } else empty.hidden = true;
    if (S.observer) S.observer.disconnect();
    r.items.forEach(function (x) { grid.appendChild(card(x)); });
  }

  function card(x) {
    var c = el('div', null, 'card');
    var pic = el('div', null, 'pic'); pic.dataset.id = x.id; pic.title = 'Bấm để chèn vào công trình';
    paintThumb(pic, S.thumbs.has(x.id) ? S.thumbs.get(x.id) : undefined);
    pic.addEventListener('click', function () { call('insert', x.id); });
    var info = el('div', null, 'info');
    var name = el('div', x.name, 'name'); name.title = x.path;
    var meta = el('div', x.folder + ' · ' + fmtSize(x.size) + ' · ' + fmtDate(x.mtime), 'meta'); meta.title = x.path;
    var act = el('div', null, 'actions');
    act.appendChild(btn('Chèn', function () { call('insert', x.id); }, 'primary', 'Nạp model và đặt bằng chuột vào công trình'));
    var fav = btn(x.fav ? '★' : '☆', function () { call('favorite', x.id); }, 'fav' + (x.fav ? ' on' : ''), 'Yêu thích');
    fav.dataset.fav = x.id; act.appendChild(fav);
    act.appendChild(btn('📂', function () { call('open_folder', x.id); }, '', 'Mở thư mục chứa file'));
    info.appendChild(name); info.appendChild(meta); info.appendChild(act);
    c.appendChild(pic); c.appendChild(info);
    if (!S.thumbs.has(x.id)) observe(pic);
    return c;
  }

  function paintThumb(pic, src) {
    pic.replaceChildren();
    if (src && isSafeImg(src)) { var i = el('img'); i.alt = ''; i.loading = 'lazy'; i.src = src; pic.appendChild(i); }
    else pic.textContent = src === undefined ? '…' : '◇';
  }

  function observe(pic) {
    if (!('IntersectionObserver' in window)) { wantThumb(pic.dataset.id); return; }
    if (!S.observer) {
      S.observer = new IntersectionObserver(function (ents) {
        ents.forEach(function (en) { if (en.isIntersecting) { wantThumb(en.target.dataset.id); S.observer.unobserve(en.target); } });
      }, { root: document.querySelector('main'), rootMargin: '200px' });
    }
    S.observer.observe(pic);
  }
  function wantThumb(id) {
    S.thumbWant.add(id);
    if (S.thumbTimer) return;
    S.thumbTimer = setTimeout(function () {
      var ids = Array.from(S.thumbWant); S.thumbWant.clear(); S.thumbTimer = null;
      if (ids.length) callJ('thumbs', ids);
    }, 80);
  }

  // ---------------------------------------------------------------- Online
  function renderLinkSources(list) {
    var box = $('linkSources'); box.replaceChildren();
    list.forEach(function (s) {
      box.appendChild(btn(s.name, function () {
        var q = $('q').value.trim();
        if (!q) { setStatus('Nhập từ khóa ở ô tìm kiếm trước khi tìm online.', 'warn'); $('q').focus(); return; }
        call('online_link', s.id, q);
      }, '', s.note));
    });
  }

  function sfSearch(cursor, isBack) {
    var q = $('q').value.trim();
    if (!q) { setStatus('Nhập từ khóa để tìm trên Sketchfab.', 'warn'); $('q').focus(); return; }
    if (!cursor) { S.sf.stack = []; }
    else if (!isBack) S.sf.stack.push(S.sf.cursor);
    S.sf.q = q; S.sf.cursor = cursor || null; S.sf.seq += 1;
    callJ('sf_search', { q: q, cursor: cursor || null, downloadable: $('sfDownloadable').checked, seq: S.sf.seq });
  }

  function renderSf(d) {
    if (d.seq !== S.sf.seq) return;
    $('sfMsg').hidden = true;
    var g = $('sfGrid'); g.replaceChildren();
    S.sf.next = d.next || null;
    if (!d.items.length) { showSfMsg('Không có kết quả trên Sketchfab cho “' + d.q + '”.', 'info'); }
    d.items.forEach(function (it) { S.sfItems.set(it.uid, it); g.appendChild(sfCard(it)); if (S.dl.has(it.uid)) renderDl({ uid: it.uid }); });
    $('sfPager').hidden = !(S.sf.next || S.sf.stack.length);
    $('sfPrev').disabled = !S.sf.stack.length; $('sfNext').disabled = !S.sf.next;
    $('sfInfo').textContent = 'Trang ' + (S.sf.stack.length + 1);
  }
  function showSfMsg(t, kind, fallback) {
    var m = $('sfMsg'); m.hidden = false; m.className = 'msg ' + (kind || ''); m.replaceChildren(el('span', t));
    if (fallback) { m.appendChild(document.createTextNode(' ')); m.appendChild(btn('Mở trên trình duyệt', function () { call('online_link', 'sketchfab_web', S.sf.q); }, 'small')); }
  }

  function sfCard(it) {
    var c = el('div', null, 'card'); c.dataset.uid = it.uid;
    var pic = el('div', null, 'pic'); pic.title = 'Xem trên Sketchfab';
    if (isSafeImg(it.thumb)) { var i = el('img'); i.alt = ''; i.loading = 'lazy'; i.referrerPolicy = 'no-referrer'; i.src = it.thumb; pic.appendChild(i); } else pic.textContent = '◇';
    if (it.downloadable) pic.appendChild(el('span', 'Cho phép tải', 'badge'));
    pic.addEventListener('click', function () { call('open_url', it.viewer_url); });
    var info = el('div', null, 'info');
    info.appendChild(el('div', it.name, 'name'));
    var by = el('div', null, 'meta');
    by.appendChild(document.createTextNode('Tác giả: '));
    if (it.author_url) by.appendChild(btn(it.author || '?', function () { call('open_url', it.author_url); }, 'link'));
    else by.appendChild(document.createTextNode(it.author || '?'));
    info.appendChild(by);
    var m2 = el('div', null, 'meta');
    m2.appendChild(el('span', it.license || 'Không rõ giấy phép', 'lic'));
    if (it.faces) m2.appendChild(document.createTextNode(' · ' + it.faces.toLocaleString('vi-VN') + ' mặt'));
    info.appendChild(m2);
    var act = el('div', null, 'actions');
    act.appendChild(btn('Xem', function () { call('open_url', it.viewer_url); }, '', 'Mở trang model trên Sketchfab'));
    if (it.downloadable) {
      var sel = el('select'); sel.title = 'Định dạng tải';
      var fm = (it.formats && it.formats.length) ? it.formats : [{ type: 'gltf', size: 0 }];
      fm.forEach(function (f) { var o = el('option', f.type.toUpperCase() + (f.size ? ' ' + fmtSize(f.size) : '')); o.value = f.type; sel.appendChild(o); });
      act.appendChild(sel);
      act.appendChild(btn('Tải', function () { callJ('sf_download', { uid: it.uid, format: sel.value }); }, 'primary', 'Tải về máy (cần Sketchfab token)'));
    }
    info.appendChild(act);
    var dl = el('div', null, 'dl'); dl.hidden = true; dl.id = 'dl_' + it.uid; info.appendChild(dl);
    c.appendChild(pic); c.appendChild(info);
    return c;
  }

  function renderDl(d) {
    S.dl.set(d.uid, Object.assign(S.dl.get(d.uid) || {}, d));
    var box = $('dl_' + d.uid); if (!box) return;
    var st = S.dl.get(d.uid); box.hidden = false; box.replaceChildren();
    if (st.state === 'requesting') box.appendChild(el('span', 'Đang xin link tải…'));
    else if (st.state === 'downloading') {
      var pct = st.total ? Math.min(100, Math.round((st.bytes || 0) * 100 / st.total)) : 0;
      box.appendChild(el('span', 'Đang tải ' + (st.format || '').toUpperCase() + '… ' + (st.total ? pct + '% (' + fmtSize(st.bytes || 0) + ' / ' + fmtSize(st.total) + ')' : fmtSize(st.bytes || 0))));
      var bar = el('div', null, 'bar'), fill = el('i'); fill.style.width = pct + '%'; bar.appendChild(fill); box.appendChild(bar);
    } else if (st.state === 'error') { var e = el('span', st.msg || 'Lỗi tải'); e.style.color = 'var(--err)'; box.appendChild(e); }
    else if (st.state === 'done') {
      box.appendChild(el('span', st.note || 'Đã tải.'));
      (st.files || []).forEach(function (f) {
        if (f.kind === 'other') return;
        var row = el('div', null, 'file'); row.appendChild(el('span', f.name)); row.title = f.path;
        row.appendChild(btn(f.kind === 'skp' ? 'Chèn' : 'Nhập', function () { call('insert_path', f.path); }, 'small primary'));
        box.appendChild(row);
      });
      box.appendChild(btn('Mở thư mục tải về', function () { call('dl_open', d.uid); }, 'small'));
    }
  }

  // ---------------------------------------------------------------- AI
  function openAi() { $('aiModal').hidden = false; }
  function closeAi() { $('aiModal').hidden = true; }
  function aiPreview(p) {
    openAi();
    S.ai.src = p.src; S.ai.mime = p.mime;
    var img = $('aiImg'); img.src = isSafeImg(p.src) ? p.src : ''; img.hidden = false; $('aiNoImg').hidden = true;
    $('aiFileInfo').textContent = p.name + ' · ' + fmtSize(p.size);
    $('aiEndpoint').textContent = p.endpoint; $('aiModelName').textContent = p.model;
    $('aiConsent').hidden = false; $('aiSend').disabled = false; $('aiState').textContent = '';
    $('aiResult').hidden = true;
  }
  function shrinkImage(src, cb) {
    var img = new Image();
    img.onload = function () {
      try {
        var max = 1280, w = img.naturalWidth, h = img.naturalHeight, k = Math.min(1, max / Math.max(w, h));
        var cv = document.createElement('canvas'); cv.width = Math.max(1, Math.round(w * k)); cv.height = Math.max(1, Math.round(h * k));
        var ctx = cv.getContext('2d'); ctx.fillStyle = '#fff'; ctx.fillRect(0, 0, cv.width, cv.height); ctx.drawImage(img, 0, 0, cv.width, cv.height);
        var out = cv.toDataURL('image/jpeg', 0.86);
        cb(out.split(',')[1], 'image/jpeg');
      } catch (e) { cb(src.split(',')[1], S.ai.mime); }
    };
    img.onerror = function () { cb(src.split(',')[1], S.ai.mime); };
    img.src = src;
  }
  function aiSend() {
    if (!S.ai.src || S.ai.busy) return;
    S.ai.busy = true; $('aiSend').disabled = true; $('aiCancel').hidden = false;
    $('aiState').textContent = 'Đang chuẩn bị ảnh…';
    shrinkImage(S.ai.src, function (b64, mime) {
      $('aiState').textContent = 'Đang gửi tới OpenAI và chờ phân tích…';
      callJ('ai_send', { b64: b64, mime: mime });
    });
  }
  function aiDone() { S.ai.busy = false; $('aiSend').disabled = !S.ai.src; $('aiCancel').hidden = true; }
  function lines(id) { return $(id).value.split(/\r?\n/).map(function (s) { return s.trim(); }).filter(Boolean); }
  function aiResult(r) {
    aiDone();
    $('aiState').textContent = 'Hoàn tất' + (r.usage && r.usage.total_tokens ? ' — ' + r.usage.total_tokens + ' token' : '') + '.';
    $('aiResult').hidden = false;
    $('rType').value = r.object_type || ''; $('rStyle').value = r.style || ''; $('rMat').value = r.material || ''; $('rColor').value = r.color || '';
    $('rVi').value = (r.queries_vi || []).join('\n'); $('rEn').value = (r.queries_en || []).join('\n');
    renderChips();
  }
  function renderChips() {
    var box = $('rChips'); box.replaceChildren();
    lines('rVi').concat(lines('rEn')).forEach(function (q) {
      box.appendChild(btn(q, function () { S.anyOf = null; updateAiFilter(); $('q').value = q; closeAi(); setTab('offline'); }, '', 'Dùng cụm này tìm offline'));
    });
  }
  function allQueries() {
    var qs = lines('rVi').concat(lines('rEn'));
    var t = $('rType').value.trim(); if (t) qs.push(t);
    return qs.filter(function (v, i, a) { return a.indexOf(v) === i; }).slice(0, 12);
  }
  function updateAiFilter() {
    var on = !!(S.anyOf && S.anyOf.length);
    $('aiFilter').hidden = !on;
    if (on) $('aiFilterText').textContent = 'Từ khóa AI: ' + S.anyOf.join(' | ');
  }

  // ---------------------------------------------------------------- Cài đặt
  function saveSettings(patch) { callJ('save_settings', patch); }
  function applySettings(s) {
    S.settings = s;
    var sel = $('fRoot'), cur = sel.value; sel.replaceChildren(el('option', 'Tất cả thư mục')); sel.firstChild.value = '';
    s.roots.forEach(function (r) { var o = el('option', r); o.value = r; sel.appendChild(o); });
    sel.value = s.roots.indexOf(cur) >= 0 ? cur : '';
    $('fSort').value = s.ui.sort; $('fSize').value = String(s.ui.size_max_mb); $('sPage').value = String(s.ui.page_size);
    $('sQuick').checked = !!s.quick_scan; $('sScanOpen').checked = !!s.scan_on_open;
    if (document.activeElement !== $('sModel')) $('sModel').value = s.ai.model;
    if (document.activeElement !== $('sBase')) $('sBase').value = s.ai.base_url;
    $('sDetail').value = s.ai.detail; $('sSfType').value = s.sketchfab.token_type; $('sfDownloadable').checked = !!s.sketchfab.downloadable_only;
    $('sTimeout').value = s.net.timeout;
    $('sRememberKey').checked = !!s.ai.remember_key; $('sRememberSf').checked = !!s.sketchfab.remember_token;
    renderRoots();
  }
  function renderRoots() {
    var box = $('rootList'); box.replaceChildren();
    if (!S.settings.roots.length) { box.appendChild(el('p', 'Chưa có thư mục nào.', 'muted')); return; }
    S.settings.roots.forEach(function (r) {
      var row = el('div', null, 'item'); row.appendChild(el('span', r, 'p'));
      var st = S.rootsState && S.rootsState[r];
      if (st) row.appendChild(el('span', st === 'ok' ? 'Đã quét' : 'Không truy cập được', 'tag' + (st === 'ok' ? '' : ' off')));
      row.appendChild(btn('Xóa', function () { call('remove_root', r); }, 'small', 'Bỏ thư mục khỏi thư viện (không xóa file)'));
      box.appendChild(row);
    });
  }
  function renderSecrets(s) {
    S.secrets = s;
    function txt(x, what) {
      if (x.session) return '✓ Đã có ' + what + (x.stored ? ' (lưu mã hóa trên máy).' : ' trong phiên hiện tại.');
      if (x.env) return '✓ Dùng ' + what + ' từ biến môi trường.';
      return '✗ Chưa có ' + what + '.';
    }
    $('keyState').textContent = txt(s.openai, 'OpenAI API key');
    $('sfState').textContent = txt(s.sketchfab, 'Sketchfab token');
  }
  function renderSummary(sm) {
    if (!sm) return;
    if (sm.cancelled || sm.failed) return;
    if (sm.roots_state) { S.rootsState = sm.roots_state; renderRoots(); }
    $('scanSummary').textContent = 'Lần quét gần nhất: ' + sm.models + ' model, ' + sm.errors + ' lỗi, ' + sm.seconds + ' giây (đọc lại ' + sm.listed + ' thư mục, dùng cache ' + sm.reused + ').';
    var list = $('scanErrList'); list.replaceChildren();
    (sm.error_samples || []).forEach(function (e) { list.appendChild(el('div', e.path + ' — ' + e.msg)); });
    $('scanErrors').hidden = !(sm.error_samples && sm.error_samples.length);
  }
  function setNet(d) {
    var dot = $('netDot'); dot.className = 'dot ' + (d.state || '');
    var t = d.state === 'online' ? 'Đang trực tuyến' + (d.ms ? ' (' + d.ms + ' ms)' : '') : d.state === 'checking' ? 'Đang kiểm tra…' : 'Mất kết nối: ' + (d.msg || '');
    dot.title = 'Trạng thái mạng: ' + t; $('netText').textContent = t;
  }

  // ---------------------------------------------------------------- Nhận dữ liệu từ Ruby
  var handlers = {
    init: function (d) {
      S.version = d.version;
      $('verLabel').textContent = 'V' + d.version + ' · SketchUp ' + d.su;
      $('verInfo').textContent = 'Phiên bản ' + d.version + ' (' + d.build + ') · ID ' + d.plugin_id;
      $('dataRoot').textContent = d.data_root;
      renderLinkSources(d.sources); renderSecrets(d.secrets); S.rootsState = d.roots_state; applySettings(d.settings);
      $('rememberKeyWrap').hidden = $('rememberSfWrap').hidden = !d.secret_store;
      if (d.summary) renderSummary(d.summary);
      if (d.update_available) handlers.update_available(d.update_available);
      if (d.pending_restart) setStatus('Đã cài bản ' + d.pending_restart + ' — khởi động lại SketchUp để áp dụng.', 'ok');
      else if (d.settings_warning) setStatus(d.settings_warning, 'warn');
      else if (d.startup) setStatus(d.startup, 'ok');
      else setStatus(d.loaded ? 'Sẵn sàng.' : 'Đang nạp chỉ mục thư viện…');
      setTab(['offline', 'online', 'favorites', 'history', 'settings'].indexOf(d.settings.ui.tab) >= 0 ? d.settings.ui.tab : 'offline');
      if (d.scan && d.scan.running) handlers.scan_progress(d.scan);
    },
    status: function (d) { setStatus(d.msg, d.kind, d.hint); },
    settings: applySettings,
    secrets: renderSecrets,
    library: function (d) { setStatus('Đã nạp chỉ mục: ' + d.size + ' model. ' + (d.info || '')); },
    refresh: function () { search(); },
    results: renderResults,
    thumb: function (d) {
      S.thumbs.set(d.id, d.src);
      if (S.thumbs.size > 3000) { var k = S.thumbs.keys().next().value; S.thumbs.delete(k); }
      document.querySelectorAll('.pic[data-id="' + d.id + '"]').forEach(function (p) { paintThumb(p, d.src); });
    },
    fav: function (d) {
      document.querySelectorAll('[data-fav="' + d.id + '"]').forEach(function (b) { b.textContent = d.on ? '★' : '☆'; b.classList.toggle('on', d.on); });
      if (S.tab === 'favorites') search();
    },
    scan_progress: function (p) {
      $('scanBar').hidden = !p.running;
      $('scanText').textContent = 'Đang quét: ' + p.dirs + ' thư mục · ' + p.files + ' file SKP' + (p.errors ? ' · ' + p.errors + ' lỗi' : '') + ' — ' + (p.current || '');
    },
    scan_done: function (d) { $('scanBar').hidden = true; renderSummary(d); },
    inserted: function () { if (S.tab === 'history') search(); },
    confirm_newer: function (d) { S.newerId = d.id; $('newerText').textContent = '“' + d.name + '”: ' + d.msg; $('newerModal').hidden = false; },
    net: setNet,
    sf_loading: function (d) { if (d.seq === S.sf.seq) showSfMsg('Đang tìm trên Sketchfab…', 'info'); },
    sf_results: renderSf,
    sf_error: function (d) { if (d.seq === S.sf.seq) showSfMsg(d.msg, '', !!d.fallback); },
    dl_state: renderDl,
    dl_progress: function (d) { var st = S.dl.get(d.uid); if (st) { renderDl({ uid: d.uid, bytes: d.bytes, total: d.total || st.total }); } },
    ai_need_key: function () { closeAi(); setTab('settings'); $('sKey').focus(); },
    ai_preview: aiPreview,
    ai_state: function (d) { if (d.state === 'error') { aiDone(); $('aiState').textContent = '✗ ' + d.msg; } },
    ai_result: aiResult,
    ai_check: function (d) { $('aiCheck').textContent = d.state === 'checking' ? 'Đang kiểm tra…' : (d.state === 'ok' ? '✓ ' : '✗ ') + d.msg; },
    update_available: function (v) { var b = $('btnUpdate'); b.classList.add('has'); b.textContent = '⟳ CÓ BẢN ' + v; b.title = 'Có phiên bản mới ' + v + ' — bấm để xem và cập nhật'; },
    update_installed: function (v) { var b = $('btnUpdate'); b.classList.remove('has'); b.textContent = '⟳ CẬP NHẬT'; setStatus('Đã cài phiên bản ' + v + ' — khởi động lại SketchUp để áp dụng (hãy lưu bản vẽ trước).', 'ok'); }
  };
  window.MT = {
    receive: function (type, payload) {
      var h = handlers[type];
      if (!h) return;
      try { h(payload); } catch (e) { setStatus('Lỗi giao diện (' + type + '): ' + e.message, 'error'); }
    }
  };

  // ---------------------------------------------------------------- Sự kiện
  function bind() {
    document.querySelectorAll('#tabs [data-tab]').forEach(function (b) { b.addEventListener('click', function () { setTab(b.dataset.tab); }); });
    $('q').addEventListener('input', function () { if (S.anyOf) { S.anyOf = null; updateAiFilter(); } searchSoon(); });
    $('q').addEventListener('keydown', function (e) {
      if (e.key === 'Enter') { if (S.tab === 'online') sfSearch(null); else { clearTimeout(S.debounce); S.page = 0; search(); } }
      if (e.key === 'Escape') { $('q').value = ''; searchSoon(); }
    });
    ['fRoot', 'fSize', 'fSort'].forEach(function (id) { $(id).addEventListener('change', function () { S.page = 0; search(); }); });
    $('fSort').addEventListener('change', function () { saveSettings({ ui: { sort: $('fSort').value } }); });
    $('fSize').addEventListener('change', function () { saveSettings({ ui: { size_max_mb: Number($('fSize').value) } }); });
    $('pFirst').onclick = function () { S.page = 0; search(); };
    $('pPrev').onclick = function () { S.page = Math.max(0, S.page - 1); search(); };
    $('pNext').onclick = function () { S.page = Math.min(S.pages - 1, S.page + 1); search(); };
    $('pLast').onclick = function () { S.page = S.pages - 1; search(); };
    ['btnAddRoot', 'btnAddRoot2'].forEach(function (id) { $(id).onclick = function () { call('add_root'); }; });
    $('btnScan').onclick = $('btnScanQuick').onclick = function () { call('scan', 'quick'); };
    $('btnScanFull').onclick = function () { call('scan', 'full'); };
    $('btnCancelScan').onclick = function () { call('cancel_scan'); };
    $('btnImportSkp').onclick = $('btnImportSkp2').onclick = function () { call('import_skp'); };
    $('btnImport3d').onclick = function () { call('import_3d'); };
    $('btnUpdate').onclick = $('btnUpdate2').onclick = function () { call('open_updater'); };
    $('btnSfSearch').onclick = function () { sfSearch(null); };
    $('sfNext').onclick = function () { if (S.sf.next) sfSearch(S.sf.next); };
    $('sfPrev').onclick = function () { if (S.sf.stack.length) { var c = S.sf.stack.pop(); sfSearch(c, true); } };
    $('sfDownloadable').onchange = function () { saveSettings({ sketchfab: { downloadable_only: $('sfDownloadable').checked } }); };
    // AI
    $('btnAi').onclick = function () { openAi(); if (!S.ai.src) call('ai_pick'); };
    $('aiPick').onclick = function () { call('ai_pick'); };
    $('aiSend').onclick = aiSend;
    $('aiCancel').onclick = function () { call('ai_cancel'); aiDone(); $('aiState').textContent = 'Đã hủy.'; };
    $('aiClose').onclick = closeAi;
    $('rVi').addEventListener('input', renderChips); $('rEn').addEventListener('input', renderChips);
    $('rOffline').onclick = function () { S.anyOf = allQueries(); $('q').value = ''; updateAiFilter(); closeAi(); setTab('offline'); };
    $('rSketchfab').onclick = function () { var q = lines('rEn')[0] || $('rType').value; if (!q) return; $('q').value = q; closeAi(); setTab('online'); sfSearch(null); };
    $('rWarehouse').onclick = function () { var q = lines('rEn')[0] || $('rType').value; if (q) call('online_link', 'warehouse', q); };
    $('aiFilterClear').onclick = function () { S.anyOf = null; updateAiFilter(); S.page = 0; search(); };
    document.querySelectorAll('[data-close]').forEach(function (b) { b.addEventListener('click', function () { $(b.dataset.close).hidden = true; }); });
    $('newerYes').onclick = function () { $('newerModal').hidden = true; if (S.newerId) call('insert', S.newerId, true); };
    // Cài đặt
    $('sQuick').onchange = function () { saveSettings({ quick_scan: $('sQuick').checked }); };
    $('sScanOpen').onchange = function () { saveSettings({ scan_on_open: $('sScanOpen').checked }); };
    $('sPage').onchange = function () { var n = Number($('sPage').value); saveSettings({ ui: { page_size: n } }); S.settings.ui.page_size = n; S.page = 0; search(); };
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
    $('btnClearThumbs').onclick = function () { S.thumbs.clear(); call('clear_thumbs'); };
    document.addEventListener('keydown', function (e) { if (e.key === 'Escape') { closeAi(); $('newerModal').hidden = true; } });
  }

  function start() {
    bind();
    if (!call('ready')) setStatus('Giao diện chạy ngoài SketchUp (không có cầu nối sketchup).', 'warn');
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start); else start();
})();
