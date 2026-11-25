# CHANGELOG — MT SMART LIBRARY PRO

## V1.0.12 — 25/11/2026 (SMART SOURCE EXTRACTOR + HYBRID HOT RELOAD)
- `ai_runtime/source_extractor.py` (làn tiến trình `crawl`, tách khỏi tìm kiếm và lập chỉ mục):
  - `wp_rest`: liệt kê toàn bộ bài viết qua WordPress REST API (nội dung, danh mục, ảnh đại diện), đồng bộ tăng dần bằng `modified_after`;
  - `sitemap`: web crawler theo sitemap.xml/sitemap index, tuân thủ robots.txt (`can_fetch`, `Crawl-delay`, tối thiểu 1,5 s/trang), chỉ lấy trang có og:title + ảnh xem trước;
  - `gdrive`: Google Drive API v3 chính thức với API key người dùng — thư mục chia sẻ công khai, đệ quy 4 cấp, ảnh cùng tên làm ảnh xem trước, link tải `alt=media` (khóa không lưu vào kho);
  - `index`: Brave Search API (key người dùng) — bài Facebook CÔNG KHAI đã được lập chỉ mục (Groups API đã bị Meta gỡ).
  Trích xuất: tên, mô tả, danh mục, ảnh, link bài viết, link tải (thẻ `<a>` + URL dạng chữ; Drive/MediaFire/Mega/Dropbox/OneDrive/file trực tiếp/link rút gọn; bỏ link mạng xã hội), mật khẩu giải nén.
  Nhật ký từng nguồn (`ai_runtime/work/crawl/<id>.log`), trạng thái đồng bộ, giới hạn số trang mỗi lần, dừng giữa chừng.
- Kho dữ liệu (SQLite): thêm cột tìm kiếm không dấu + có link tải (nâng cấp bảng cũ, giữ dữ liệu); `catalog_text` (tìm từ khóa), `catalog_embed` (vector ảnh trên làn index), `catalog_source_stats`.
- `Providers::CatalogProvider`: tìm từ khóa Việt/Anh trong kho, trộn vào lưới chung; tìm bằng ảnh dùng vector của model đã trích xuất.
- CHÈN model từ kho: link Drive API/Dropbox/file trực tiếp → tải, nhận diện file thật, giải nén (kể cả mật khẩu đã trích xuất), chèn; trang trung gian → mở trình duyệt + tự nhận file vừa tải.
- Cài đặt › Nguồn tìm kiếm: Kiểm tra kết nối, Quét (toàn bộ), Đồng bộ (phần mới), Dừng, Nhật ký; số model đã lập chỉ mục / có link tải / có vector, thời gian đồng bộ, tiến trình.
- Tài khoản thư viện: Google API key, Brave Search API key (DPAPI, không ghi settings/log; chỉ truyền cho tiến trình trích xuất qua biến môi trường lúc khởi động).
- `updater/hot_reload.rb` — HYBRID HOT RELOAD: tự phân loại gói (so SHA256 từng file với bản đang cài). Chỉ đổi giao diện, Python, cấu hình JSON, tài nguyên,
  hoặc module Ruby thuần hàm được khai báo (version, wp_sources, site_probe, link_import, query_normalizer, categories, synonyms) → **cập nhật nhanh**:
  sao lưu → cài → kiểm tra → nạp lại module, tiến trình Python khởi động lại khi rảnh, giao diện tải lại trên chính dialog (callback giữ nguyên);
  không chạy lại main.rb nên không trùng menu/toolbar/callback/timer/observer. Đổi phần lõi, loader hoặc xóa file Ruby → **cập nhật hệ thống**: chờ người dùng tự khởi động lại.
  Áp dụng nóng lỗi → tự chuyển sang chờ khởi động lại. Hộp cập nhật hiển thị loại cập nhật + lý do trước khi cài.

## V1.0.11 — 25/11/2026 (SMART SOURCE MANAGER)
- `sources/source_registry.rb`: danh sách nguồn của người dùng ở `<dữ liệu>/sources.json` (không nằm trong mã, giữ qua cập nhật): 9 loại
  (website, Facebook Group, Facebook Fanpage, Google Drive, MediaFire, Mega, Dropbox, OneDrive, thư mục máy tính), tự nhận diện loại theo link,
  thêm/sửa/xóa/bật-tắt, xuất/nhập JSON (chỉ nhận trường an toàn, bỏ trùng). Nguồn có sẵn trộn vào danh sách (chỉ bật/tắt).
