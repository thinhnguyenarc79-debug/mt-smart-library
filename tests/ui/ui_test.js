// V1.0.2 — Kiểm thử giao diện tìm kiếm tổng hợp trên Chrome headless (file://, CSP thật, cầu nối sketchup giả lập).
const { chromium } = require('/opt/npm-tools/node_modules/playwright');
const path = require('path');
const SRC = path.resolve(__dirname, '../../src/mt_smart_library');
const OUT = process.argv[2] || '/tmp';
const R = [];
const check = (n, ok, d) => R.push({ n, ok: !!ok, d });
const PNG = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';
const SETTINGS = { roots: ['D:/Thư viện 3D'], favorites: [], history: [], quick_scan: true, scan_on_open: true, auto_save_downloads: true,
  ui: { page_size: 48, sort: 'relevance', size_max_mb: 0, tab: 'offline', thumb_size: 200, filter: 'all', category: 'all' },
  ai: { model: 'gpt-6-luna', base_url: 'https://api.openai.com/v1', detail: 'low', remember_key: false },
  sketchfab: { downloadable_only: true, token_type: 'token', remember_token: false }, net: { timeout: 30 }, sources: { sketchfab: true },
  update: { source: 'manifest', manifest_url: '', github_repo: '', check_on_start: false }, categories_custom: [], online_favorites: [] };
const CATS = [['all', 'Tất cả', '▦'], ['sofa', 'Sofa', '🛋'], ['chair', 'Ghế', '🪑'], ['table', 'Bàn', '◧'], ['storage', 'Tủ kệ', '▤'], ['bed', 'Giường', '🛏'],
  ['lighting', 'Đèn', '💡'], ['plant', 'Cây xanh', '🌿'], ['kitchen', 'Đồ bếp', '🍳'], ['bath', 'Thiết bị vệ sinh', '🚿'], ['curtain', 'Rèm cửa', '🪟'],
  ['decor', 'Trang trí', '🖼'], ['exterior', 'Ngoại thất', '🏡']].map(([id, name, icon]) => ({ id, name, icon }))
  .concat([{ id: 'c_abcd1234', name: 'Bàn trang điểm', custom: true, keywords: ['vanity'], icon: '◆' },
    { id: 'personal', name: 'Thư viện cá nhân', kind: 'local', icon: '💻' }, { id: 'favorites', name: 'Yêu thích', kind: 'favorites', icon: '♥' }, { id: 'history', name: 'Lịch sử', kind: 'history', icon: '🕘' }]);
