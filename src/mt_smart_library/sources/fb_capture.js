/* MT SMART LIBRARY PRO — thanh “Lưu bài đang hiển thị” gắn vào trang nhóm Facebook trong cửa sổ plugin.
   Chỉ chạy khi NGƯỜI DÙNG bấm nút; chỉ đọc các bài ĐANG HIỂN THỊ (đã tải trên màn hình): nội dung bài, ảnh, link bài, link tải.
   Không tự cuộn, không tự mở trang, không đọc cookie/mật khẩu, không gửi dữ liệu đi đâu ngoài plugin trên máy. */
(function () {
  if (!/(^|\.)facebook\.com$/.test(location.hostname)) return;
  if (window.__mtfb) { window.__mtfb.ensure(); return; }
  var M = window.__mtfb = {}, st = null, lastTitle = '';
  function txt(e) { return (e && (e.innerText || e.textContent) || '').trim(); }
  function groupSlug() { var m = /^\/groups\/([^/]+)/.exec(location.pathname); return m ? m[1] : ''; }
  // Tên nhóm: tiêu đề tab (“Tên nhóm | Facebook”) — đúng cả ở trang tìm kiếm trong nhóm; dự phòng: tiêu đề h1.
  function groupName() {
    var t = document.title.replace(/^\(\d+\)\s*/, '');
    if (/\s[|\-–]\s*Facebook\s*$/i.test(t)) t = t.replace(/\s*[|\-–]\s*Facebook\s*$/i, '');
    else t = txt(document.querySelector('div[role="main"] h1') || document.querySelector('h1'));
    return /^(facebook|kết quả tìm kiếm|search results)$/i.test(t) ? '' : t.slice(0, 120);
  }
  function realLink(h) {
    try {
      var u = new URL(h, location.href);
      if (/(^|\.)l\.facebook\.com$/.test(u.hostname) || u.pathname === '/l.php') return u.searchParams.get('u') || '';
      return u.href;
    } catch (e) { return ''; }
  }
  // Bài viết đang hiển thị: con trực tiếp của luồng bài (div[role=feed]); trang một bài → khối bài chính.
  function postNodes() {
    var feed = document.querySelector('div[role="feed"]'), list = [];
    if (feed) list = [].slice.call(feed.children).filter(function (c) { return c.offsetHeight > 100; });
    if (!list.length) {
      list = [].slice.call(document.querySelectorAll('div[role="article"]')).filter(function (a) {
        return !(a.parentElement && a.parentElement.closest('div[role="article"]'));
      });
    }
    return list;
  }
  // Link bài: /posts/ID, /permalink/ID, story_fbid; ảnh của bài (set=pcb.ID / gm.ID); reel.
  function postUrl(c) {
    var as = c.querySelectorAll('a[href]'), slug = groupSlug(), reel = '';
    for (var j = 0; j < as.length; j++) {
      var h = as[j].getAttribute('href') || '';
      if (/\/(posts|permalink)\/\d+|story_fbid=/.test(h)) {
        var u = realLink(h);
        if (/story_fbid=/.test(u)) { try { var q = new URL(u); return 'https://www.facebook.com/' + (slug ? 'groups/' + slug + '/posts/' : 'permalink.php?story_fbid=') + q.searchParams.get('story_fbid') + (slug ? '/' : ''); } catch (e) {} }
        return u.split('?')[0];
      }
      var m = /[?&]set=(?:pcb|gm)\.(\d+)/.exec(h);
      if (m && slug) return 'https://www.facebook.com/groups/' + slug + '/posts/' + m[1] + '/';
      var r = /^(?:https:\/\/www\.facebook\.com)?\/reel\/(\d+)/.exec(h);
      if (r && !reel) reel = 'https://www.facebook.com/reel/' + r[1] + '/';
    }
    return reel;
  }
  function hash(s) { var h = 5381; for (var i = 0; i < s.length; i++) h = ((h << 5) + h + s.charCodeAt(i)) | 0; return (h >>> 0).toString(36); }
  function collect() {
    var out = [], seen = {}, nodes = postNodes();
    for (var i = 0; i < nodes.length; i++) {
      var c = nodes[i];
      var msg = c.querySelector('[data-ad-rendering-role="story_message"], [data-ad-preview="message"], [data-ad-comet-preview="message"]');
      var text = txt(msg).slice(0, 4000);
      var imgs = [], im = c.querySelectorAll('img');
      for (var k = 0; k < im.length && imgs.length < 6; k++) {
        var s = im[k].currentSrc || im[k].src || '';
        if (/^https:\/\/[^/]*fbcdn\.net\//.test(s) && (im[k].naturalWidth || 0) >= 160 && imgs.indexOf(s) < 0) imgs.push(s);
      }
      if (!text && !imgs.length) continue; // khung bài chưa tải nội dung
      var links = [], as = c.querySelectorAll('a[href]'); // cả bình luận đang hiển thị (“link ở bình luận”); plugin chỉ giữ link tải hợp lệ
      for (var j = 0; j < as.length; j++) {
        var r = realLink(as[j].getAttribute('href') || '');
        if (/^https:\/\//.test(r) && !/(^|\.)(facebook|fb|instagram|messenger)\.com\//.test(r.replace(/^https:\/\//, '').split('?')[0] + '/') && links.indexOf(r) < 0) links.push(r);
      }
      var url = postUrl(c) || (location.origin + location.pathname + '#mt-' + hash(text + imgs.join('')));
      if (seen[url]) continue;
      seen[url] = 1;
      out.push({ url: url, text: text, images: imgs, links: links.slice(0, 20) });
    }
    return out;
  }
  M.collect = collect;
  M.groupName = groupName;
  function bar() {
    var d = document.createElement('div');
    d.id = 'mtfb-bar';
    d.style.cssText = 'position:fixed;right:16px;bottom:16px;z-index:2147483647;background:#1f3a2e;color:#fff;font:13px Segoe UI,Arial;' +
      'padding:8px 10px;border-radius:8px;box-shadow:0 4px 16px rgba(0,0,0,.35);max-width:360px';
    var b = document.createElement('button');
    b.textContent = 'MT: Lưu bài đang hiển thị';
    b.style.cssText = 'background:#c9a14a;color:#1f1f1f;border:0;border-radius:6px;padding:6px 10px;font-weight:600;cursor:pointer';
    st = document.createElement('div');
    st.style.cssText = 'margin-top:6px;font-size:12px;opacity:.9';
    st.textContent = 'Đăng nhập (nếu cần), cuộn xem bài, mở “Xem thêm”, rồi bấm lưu.';
    b.onclick = function () {
      var posts = collect();
      if (typeof sketchup === 'undefined' || !sketchup.mt_fb_capture) { st.textContent = 'Không kết nối được plugin.'; return; }
      st.textContent = 'Đang gửi ' + posts.length + ' bài cho plugin…';
      sketchup.mt_fb_capture(JSON.stringify({ group: groupName(), posts: posts }));
    };
    d.appendChild(b); d.appendChild(st);
    document.body.appendChild(d);
  }
  M.notify = function (m) { if (st) st.textContent = m; };
  M.ensure = function () {
    if (!document.getElementById('mtfb-bar') && document.body && typeof sketchup !== 'undefined') bar();
    var t = groupName();
    if (t && t !== lastTitle && /\/groups\//.test(location.pathname) && typeof sketchup !== 'undefined' && sketchup.mt_fb_title) {
      lastTitle = t; sketchup.mt_fb_title(t);
    }
  };
  M.ensure();
})();