- `sources/site_probe.rb`: website mới → đọc robots.txt (nhóm `*`, Allow/Disallow dài nhất thắng) → thử WordPress REST API lõi; đạt thì thành
  nguồn tìm kiếm thật (WpProvider dùng chung, ảnh chỉ nhận tên miền của trang + tên miền con); 401/403 → “cần đăng nhập”; không có API → mở nguồn + nhập link.
- Facebook: Meta đã gỡ Groups API (22/04/2024) và đọc Fanpage cần quyền Meta duyệt → nguồn được giữ, trạng thái “Cần đăng nhập trên trình duyệt”, có Mở nguồn + nhập link.
- `sources/link_import.rb` (“Nhập link model”): Dropbox (`dl=1` theo hướng dẫn chính thức) và link file trực tiếp → tải, nhận diện loại file thật theo nội dung
  (ZIP/SKP/GLB/RAR/7z; trang HTML bị loại) → chèn; Facebook/Drive/MediaFire/Mega/OneDrive → mở trình duyệt + tự nhận file vừa tải.
- Kho dữ liệu tích lũy (SQLite trong tiến trình AI, `catalog.sqlite`): lưu metadata kết quả online (không tải file SKP), vector ảnh xem trước,
  đánh dấu trùng (ảnh gần như giống hệt từ nguồn khác, cosine ≥ 0.97), kiểm tra link (tối đa 4 kết nối), thống kê, xóa cache (kèm ảnh xem trước).
  Tìm bằng ảnh dùng lại kho ngay (không cần mạng), bỏ nguồn đang tắt và link đã mất.
- `ai_runtime/worker_lane.rb`: 2 làn tiến trình AI độc lập — `search` (tìm bằng ảnh, so sánh online, kho dữ liệu; 2 luồng) và `index` (lập chỉ mục thư viện; 1 luồng);
  mỗi làn có hàng đợi, log, chống vòng lặp lỗi riêng; làn tìm kiếm tự nạp lại chỉ mục khi làn lập chỉ mục cập nhật.
- CSP ảnh cho phép https; giao diện chỉ hiển thị ảnh từ host nguồn có sẵn hoặc tên miền của nguồn người dùng đã xác minh.

## V1.0.10 — 25/11/2026 (Sửa tiến trình AI tìm bằng ảnh)
- Nguyên nhân (người dùng kiểm tra trên máy): Vision model gây Windows fatal exception (access violation) khi nạp bằng DirectML
  (`_create_inference_session`); worker sập → việc tồn đọng, báo lỗi mỗi 30 giây.
- `inference_worker.py`: `_session` mặc định CPUExecutionProvider; DirectML chỉ khi người dùng chọn GPU (SessionOptions đúng yêu cầu DirectML:
  tắt mem pattern, chạy tuần tự). Ghi stdout/stderr + faulthandler (mọi luồng) vào `worker.log` ngay từ đầu; lỗi import/DLL/mô hình ghi `worker.error.json` kèm traceback.
  Chế độ `--probe-gpu`: nạp 2 mô hình bằng DirectML + chạy thử trong tiến trình riêng.
- `runtime_manager.rb`: tùy chọn thiết bị (cài đặt `ai.device`, mặc định cpu); GPU phải qua bài kiểm tra riêng (kết quả lưu `gpu_probe.json`, chọn lại GPU thì kiểm tra lại);
  worker GPU sập → ghi nhận, tự chạy lại bằng CPU và gửi lại việc dở; CPU sập 2 lần/5 phút hoặc lỗi nạp → dừng hẳn, dọn hàng đợi, báo lỗi 1 lần kèm mã thoát (0xC0000005…) và log;
  tự thoát do rảnh không tính là lỗi; phiên mới dọn việc tồn đọng; mã thoát Windows hiển thị dạng hex.
- Không tạo việc lặp: lập chỉ mục chỉ chạy khi bộ AI sẵn sàng; lỗi không thử lại liên tục; người dùng chủ động tìm lại thì thử lại 1 lần.
- Cài đặt › AI: “Tìm bằng ảnh chạy trên CPU / GPU DirectML (thử nghiệm)”. Hỗ trợ kỹ thuật: “Cài lại thành phần AI (giữ mô hình)”, “Mở log AI”.
- Giữ nguyên bộ AI đã tải (Python, thư viện, mô hình 330 MB) — không tải lại.