function items() {
  const L = (i, name) => ({ key: 'local:' + String(i).repeat(64).slice(0, 64), source: 'local', source_label: 'Máy tính', id: String(i).repeat(64).slice(0, 64),
    title: name, path: 'D:/Thư viện 3D/Sofa/' + name + '.skp', folder: 'Sofa', size: 2345678, mtime: 1732400000, insertable: true, downloadable: true, free: true, format: 'skp', fav: i === 1, score: 90 - i });
  const O = (i, name, dl) => ({ key: 'sketchfab:' + String(i).repeat(32), source: 'sketchfab', source_label: 'Sketchfab', uid: String(i).repeat(32), title: name,
    thumb: i === 7 ? 'https://evil.example/x.jpg' : 'https://media.sketchfab.com/m/' + i + '.jpg', thumb_large: 'https://media.sketchfab.com/m/' + i + 'L.jpg',
    author: 'Studio ' + i, license: 'CC Attribution', url: 'https://sketchfab.com/3d-models/x-' + i, downloadable: dl, free: dl, insertable: false,
    format: 'gltf', formats: [{ type: 'gltf', size: 3000000 }], faces: 45000, fav: false, score: 60 - i });
  return [L(1, '<img src=x onerror="window.pwned=1"> Ghế sofa vải xám'), L(2, 'Sofa góc chữ L gỗ óc chó rất dài tên model để kiểm tra cắt ngắn hiển thị trên thẻ'),
    O(5, 'Modern Sofa', true), O(6, 'Velvet couch <b>x</b>', false), O(7, 'Evil thumb sofa', true), L(3, 'Sofa đơn')];
}
(async () => {
  const browser = await chromium.launch({ executablePath: '/usr/bin/google-chrome', args: ['--allow-file-access-from-files'] });
  const page = await browser.newPage({ viewport: { width: 1280, height: 820 } });
  const errors = [];
  page.on('pageerror', e => errors.push('pageerror: ' + e.message));
  page.on('console', m => { if (m.type() === 'error' && !/media\.sketchfab|evil\.example|ERR_/.test(m.text())) errors.push('console: ' + m.text()); });
  await page.route('https://media.sketchfab.com/**', r => r.fulfill({ status: 200, contentType: 'image/png', body: Buffer.from(PNG.split(',')[1], 'base64') }));
  await page.addInitScript(() => { window.__calls = []; window.MT_DEV_BRIDGE = (n, a) => window.__calls.push([n, a]); });
  await page.goto('file://' + SRC + '/ui/index.html');
  await page.waitForFunction(() => window.MT && window.__calls.some(c => c[0] === 'ready'));
  await page.evaluate(([s, cats]) => MT.receive('init', { version: '1.0.2', plugin_id: 'mtdesign.smart_library_pro', build: '2026-11-24', su: '22.0.354', settings: s,
    secrets: { openai: { session: true }, sketchfab: {} }, data_root: 'C:/Users/Thinh/AppData/Local/MT_Smart_Library', secret_store: true, roots_state: { 'D:/Thư viện 3D': 'ok' },
    loaded: true, library_size: 3, scan: { running: false }, categories: cats,
    sources_status: [{ id: 'local', name: 'Máy tính', integrated: true, enabled: true, note: '1 thư mục' }, { id: 'sketchfab', name: 'Sketchfab', integrated: true, enabled: true, note: 'API chính thức' },
      { id: 'warehouse', name: '3D Warehouse', integrated: false, enabled: false, note: 'Chưa có API công khai' }],
    src: { types: { website: 'Website' }, list: [{ id: 'sketchfab', name: 'Sketchfab', builtin: true, integrated: true, enabled: true, url: 'https://sketchfab.com' },
      { id: 'warehouse', name: '3D Warehouse', builtin: true, integrated: false, enabled: false, note: 'Chưa có API công khai', url: 'https://3dwarehouse.sketchup.com' }] } }), [SETTINGS, CATS]);
  const starts = () => page.evaluate(() => window.__calls.filter(c => c[0] === 'sr_start').map(c => JSON.parse(c[1][0])));
  check('Khởi động tự tìm (1 lần)', (await starts()).length === 1);
  check('Thanh danh mục đủ 13 mặc định + tùy chỉnh + 3 mục cá nhân', (await page.locator('#cats .cat').count()) === 17);

  // Gõ từ khóa -> 1 lần tìm sau debounce
  await page.click('#q'); await page.keyboard.type('ghế sofa', { delay: 15 });
  await page.waitForTimeout(500);
  let st = await starts();
  check('Gõ từ khóa: chỉ 1 lần tìm sau debounce', st.length === 2 && st[1].q === 'ghế sofa' && st[1].category === 'all', st.map(x => x.q));
  const sid = st[1].sid;
  // Đợt 1: chỉ máy tính, còn đang tải online
  const all = items();
  await page.evaluate(([sid, it]) => {
    MT.receive('sr_begin', { sid, expansions: ['sofa', 'couch', 'modern sofa', 'living room sofa'] });
    MT.receive('sr_update', { sid, items: it.filter(x => x.source === 'local'), counts: { all: 3, local: 3, online: 0, insertable: 3, free: 3 }, filter: 'all', loading: true, has_more: false,
      sources: [{ id: 'local', label: 'Máy tính', state: 'done', count: 3 }, { id: 'sketchfab', label: 'Sketchfab', state: 'loading', count: 0 }], hidden: 0 });
    MT.receive('thumb', { id: '1'.repeat(64), src: 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==' });
  }, [sid, all]);
  const firstCard = await page.evaluate(() => document.querySelector('#grid .card'));
  check('Đợt 1 hiển thị ngay kết quả máy tính', (await page.locator('#grid .card').count()) === 3);
  check('Đang tải online hiển thị trạng thái', await page.isVisible('#loading'));
  await page.evaluate(() => { window.__firstCard = document.querySelector('#grid .card'); });
  // Đợt 2: thêm online, xếp lại
  await page.evaluate(([sid, it]) => MT.receive('sr_update', { sid, items: it, counts: { all: 6, local: 3, online: 3, insertable: 3, free: 5 }, filter: 'all', loading: false, has_more: false,
    sources: [{ id: 'local', label: 'Máy tính', state: 'done', count: 3 }, { id: 'sketchfab', label: 'Sketchfab', state: 'done', count: 3 }], hidden: 4 }), [sid, all]);
  await page.waitForTimeout(250);
  const r = await page.evaluate(() => ({
    cards: document.querySelectorAll('#grid .card').length,
    reused: window.__firstCard === document.querySelector('#grid .card'),
    pwned: window.pwned, imgInTitle: document.querySelectorAll('#grid .title img, #grid .title b').length,
    evilImg: [...document.querySelectorAll('#grid img')].filter(i => /evil/.test(i.src)).length,
    longTitle: document.querySelectorAll('#grid .title')[1].textContent,
    siteNames: [...document.querySelectorAll('#grid .card')].filter(c => /sketchfab|warehouse|cgtrader/i.test(c.textContent)).length,
    faces: [...document.querySelectorAll('#grid .card')].filter(c => /mặt|faces|GLTF|gltf|\d MB|\d KB/.test(c.textContent)).length,
    insLabels: [...document.querySelectorAll('#grid .ins')].map(b => b.textContent),
    counts: [...document.querySelectorAll('#filters i')].map(i => i.textContent).join(','),
    info: document.getElementById('resInfo').textContent
  }));
  check('Đợt 2 gộp vào cùng lưới (6 model)', r.cards === 6, r.cards);
  check('Giữ nguyên thẻ cũ (không vẽ lại ảnh)', r.reused);
  check('Tên file độc hại hiển thị dạng chữ', !r.pwned && r.imgInTitle === 0);
  check('Chặn ảnh từ host lạ', r.evilImg === 0);
  check('Tên dài được rút gọn', r.longTitle.endsWith('…') && r.longTitle.length <= 60, r.longTitle);
  check('Thẻ không hiện tên website / số mặt / định dạng / dung lượng', r.siteNames === 0 && r.faces === 0, r);
  check('Nút CHÈN / XEM đúng theo khả năng chèn', JSON.stringify(r.insLabels) === JSON.stringify(['CHÈN', 'CHÈN', 'CHÈN', 'XEM', 'CHÈN', 'CHÈN']), r.insLabels);
  check('Số lượng trên bộ lọc', r.counts === '6,3,3,3,5', r.counts);
  check('Thông tin mở rộng từ khóa', /couch/.test(r.info), r.info);
  await page.screenshot({ path: OUT + '/v102_grid.png' });

  // Kết quả cũ (sid khác) bị bỏ qua
  await page.evaluate(([sid]) => MT.receive('sr_update', { sid: sid - 1, items: [], counts: { all: 0 }, filter: 'all', loading: false, has_more: false, sources: [], hidden: 0 }), [sid]);
  check('Bỏ qua kết quả truy vấn cũ', (await page.locator('#grid .card').count()) === 6);

  // Bộ lọc
  await page.click('#filters [data-f="insertable"]');
  const fcall = await page.evaluate(() => window.__calls.filter(c => c[0] === 'sr_filter').pop()[1]);
  check('Bấm bộ lọc gửi sr_filter (không tìm lại)', fcall[1] === 'insertable' && (await starts()).length === 2, fcall);

  // Kích thước ảnh
  await page.evaluate(() => { const r = document.getElementById('thumbSize'); r.value = 300; r.dispatchEvent(new Event('input')); r.dispatchEvent(new Event('change')); });
  const w = await page.evaluate(() => document.querySelector('#grid .card').getBoundingClientRect().width);
  check('Thanh trượt đổi kích thước thumbnail', w >= 295, w);
  await page.screenshot({ path: OUT + '/v102_grid_large.png' });
  await page.evaluate(() => { const r = document.getElementById('thumbSize'); r.value = 200; r.dispatchEvent(new Event('input')); });

  // Chi tiết: click ảnh -> mở chi tiết, có thông tin nguồn/tác giả/giấy phép
  await page.click('#grid .card:nth-child(3) .thumb img');
  const det = await page.evaluate(() => ({ open: !document.getElementById('detailModal').hidden, title: document.getElementById('dTitle').textContent,
    meta: document.getElementById('dMeta').textContent, attr: document.getElementById('dAttrText').textContent, btn: document.getElementById('dInsert').textContent,
    img: document.querySelector('#dImg img') && document.querySelector('#dImg img').src }));
  check('Click ảnh mở chi tiết', det.open && det.title === 'Modern Sofa');
  check('Chi tiết có nguồn, tác giả, giấy phép, định dạng', /Sketchfab/.test(det.meta) && /Studio 5/.test(det.meta) && /CC Attribution/.test(det.meta) && /GLTF/.test(det.meta), det.meta);
  check('Ghi công theo giấy phép', /Studio 5/.test(det.attr) && /CC Attribution/.test(det.attr));
  check('Ảnh lớn trong chi tiết', /5L\.jpg/.test(det.img || ''), det.img);
  await page.screenshot({ path: OUT + '/v102_detail.png' });
  await page.click('#dInsert');
  check('CHÈN trong chi tiết gửi insert_item', await page.evaluate(() => window.__calls.some(c => c[0] === 'insert_item' && c[1][0] === 'sketchfab:' + '5'.repeat(32))));
  await page.evaluate(() => MT.receive('dl_state', { uid: '5'.repeat(32), state: 'downloading', bytes: 500000, total: 1000000 }));
  check('Tiến độ tải hiện trong chi tiết', /50%/.test(await page.textContent('#dDl')));
  await page.evaluate(() => MT.receive('dl_state', { uid: '5'.repeat(32), state: 'done', note: 'Đã tải GLTF. SketchUp 2022 không nhập trực tiếp glTF — cần chuyển đổi.', files: [] }));
  check('Báo cần chuyển đổi định dạng', /chuyển đổi/.test(await page.textContent('#dDl')));
  await page.keyboard.press('Escape');
  check('Esc đóng chi tiết', await page.isHidden('#detailModal'));

  // Yêu thích trên thẻ
  await page.hover('#grid .card:nth-child(3)');
  await page.click('#grid .card:nth-child(3) .heart');
  check('♡ gửi fav_item', await page.evaluate(() => window.__calls.some(c => c[0] === 'fav_item')));
  await page.evaluate(() => MT.receive('fav', { key: 'sketchfab:' + '5'.repeat(32), on: true }));
  check('♥ cập nhật trên thẻ', (await page.textContent('#grid .card:nth-child(3) .heart')) === '♥');

  // Danh mục
  await page.click('#cats [data-cat="lighting"]');
  st = await starts();
  check('Chọn danh mục -> tìm lại với danh mục', st[st.length - 1].category === 'lighting');
  await page.click('#btnAddCat');
  await page.fill('#catName', 'Bàn trang điểm'); await page.fill('#catKw', 'bàn trang điểm, vanity');
  await page.click('#catSave');
  const cs = await page.evaluate(() => JSON.parse(window.__calls.filter(c => c[0] === 'cat_save').pop()[1][0]));
  check('Thêm danh mục tùy chỉnh', cs.name === 'Bàn trang điểm' && /vanity/.test(cs.keywords));
  await page.evaluate((cats) => MT.receive('categories', { list: cats, select: 'c_abcd1234' }), CATS);
  check('Lưu xong: đóng form, chọn danh mục mới, tìm lại', await page.isHidden('#catModal') && (await starts()).pop().category === 'c_abcd1234');
  await page.hover('#cats [data-cat="c_abcd1234"]'); await page.click('#cats [data-cat="c_abcd1234"] .ed');
  check('Sửa danh mục: mở form có sẵn dữ liệu', (await page.inputValue('#catName')) === 'Bàn trang điểm' && await page.isVisible('#catDelete'));
  await page.click('#catModal [data-close]');

  // Trống + thêm thư mục
  await page.evaluate(([sid]) => MT.receive('sr_update', { sid: sid + 99, items: [], counts: {}, filter: 'all', loading: false, has_more: false, sources: [], hidden: 0 }), [sid]);
  const sidNow = (await starts()).pop().sid;
  await page.evaluate(([s]) => MT.receive('sr_update', { sid: s, items: [], counts: { all: 0 }, filter: 'all', loading: false, has_more: false, sources: [{ id: 'sketchfab', label: 'Sketchfab', state: 'error', offline: true, count: 0 }], hidden: 0 }), [sidNow]);
  check('Trạng thái rỗng thân thiện + báo nguồn lỗi', await page.isVisible('#empty') && /Sketchfab không kết nối/.test(await page.textContent('#resInfo')));

  // Cuộn tải thêm
  const many = Array.from({ length: 60 }, (_, i) => ({ key: 'local:' + String(i).padStart(64, 'a'), source: 'local', id: String(i).padStart(64, 'a'), title: 'Model ' + i, insertable: true, downloadable: true, free: true }));
  await page.evaluate(([s, m]) => MT.receive('sr_update', { sid: s, items: m, counts: { all: 60 }, filter: 'all', loading: false, has_more: true, sources: [], hidden: 0 }), [sidNow, many]);
  await page.evaluate(() => { document.getElementById('content').scrollTop = 1e6; document.getElementById('content').dispatchEvent(new Event('scroll')); });
  await page.waitForTimeout(150);
  check('Cuộn tới cuối -> sr_more', await page.evaluate(() => window.__calls.some(c => c[0] === 'sr_more')));

  // Cài đặt: mục Nguồn tìm kiếm ghi rõ giới hạn
  await page.click('#btnSettings'); await page.click('#stabs [data-s="src"]');
  const srcTxt = await page.textContent('#srcList');
  check('Cài đặt › Nguồn ghi rõ nguồn chưa tích hợp', /3D Warehouse/.test(srcTxt) && /Chưa tích hợp/.test(srcTxt));
  await page.screenshot({ path: OUT + '/v102_settings.png' });
  await page.keyboard.press('Escape');

  // Màu chữ ô tìm kiếm (không tái phát lỗi V1.0.0)
  const col = await page.evaluate(() => getComputedStyle(document.getElementById('q')).webkitTextFillColor);
  check('Ô tìm kiếm chữ tối', col === 'rgb(29, 41, 57)', col);

  // V1.0.6: Cài đặt chỉ 4 tab; công cụ kỹ thuật nằm ở bảng Hỗ trợ (mở từ menu)
  const tabs = await page.$$eval('#stabs [data-s]', b => b.map(x => x.textContent.trim()));
  check('Cài đặt chỉ còn 4 tab', JSON.stringify(tabs) === JSON.stringify(['Thư viện', 'Nguồn tìm kiếm', 'AI', 'Tài khoản thư viện']), tabs);
  check('Không còn ô thông số kỹ thuật', (await page.$$('#sTimeout, #cTimeout, #cGltf')).length === 0);
  await page.evaluate(() => MT.receive('src_list', { types: { website: 'Website', facebook_group: 'Facebook Group', dropbox: 'Dropbox' }, list: [
    { id: 'local', name: 'Thư viện máy tính', type: 'local', builtin: true, integrated: true, enabled: true, type_label: 'Thư mục máy tính', method_label: 'Đọc thư mục máy tính', url: '' },
    { id: 'polyhaven', name: 'Poly Haven', type: 'website', builtin: true, integrated: true, enabled: true, url: 'https://polyhaven.com', type_label: 'Website', method_label: 'API chính thức' },
    { id: 'warehouse', name: '3D Warehouse', type: 'website', builtin: true, integrated: false, enabled: false, url: 'https://3dwarehouse.sketchup.com', type_label: 'Website', method_label: 'Chưa xác minh' },
    { id: 'u_0123456789', name: 'Nhóm thư viện 3D', type: 'facebook_group', builtin: false, integrated: false, enabled: true, status: 'login', url: 'https://www.facebook.com/groups/x', type_label: 'Facebook Group', method_label: 'Mở nguồn + nhập link thủ công', note: 'Meta đã gỡ Groups API' }] }));
  await page.evaluate(() => { document.querySelector('#stabs [data-s=src]').click(); document.querySelector('#settingsModal').hidden = false; });
  await page.evaluate(() => { window.__calls.length = 0; const c = document.querySelector('#srcList input[data-src=polyhaven]'); c.click(); });
  const sv = await page.evaluate(() => window.__calls.filter(c => c[0] === 'src_toggle').map(c => c[1]));
  check('Bật/tắt từng nguồn ngay trong danh sách và lưu lại', sv.length === 1 && sv[0][0] === 'polyhaven' && sv[0][1] === false, sv);
  check('Nguồn chưa tích hợp không có ô bật', (await page.$$('#srcList input[data-src=warehouse]')).length === 0);
  check('Loại nguồn lấy từ dữ liệu (không cố định trong giao diện)', (await page.$$eval('#srcType option', o => o.length)) === 4);
  check('Nguồn Facebook giữ lại, ghi rõ cần đăng nhập + có nút Mở/Sửa/Xóa', (await page.textContent('#srcList')).includes('Cần đăng nhập trên trình duyệt') &&
    (await page.$$('#srcList .item.src')).length === 4);
  await page.evaluate(() => { window.__calls.length = 0; document.querySelector('#srcUrl').value = 'https://myskp.vn'; document.querySelector('#srcAddBtn').click();
    document.querySelector('#linkUrl').value = 'https://www.dropbox.com/s/a/x.zip?dl=0'; document.querySelector('#linkGo').click(); });
  const sc = await page.evaluate(() => window.__calls.map(c => c[0]));
  check('Thêm nguồn + nhập link gửi đúng lệnh', sc.includes('src_add') && sc.includes('link_import'), sc);
  await page.evaluate(() => MT.receive('cat_stats', { available: true, total: 120, with_vec: 80, dup: 3, dead: 2, checked: 50 }));
  check('Hiện thống kê kho dữ liệu', (await page.textContent('#catInfo')).includes('120 model'));
  await page.evaluate(() => MT.receive('src_list', { types: { website: 'Website' }, list: [
    { id: 'u_aaaaaaaaaa', name: 'CGTips', type: 'website', builtin: false, integrated: true, enabled: true, scannable: true, status: 'ok', url: 'https://sketchup.cgtips.org',
      type_label: 'Website', method_label: 'WordPress REST API công khai', stats: { indexed: 1240, with_links: 1180, with_vec: 900, last_sync: 1795560000 },
      sync: { running: true, phase: 'Đang trích xuất bài viết', done: 150, total: 3000 } }] }));
  const srcTxt2 = await page.textContent('#srcList');
  check('Nguồn hiện số model đã lập chỉ mục / có link tải / thời gian đồng bộ / tiến trình', srcTxt2.includes('1240 model đã lập chỉ mục') && srcTxt2.includes('1180 có link tải') &&
    srcTxt2.includes('đồng bộ') && srcTxt2.includes('(150/3000)'), srcTxt2);
  await page.evaluate(() => { window.__calls.length = 0; [...document.querySelectorAll('#srcList button')].find(b => b.textContent === 'Dừng').click(); });
  check('Đang quét: có nút Dừng', await page.evaluate(() => window.__calls.some(c => c[0] === 'src_stop')));
  await page.evaluate(() => MT.receive('src_progress', { id: 'u_aaaaaaaaaa', running: false, phase: 'Xong: 1300 model, 1200 có link tải' }));
  await page.evaluate(() => { window.__calls.length = 0; const bs = [...document.querySelectorAll('#srcList button')];
    bs.find(b => b.textContent === 'Đồng bộ').click(); bs.find(b => b.textContent === 'Quét').click(); bs.find(b => b.textContent === 'Nhật ký').click(); });
  const sc2 = await page.evaluate(() => window.__calls.map(c => c[0] + ':' + (c[1][1] || '')));
  check('Đồng bộ / Quét / Nhật ký gửi đúng lệnh', sc2.includes('src_scan:sync') && sc2.includes('src_scan:full') && sc2.some(x => x.startsWith('src_log')), sc2);
  await page.evaluate(() => MT.receive('src_log', { id: 'u_aaaaaaaaaa', text: '2026-11-25 11:00:00 Trang lỗi https://x: HTTP 500' }));
  check('Nhật ký lỗi chi tiết hiển thị', (await page.textContent('#srcLogText')).includes('HTTP 500') && await page.locator('#srcLogModal').isVisible());
  await page.evaluate(() => { document.querySelector('[data-close=srcLogModal]').click(); });
  // V1.0.13: Đồng bộ tất cả, Facebook đăng nhập & lưu bài, công cụ tìm kiếm, chế độ tìm bằng ảnh, điểm tương đồng
  await page.evaluate(() => MT.receive('src_list', { types: { facebook_group: 'Facebook Group' }, list: [
    { id: 'u_bbbbbbbbbb', name: 'CỘNG ĐỒNG SKETCHUP VIỆT NAM', type: 'facebook_group', builtin: false, enabled: true, scannable: true, status: 'ok', method: 'index',
      url: 'https://www.facebook.com/groups/vietnamsketchup', type_label: 'Facebook Group', method_label: 'Chỉ mục máy tìm kiếm', stats: { indexed: 4 },
      sync: { running: true, phase: 'Đang tìm bài', done: 2, total: 14, found: 3, with_links: 1 } }] }));
  const fbTxt = await page.textContent('#srcList');
  check('Nhóm Facebook hiện tên thật + số model tìm thấy khi đang quét', fbTxt.includes('CỘNG ĐỒNG SKETCHUP VIỆT NAM') && fbTxt.includes('đã tìm thấy 3 model'), fbTxt);
  await page.evaluate(() => { window.__calls.length = 0; [...document.querySelectorAll('#srcList button')].find(b => b.textContent === 'Đăng nhập & lưu bài').click();
    document.querySelector('#srcSyncAll').click(); });
  const fc = await page.evaluate(() => window.__calls.map(c => c[0]));
  check('Nút Đăng nhập & lưu bài + Đồng bộ tất cả nguồn', fc.includes('fb_open') && fc.includes('src_sync_all'), fc);
  await page.evaluate(() => MT.receive('src_all', { running: false, total: 2, done: 2, results: [{ id: 'u_bbbbbbbbbb', ok: true, found: 4, with_links: 1 }, { id: 'u_x', ok: false, error: 'HTTP 500' }] }));
  const sa = await page.textContent('#srcAllList');
  check('Kết quả đồng bộ tất cả theo từng nguồn, nguồn lỗi vẫn báo', sa.includes('4 model') && sa.includes('HTTP 500'), sa);
  const prov = await page.$$eval('#searchList .item', x => x.map(e => e.textContent));
  check('Cài đặt có danh sách công cụ tìm kiếm (Tavily không cần key)', prov.length === 5 && prov[0].includes('Tavily') && prov[0].includes('Dùng không key'), prov);
  await page.evaluate(() => { window.__calls.length = 0; [...document.querySelectorAll('#searchList button')].find(b => b.textContent === 'Kiểm tra').click(); });
  check('Kiểm tra kết nối công cụ tìm kiếm', await page.evaluate(() => window.__calls.some(c => c[0] === 'search_test' && c[1][0] === 'tavily')));
  await page.evaluate(() => MT.receive('search_test', { provider: 'tavily', ok: true, state: 'ok', count: 5, ms: 800 }));
  check('Hiện kết quả kiểm tra kết nối', (await page.textContent('#searchList')).includes('Kết nối được (5 kết quả'));
  await page.evaluate(() => { document.querySelector('#settingsModal').hidden = true; window.__calls.length = 0; document.querySelector('#vsBar').hidden = false;
    document.querySelector('#vsModes [data-m=similar]').click(); });
  check('Chọn Chính xác / Tương tự / Mở rộng', await page.evaluate(() => window.__calls.some(c => c[0] === 'vs_mode' && c[1][0] === 'similar')) &&
    await page.evaluate(() => document.querySelector('#vsModes [data-m=similar]').classList.contains('on')));
  await page.evaluate(() => MT.receive('vs_state', { state: 'searching', mode: 'exact', categories: [{ vi: 'sofa', prob: 0.42 }], allowed: { exact: ['sofa', 'sofa góc'], similar: [] }, msg: 'Đang tìm' }));
  check('Hiện danh mục được giữ (lọc cứng)', (await page.textContent('#vsCats')).includes('sofa góc'));
  await page.screenshot({ path: OUT + '/v110_sources.png' });
  await page.evaluate(() => { document.querySelector('#settingsModal').hidden = true; });
  await page.evaluate(() => MT.receive('accounts', [
    { id: 'sketchfab', name: 'Sketchfab', status: 'not_logged_in', status_label: 'Chưa đăng nhập', note: '', actions: ['login', 'open'] },
    { id: 'cgtrader', name: 'CGTrader', status: 'need_api', status_label: 'Cần cấp quyền API', note: '', actions: ['login', 'open'] }]));
  await page.evaluate(() => { window.__calls.length = 0; document.querySelector('#accList .acc .acts button').click(); });
  const ac = await page.evaluate(() => window.__calls.filter(c => c[0] === 'acct_action').map(c => c[1]));
  check('Tài khoản thư viện: hiện trạng thái + nút ĐĂNG NHẬP', ac.length === 1 && ac[0][0] === 'sketchfab' && ac[0][1] === 'login' &&
    (await page.locator('#accList .st.need_api').count()) === 1, ac);
  await page.evaluate(() => MT.receive('dl_found', { name: 'sofa.zip', title: 'Sofa', source: 'SketchUp CGTips' }));
  check('Nhận file vừa tải: hiện thanh CHÈN', await page.locator('#foundBar').isVisible());
  await page.evaluate(() => { window.__calls.length = 0; document.querySelector('#foundIns').click(); });
  check('Bấm CHÈN gửi insert_found', await page.evaluate(() => window.__calls.some(c => c[0] === 'insert_found')) && !(await page.locator('#foundBar').isVisible()));
  // Tìm bằng ảnh: bấm nút → chọn ảnh (Ruby), dán ảnh → gửi vs_start, cài bộ AI 1 lần, cắt vùng → vs_crop
  await page.evaluate(() => { window.__calls.length = 0; document.querySelector('#btnAi').click(); });
  check('TÌM BẰNG ẢNH mở chọn ảnh (không mở Cài đặt OpenAI)', await page.evaluate(() => window.__calls.some(c => c[0] === 'vs_pick')) &&
    !(await page.locator('#settingsModal').isVisible()) && await page.locator('#vsBar').isVisible());
  const png = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==';
  await page.evaluate((src) => {
    window.__calls.length = 0;
    const bin = atob(src.split(',')[1]); const u = new Uint8Array(bin.length); for (let i = 0; i < bin.length; i++) u[i] = bin.charCodeAt(i);
    const dt = new DataTransfer(); dt.items.add(new File([u], 'a.png', { type: 'image/png' }));
    document.dispatchEvent(new ClipboardEvent('paste', { clipboardData: dt, bubbles: true }));
  }, png);
  await page.waitForFunction(() => window.__calls.some(c => c[0] === 'vs_start'), null, { timeout: 5000 });
  check('Dán ảnh (Ctrl+V) tự tìm ngay', true);
  await page.evaluate(() => MT.receive('vs_state', { state: 'need_runtime', sid: 900000001, download_mb: 330, model: 'CLIP ViT-B/32', license: 'MIT' }));
  check('Lần đầu: hỏi cài bộ AI 1 lần', await page.locator('#vsInstallModal').isVisible());
  await page.evaluate(() => { window.__calls.length = 0; document.querySelector('#vsInstallOk').click(); });
  check('Đồng ý → vs_install', await page.evaluate(() => window.__calls.some(c => c[0] === 'vs_install')));
  await page.evaluate(() => MT.receive('vs_state', { state: 'searching', sid: 900000002, msg: 'Đang tìm model…', categories: [{ vi: 'sofa' }] }));
  await page.evaluate(() => MT.receive('sr_update', { sid: 900000002, items: [{ key: 'local:x', source: 'local', id: 'x', title: 'Sofa giống', insertable: true, vscore: 0.81 }],
    counts: { all: 1, local: 1, online: 0, insertable: 1, free: 1 }, filter: 'all', loading: false, has_more: false, sources: [], visual: true }));
  await page.screenshot({ path: OUT + '/v109_visual.png' });
  check('Kết quả tìm bằng ảnh hiện trên lưới chung', (await page.locator('#grid .card').count()) === 1 && (await page.textContent('#vsMsg')).includes('sofa'));
  await page.evaluate(() => { document.querySelector('#vsCropBtn').click(); });
  check('Mở cắt vùng', await page.locator('#cropModal').isVisible());
  const bb = await page.locator('#cropImg').boundingBox();
  if (bb) { await page.mouse.move(bb.x + 2, bb.y + 2); await page.mouse.down(); await page.mouse.move(bb.x + bb.width * 0.6, bb.y + bb.height * 0.7); await page.mouse.up(); }
  await page.evaluate(() => { window.__calls.length = 0; document.querySelector('#cropOk').disabled = false; document.querySelector('#cropOk').click(); });
  const cc = await page.evaluate(() => window.__calls.filter(c => c[0] === 'vs_crop').map(c => JSON.parse(c[1][0])));
  check('Cắt vùng gửi vs_crop', cc.length === 1, cc);
  await page.evaluate(() => { window.__calls.length = 0; document.querySelector('#vsClear').click(); });
  check('Xóa ảnh mẫu → về tìm bằng từ khóa', await page.evaluate(() => window.__calls.some(c => c[0] === 'vs_clear') && window.__calls.some(c => c[0] === 'sr_start')) &&
    !(await page.locator('#vsBar').isVisible()));
  await page.evaluate(() => MT.receive('open_support'));
  check('Menu Hỗ trợ kỹ thuật mở bảng chẩn đoán', await page.locator('#supportModal').isVisible());
  await page.evaluate(() => { document.querySelector('[data-close=supportModal]').click(); });
  // Trình cập nhật vẫn hoạt động
  const up = await browser.newPage({ viewport: { width: 820, height: 900 } });
  up.on('pageerror', e => errors.push('update: ' + e.message));
  await up.addInitScript(() => { window.__calls = []; window.MT_DEV_BRIDGE = (n, a) => window.__calls.push([n, a]); });
  await up.goto('file://' + SRC + '/updater/update_dialog.html');
  await up.waitForFunction(() => window.UP && window.__calls.some(c => c[0] === 'up_ready'));
  check('Trình cập nhật mở và gửi up_ready', true);

  check('Không lỗi JavaScript', errors.length === 0, errors);
  await browser.close();
  R.forEach(x => console.log((x.ok ? '✓ ' : '✗ ') + x.n + (x.ok ? '' : '  → ' + JSON.stringify(x.d))));
  const ok = R.every(x => x.ok);
  console.log(ok ? `UI_TEST_PASS (${R.length} kiểm tra)` : 'UI_TEST_FAIL');
  process.exit(ok ? 0 : 1);
})().catch(e => { console.error(e); process.exit(2); });
