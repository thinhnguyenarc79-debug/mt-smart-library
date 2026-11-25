# Báo cáo kiểm thử — MT SMART LIBRARY PRO

## V1.0.9 (25/11/2026) — MT VISUAL SEARCH ENGINE

| Bộ test | Nội dung | Kết quả |
|---|---|---|
| `test_visual.rb` (5) | Chạy THẬT tiến trình Python + ONNX Runtime 1.29 (CPU) với bộ mô hình ONNX nhỏ cùng giao diện CLIP (`tests/fixtures/make_tiny_clip.py`): lập chỉ mục từ ảnh PNG nhúng trong SKP, model không ảnh tách riêng, không tính lại khi không đổi; ảnh mẫu → model giống nhất lên đầu, điểm giảm dần; cắt vùng trong ảnh nhiều đồ vật → đúng món được chọn; ứng viên online xếp theo thumbnail thật, host lạ bị bỏ, trộn với máy tính; hủy giữa chừng; chưa cài bộ AI → hỏi cài 1 lần (không đòi OpenAI); cài đặt: giải nén Python, bật site-packages, pip (bản DirectML lỗi → bản CPU), kiểm SHA256/git SHA1, file hỏng bị xóa, lệnh dạng danh sách | ✅ |
| `ui_test.js` (53) | Nút Tìm bằng ảnh mở chọn ảnh (không mở Cài đặt), dán Ctrl+V tự tìm, hỏi cài 1 lần, kết quả lên lưới chung, cắt vùng, xóa ảnh mẫu quay về tìm từ khóa | ✅ |

**Chưa kiểm thử (cần máy Windows có mạng):**
- Mô hình CLIP thật: chưa tải được về máy test → chưa đo chất lượng (sofa cùng dáng khác màu, ghế cùng màu khác dáng, bàn tròn/chữ nhật, ảnh thật vs thumbnail, nền phức tạp). Ngưỡng `min_score 0.55`, `spread 0.18` trong `model_config.json` cần hiệu chỉnh sau khi chạy thật.
- Cài bộ AI thật trên Windows: tải Python nhúng 3.11.9 (python.org), get-pip (bootstrap.pypa.io), gói PyPI — địa chỉ python.org/pypa chưa xác minh lại được trong phiên này (yêu cầu đọc trang chưa được duyệt); file mô hình Hugging Face đã xác minh dung lượng + SHA256.
- Tốc độ lập chỉ mục 10.000–100.000 model trên CPU thật; DirectML; tiến trình không cửa sổ (CreateProcessW).
- WEBP: Pillow hỗ trợ; ảnh xem trước của mọi phiên bản SKP (định dạng mới có thể không chứa PNG ở 8 MB đầu → dùng thumbnail plugin hoặc ảnh cùng tên).

---

## V1.0.8 (25/11/2026)

| Bộ test | Nội dung | Kết quả |
|---|---|---|
| `test_sources.rb` (8) | URL REST API lõi WordPress; đọc bài viết/ảnh (bỏ link & ảnh ngoài host, giải mã HTML, bỏ số thứ tự); provider trang Anh (từ khóa dịch, ảnh, cache, hết trang); trang Việt (từ khóa gốc, lọc “giường ngủ” đúng, gói trả phí); lỗi mạng/400 không làm hỏng tìm kiếm; bật/tắt nguồn; theo dõi Downloads (bỏ .crdownload/.txt, chờ ổn định, nhận 1 file); giải nén ZIP mật khẩu (sai mật khẩu báo rõ; gói cập nhật vẫn chặn); trạng thái 12 tài khoản; App: XEM mở đúng trang, nhận file, CHÈN với mật khẩu của trang; chặn link ngoài | ✅ |
| `ui_test.js` (45) | Tab “Tài khoản thư viện”, trạng thái + nút ĐĂNG NHẬP, thanh CHÈN file vừa tải | ✅ |

Chi tiết từng nguồn: `docs/BAO_CAO_NGUON_THU_VIEN.md`.
**Chưa kiểm thử thật:** gọi REST API từ SketchUp trên Windows (môi trường test không có mạng ra ngoài), tải file thật từ 3 trang, giải nén file thật của CGTips (có thể là RAR — plugin sẽ báo giải nén thủ công).

---

## V1.0.6 – V1.0.7 (25/11/2026)

