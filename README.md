# MT SMART LIBRARY PRO — V1.0.13

Plugin SketchUp quản lý thư viện model 3D cho MT Design (Kiến trúc & Nội thất Mạnh Trường).
Tương thích **SketchUp 2022 (Ruby 2.7.2) trên Windows**. Mã định danh plugin: `mtdesign.smart_library_pro`.

## 1. Cài đặt

1. Mở SketchUp 2022 → **Extensions › Extension Manager › Install Extension**.
2. Chọn file `MT_SMART_LIBRARY_PRO_v1.0.12.rbz` → **Yes** để cài.
3. Khởi động lại SketchUp (khuyến nghị).
4. Mở bằng toolbar **MT SMART LIBRARY PRO** (2 nút: *Mở thư viện* và *Cập nhật*) hoặc menu
   **Extensions › MT SMART LIBRARY PRO**.

Nếu máy đã có bản mẫu cũ (`mt_smart_library.rb` cùng tên), cài RBZ mới sẽ ghi đè. Danh sách thư mục,
yêu thích và lịch sử của bản cũ được tự chuyển sang bản mới.

Từ V1.0.0 trở đi, cập nhật bằng nút **⟳ CẬP NHẬT** trong plugin, không cần gỡ bản cũ (xem mục 4).

## 2. Sử dụng nhanh (giao diện V1.0.2)

- Gõ từ khóa một lần (có dấu/không dấu, Việt/Anh) → kết quả từ máy tính và online hiện chung trong một lưới, đến đâu hiện đến đó.
- Chọn danh mục bên trái để thu hẹp; thêm danh mục riêng bằng **+ Thêm danh mục**.
- Lọc nhanh: Tất cả / Máy tính / Online / Chèn được ngay / Miễn phí. Kéo thanh trượt để đổi kích thước ảnh.
- **CHÈN**: chèn mọi định dạng (SKP, GLB/glTF, DAE, FBX, OBJ, USDZ, ZIP…). Định dạng SketchUp không đọc được sẽ được Blender 4.5 LTS chuyển đổi ngầm (cài Blender 1 lần).
- Bấm vào ảnh để xem chi tiết (nguồn, tác giả, giấy phép, ghi công).

### Bảng thao tác chi tiết (tham khảo)

| Việc | Thao tác |
|------|----------|
| Thêm thư viện | *+ Thêm thư mục* → chọn thư mục chứa `.skp` (ổ cứng, ổ ngoài, ổ mạng `\\server\share`). Plugin quét nền, có tiến độ và nút *Hủy quét*. |
| Tìm kiếm | Gõ có dấu hoặc không dấu, tiếng Việt hoặc tiếng Anh: `ghe sofa`, `bàn ăn gỗ`, `pendant lamp`. Từ đồng nghĩa: *ghế ↔ chair*, *đèn ↔ lamp*… |
| Lọc / sắp xếp | Thư mục gốc, dung lượng, liên quan/tên/ngày/dung lượng. Phân trang 24–150 model/trang. |
| Chèn model | Bấm *Chèn* hoặc bấm vào ảnh → đặt bằng chuột (Esc để hủy). Có Undo. Vật liệu và tỉ lệ được giữ nguyên. |
| Yêu thích / Lịch sử | ☆ trên thẻ model; tab *Yêu thích*, *Lịch sử*. |
| Online | Tab *Online*: mở trang tìm kiếm 3D Warehouse / Sketchfab / 3dsky / CGTrader / Google; kết quả Sketchfab hiển thị ngay trong plugin. |
| AI tìm bằng ảnh | *✦ Tìm bằng ảnh AI* → chọn ảnh → xem trước → *Đồng ý gửi & phân tích* → sửa từ khóa → tìm offline/online. |
| Chèn file vừa tải | *Chèn file SKP…* hoặc *Nhập file 3D (DAE/3DS/KMZ/STL…)…* |

### Cấu hình AI (OpenAI)
Cài đặt › AI: dán API key → *Lưu key*. Mặc định key chỉ giữ trong phiên SketchUp. Có thể:
- đặt biến môi trường `OPENAI_API_KEY`, hoặc
- tick *Ghi nhớ trên máy này*: key được mã hóa bằng Windows DPAPI (chỉ tài khoản Windows của bạn giải mã được), lưu ở file riêng, **không** nằm trong `settings.json`/log.

Model mặc định `gpt-6-luna` (OpenAI đã đưa `gpt-4.1-mini` vào danh sách ngừng, tắt ngày 14/01/2027). Bấm *Kiểm tra API* để thử key/model (không tốn phí phân tích ảnh).

> AI ở đây **gợi ý từ khóa từ ảnh** (loại đồ vật, phong cách, vật liệu, màu, từ khóa Việt/Anh), **không phải** tìm ảnh tương đồng bằng vector.

