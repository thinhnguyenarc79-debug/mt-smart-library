# Review mã nguồn gốc (trước V1.0.0)

Phạm vi: `mt_smart_library.rb`, `mt_smart_library/main.rb`, `mt_smart_library/index.html` trong gói `MT_SMART_LIBRARY_SOURCE_FOR_CLAUDE.zip`.

## Lỗi thực tế (ảnh hưởng chức năng)

| # | Vị trí | Lỗi | Hậu quả |
|---|--------|-----|---------|
| 1 | `main.rb#scan` | Luồng quét chỉ `rescue SystemCallError`. Lỗi encoding tên file (tên tiếng Việt trả về sai encoding trên Windows) hoặc lỗi khác làm luồng chết im lặng. | `@scanning` kẹt `true` vĩnh viễn → không bao giờ quét lại được cho tới khi khởi động lại SketchUp. |
| 2 | `main.rb#scan` | `Find.find` không chỉ định encoding UTF‑8; `JSON.generate` sau đó raise `Encoding::UndefinedConversionError` với tên file có dấu. | Danh sách model không hiển thị / dialog không nhận dữ liệu. |
| 3 | `main.rb#scan` | Gọi quét khi đang quét → chỉ báo "Đang quét" rồi bỏ qua. | Thêm/xóa thư mục gốc trong lúc quét không được áp dụng; kết quả cũ (gồm root đã xóa) ghi đè lên. |
| 4 | `main.rb#scan` | `Find.find` tự nuốt EACCES/ENOENT; lỗi khác nằm ngoài vòng lặp sẽ dừng cả root. | Số lỗi báo cáo sai; một file lỗi có thể làm mất phần còn lại của thư mục. |
| 5 | `main.rb` | Không có cache chỉ mục. `ready` luôn gọi `scan`. | Mỗi lần mở dialog quét lại toàn bộ ổ đĩa/ổ mạng. |
| 6 | `main.rb#refresh` + `index.html` | Gửi **toàn bộ** mảng item sang JS mỗi lần refresh; JS lọc lại toàn bộ và `normalize()` lại từng đường dẫn mỗi lần gõ phím. | Với 10.000–100.000 model: JSON hàng chục MB qua `execute_script`, dialog đơ/treo. |
| 7 | `main.rb` | Luồng Ruby trong SketchUp không được nhường GVL; timer chỉ `pop` queue. | Quét nền chạy rất chậm hoặc đứng khi SketchUp rảnh; không có tiến độ, không hủy được. |
| 8 | `callback('thumb')` | `Sketchup.save_thumbnail` chạy đồng bộ cho mỗi request; JS gửi 24 request cùng lúc; ảnh lỗi không được ghi nhớ. | Giật khi lật trang; file lỗi bị thử lại liên tục. |
| 9 | `setup`/`save` | `JSON.parse ... rescue {}` không kiểm tra schema; `File.write` không atomic. | settings.json hỏng → lần lưu sau ghi đè mất toàn bộ thư mục gốc/yêu thích. |
| 10 | `place` | Không bọc `start_operation`, không phân biệt lỗi phiên bản SKP mới hơn. | Không Undo gọn; thông báo lỗi chung chung. |
| 11 | `ai` | Chỉ trả 1 cụm từ, không có `object_type/style/material/color/queries_vi/queries_en`; dùng `max_tokens` (không hợp lệ với model reasoning mới); model mặc định `gpt-4.1-mini` đã bị OpenAI đưa vào danh sách ngừng (shutdown 14/01/2027). | Không đáp ứng đặc tả AI; lỗi 400 với model mới. |
| 12 | `ai` | Xác nhận bằng `messagebox` nhưng không có preview ảnh. Che key chỉ bằng `gsub(key)`. | Người dùng không thấy ảnh sẽ gửi; key dạng khác (env) có thể lọt log. |
| 13 | `@timer ||=` | Timer lặp không bao giờ dừng, không chống re-entrancy. | Timer chạy suốt phiên SketchUp kể cả khi đóng dialog. |
| 14 | Online | Sketchfab chỉ mở trình duyệt; 3dsky/CGTrader đi vòng qua Google `site:`. | Chưa đạt P1 (kết quả trong plugin qua API hợp lệ). |
| 15 | Toolbar | Dùng cùng 1 ảnh 64px cho small/large icon. | Icon mờ/vỡ trên toolbar. |

## Điểm tốt được giữ lại

- Dùng `textContent`, không `innerHTML` với dữ liệu tên file.
- API key chỉ giữ trong phiên / biến môi trường `OPENAI_API_KEY`.
- Chèn model bằng `definitions.load` + `place_component`.
- Thư mục dữ liệu `%LOCALAPPDATA%\MT_Smart_Library`, ID model = SHA256(đường dẫn) → V1.0.0 giữ nguyên để không mất danh sách Yêu thích/Lịch sử cũ.