| Bộ test | Nội dung | Kết quả |
|---|---|---|
| `test_polyhaven.rb` (5) | Đọc danh mục (bỏ id độc, ảnh ngoài cdn.polyhaven.com); chọn glTF 2k→1k→4k; chặn đường dẫn `../`, host lạ; tìm “ghế sofa”/“ghế” ra đúng model, không ra thùng phuy; danh mục tải 1 lần; khởi động lại + mất mạng vẫn tìm bằng bản lưu đĩa; bật/tắt nguồn được ghi nhớ; App: tải gltf+bin+texture đúng thư mục, kiểm MD5, ghi ATTRIBUTION, chèn; lần 2 không tải lại; file sai MD5 → báo lỗi, không chèn | ✅ |
| `ui_test.js` | Cài đặt chỉ 4 tab, không còn ô thông số kỹ thuật, menu Hỗ trợ kỹ thuật mở bảng chẩn đoán, ô bật/tắt từng nguồn lưu cài đặt | ✅ |

**Chưa kiểm thử với dữ liệu thật:** máy test không gọi được api.polyhaven.com (đã kiểm cấu trúc JSON thật qua công cụ đọc web: `/assets?type=models`, `/files/ArmChair_01`).
File glTF thật của Poly Haven chưa được chạy qua bộ đọc tích hợp trong SketchUp 2022 — nếu bộ đọc không đọc được, plugin tự chuyển qua Blender.

---

## V1.0.4 (25/11/2026) — MT AUTO CONVERT ENGINE

| Bộ test | Nội dung | Kết quả |
|---|---|---|
| `test_convert.rb` (14) | Nhận phiên bản Blender, ưu tiên 4.5 LTS, chặn 5.x/quá cũ; đối số kiểm tra dạng danh sách, đường dẫn Unicode/dấu ngoặc kép được trích dẫn an toàn; quy tắc trích dẫn Windows; **tên file độc (`; rm -rf $(…) \`id\` & del`) không chạy qua shell**; timeout và hủy giết tiến trình; dò Blender → chuyển đổi bằng **chính `convert_model.py`** → DAE + báo cáo (số mặt, kích thước, texture nhúng ghi ra file, cảnh báo texture thiếu) → cache (lần 2 không chạy Blender); Blender 5.x bị từ chối; không có Blender → yêu cầu chọn; file không có mặt / Blender crash / quá thời gian → báo lỗi, không rác cache; hủy; định tuyến 12 định dạng; ZIP: giữ texture thư mục con, ưu tiên GLB, chặn `../`; nhập DAE: `DefinitionList#import` → đổi tên → `place_component`, 1 Undo, lỗi thì hoàn tác, cảnh báo lệch kích thước; App: CHÈN file FBX đã tải → chuyển đổi → nhập → đặt | ✅ |
| Toàn bộ test cũ + giao diện | Ruby, giao diện, bàn phím, khởi động từ RBZ | ✅ |

**Quan trọng — chưa kiểm thử với Blender thật:** máy test không cài được Blender (không có mạng). Test dùng “Blender giả” + `bpy` giả lập để chạy
toàn bộ luồng và chính script `convert_model.py`, nhưng các lệnh nhập/xuất thật của Blender 4.5 (`import_scene.fbx/gltf`, `wm.obj_import`, `wm.usd_import`,
`wm.collada_export` và tham số của nó), chất lượng UV/texture trong DAE, và CreateProcessW ẩn cửa sổ trên Windows **cần kiểm tra trên máy thật**.

Checklist trên máy thật: cài Blender 4.5 LTS → Cài đặt › Chuyển đổi › Tự tìm Blender (✓ 4.5.x) → CHÈN 1 model Sketchfab GLB, 1 file FBX có texture,
1 file OBJ + MTL, 1 USDZ, 1 ZIP → model đặt được bằng chuột, đúng kích thước (Tape Measure), có texture, Ctrl+Z gỡ được; trong lúc chuyển đổi SketchUp không treo, không hiện cửa sổ đen; bấm “Hủy chuyển đổi” dừng được.

---


## V1.0.3 (24/11/2026) — chèn thẳng model Sketchfab