## V1.0.9 — 25/11/2026 (MT VISUAL SEARCH ENGINE)
- `ai_runtime/inference_worker.py`: tiến trình AI độc lập (Python + ONNX Runtime, CPU; DirectML nếu GPU tương thích), mô hình CLIP ViT-B/32 ONNX
  (vision + text). Tiền xử lý ảnh chuẩn CLIP, nền trong suốt → trắng, cắt vùng; vector ảnh L2; tokenizer BPE của CLIP cho vector văn bản.
  Công việc: nhận diện ảnh mẫu (vector + nhóm đồ vật zero-shot), tìm trong chỉ mục, cập nhật chỉ mục theo đợt, xếp hạng thumbnail online.
  Giao tiếp qua thư mục công việc (atomic), tự thoát khi SketchUp đóng (heartbeat) hoặc rảnh lâu.
- Chỉ mục vector thư viện máy tính (`vectors.npy` float16 + `ids.json`): lấy ảnh xem trước nhúng trong SKP / thumbnail plugin / ảnh cùng tên;
  chỉ tính model mới hoặc đổi (mtime+size), xóa model không còn; model không có ảnh được tách riêng (không giả lập); chạy nền theo đợt 64 ảnh.
- `ai_runtime/runtime_manager.rb`: cài 1 lần sau khi người dùng đồng ý — Python nhúng 3.11 (python.org) → pip (bootstrap.pypa.io) →
  onnxruntime-directml (lỗi thì onnxruntime) + numpy + pillow (PyPI) → mô hình (Hugging Face Xenova/clip-vit-base-patch32, kiểm SHA256 / git SHA1).
  Lưu ở `%LOCALAPPDATA%\MT_Smart_Library\ai_runtime`. Tiến trình chạy không cửa sổ, đối số dạng danh sách.
- `visual_search/visual_search_manager.rb`: ảnh mẫu → vector → (1) so với chỉ mục máy tính, hiện ngay; (2) nhóm đồ vật → từ khóa →
  lấy ứng viên mọi nguồn online đang bật → tải thumbnail (chỉ host được phép) → vector → so sánh → trộn chung, xếp theo cosine, bỏ điểm thấp.
- Giao diện: nút 📷 Tìm bằng ảnh mở chọn ảnh ngay (không còn chuyển sang Cài đặt OpenAI); dán Ctrl+V, kéo thả, Đổi ảnh, Cắt vùng, Hủy, Xóa ảnh mẫu;
  tiến trình Đang nhận diện / Đang tìm / Đang so sánh; chi tiết model ghi “Tương đồng ảnh 0.xx (cosine CLIP, không phải xác suất)”.
- OpenAI giữ làm tùy chọn (Cài đặt › AI › “phân tích ảnh bằng OpenAI”).
- SearchManager: chế độ `loose` (bỏ lọc theo tên) cho ứng viên tìm bằng ảnh; ZipReader dùng giải nén Python nhúng.

## V1.0.8 — 25/11/2026 (Multi-Source Library Engine)
- `online/wp_sources.rb` + `search/providers/wp_provider.rb`: 3 thư viện SketchUp có WordPress REST API công khai (đã kiểm JSON thật):
  sketchup.cgtips.org, sketchupfree.com, thuviensketchup.vn. Tìm theo từ khóa (trang Việt: từ khóa gốc; trang Anh: bản dịch), ảnh từ /media, phân trang, cache.
- Nguồn không cho tải tự động: nút XEM mở trang chính thức; `core/download_watcher.rb` theo dõi thư mục Downloads 30 phút, nhận file vừa tải
  (bỏ file đang tải dở, chờ dung lượng ổn định) → thanh “Chèn vào SketchUp?” → CHÈN. Giải nén vào thư mục dữ liệu plugin (không xả rác Downloads).
