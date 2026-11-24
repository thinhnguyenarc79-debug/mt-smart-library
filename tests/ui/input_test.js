// V1.0.1 — Kiểm thử ô nhập liệu bằng thao tác bàn phím/chuột thật trên Chromium headless.
const { chromium } = require('/opt/npm-tools/node_modules/playwright');
const path = require('path');
const SRC = path.resolve(__dirname, '../../src/mt_smart_library');
const OUT = process.argv[2] || '/tmp';
const results = [];
function check(name, ok, detail) { results.push({ name, ok: !!ok, detail }); }
(async () => {
  const browser = await chromium.launch({ executablePath: '/usr/bin/google-chrome', args: ['--allow-file-access-from-files'] });
  const ctx = await browser.newContext({ viewport: { width: 1180, height: 780 } });
  const page = await ctx.newPage();
  const errors = [];
  page.on('pageerror', e => errors.push(e.message));
  await page.addInitScript(() => { window.__calls = []; window.MT_DEV_BRIDGE = (n, a) => window.__calls.push([n, a]); });
  await page.goto('file://' + SRC + '/ui/index.html');
  await page.waitForFunction(() => window.MT && window.__calls.some(c => c[0] === 'ready'));
  const settings = { roots: ['D:/Thư viện'], favorites: [], history: [], quick_scan: true, scan_on_open: true,
    ui: { page_size: 48, sort: 'relevance', size_max_mb: 0, tab: 'offline' }, ai: { model: 'gpt-6-luna', base_url: 'https://api.openai.com/v1', detail: 'low', remember_key: false },
    sketchfab: { downloadable_only: true, token_type: 'token', remember_token: false }, net: { timeout: 30 }, update: { source: 'none', manifest_url: '', github_repo: '', check_on_start: false } };
  await page.evaluate((s) => MT.receive('init', { version: '1.0.1', plugin_id: 'x', build: 'b', su: '22.0.354', settings: s,
    secrets: { openai: {}, sketchfab: {} }, sources: [], data_root: 'C:/x', secret_store: true, roots_state: {}, loaded: true, library_size: 0, scan: { running: false } }), settings);
  const searches = () => page.evaluate(() => window.__calls.filter(c => c[0] === 'search').map(c => JSON.parse(c[1][0])));

  // 1. Màu chữ / con trỏ / nền
  const st = await page.evaluate(() => { const cs = getComputedStyle(document.getElementById('q')); return { color: cs.color, fill: cs.webkitTextFillColor, caret: cs.caretColor, bg: cs.backgroundColor, sel: cs.userSelect }; });
  check('Chữ ô tìm kiếm màu tối, nền trắng', st.color === 'rgb(29, 41, 57)' && st.fill === 'rgb(29, 41, 57)' && st.bg === 'rgb(255, 255, 255)', st);
  check('Con trỏ nhập liệu màu tối', st.caret === 'rgb(29, 41, 57)', st.caret);
  check('Cho phép chọn chữ', st.sel === 'text', st.sel);
  const ph = await page.evaluate(() => getComputedStyle(document.getElementById('q'), '::placeholder').color);
  check('Placeholder màu xám rõ', ph === 'rgb(132, 146, 166)', ph);

  // 2. Focus khi click (cả khi click vào ô và vùng đệm của thanh tìm kiếm)
  await page.click('#btnAi'); await page.keyboard.press('Escape');
  await page.click('#q');
  check('Nhận focus khi click vào ô', await page.evaluate(() => document.activeElement.id === 'q'));
  await page.click('#tabs [data-tab="offline"]');
  const box = await page.locator('.search').boundingBox();
  const qb = await page.locator('#q').boundingBox();
  await page.mouse.click(qb.x + qb.width + 3, box.y + box.height / 2); // khe giữa ô và nút AI
  check('Click vùng thanh tìm kiếm cũng focus ô', await page.evaluate(() => document.activeElement.id === 'q'));

  // 3. Gõ tiếng Anh + debounce
  const before = (await searches()).length;
  await page.click('#q');
  await page.keyboard.type('modern sofa', { delay: 20 });
  await page.waitForTimeout(450);
  const s1 = await searches();
  check('Gõ tiếng Anh: giá trị đúng', (await page.inputValue('#q')) === 'modern sofa');
  check('Debounce: gõ 11 ký tự chỉ gửi 1 lần tìm', s1.length - before === 1, s1.length - before);
  check('Lần tìm mang đúng từ khóa', s1[s1.length - 1].q === 'modern sofa');
  await page.screenshot({ path: OUT + '/v101_search_typed.png', clip: { x: 0, y: 0, width: 1180, height: 60 } });

  // 4. Backspace / Delete / Enter
  await page.keyboard.press('Backspace'); await page.keyboard.press('Backspace');
  await page.keyboard.press('Home'); await page.keyboard.press('Delete');
  check('Backspace + Delete', (await page.inputValue('#q')) === 'odern so', await page.inputValue('#q'));
  const b2 = (await searches()).length;
  await page.keyboard.press('Enter');
  const s2 = await searches();
  check('Enter tìm ngay (không chờ debounce)', s2.length === b2 + 1 && s2[s2.length - 1].q === 'odern so');

  // 5. Copy/Paste Ctrl+A, Ctrl+C, Ctrl+V
  await ctx.grantPermissions(['clipboard-read', 'clipboard-write']).catch(() => {});
  await page.fill('#q', 'bàn ăn gỗ');
  await page.click('#q');
  await page.keyboard.press('Control+A'); await page.keyboard.press('Control+C');
  await page.keyboard.press('End'); await page.keyboard.type(' ');
  await page.keyboard.press('Control+V');
  const pasted = await page.inputValue('#q');
  check('Ctrl+A / Ctrl+C / Ctrl+V', pasted === 'bàn ăn gỗ bàn ăn gỗ', pasted);

  // 6. Tiếng Việt: kiểu UniKey (xóa lùi + gõ lại) và kiểu IME ghép (composition)
  await page.fill('#q', '');
  await page.click('#q');
  for (const step of ['g', 'gh', 'ghe', 'ghê', 'ghế']) {           // UniKey gửi backspace rồi ký tự có dấu
    const cur = await page.inputValue('#q');
    for (let i = 0; i < cur.length; i++) await page.keyboard.press('Backspace');
    await page.keyboard.insertText(step);
  }
  await page.keyboard.insertText(' sofa');
  await page.waitForTimeout(400);
  check('UniKey (backspace + gõ lại): ra “ghế sofa”', (await page.inputValue('#q')) === 'ghế sofa');
  const b3 = (await searches()).length;
  // Mô phỏng IME/TSF: trong lúc composition KHÔNG được gửi tìm kiếm
  await page.evaluate(() => {
    const q = document.getElementById('q');
    q.dispatchEvent(new CompositionEvent('compositionstart', { data: '' }));
    q.value = 'ghế sofa v'; q.dispatchEvent(new InputEvent('input', { isComposing: true, data: 'v' }));
    q.value = 'ghế sofa vả'; q.dispatchEvent(new InputEvent('input', { isComposing: true, data: 'vả' }));
  });
  await page.waitForTimeout(400);
  const midComp = (await searches()).length - b3;
  await page.evaluate(() => {
    const q = document.getElementById('q'); q.value = 'ghế sofa vải';
    q.dispatchEvent(new CompositionEvent('compositionend', { data: 'vải' }));
  });
  await page.waitForTimeout(400);
  const s4 = await searches();
  check('IME ghép dấu: không tìm giữa chừng', midComp === 0, midComp);
  check('IME ghép dấu: tìm sau khi ghép xong', s4[s4.length - 1].q === 'ghế sofa vải');

  // 7. Dữ liệu từ Ruby không làm mất từ khóa / focus
  await page.click('#q');
  await page.evaluate((s) => {
    const seq = Math.max(...window.__calls.filter(c => c[0] === 'search').map(c => JSON.parse(c[1][0]).seq));
    MT.receive('results', { seq, total: 1, page: 0, pages: 1, per_page: 48, library_size: 1, items: [{ id: 'a'.repeat(64), name: 'Ghế sofa vải', path: 'D:/x.skp', folder: 'x', size: 1, mtime: 1 }] });
    MT.receive('settings', s); MT.receive('status', { msg: 'ok', kind: 'ok' }); MT.receive('scan_progress', { running: true, dirs: 1, files: 1, errors: 0, current: 'D:/' });
    MT.receive('scan_done', { models: 1, errors: 0, seconds: 0.1, listed: 1, reused: 0, roots_state: {} }); MT.receive('refresh');
    MT.receive('library', { size: 1 }); MT.receive('secrets', { openai: {}, sketchfab: {} }); MT.receive('thumb', { id: 'a'.repeat(64), src: null });
  }, settings);
  check('Nhận dữ liệu Ruby không mất từ khóa', (await page.inputValue('#q')) === 'ghế sofa vải');
  check('Nhận dữ liệu Ruby không mất focus', await page.evaluate(() => document.activeElement.id === 'q'));
  await page.keyboard.press('Escape');
  check('Escape xóa từ khóa', (await page.inputValue('#q')) === '');

  // 8. Mọi ô nhập khác: màu chữ khác màu nền, gõ được
  await page.click('[data-tab="settings"]');
  const others = await page.evaluate(() => Array.from(document.querySelectorAll('input:not([type=checkbox]),select,textarea')).map(e => {
    const cs = getComputedStyle(e); return { id: e.id, color: cs.webkitTextFillColor || cs.color, bg: cs.backgroundColor };
  }));
  const bad = others.filter(o => o.color === o.bg || o.color === 'rgb(255, 255, 255)');
  check('Mọi ô nhập/select/textarea: chữ không trùng màu nền (' + others.length + ' ô)', bad.length === 0, bad);
  for (const id of ['sKey', 'sModel', 'sBase', 'sTimeout', 'sSfToken']) {
    await page.fill('#' + id, '');
    await page.click('#' + id); await page.keyboard.type(id === 'sTimeout' ? '45' : 'abc');
    const v = await page.inputValue('#' + id);
    check('Gõ được vào #' + id, v === (id === 'sTimeout' ? '45' : 'abc'), v);
  }
  await page.screenshot({ path: OUT + '/v101_settings_inputs.png' });
  // Hộp AI
  await page.evaluate(() => { document.getElementById('aiModal').hidden = false; document.getElementById('aiResult').hidden = false; });
  await page.click('#rType'); await page.keyboard.type('sofa góc');
  check('Gõ được vào ô kết quả AI', (await page.inputValue('#rType')) === 'sofa góc');

  // 9. Trình cập nhật
  const up = await ctx.newPage();
  await up.addInitScript(() => { window.__calls = []; window.MT_DEV_BRIDGE = (n, a) => window.__calls.push([n, a]); });
  await up.goto('file://' + SRC + '/updater/update_dialog.html');
  await up.waitForFunction(() => window.UP);
  await up.selectOption('#src', 'github');
  await up.click('#srcRepo'); await up.keyboard.type('thinhnguyenarc79-debug/mt-smart-library');
  const upc = await up.evaluate(() => getComputedStyle(document.getElementById('srcRepo')).webkitTextFillColor);
  check('Trình cập nhật: gõ repo, chữ màu tối', (await up.inputValue('#srcRepo')) === 'thinhnguyenarc79-debug/mt-smart-library' && upc === 'rgb(29, 41, 57)', upc);

  check('Không có lỗi JavaScript', errors.length === 0, errors);
  await browser.close();
  results.forEach(r => console.log((r.ok ? '✓ ' : '✗ ') + r.name + (r.ok ? '' : '  → ' + JSON.stringify(r.detail))));
  const ok = results.every(r => r.ok);
  console.log(ok ? `INPUT_TEST_PASS (${results.length} kiểm tra)` : 'INPUT_TEST_FAIL');
  process.exit(ok ? 0 : 1);
})().catch(e => { console.error(e); process.exit(2); });