| Bộ test | Nội dung | Kết quả |
|---|---|---|
| `test_gltf.rb` (6) | File GLB và glTF+bin+texture rời do `fixtures/make_gltf.py` tạo: node lồng nhau (scale, xoay quaternion, tịnh tiến), dữ liệu xen kẽ (byteStride), chỉ số uint8/uint16, dải tam giác, bỏ primitive dạng đường; đổi mét→inch và Y-up→Z-up đúng tọa độ; lật UV; texture PNG tách ra file; màu + độ trong suốt; chặn Draco, đường dẫn `../`, file hỏng/cắt cụt; dựng component (PolygonMesh, UV, soften, vật liệu, 1 Undo); App: GLB tải về → đọc nền → dựng → đặt; CHÈN Sketchfab ưu tiên GLB | ✅ |
| Toàn bộ test cũ + giao diện | 77 test Ruby, 37 kiểm tra giao diện, 28 kiểm tra bàn phím | ✅ |

Chưa kiểm thử: dựng hình bằng SketchUp API thật (PolygonMesh/UV/texture) trên SketchUp 2022; model Sketchfab thật (phiên này không truy cập được Sketchfab); hiệu năng model rất nặng (> 1 triệu tam giác).

---


## V1.0.2 (24/11/2026) — Unified Search & UI Redesign

| Bộ test | Nội dung | Kết quả |
|---|---|---|
| `test_search_engine.rb` (14) | Mở rộng “ghế sofa / ghe sofa / GHẾ SOFA” → sofa, couch, modern sofa, living room sofa; “bàn ăn gỗ” → dining table wood; lọc liên quan: giữ khớp tên/tag, loại nhân vật/động vật/chỉ khớp mô tả/giới hạn tuổi, bắt buộc khớp đồ vật chính; điểm: SKP chèn ngay > online tải được > chỉ xem; gộp trùng; 5 bộ lọc; danh mục tùy chỉnh; cache LRU/TTL; **kết quả theo đợt** (máy tính hiện ngay, online đến sau), **nguồn lỗi không ảnh hưởng nguồn khác**, **bỏ kết quả truy vấn cũ + hủy request**, tải thêm, danh mục không có từ khóa, yêu thích online; Sketchfab provider: chuẩn hóa, ảnh lớn, ưu tiên định dạng gốc, cache | ✅ |
| `test_app.rb` (+1) | Luồng thật qua dialog: thêm thư mục → quét → `sr_start` → CHÈN (start/commit_operation) → ♡; online không cho tải → mở trang nguồn; cho tải chưa có token → yêu cầu token; yêu thích online lưu vào settings và hiện ở mục Yêu thích; thêm/xóa danh mục; trạng thái 5 nguồn | ✅ |
| `ui/ui_test.js` (37) | Khởi động, 17 danh mục, debounce, đợt 1 (máy tính) rồi đợt 2 (online) cùng lưới và **giữ nguyên thẻ cũ**, XSS tên file, chặn ảnh host lạ, rút gọn tên, **thẻ không có tên website/số mặt/định dạng/dung lượng**, CHÈN/XEM, số đếm bộ lọc, bỏ kết quả cũ, bộ lọc không tìm lại, thanh trượt kích thước, chi tiết (nguồn/tác giả/giấy phép/ảnh lớn/ghi công), tiến độ tải, báo cần chuyển đổi, ♡, danh mục (chọn/thêm/sửa), trạng thái rỗng + nguồn lỗi, cuộn tải thêm, Cài đặt › Nguồn, chữ ô tìm kiếm tối, trình cập nhật | ✅ |
| `ui/input_test.js` (28) | Toàn bộ kiểm tra bàn phím của V1.0.1 trên giao diện mới + gõ tên danh mục tiếng Việt | ✅ |
| Hiệu năng 100.000 model | Lượt tìm đầu 0,16–0,6 giây; tải thêm ~3 ms | ✅ |
| `tools/verify_upgrade.rb` 1.0.1 → 1.0.2 | Cài bằng updater của V1.0.1, dữ liệu người dùng giữ nguyên, khôi phục ngược được | ✅ (xem dưới) |

Chưa kiểm thử: gọi Sketchfab thật từ máy test (proxy chặn; cấu trúc JSON đã đối chiếu phản hồi thật), tải + chèn model Sketchfab thật (cần token),
giao diện mới trong CEF của SketchUp 2022 thật. Bộ lọc danh mục phía Sketchfab dùng lọc theo tên/tag kết quả thay vì tham số `categories` của API
(chưa xác minh được slug danh mục chính thức trong phiên này).