- ZipReader: hỗ trợ ZIP mã hóa ZipCrypto với mật khẩu do trang nguồn công bố, tên file không UTF-8; gói cập nhật plugin vẫn chặn file mã hóa như cũ.
- `accounts/account_manager.rb`: tab “Tài khoản thư viện” — 12 website với trạng thái Đã kết nối / Chưa đăng nhập / Không cần đăng nhập / Phiên hết hạn
  (Sketchfab 401) / Cần cấp quyền API / Chưa xác minh; nút ĐĂNG NHẬP, Đăng xuất, Kết nối lại, Mở trang. Không hỏi mật khẩu, không đọc cookie.
- Nguồn chưa tích hợp được (3D Warehouse, CGTrader, 3dsky, 3dbox, Sketch Shaper, Tài liệu kiến trúc, sketchup.vn) giữ trong danh sách kèm lý do — xem docs/BAO_CAO_NGUON_THU_VIEN.md.

## V1.0.7 — 25/11/2026 (Mở rộng nguồn thư viện)
- Nguồn mới **Poly Haven** (`online/polyhaven.rb`, `search/providers/polyhaven_provider.rb`) qua API chính thức api.polyhaven.com:
  miễn phí mọi mục đích, không cần key; gửi User-Agent riêng; ghi nguồn “Poly Haven” ở chi tiết/tooltip và ATTRIBUTION.txt (điều kiện của API).
  Danh mục model tải 1 lần, lưu đĩa 24 giờ, tìm tức thì bằng từ khóa Việt/Anh; mất mạng vẫn dùng bản đã lưu.
  CHÈN: lấy /files/{id} → tải glTF 2k (hoặc 1k/4k) + bin + texture, kiểm MD5 từng file, giữ thư mục textures/ → bộ đọc glTF tích hợp chèn thẳng.
- Cài đặt › Nguồn tìm kiếm: ô bật/tắt cho từng nguồn đã tích hợp (ghi nhớ; mặc định bật). Bỏ ô riêng “Bật nguồn Sketchfab”.
- 3D Warehouse / CGTrader / 3dsky: vẫn chưa tích hợp vì không có API công khai hợp lệ cho plugin (ghi rõ lý do).

## V1.0.6 — 25/11/2026 (Đơn giản hóa cài đặt)
- Bỏ tab “Chuyển đổi” và “Mạng & dữ liệu”; Cài đặt còn 4 tab: Thư viện, Nguồn tìm kiếm, AI, Tài khoản Sketchfab.
- Bỏ các ô thông số kỹ thuật (thời gian chờ mạng/chuyển đổi, cách đọc glTF): dùng mặc định tự quản lý; glTF luôn ưu tiên bộ đọc tích hợp, lỗi mới dùng Blender.
- Công cụ chẩn đoán (Blender: tìm lại/chọn/tải, xóa cache chuyển đổi, kiểm tra kết nối, mở thư mục dữ liệu/log, xóa cache ảnh) chuyển sang bảng
  “Hỗ trợ kỹ thuật” mở từ menu Extensions › MT SMART LIBRARY PRO. Khi thiếu Blender, hộp hướng dẫn cài vẫn tự hiện như cũ.
- Nút “Chèn file từ máy…” (SKP/GLB/FBX/OBJ/DAE/USDZ/ZIP…) chuyển vào tab Thư viện.
- Không đổi: bộ máy chuyển đổi, hệ thống cập nhật, token/API key, thư viện cá nhân.

## V1.0.5 — 25/11/2026
- Sửa: bật/tắt nguồn Sketchfab cập nhật nhãn trạng thái ngay (trước đây vẫn hiện “Đang dùng” khi đã tắt → khó nhận ra vì sao không có kết quả online).
- Ô “Tìm trên Sketchfab” → “Bật nguồn Sketchfab (tìm online)”; mô tả nguồn Sketchfab cập nhật theo V1.0.4.

## V1.0.4 — 25/11/2026 (MT AUTO CONVERT ENGINE)
- Module `convert/`: `converter_manager.rb`, `blender_detector.rb`, `blender_runner.rb`, `convert_model.py`, `import_manager.rb`, `model_cache.rb`.
- Một nút CHÈN cho mọi định dạng: SKP (nạp trực tiếp), GLB/glTF (bộ đọc tích hợp; lỗi/nén Draco → Blender), DAE (`DefinitionList#import`),
  FBX/OBJ/USD/USDZ/PLY/BLEND (Blender → DAE → `DefinitionList#import`), 3DS/KMZ/DWG/DXF/STL (importer SketchUp; STL lỗi → Blender), ZIP (giải nén an toàn, tự chọn file chính).