### Sketchfab
Tìm kiếm dùng Data API công khai (không cần token). Tải model cần **Sketchfab API token** (Cài đặt › Sketchfab).
Sketchfab Download API chỉ cung cấp **glTF / GLB / USDZ** — SketchUp 2022 không nhập trực tiếp các định dạng này;
cần chuyển đổi (ví dụ Blender → DAE) rồi dùng *Nhập file 3D*. File tải về kèm `ATTRIBUTION.txt` (tác giả, giấy phép, nguồn).

## 3. Nơi lưu dữ liệu (tách biệt mã nguồn)

| Loại | Vị trí |
|------|--------|
| Mã nguồn plugin | `%APPDATA%\SketchUp\SketchUp 2022\SketchUp\Plugins\mt_smart_library.rb` + thư mục `mt_smart_library\` |
| Dữ liệu người dùng | `%LOCALAPPDATA%\MT_Smart_Library\` |
| ├ `settings.json` | thư mục thư viện, yêu thích, lịch sử, cài đặt giao diện/AI (không chứa key) |
| ├ `index_cache.json` | chỉ mục tìm kiếm (cache theo thư mục: mtime, tên, size) |
| ├ `thumbs\` | ảnh thumbnail cache |
| ├ `secrets\*.dpapi` | key/token mã hóa (chỉ khi bật “Ghi nhớ”) |
| ├ `downloads\` | model tải từ Sketchfab |
| ├ `backups\` | bản sao lưu mã nguồn plugin trước mỗi lần cập nhật (giữ 5 bản) |
| ├ `updates\` | gói cập nhật tải về |
| └ `logs\` | `mt_smart_library.log`, `update.log` |

Cập nhật/khôi phục plugin **chỉ** thay thư mục mã nguồn trong Plugins — không đụng tới thư mục dữ liệu.

## 4. MT SMART UPDATE SYSTEM

- **Từ file**: nút ⟳ CẬP NHẬT › *Chọn file cập nhật…* (RBZ hoặc ZIP). Plugin kiểm tra cấu trúc, `PLUGIN_ID`,
  phiên bản, tương thích SketchUp/Ruby, đường dẫn nguy hiểm (`..`, đường dẫn tuyệt đối, symlink, tên thiết bị Windows),
  CRC từng file → sao lưu bản đang chạy → cài đè → kiểm tra SHA256 từng file → tự khôi phục nếu lỗi.
- **Online**: cấu hình *URL manifest JSON* hoặc *GitHub Releases* (`chu-so-huu/ten-repo`). Plugin chỉ **kiểm tra**;
  chỉ cài khi bạn bấm và xác nhận. Gói tải về luôn được đối chiếu `sha256` trong manifest.
- **Khôi phục**: bảng *Khôi phục phiên bản trước* (5 bản gần nhất).
- **Khởi động lại**: bản mới có hiệu lực sau khi bạn tự đóng/mở SketchUp. Plugin không nạp nóng mã mới
  (tránh trùng menu/toolbar/callback) và không ép khởi động lại; nếu bản vẽ chưa lưu sẽ nhắc lưu trước.

Hướng dẫn phát hành bản cập nhật: `docs/HUONG_DAN_PHAT_HANH_CAP_NHAT.md`.

## 5. Cấu trúc mã nguồn

```
mt_smart_library.rb                 loader (đăng ký extension, đọc VERSION từ updater/version.rb)
mt_smart_library/
  main.rb                           nạp module, tạo menu + toolbar (1 lần/phiên)
  core/   util, paths, logger, settings, synonyms, search_index, indexer, thumbs, inserter, secret_store
  net/    http_client.rb            Net::HTTP trong luồng nền + fallback Sketchup::Http khi lỗi SSL
  online/ link_sources.rb, sketchfab.rb
  search/ search_manager, query_normalizer, result_ranker, result_cache, categories
          providers/ base_provider, local_provider, sketchfab_provider (+ nguồn chưa tích hợp)
  ai/     vision.rb                 OpenAI Chat Completions + vision + structured outputs
  ui/     app.rb (bộ điều khiển, dialog, timer), index.html, app.css, app.js
  updater/ updater.rb, backup_manager.rb, version.rb, update_manifest.json,
           update_dialog.html, update_dialog.js, zip_reader.rb
  icons/  library_*.png, update_*.png
```

Nguyên tắc luồng: quét thư mục, HTTP, giải nén/cài đặt chạy luồng nền thuần Ruby; mọi lệnh SketchUp API,
HtmlDialog và thao tác model chạy ở main thread qua `UI.start_timer`.

## 6. Build và kiểm thử (dành cho lập trình)

```bash
tools/run_tests.sh      # 56 test Ruby + 2 bộ test giao diện Chrome headless
ruby tools/build.rb     # kiểm tra cú pháp, đồng bộ phiên bản, tạo dist/*.rbz + dist/update_manifest.json
```