---


## V1.0.1 (24/11/2026) — sửa lỗi ô tìm kiếm

Lỗi thực tế báo từ SketchUp 2022: gõ vào ô tìm kiếm không thấy chữ.

| Kiểm tra | Kết quả |
|---|---|
| Tái hiện lỗi bằng CSS V1.0.0 trên Chromium: `#q` có color/caret/text-fill = rgb(255,255,255) trên nền trắng; là ô duy nhất bị (1/18 ô nhập) | ✅ tái hiện đúng |
| `tests/ui/input_test.js` — 27 kiểm tra bằng bàn phím/chuột thật: màu chữ, con trỏ, placeholder, user-select; focus khi click ô và vùng thanh tìm kiếm; gõ tiếng Anh; debounce (11 ký tự → 1 lần tìm); Backspace/Delete; Enter tìm ngay; Ctrl+A/C/V; tiếng Việt kiểu UniKey (xóa lùi + gõ lại) → “ghế sofa”; kiểu IME ghép dấu (không tìm giữa chừng, tìm sau compositionend); nhận 9 loại dữ liệu từ Ruby không mất từ khóa/focus; Escape; 18 ô nhập khác đủ tương phản và gõ được; ô repo trong trình cập nhật | ✅ 27/27 |
| Toàn bộ test cũ (56 test Ruby, test giao diện, test khởi động từ RBZ) | ✅ |
| `tools/verify_upgrade.rb`: giải nén V1.0.0, dùng **updater của V1.0.0** cài RBZ V1.0.1 → đúng phiên bản, dữ liệu người dùng (settings, chỉ mục, thumbnail, key mã hóa) giữ nguyên byte-by-byte, không trùng loader; khôi phục về V1.0.0 thành công | ✅ |

Chưa kiểm thử: UniKey thật trên Windows trong CEF của SketchUp 2022 (đã mô phỏng cả 2 kiểu gửi phím của UniKey trên Chromium; Chromium bản mới hơn CEF của SketchUp 2022 — tính năng dùng đều có từ Chromium 86 trở xuống, và giao diện V1.0.0 đã hiển thị đúng trên máy thật).

Checklist nhanh sau khi cập nhật lên V1.0.1 (khởi động lại SketchUp trước):
1. Bấm ô tìm kiếm → thấy con trỏ nhấp nháy màu tối.
2. Gõ `ghế sofa` bằng UniKey (Telex/VNI), gõ `modern sofa` → chữ hiển thị rõ, kết quả cập nhật sau khoảng 0,2 giây.
3. Ctrl+A, Ctrl+C, Ctrl+V, Backspace, Delete, Enter, Escape hoạt động.
4. Cài đặt: gõ vào các ô key/model/timeout bình thường.

---

## V1.0.0

Ngày: 24/11/2026. Môi trường kiểm thử tự động: Linux, Ruby 3.3.6 (stub SketchUp/UI), Chrome headless (Playwright).
**Chưa chạy trong SketchUp 2022 thật trên Windows** → cần chạy checklist mục 3 trước khi dùng chính thức.

## 1. Đã kiểm thử tự động (56 test, 330 assertion, 0 lỗi + test giao diện)