- Blender nền: tự tìm (Program Files, Steam, Portable, PATH, đường dẫn người dùng chọn), kiểm tra phiên bản và khả năng xuất DAE trước khi dùng,
  không dùng Blender 5.x để xuất DAE; chạy `--background --factory-startup --disable-autoexec --python-exit-code 1`; danh sách đối số (không shell);
  Windows dùng CreateProcessW + CREATE_NO_WINDOW (không hiện cửa sổ), dự phòng `Process.spawn`; timeout, nút Hủy; không chặn SketchUp.
- `convert_model.py`: nhập theo định dạng, chuyển chữ/đường cong thành lưới, kiểm tra hình học, ghi texture nhúng ra file, giữ texture thư mục con,
  xuất DAE (Z-up, đơn vị mét, không giảm polygon), báo cáo JSON (số mặt, kích thước, texture, cảnh báo); mã thoát rõ ràng.
- Kiểm tra exit code + báo cáo + file DAE trước khi nhập; nhập trong 1 thao tác Undo, lỗi thì hoàn tác (không rác); so kích thước với file gốc.
- Cache kết quả chuyển đổi theo SHA256 file nguồn (tối đa 3 GB, tự dọn).
- Cài đặt › Chuyển đổi: trạng thái Blender, Tự tìm / Chọn blender.exe / Tải Blender 4.5 LTS, thời gian chờ, cách đọc glTF, xóa cache.

## V1.0.3 — 24/11/2026
- Bộ nhập glTF 2.0 tích hợp (`importers/gltf_importer.rb`): đọc GLB/glTF (node lồng nhau, ma trận/TRS, dữ liệu xen kẽ, dải/quạt tam giác,
  chỉ số uint8/16/32, vật liệu màu + texture PNG/JPG nhúng hoặc file rời), đổi mét→inch và trục Y-up→Z-up; đọc file ở luồng nền, dựng hình bằng
  PolygonMesh ở main thread, 1 bước Undo, đặt bằng chuột. Không hỗ trợ glTF nén Draco/meshopt (báo rõ).
- CHÈN model Sketchfab: ưu tiên tải GLB → tự chèn. Chưa có token: hộp dán token 1 bước rồi tự tải và chèn.
- Nhập file 3D thủ công nhận GLB/glTF.

## V1.0.2 — 24/11/2026 (Unified Search & UI Redesign)

### Giao diện mới
- Thanh trên: logo, ô tìm kiếm lớn + nút Tìm, Tìm bằng ảnh (AI), Cập nhật, Cài đặt.
- Thanh danh mục bên trái: Tất cả, Sofa, Ghế, Bàn, Tủ kệ, Giường, Đèn, Cây xanh, Đồ bếp, Thiết bị vệ sinh, Rèm cửa, Trang trí, Ngoại thất,
  Thư viện cá nhân, Yêu thích, Lịch sử. Thêm/sửa/xóa danh mục tùy chỉnh (tên + từ khóa Việt/Anh).
- Lưới ảnh vuông thống nhất, kích thước chỉnh bằng thanh trượt, số cột tự động theo độ rộng cửa sổ; thẻ chỉ có ảnh, tên ngắn, ♡ và CHÈN.
- Không còn tên website, số mặt, định dạng, đoạn hướng dẫn trên thẻ. Bấm ảnh → cửa sổ chi tiết: ảnh lớn, nguồn, tác giả, giấy phép, định dạng,
  dung lượng/đường dẫn, nút sao chép ghi công.
- Cài đặt gom vào một cửa sổ có tab: Thư viện, Nguồn tìm kiếm, AI, Tài khoản Sketchfab, Mạng & dữ liệu.

### Unified Search Engine (`search/`)
- `query_normalizer.rb`: có dấu/không dấu, tách cụm theo từ điển, dịch Việt→Anh, mở rộng từ khóa (ghế sofa → sofa, couch, modern sofa, living room sofa) — không gọi AI.
- `search_manager.rb`: gửi đồng thời tới mọi nguồn, nhận kết quả theo đợt và cập nhật lưới ngay, hủy truy vấn cũ, timeout riêng từng nguồn,
  một nguồn lỗi không ảnh hưởng nguồn khác, tải thêm khi cuộn.
