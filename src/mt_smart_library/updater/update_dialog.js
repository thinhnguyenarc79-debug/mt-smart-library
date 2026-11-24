/* MT SMART UPDATE SYSTEM — giao diện. Dữ liệu hiển thị qua textContent. */
(function () {
  'use strict';
  var $ = function (id) { return document.getElementById(id); };
  var U = { busy: false, confirmFn: null, cur: '' };
  function call(name) {
    var a = Array.prototype.slice.call(arguments, 1);
    if (window.sketchup && typeof window.sketchup[name] === 'function') { window.sketchup[name].apply(window.sketchup, a); return true; }
    if (window.MT_DEV_BRIDGE) { window.MT_DEV_BRIDGE(name, a); return true; }
    return false;
  }
  function el(t, txt, cls) { var e = document.createElement(t); if (txt !== undefined && txt !== null) e.textContent = String(txt); if (cls) e.className = cls; return e; }
  function size(b) { b = Number(b) || 0; return b >= 1048576 ? (b / 1048576).toFixed(2) + ' MB' : (b / 1024).toFixed(0) + ' KB'; }
  function list(ul, items) { ul.replaceChildren(); (items && items.length ? items : ['(không có mô tả)']).forEach(function (x) { ul.appendChild(el('li', x)); }); }
  function rel(r) { return r === 'newer' ? 'Mới hơn — sẵn sàng cập nhật' : r === 'same' ? 'Cùng phiên bản (cài lại)' : 'CŨ HƠN — sẽ hạ cấp'; }
  function setBusy(b) { U.busy = b; ['pick', 'install', 'check', 'installOnline'].forEach(function (id) { $(id).disabled = b; }); document.querySelectorAll('[data-restore]').forEach(function (x) { x.disabled = b; }); }
  function confirmBox(title, text, fn) { $('cTitle').textContent = title; $('cText').textContent = text; U.confirmFn = fn; $('confirmModal').hidden = false; }

  function renderSteps(p) {
    $('progressPanel').hidden = false;
    var ul = $('steps'); ul.replaceChildren();
    (p.steps || []).forEach(function (s, i) {
      var cls = i < p.step ? 'done' : i === p.step ? (p.status === 'failed' ? 'fail' : p.status === 'done' ? 'done' : 'cur') : '';
      ul.appendChild(el('li', (i < p.step || (i === p.step && p.status === 'done') ? '✓ ' : i === p.step && p.status === 'failed' ? '✗ ' : '• ') + s, cls));
    });
  }
  function result(kind, lines) {
    var r = $('result'); r.hidden = false; r.className = 'result ' + kind; r.replaceChildren();
    lines.filter(Boolean).forEach(function (t, i) { if (i) r.appendChild(el('br')); r.appendChild(document.createTextNode(t)); });
  }
  function renderBackups(bs) {
    var tb = $('backups'); tb.replaceChildren();
    if (!bs || !bs.length) { var tr = el('tr'); var td = el('td', 'Chưa có bản sao lưu.'); td.colSpan = 4; tr.appendChild(td); tb.appendChild(tr); return; }
    bs.forEach(function (b) {
      var tr = el('tr');
      tr.appendChild(el('td', b.version)); tr.appendChild(el('td', b.created_at)); tr.appendChild(el('td', b.reason || ''));
      var td = el('td'); var bt = el('button', 'Khôi phục'); bt.dataset.restore = b.id;
      bt.onclick = function () { confirmBox('Khôi phục phiên bản ' + b.version, 'Bản đang dùng (' + U.cur + ') sẽ được sao lưu trước, sau đó cài lại phiên bản ' + b.version + ' (sao lưu lúc ' + b.created_at + '). Dữ liệu người dùng giữ nguyên. Tiếp tục?', function () { call('up_restore', b.id); }); };
      td.appendChild(bt); tr.appendChild(td); tb.appendChild(tr);
    });
  }
  function renderHistory(h) {
    var tb = $('history'); tb.replaceChildren();
    if (!h || !h.length) { var tr = el('tr'); var td = el('td', 'Chưa có thao tác cập nhật.'); td.colSpan = 4; tr.appendChild(td); tb.appendChild(tr); return; }
    h.forEach(function (x) {
      var tr = el('tr');
      tr.appendChild(el('td', x.at)); tr.appendChild(el('td', x.reason)); tr.appendChild(el('td', (x.from || '?') + ' → ' + (x.to || '?')));
      var r = el('td', x.status === 'ok' ? '✓ Thành công' : '✗ Lỗi: ' + (x.error || '')); r.style.color = x.status === 'ok' ? 'var(--ok)' : 'var(--err)';
      tr.appendChild(r); tb.appendChild(tr);
    });
  }
  function srcUi() { var s = $('src').value; $('srcUrl').hidden = s !== 'manifest'; $('srcRepo').hidden = s !== 'github'; }

  var H = {
    init: function (d) {
      U.cur = d.version; $('curVer').textContent = 'V' + d.version;
      $('envInfo').textContent = 'SketchUp ' + d.su + ' · Ruby ' + d.ruby;
      $('plugRoot').textContent = d.plugins_root; $('dataRoot').textContent = d.data_root;
      $('src').value = d.source.source; $('srcUrl').value = d.source.manifest_url; $('srcRepo').value = d.source.github_repo; $('srcAuto').checked = !!d.source.check_on_start; srcUi();
      renderBackups(d.backups); renderHistory(d.history);
      if (d.pending_restart) { var b = $('banner'); b.hidden = false; b.textContent = 'Đã cài phiên bản ' + d.pending_restart + '. Hãy LƯU bản vẽ rồi khởi động lại SketchUp để áp dụng. SketchUp hiện vẫn chạy bản ' + d.version + '.'; }
      else if (d.startup) { var b2 = $('banner'); b2.hidden = false; b2.className = 'result ok'; b2.textContent = d.startup; }
      if (d.online) H.up_online(d.online);
      setBusy(!!d.busy);
    },
    up_package: function (p) {
      $('pkgErr').hidden = true; $('pkg').hidden = false;
      $('pVer').textContent = p.version; $('pRel').textContent = rel(p.relation);
      $('pCompat').textContent = (p.compatible ? '✓ ' : '✗ ') + p.compat_message; $('pCompat').style.color = p.compatible ? 'var(--ok)' : 'var(--err)';
      $('pId').textContent = p.plugin_id; $('pFiles').textContent = p.files + ' file · ' + size(p.bytes); $('pSha').textContent = p.sha256;
      list($('pLog'), p.changelog);
      $('install').disabled = !p.compatible || U.busy;
      $('install').textContent = p.relation === 'newer' ? 'Sao lưu & cài đặt phiên bản ' + p.version : 'Sao lưu & cài lại/hạ cấp về ' + p.version;
    },
    up_package_error: function (m) { $('pkg').hidden = true; var e = $('pkgErr'); e.hidden = false; e.textContent = '✗ ' + m; },
    up_confirm_downgrade: function (p) {
      confirmBox('Cài phiên bản không mới hơn', 'Gói là phiên bản ' + p.version + ' trong khi đang dùng ' + U.cur + '. Bản hiện tại vẫn được sao lưu để có thể khôi phục. Tiếp tục cài?', function () { call('up_install', true); });
    },
    up_started: function (d) { setBusy(true); $('progressPanel').hidden = false; $('result').hidden = true; renderSteps({ steps: ['Kiểm tra gói', 'Sao lưu bản hiện tại', 'Giải nén', 'Cài đặt', 'Kiểm tra sau cài', 'Hoàn tất'], step: 0, status: 'running' }); },
    up_progress: function (d) {
      if (d.progress) renderSteps(d.progress);
      if (d.download) { $('dlBar').hidden = false; var pct = d.download.total ? Math.round(d.download.bytes * 100 / d.download.total) : 0; $('dlFill').style.width = pct + '%'; $('dlText').textContent = 'Đã tải ' + size(d.download.bytes) + (d.download.total ? ' / ' + size(d.download.total) + ' (' + pct + '%)' : ''); }
      else $('dlBar').hidden = true;
    },
    up_downloading: function (d) { setBusy(true); $('progressPanel').hidden = false; $('result').hidden = true; $('dlBar').hidden = false; $('dlText').textContent = 'Đang tải phiên bản ' + d.version + '…'; },
    up_done: function (d) {
      setBusy(false); if (d.progress) renderSteps(d.progress); $('dlBar').hidden = true;
      result('ok', ['✓ Đã cài đặt thành công phiên bản ' + d.version + ' (bản sao lưu: ' + d.backup + ').',
        'Phiên SketchUp hiện tại vẫn chạy bản ' + U.cur + ' — bản mới có hiệu lực sau khi khởi động lại SketchUp.',
        d.model_modified ? '⚠ Bản vẽ hiện tại CHƯA LƯU. Hãy lưu bản vẽ trước, sau đó tự đóng và mở lại SketchUp. Plugin sẽ không tự khởi động lại.' : 'Bạn có thể đóng và mở lại SketchUp khi thuận tiện.',
        'Dữ liệu thư viện, yêu thích, lịch sử, cài đặt được giữ nguyên.']);
      var b = $('banner'); b.hidden = false; b.className = 'result warn'; b.textContent = 'Đã cài phiên bản ' + d.version + ' — cần khởi động lại SketchUp để áp dụng.';
      renderBackups(d.backups); renderHistory(d.history); $('pkg').hidden = true;
    },
    up_failed: function (d) {
      setBusy(false); if (d.progress) renderSteps(d.progress); $('dlBar').hidden = true;
      result('err', ['✗ Cập nhật thất bại: ' + d.error, d.rollback || 'Lỗi xảy ra trước khi thay đổi file — phiên bản hiện tại không bị ảnh hưởng.', 'Xem chi tiết trong nhật ký cập nhật (update.log).']);
      renderHistory(d.history);
    },
    up_error: function (m) { setBusy(false); $('progressPanel').hidden = false; result('err', ['✗ ' + m]); },
    up_online_state: function (d) { $('onState').textContent = d.state === 'checking' ? 'Đang kiểm tra…' : '✗ ' + d.msg; $('onState').style.color = d.state === 'error' ? 'var(--err)' : ''; },
    up_online: function (m) {
      $('onState').style.color = '';
      $('onState').textContent = m.relation === 'newer' ? '✓ Có phiên bản mới ' + m.version : 'Bạn đang dùng phiên bản mới nhất (' + m.current + ').';
      $('online').hidden = false; $('oVer').textContent = m.version; $('oDate').textContent = m.released_at || '—';
      $('oCompat').textContent = (m.compatible ? '✓ ' : '✗ ') + m.compat_message; $('oSize').textContent = m.size ? size(m.size) : '—';
      list($('oLog'), m.changelog);
      $('installOnline').disabled = !(m.relation === 'newer' && m.compatible) || U.busy;
    },
    up_source_saved: function (s) { if (s) { $('src').value = s.source; $('srcUrl').value = s.manifest_url; $('srcRepo').value = s.github_repo; $('srcAuto').checked = !!s.check_on_start; srcUi(); } $('onState').style.color = ''; $('onState').textContent = (s && s.source === 'none') ? 'Đã lưu: chưa có nguồn hợp lệ (URL phải là https, repo dạng chu-so-huu/ten-repo).' : 'Đã lưu nguồn cập nhật.'; }
  };
  window.UP = { receive: function (t, p) { var h = H[t]; if (!h) return; try { h(p); } catch (e) { result('err', ['Lỗi giao diện: ' + e.message]); } } };

  function bind() {
    $('pick').onclick = function () { call('up_pick_file'); };
    $('install').onclick = function () { confirmBox('Cài đặt bản cập nhật', 'Plugin sẽ sao lưu phiên bản ' + U.cur + ', cài đè phiên bản mới và kiểm tra lại. Nếu có lỗi sẽ tự khôi phục. Dữ liệu người dùng giữ nguyên. Tiếp tục?', function () { call('up_install', false); }); };
    $('check').onclick = function () { call('up_check_online'); };
    $('installOnline').onclick = function () { confirmBox('Cập nhật online', 'Tải gói từ nguồn đã cấu hình, kiểm tra SHA256, sao lưu bản hiện tại rồi cài đặt. Tiếp tục?', function () { call('up_install_online'); }); };
    $('src').onchange = srcUi;
    $('saveSrc').onclick = function () { call('up_save_source', JSON.stringify({ source: $('src').value, manifest_url: $('srcUrl').value.trim(), github_repo: $('srcRepo').value.trim(), check_on_start: $('srcAuto').checked })); };
    $('openBackups').onclick = function () { call('up_open_backups'); };
    $('openLog').onclick = function () { call('up_open_log'); };
    $('cYes').onclick = function () { $('confirmModal').hidden = true; var f = U.confirmFn; U.confirmFn = null; if (f) f(); };
    $('cNo').onclick = function () { $('confirmModal').hidden = true; U.confirmFn = null; };
  }
  function start() { bind(); call('up_ready'); }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start); else start();
})();
