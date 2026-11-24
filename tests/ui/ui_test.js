// Kiểm thử giao diện trên Chrome headless với cầu nối sketchup giả lập.
const { chromium } = require('/opt/npm-tools/node_modules/playwright');
const path = require('path');
const SRC = path.resolve(__dirname, '../../src/mt_smart_library');
const OUT = process.argv[2] || '/tmp';
(async () => {
  const browser = await chromium.launch({ executablePath: '/usr/bin/google-chrome', args: ['--allow-file-access-from-files'] });
  const page = await browser.newPage({ viewport: { width: 1180, height: 780 } });
  const errors = [];
  page.on('pageerror', e => errors.push('pageerror: ' + e.message));
  page.on('console', m => { if (m.type() === 'error') errors.push('console: ' + m.text()); });
  await page.addInitScript(() => {
    window.__calls = [];
    window.MT_DEV_BRIDGE = (n, a) => window.__calls.push([n, a]);
  });
  await page.goto('file://' + SRC + '/ui/index.html');
  await page.waitForFunction(() => window.MT && window.__calls.some(c => c[0] === 'ready'));
  const settings = { roots: ['D:/Thư viện 3D', '//nas/share/SKP'], favorites: [], history: [], quick_scan: true, scan_on_open: true,
    ui: { page_size: 48, sort: 'relevance', size_max_mb: 0, tab: 'offline' }, ai: { model: 'gpt-6-luna', base_url: 'https://api.openai.com/v1', detail: 'low', remember_key: false },
    sketchfab: { downloadable_only: true, token_type: 'token', remember_token: false }, net: { timeout: 30 }, update: { source: 'none', manifest_url: '', github_repo: '', check_on_start: false } };
  // Ảnh PNG nhỏ hợp lệ để mô phỏng thumbnail
  const png = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';
  await page.evaluate(([settings]) => {
    MT.receive('init', { version: '1.0.0', plugin_id: 'mtdesign.smart_library_pro', build: '2026-11-24', su: '22.0.354', settings,
      secrets: { openai: { session: false, env: false, stored: false }, sketchfab: { session: true, env: false, stored: false } },
      sources: [{ id: 'warehouse', name: '3D Warehouse', note: '' }, { id: '3dsky', name: '3dsky', note: '' }],
      data_root: 'C:/Users/Thinh/AppData/Local/MT_Smart_Library', secret_store: true, roots_state: { 'D:/Thư viện 3D': 'ok', '//nas/share/SKP': 'offline' },
      loaded: true, library_size: 2, scan: { running: false }, summary: null });
  }, [settings]);
  const items = [
    { id: 'a'.repeat(64), name: '<img src=x onerror="window.pwned=1"> Ghế sofa vải xám', path: 'D:/Thư viện 3D/Ghế/x.skp', folder: 'Ghế', size: 2345678, mtime: 1732400000, fav: true },
    { id: 'b'.repeat(64), name: 'Bàn ăn gỗ óc chó 6 chỗ', path: 'D:/Thư viện 3D/Bàn/y.skp', folder: 'Bàn', size: 812345, mtime: 1732000000, fav: false },
    { id: 'c'.repeat(64), name: 'Đèn thả pendant brass', path: '//nas/share/SKP/Đèn/z.skp', folder: 'Đèn', size: 45678, mtime: 1731000000, fav: false }];
  await page.evaluate(([items, png]) => {
    const seq = Math.max(...window.__calls.filter(c => c[0] === 'search').map(c => JSON.parse(c[1][0]).seq));
    MT.receive('results', { seq, total: 3, page: 0, pages: 1, per_page: 48, items, library_size: 3 });
    MT.receive('thumb', { id: 'a'.repeat(64), src: png });
    MT.receive('thumb', { id: 'b'.repeat(64), src: 'javascript:alert(1)' });
    MT.receive('scan_progress', { running: true, dirs: 120, files: 3456, errors: 2, current: 'D:/Thư viện 3D/Nội thất' });
    MT.receive('status', { msg: 'Đã lập chỉ mục 3 model trong 0.4 giây.', kind: 'ok' });
    MT.receive('net', { state: 'online', ms: 120 });
  }, [items, png]);
  await page.waitForTimeout(300);
  const r = await page.evaluate(() => ({
    pwned: window.pwned, cards: document.querySelectorAll('#grid .card').length,
    firstName: document.querySelector('#grid .card .name').textContent,
    imgInName: document.querySelectorAll('#grid .name img').length,
    badThumb: document.querySelectorAll('.pic[data-id="' + 'b'.repeat(64) + '"] img').length,
    goodThumb: document.querySelectorAll('.pic[data-id="' + 'a'.repeat(64) + '"] img').length,
    thumbsRequested: window.__calls.filter(c => c[0] === 'thumbs').length
  }));
  await page.screenshot({ path: OUT + '/ui_offline.png' });
  // Tab Online + kết quả Sketchfab
  await page.click('[data-tab="online"]');
  await page.fill('#q', 'ghế sofa');
  await page.click('#btnSfSearch');
  const sfseq = await page.evaluate(() => JSON.parse(window.__calls.filter(c => c[0] === 'sf_search').pop()[1][0]).seq);
  await page.evaluate((seq) => {
    MT.receive('sf_results', { seq, q: 'ghế sofa', next: '24', items: [
      { uid: '9aea3b516d3e4e169710049b32282670', name: 'Modern Sofa', author: 'Studio', author_url: 'https://sketchfab.com/studio', license: 'CC Attribution', thumb: 'https://evil.example/x.jpg', viewer_url: 'https://sketchfab.com/3d-models/x', downloadable: true, faces: 12000, formats: [{ type: 'gltf', size: 2000000 }, { type: 'glb', size: 1500000 }] },
      { uid: '1aea3b516d3e4e169710049b32282671', name: 'Armchair <b>bold</b>', author: 'A', author_url: null, license: 'CC0', thumb: null, viewer_url: 'https://sketchfab.com/3d-models/y', downloadable: false, faces: 0, formats: [] }] });
    MT.receive('dl_state', { uid: '9aea3b516d3e4e169710049b32282670', state: 'done', note: 'Đã tải GLTF. SketchUp 2022 KHÔNG nhập trực tiếp glTF/GLB/USDZ.', files: [] });
  }, sfseq);
  await page.waitForTimeout(200);
  const r2 = await page.evaluate(() => ({ sfCards: document.querySelectorAll('#sfGrid .card').length, evilImg: document.querySelectorAll('#sfGrid img').length, bold: document.querySelectorAll('#sfGrid b').length }));
  await page.screenshot({ path: OUT + '/ui_online.png' });
  // AI modal
  await page.click('#btnAi');
  await page.evaluate((png) => {
    MT.receive('ai_preview', { src: png, name: 'anh-mau.png', size: 123456, mime: 'image/png', model: 'gpt-6-luna', endpoint: 'https://api.openai.com/v1' });
    MT.receive('ai_result', { object_type: 'sofa', style: 'hiện đại', material: 'vải', color: 'xám', queries_vi: ['ghế sofa vải xám', 'sofa văng hiện đại'], queries_en: ['gray fabric sofa', 'modern sofa'], usage: { total_tokens: 812 } });
  }, png);
  await page.waitForTimeout(200);
  await page.screenshot({ path: OUT + '/ui_ai.png' });
  await page.click('#rOffline');
  const anyOf = await page.evaluate(() => JSON.parse(window.__calls.filter(c => c[0] === 'search').pop()[1][0]).any_of);
  // Cài đặt
  await page.click('[data-tab="settings"]');
  await page.waitForTimeout(150);
  await page.screenshot({ path: OUT + '/ui_settings.png', fullPage: true });
  // Trình cập nhật
  const up = await browser.newPage({ viewport: { width: 820, height: 980 } });
  up.on('pageerror', e => errors.push('update pageerror: ' + e.message));
  await up.addInitScript(() => { window.__calls = []; window.MT_DEV_BRIDGE = (n, a) => window.__calls.push([n, a]); });
  await up.goto('file://' + SRC + '/updater/update_dialog.html');
  await up.waitForFunction(() => window.UP && window.__calls.some(c => c[0] === 'up_ready'));
  await up.evaluate(() => {
    UP.receive('init', { version: '1.0.0', plugin_id: 'mtdesign.smart_library_pro', su: '22.0.354', ruby: '2.7.2', plugins_root: 'C:/Users/Thinh/AppData/Roaming/SketchUp/SketchUp 2022/SketchUp/Plugins', data_root: 'C:/Users/Thinh/AppData/Local/MT_Smart_Library', source: { source: 'github', manifest_url: '', github_repo: 'mt-design/mt-smart-library', check_on_start: false },
      backups: [{ id: '1.0.0_20261124_101500', version: '1.0.0', created_at: '2026-11-24 10:15:00', reason: 'Trước khi Cập nhật từ file lên 1.0.1' }], history: [{ at: '2026-11-24 10:15:03', status: 'ok', reason: 'Cập nhật từ file', from: '1.0.0', to: '1.0.1' }], pending_restart: null, busy: false });
    UP.receive('up_package', { version: '1.0.1', relation: 'newer', compatible: true, compat_message: 'Tương thích SketchUp 2022, Ruby 2.7.2.', plugin_id: 'mtdesign.smart_library_pro', files: 31, bytes: 214000, sha256: 'ab'.repeat(32), changelog: ['Sửa lỗi quét ổ mạng', '<script>alert(1)</script> hiển thị dạng chữ'] });
    UP.receive('up_started', { version: '1.0.1' });
    UP.receive('up_progress', { progress: { step: 3, status: 'running', steps: ['Kiểm tra gói', 'Sao lưu bản hiện tại', 'Giải nén', 'Cài đặt', 'Kiểm tra sau cài', 'Hoàn tất'] } });
  });
  await up.waitForTimeout(150);
  await up.screenshot({ path: OUT + '/ui_update_progress.png', fullPage: true });
  await up.evaluate(() => UP.receive('up_done', { version: '1.0.1', backup: '1.0.0_20261124_101500', model_modified: true, progress: { step: 5, status: 'done', steps: ['Kiểm tra gói', 'Sao lưu bản hiện tại', 'Giải nén', 'Cài đặt', 'Kiểm tra sau cài', 'Hoàn tất'] }, backups: [], history: [] }));
  await up.waitForTimeout(100);
  await up.screenshot({ path: OUT + '/ui_update_done.png', fullPage: true });
  const r3 = await up.evaluate(() => ({ scripts: document.querySelectorAll('#pLog script').length, done: document.querySelector('#result').textContent.includes('CHƯA LƯU') }));
  console.log(JSON.stringify({ r, r2, anyOf, r3, errors }, null, 1));
  await browser.close();
  const ok = !r.pwned && r.cards === 3 && r.imgInName === 0 && r.badThumb === 0 && r.goodThumb === 1 && r.thumbsRequested >= 1 &&
    r2.sfCards === 2 && r2.evilImg === 0 && r2.bold === 0 && anyOf.length >= 4 && r3.scripts === 0 && r3.done && errors.length === 0;
  console.log(ok ? 'UI_TEST_PASS' : 'UI_TEST_FAIL');
  process.exit(ok ? 0 : 1);
})().catch(e => { console.error(e); process.exit(2); });