- `result_ranker.rb`: chuẩn hóa, loại kết quả không liên quan (chỉ chấp nhận khớp tên/tag; loại nhân vật, động vật, nội dung giới hạn tuổi), loại trùng,
  xếp hạng theo liên quan, danh mục, ảnh, quyền tải, SKP, chèn ngay, chất lượng, dung lượng — không ưu tiên website.
- `result_cache.rb`: cache kết quả online (LRU, 10 phút). `providers/`: `base_provider`, `local_provider`, `sketchfab_provider`.
- Bộ lọc: Tất cả / Máy tính / Online / Chèn được ngay / Miễn phí (lọc tại chỗ, không tìm lại).
- 3D Warehouse, CGTrader, 3dsky: chưa có phương thức truy cập hợp lệ → ghi rõ giới hạn trong Cài đặt › Nguồn tìm kiếm, không giả lập.

### Chèn model một nút
- File SKP trên máy: chèn ngay. Model online được phép tải: tự chọn định dạng (ưu tiên bản gốc, sau đó glTF), tải, tự chèn/nhập nếu SketchUp đọc được,
  báo rõ khi cần chuyển đổi; model chỉ xem: mở trang nguồn. Tùy chọn tự lưu model tải về vào Thư viện cá nhân.
- Yêu thích cả model online (lưu ảnh chụp thông tin, xem lại khi offline).

### Giữ nguyên
- MT SMART UPDATE SYSTEM, dữ liệu thư viện, chỉ mục, thumbnail, yêu thích, lịch sử, API key, cài đặt. Sửa lỗi chữ trắng của V1.0.1 được giữ.

## V1.0.1 — 24/11/2026 (bản sửa lỗi)

- **Sửa lỗi**: gõ vào ô tìm kiếm không thấy chữ trên SketchUp 2022. Nguyên nhân: `input` dùng `color: inherit` nằm trong thanh `.top` có `color: #fff` → chữ trắng trên nền trắng (chỉ ô `#q` bị; 17 ô nhập khác không bị).
- Mọi `input/select/textarea` có màu chữ, `-webkit-text-fill-color`, `caret-color`, placeholder và `user-select: text` riêng; ô tìm kiếm áp dụng đúng khối CSS yêu cầu.
- Ô tìm kiếm: hỗ trợ bộ gõ ghép dấu (UniKey chế độ TSF/IME) — không gửi tìm kiếm giữa chừng khi đang ghép dấu; Enter tìm ngay; Escape xóa từ khóa; bấm vào vùng thanh tìm kiếm là nhận focus; gõ ở tab Online không gửi tìm offline thừa.
- Trình cập nhật: thông báo “chưa cấu hình nguồn online” chỉ đúng vị trí (mục 2 trong cửa sổ Cập nhật).
- Thêm bộ test bàn phím thật trên Chromium (27 kiểm tra): focus, tiếng Anh, UniKey, IME, Ctrl+A/C/V, Backspace/Delete/Enter/Escape, debounce, giữ từ khóa khi nhận dữ liệu từ Ruby, màu chữ của toàn bộ ô nhập.
- Không thay đổi chức năng khác; MT SMART UPDATE SYSTEM giữ nguyên. Không có chức năng Smart Placement/Curtain/Wall/Ceiling/Parametric Library trong mã nguồn.

## V1.0.0 — 24/11/2026

Viết lại toàn bộ từ bản mẫu (xem `docs/REVIEW_MA_NGUON_CU.md` — 15 lỗi thực tế của bản mẫu đã được xử lý).

### Thư viện Offline
- Quét thư mục trong luồng nền thuần Ruby: tiến độ, hủy quét, tự quét lại khi thêm/xóa thư mục trong lúc đang quét.
- Đường dẫn Unicode tiếng Việt (đọc thư mục với encoding UTF-8), ổ mạng UNC, ổ ngoài; bỏ qua symlink (chống vòng lặp),
  thư mục ẩn, `$RECYCLE.BIN`; lỗi từng file được ghi riêng, không làm dừng cả lượt quét.
- Cache chỉ mục `index_cache.json` (schema 2, ghi atomic): mở plugin hiển thị ngay; *Quét nhanh* chỉ đọc lại thư mục có thay đổi.
  Ổ mạng tạm mất kết nối → giữ dữ liệu cũ, đánh dấu “Không truy cập được”.