| Bộ test | Nội dung | Kết quả |
|---|---|---|
| `test_core.rb` (28) | Bỏ dấu tiếng Việt (cả NFD), chuẩn hóa đường dẫn Windows/UNC, file URL Unicode, ghi atomic + .bak; so sánh phiên bản; che key trong log; settings: chuyển đổi bản cũ, file hỏng → khôi phục .bak, whitelist (không lưu key), chỉ nhận URL https; tìm kiếm: không dấu, Việt↔Anh, từ ngắn, “da/đá”, any_of, lọc, sắp xếp, phân trang; **hiệu năng 100.000 model: ~0,30 s/lượt tìm, lật trang 0,1 ms**; parse Sketchfab (chặn ảnh ngoài media.sketchfab.com, cursor độc hại); link nguồn; AI: nhận dạng ảnh theo magic bytes, body JSON schema, phương án dự phòng 400, parse kết quả/refusal, thông báo 401/429 | ✅ |
| `test_indexer_http.rb` (9) | Quét thư mục tên tiếng Việt, file `.SKP` hoa, bỏ thư mục ẩn/`$RECYCLE.BIN`, **symlink vòng lặp**, symlink hỏng, **tên file sai UTF-8 → lỗi riêng từng file**; cache schema, nạp lại từ cache; quét nhanh phát hiện file thêm/xóa và tái dùng cache; **root offline giữ dữ liệu cũ**; **đổi root khi đang quét → hủy và quét lại đúng root mới**; hủy quét; cache hỏng; thumbnail queue + đánh dấu lỗi không tạo lại. HTTP mock: 200/401/**timeout**/lỗi mạng/**redirect không chuyển Authorization sang host khác**/tải file có tiến độ | ✅ |
| `test_updater.rb` (13) | **Chu trình đầy đủ**: kiểm tra gói → sao lưu → cài đè → dọn file thừa → không loader trùng → **dữ liệu người dùng giữ nguyên byte-by-byte** → khôi phục bản trước; **tự rollback khi lỗi giữa chừng** (thư mục plugin trở về y nguyên); ZIP có thư mục bọc ngoài; sai PLUGIN_ID; không tương thích SketchUp → chặn; hạ cấp; **đường dẫn nguy hiểm** (`../`, tuyệt đối, `C:`, `\`, `con.rb`, ADS `:`), **symlink trong zip**; thiếu file; file rác; **CRC hỏng**; kiểm tra manifest; **online: manifest + tải gói + SHA256 sai bị từ chối + cài thành công**; giới hạn số bản sao lưu; báo cáo sau khởi động | ✅ |
| `test_app.rb` (5) | **Vòng đời dialog**: không gửi dữ liệu trước `ready`, mở lại không tạo dialog/timer mới, đóng → timer dừng, mở lại → dialog mới, callback không trùng; luồng thêm thư mục → quét → tìm → thumbnail → chèn (start/commit_operation) → lịch sử → yêu thích; file SKP mới hơn → hỏi trong giao diện rồi `allow_newer`; xóa root; **API key không xuất hiện trong dữ liệu gửi HTML, log, settings.json** (kể cả khi API trả lỗi chứa key); AI không gửi ảnh khi chưa xác nhận; trình cập nhật: gói cùng phiên bản → hỏi xác nhận, nguồn chưa cấu hình → báo lỗi, lưu nguồn GitHub | ✅ |
| `test_boot.rb` (1) | Giải nén **chính file RBZ đã build** vào Plugins giả, nạp như SketchUp, nạp lại lần 2: 1 extension, 1 toolbar, 1 menu, icon tồn tại, không ghi dữ liệu vào thư mục plugin | ✅ |
| `ui/ui_test.js` | Chrome headless mở `index.html`/`update_dialog.html` qua `file://` với CSP thật: script chạy, tên file chứa `<img onerror>` hiển thị dạng chữ (không thực thi), thumbnail `javascript:` bị chặn, ảnh Sketchfab từ host lạ bị chặn, AI any_of, tiến trình/kết quả cập nhật; 0 lỗi console | ✅ |
| `tools/build.rb` | `ruby -wc` 21 file (0 cảnh báo), `node --check` 2 file JS, JSON hợp lệ, đồng bộ phiên bản, RBZ gốc phẳng, tự kiểm tra RBZ bằng `Updater.inspect_package` | ✅ |

Ruby 2.7.2: mã không dùng cú pháp riêng Ruby 3.x (đã rà soát thủ công: không pattern matching, endless method, `Hash#except`, `Queue#pop(timeout:)`…). Chưa chạy bằng trình thông dịch 2.7.2 thật.

## 2. Chưa kiểm thử (cần máy Windows + SketchUp 2022)

| Hạng mục | Lý do |
|---|---|
| Chạy trong SketchUp 2022 thật (CEF HtmlDialog, cầu nối `sketchup.*`, `execute_script` với CSP) | Không có SketchUp trong môi trường build |
| `Sketchup.save_thumbnail`, `definitions.load(allow_newer:)`, `place_component`, `model.import` thật | Như trên |
| Quét ổ mạng/ổ ngoài thật trên Windows, đường dẫn > 260 ký tự | Như trên |
| Đổi tên thư mục plugin khi cập nhật trên Windows (có thể bị khóa file → nhánh dự phòng ghi đè từng file) | Như trên |
| Lưu key mã hóa DPAPI (`crypt32.dll` qua Fiddle) | Chỉ có trên Windows |
| HTTPS bằng Net::HTTP trong SketchUp 2022 (chứng chỉ) và nhánh dự phòng `Sketchup::Http` | Như trên |
| Gọi OpenAI thật | Không có API key (đã test bằng máy chủ giả lập) |
| Sketchfab search/download thật | Proxy môi trường build chặn api.sketchfab.com; cấu trúc JSON đã đối chiếu với phản hồi thật lấy qua công cụ web; download cần token |
| GitHub Releases thật | Chưa có repo phát hành |
| URL tìm kiếm 3dsky / CGTrader | Theo mẫu URL công khai; cần bấm thử |

## 3. Checklist kiểm thử trong SketchUp 2022

1. Cài RBZ qua Extension Manager → khởi động lại → toolbar có 2 nút; menu Extensions › MT SMART LIBRARY PRO có 3 mục, không trùng.
2. Mở thư viện → *+ Thêm thư mục* chọn thư mục có tên tiếng Việt → thanh tiến độ chạy, *Hủy quét* hoạt động.
3. Thêm thư mục ổ mạng `\\server\share\...` → quét được; rút mạng → *Quét lại* → báo “Không truy cập được”, thư viện cũ vẫn còn.
4. Gõ `ghe sofa`, `bàn ăn`, `chair`, `den` → kết quả đúng; đổi trang, lọc dung lượng, sắp xếp.
5. Cuộn → thumbnail hiện dần, SketchUp không giật; thư viện lớn (≥ 10.000 file) tìm kiếm < 1 giây.
6. *Chèn* → model bám chuột, đặt được; Ctrl+Z gỡ được; vật liệu/tỉ lệ đúng. Thử 1 file SKP hỏng và 1 file SketchUp 2024 → thông báo rõ.
7. ☆ yêu thích, tab Yêu thích/Lịch sử; đóng/mở lại SketchUp → vẫn còn.
8. Đóng dialog → mở lại nhiều lần → không lỗi, không nhân đôi thao tác.
9. Online: các nút 3D Warehouse/3dsky/CGTrader mở đúng trang; *Tìm trên Sketchfab* hiện ảnh, tác giả, giấy phép; *Sau ›/‹ Trước*.
10. Cài đặt › Sketchfab: nhập token → *Tải* GLTF 1 model cho phép tải → tiến độ → có `ATTRIBUTION.txt`, nút *Mở thư mục tải về*.
11. Cài đặt › AI: nhập key → *Kiểm tra API* → ✓. *✦ Tìm bằng ảnh AI* → chọn ảnh → xem trước → *Đồng ý gửi* → có loại/phong cách/vật liệu/màu + từ khóa → *Tìm Offline*.
12. Thử key sai → thông báo 401; tắt mạng → thông báo không kết nối.
13. Tick *Ghi nhớ trên máy này* → khởi động lại SketchUp → key vẫn có; mở `settings.json` và log → không thấy key.
14. ⟳ CẬP NHẬT › *Chọn file cập nhật…* chọn một bản 1.0.1 thử nghiệm (build bằng cách đổi VERSION) → cài → thông báo khởi động lại → khởi động lại → phiên bản 1.0.1, thư viện/yêu thích/lịch sử còn nguyên.
15. *Khôi phục* bản 1.0.0 → khởi động lại → về 1.0.0.
16. Chọn file RBZ của plugin khác → bị từ chối với thông báo mã định danh.

## 4. Lấy log khi có lỗi
- **Ruby Console**: SketchUp 2022 › *Extensions › Developer › Ruby Console* (hoặc *Window › Ruby Console*). Chạy lệnh
  `MTDesign::SmartLibrary::App.instance.log.echo = true` để in log trực tiếp ra console, rồi lặp lại thao tác lỗi.
- **File log**: `%LOCALAPPDATA%\MT_Smart_Library\logs\mt_smart_library.log` và `update.log`
  (Cài đặt › *Mở thư mục log*). Log đã tự che key/token.
- Gửi kèm: phiên bản SketchUp (Help › About), ảnh chụp thông báo lỗi, 50 dòng cuối file log.
