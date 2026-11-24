# CHANGELOG — MT SMART LIBRARY PRO

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
