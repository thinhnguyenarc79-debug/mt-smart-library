# Hướng dẫn phát hành bản cập nhật (MT SMART UPDATE SYSTEM)

Áp dụng cho mọi phiên bản sau V1.0.0. Hệ thống cập nhật là một phần bắt buộc của plugin, luôn được giữ trong các bản tiếp theo.

## 1. Quy tắc phiên bản
- Sửa `mt_smart_library/updater/version.rb`: `VERSION` (MAJOR.MINOR.PATCH), `BUILD_DATE`; giữ nguyên `PLUGIN_ID = 'mtdesign.smart_library_pro'`.
- Sửa `mt_smart_library/updater/update_manifest.json`: `version` trùng `VERSION`, cập nhật `changelog`, `released_at`.
- Nếu bản mới cần SketchUp/Ruby mới hơn: tăng `MIN_SKETCHUP` / `MIN_RUBY` (plugin sẽ chặn cài trên máy không tương thích).
- Không đổi tên `mt_smart_library.rb` và thư mục `mt_smart_library/` (đổi tên sẽ tạo extension trùng).
- Không lưu dữ liệu người dùng trong thư mục plugin (dùng `Paths.data_root`).

## 2. Build
```bash
tools/run_tests.sh
ruby tools/build.rb
```
Kết quả: `dist/MT_SMART_LIBRARY_PRO_vX.Y.Z.rbz` và `dist/update_manifest.json` (đã có `sha256`, `size`).

## 3. Phân phối
**Cách A — gửi file**: gửi file `.rbz` (hoặc `.zip`) cho người dùng → ⟳ CẬP NHẬT › *Chọn file cập nhật…*.

**Cách B — GitHub Releases**
1. Tạo release tag `vX.Y.Z` trong repo.
2. Tải lên file `.rbz` → copy link tải trực tiếp của asset (dạng `https://github.com/<owner>/<repo>/releases/download/vX.Y.Z/MT_SMART_LIBRARY_PRO_vX.Y.Z.rbz`).
3. Điền link đó vào `download_url` trong `dist/update_manifest.json`, xóa khóa `_huong_dan`.
4. Đính kèm file đó vào release với tên **đúng** `update_manifest.json`.
5. Trên máy người dùng: Nguồn = *GitHub Releases*, repo `<owner>/<repo>` → *Kiểm tra cập nhật online*.

**Cách C — máy chủ riêng**: đặt `update_manifest.json` (đã điền `download_url` https) ở một URL https cố định → Nguồn = *URL manifest JSON*.

## 4. Định dạng manifest (schema 1)
```json
{
  "schema": 1,
  "plugin_id": "mtdesign.smart_library_pro",
  "name": "MT SMART LIBRARY PRO",
  "version": "1.0.1",
  "released_at": "2026-12-01",
  "download_url": "https://.../MT_SMART_LIBRARY_PRO_v1.0.1.rbz",
  "sha256": "<64 ký tự hex của file rbz>",
  "size": 95000,
  "min_sketchup": 22,
  "max_sketchup": null,
  "min_ruby": "2.7.0",
  "changelog": ["Mô tả thay đổi 1", "Mô tả thay đổi 2"]
}
```
Bắt buộc: `plugin_id`, `version`, `download_url` (https), `sha256`. Gói tải về sai SHA256/kích thước sẽ bị từ chối.

## 5. Plugin làm gì khi cài
1. Kiểm tra lại gói (SHA256 không đổi kể từ lúc xem), tương thích.
2. Sao lưu bản đang chạy vào `%LOCALAPPDATA%\MT_Smart_Library\backups\<version>_<thời gian>` (giữ 5 bản).
3. Giải nén vào thư mục tạm, chỉ lấy `mt_smart_library.rb` + `mt_smart_library/**`.
4. Đổi thư mục cũ ↔ mới (nếu Windows khóa thư mục: ghi đè từng file và dọn file thừa).
5. So SHA256 từng file sau cài. Lỗi ở bất kỳ bước nào → tự khôi phục từ bản sao lưu.
6. Ghi `update.log`, `update_history.json`, `update_state.json` (để báo kết quả ở lần khởi động sau).
