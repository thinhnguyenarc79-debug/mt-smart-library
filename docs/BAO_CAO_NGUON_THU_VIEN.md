# Báo cáo nguồn thư viện — MT SMART LIBRARY PRO V1.0.8 (25/11/2026)

Kiểm tra thực tế bằng công cụ đọc web (robots.txt, REST API, trang model, tài liệu API). Plugin chỉ dùng phương thức công khai/được phép;
không scrape HTML, không vượt CAPTCHA/Turnstile, paywall hay giới hạn tải, không đọc cookie trình duyệt.

## Bảng tổng hợp

| Nguồn | Phương thức | Tìm kiếm thật | Ảnh | Đăng nhập | Tải tự động | Giải nén | Chuyển đổi | Chèn SketchUp | Giấy phép | Giới hạn |
|---|---|---|---|---|---|---|---|---|---|---|
| Máy tính | Chỉ mục cục bộ | ✅ | ✅ | Không | — | — | — | ✅ SKP | Của người dùng | — |
| Sketchfab | Data API v3 + Download API (chính thức) | ✅ (đã chạy thật trên máy người dùng V1.0.2) | ✅ | API token | ✅ GLB/glTF | ✅ ZIP | ✅ Blender khi cần | ✅ glTF tích hợp / DAE | Theo từng model (CC…) | Không có SKP; OAuth cần MT Design đăng ký ứng dụng |
| Poly Haven | API chính thức api.polyhaven.com | ✅ cấu trúc JSON thật đã kiểm; chưa chạy từ máy SketchUp | ✅ cdn.polyhaven.com | Không | ✅ glTF + texture, kiểm MD5 | — | Không cần | ✅ glTF tích hợp | CC0 | Ít model (vài trăm), không có SKP |
| SketchUp CGTips | WordPress REST API công khai (`/wp-json/wp/v2/posts?search=`, `/media?include=`) | ✅ đã nhận JSON thật (3 kết quả “sofa”) | ✅ host sketchup.cgtips.org | Không | ❌ link rút gọn link.cgtips.org | ✅ ZIP mật khẩu do trang công bố (ZipCrypto) | Không cần (SKP) | ✅ sau khi người dùng tải: plugin tự nhận file trong Downloads → nút CHÈN | Terms of Use + Model License Agreement của trang | Người dùng tự mở trang và tải |
| SketchupFree | WordPress REST API công khai | ✅ JSON thật | ✅ img.sketchupfree.com | Không | ❌ trang yêu cầu xác minh Turnstile | ✅ ZIP thường | — | ✅ sau khi người dùng tải | Terms of Service của trang | Người dùng tự xác minh và tải |
| Thư viện SketchUp (thuviensketchup.vn) | WordPress REST API công khai | ✅ JSON thật | ✅ thuviensketchup.vn | Có (khi mua) | ❌ gói trả phí, link Google Drive sau khi mua | ✅ | — | ✅ sau khi người dùng tải | Trả phí | robots.txt chặn trang tìm kiếm HTML (plugin dùng REST API, không dùng trang đó) |
| CGTrader | API chính thức api.cgtrader.com (GET /v1/models, /files) | ❌ chưa — cần khóa | — | OAuth client ID/secret | Có theo tài liệu | — | Có | — | Theo từng model | Cần MT Design đăng ký API tại cgtrader.com/developers; URL token OAuth chưa công bố trong tài liệu |
| 3D Warehouse | Không có API công khai | ❌ | — | — | ❌ | — | — | Dùng Window › 3D Warehouse của SketchUp | Trimble ToS | Cần Trimble cấp API |
| 3dsky | Không có API công khai đã xác minh | ❌ | — | — | ❌ | — | — | — | — | Chủ yếu 3ds Max |
| 3dbox | robots.txt cấm `/api/` | ❌ | — | Có (credit) | ❌ | — | — | — | Mỗi model một giấy phép | Cần 3dbox cấp phép |
| Sketch Shaper | robots.txt cấm `/api/`, `/api.php`; không có API công khai | ❌ | — | Không | ❌ | — | — | — | Terms + License của trang | Cần xin phép |
| Tài liệu kiến trúc | Không có API; tải bằng điểm | ❌ | — | Có | ❌ | — | — | — | Điều khoản trang | — |
| sketchup.vn | Trang không phản hồi khi kiểm tra | ❌ | — | — | — | — | — | — | — | Kiểm tra lại sau |

## Website cần anh hỗ trợ đăng nhập / cấp quyền

| Website | Việc cần làm | Đường dẫn chính thức |
|---|---|---|
| Sketchfab | Dán API token (đã có) | https://sketchfab.com/settings/password |
| CGTrader | Đăng nhập, gửi yêu cầu cấp API cho MT Design (OAuth client ID/secret) | https://www.cgtrader.com/developers |
| Thư viện SketchUp | Đăng nhập khi mua gói trên web (plugin không cần tài khoản để tìm) | https://thuviensketchup.vn |
| 3D Warehouse, 3dbox, Sketch Shaper | Liên hệ chủ trang xin API/giấy phép tích hợp — đăng nhập tài khoản thường không mở được API | — |
