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
      { id: 'warehouse', name: '3D Warehouse', integrated: false, enabled: false, note: 'Chưa có API công khai' }] }), [SETTINGS, CATS]);
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
  check('Cài đặt chỉ còn 4 tab', JSON.stringify(tabs) === JSON.stringify(['Thư viện', 'Nguồn tìm kiếm', 'AI', 'Tài khoản Sketchfab']), tabs);
  check('Không còn ô thông số kỹ thuật', (await page.$$('#sTimeout, #cTimeout, #cGltf')).length === 0);
  await page.evaluate(() => MT.receive('sources_status', [
    { id: 'local', name: 'Máy tính', enabled: true, integrated: true, note: '' },
    { id: 'polyhaven', name: 'Poly Haven', enabled: true, integrated: true, note: 'API chính thức' },
    { id: 'warehouse', name: '3D Warehouse', enabled: false, integrated: false, note: 'Chưa tích hợp' }]));
  await page.evaluate(() => { document.querySelector('#stabs [data-s=src]').click(); document.querySelector('#settingsModal').hidden = false; });
  await page.evaluate(() => { window.__calls.length = 0; const c = document.querySelector('#srcList input[data-src=polyhaven]'); c.click(); });
  const sv = await page.evaluate(() => window.__calls.filter(c => c[0] === 'save_settings').map(c => JSON.parse(c[1][0])));
  check('Bật/tắt từng nguồn ngay trong danh sách và lưu lại', sv.length === 1 && sv[0].sources && sv[0].sources.polyhaven === false, sv);
  check('Nguồn chưa tích hợp không có ô bật', (await page.$$('#srcList input[data-src=warehouse]')).length === 0);
  await page.evaluate(() => { document.querySelector('#settingsModal').hidden = true; });
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