- Tìm kiếm ở Ruby, chỉ gửi 1 trang sang giao diện: không dấu, từ đồng nghĩa Việt/Anh (~200 cụm), xếp hạng liên quan,
  lọc thư mục gốc/dung lượng, 7 kiểu sắp xếp, phân trang có cache. 100.000 model: ~0,3 giây/lượt tìm, lật trang < 1 ms (máy test).
- Thumbnail: `Sketchup.save_thumbnail` (đọc ảnh preview trong SKP, không nạp model), lazy-load theo vùng nhìn thấy,
  hàng đợi giới hạn thời gian mỗi nhịp, cache theo id+mtime+size, ghi nhớ file không có ảnh.
- Chèn model: `definitions.load` + `place_component`, bọc `start_operation` (Undo 1 bước), báo lỗi rõ file hỏng/ổ mất kết nối;
  file SKP phiên bản mới hơn → hỏi xác nhận rồi thử `allow_newer`. Không xóa đối tượng hiện có.
- ID model giữ nguyên cách tính bản cũ (SHA256 đường dẫn) → yêu thích/lịch sử cũ được giữ.

### Online
- Adapter mở trang tìm kiếm chính thức: 3D Warehouse, Sketchfab, 3dsky, CGTrader, Google (SKP).
- Sketchfab Data API v3 `/v3/search`: thumbnail, tên, tác giả, giấy phép, link nguồn, phân trang cursor ngay trong plugin.
- Sketchfab Download API (cần token): tải glTF/GLB/USDZ có tiến độ, kèm `ATTRIBUTION.txt`; giải nén an toàn; nêu rõ SketchUp 2022
  không nhập trực tiếp glTF/GLB. Nút *Nhập file 3D* cho DAE/3DS/KMZ/STL… sau khi chuyển đổi.
- Trạng thái mạng, timeout cấu hình được, mở trình duyệt khi API lỗi.

### AI
- Chọn ảnh → xem trước → xác nhận rõ endpoint/model/phí → mới gửi. Ảnh thu nhỏ ≤ 1280 px trước khi gửi.
- OpenAI Chat Completions + vision + structured outputs (JSON schema) trả `object_type, style, material, color, queries_vi, queries_en`;
  tự thử lại khi model không hỗ trợ `reasoning_effort`/`json_schema`/`max_completion_tokens`.
- Thông báo lỗi cụ thể 401/403/404/429 (rate limit vs insufficient_quota)/5xx/timeout/SSL. Kiểm tra API không tốn phí.
- Key: bộ nhớ phiên, biến môi trường, hoặc tùy chọn lưu mã hóa DPAPI; không ghi vào settings/log/HTML (đã kiểm thử).
- Từ khóa AI sửa được; tìm offline theo tất cả từ khóa (OR), tìm Sketchfab, mở 3D Warehouse.

### MT SMART UPDATE SYSTEM (mới)
- Cập nhật từ file RBZ/ZIP và online (manifest JSON hoặc GitHub Releases), không cần gỡ bản cũ.
- Kiểm tra cấu trúc, PLUGIN_ID, phiên bản, tương thích, CRC, SHA256, chặn đường dẫn nguy hiểm/symlink/ZIP64/mã hóa.
- Sao lưu tự động, cài đè, kiểm tra sau cài, tự khôi phục khi lỗi; khôi phục phiên bản trước; nhật ký `update.log` + lịch sử.
- Không nạp nóng mã → không trùng menu/toolbar/callback; thông báo khởi động lại, nhắc lưu bản vẽ, không ép khởi động lại.
- Dữ liệu người dùng tách riêng `%LOCALAPPDATA%\MT_Smart_Library`.

### Giao diện
- Tiếng Việt; tab Thư viện Offline / Online / Yêu thích / Lịch sử / Cài đặt; nút ⟳ CẬP NHẬT trên header và toolbar.
- Toàn bộ dữ liệu hiển thị qua `textContent`; ảnh online chỉ nhận `https://media.sketchfab.com`; CSP; không tải JS từ CDN.
- Toolbar 2 nút với icon 24/32 px; menu Extensions › MT SMART LIBRARY PRO.
