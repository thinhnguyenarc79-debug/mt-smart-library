# Kênh cập nhật online — MT SMART LIBRARY PRO

Trong plugin: ⟳ CẬP NHẬT › mục 2 › Nguồn = **URL manifest JSON**, nhập:

```
https://raw.githubusercontent.com/thinhnguyenarc79-debug/mt-smart-library/main/releases/update_manifest.json
```

Bấm **Lưu nguồn** › **Kiểm tra cập nhật online**. Plugin chỉ cài khi bạn xác nhận và luôn kiểm tra SHA256 của gói.

| Phiên bản | File | SHA256 |
|---|---|---|
| 1.0.2 (mới nhất) | MT_SMART_LIBRARY_PRO_v1.0.2.rbz | a5e88849efbd8f7ff2a1b5b36e4089f16ce4fafcc750cc04bf1cb4c4bf706f38 |
| 1.0.1 | MT_SMART_LIBRARY_PRO_v1.0.1.rbz | 4c3db1331f9b4c229bb6a679a941d27f16d6399afc2eb74c58746351f552f9bd |

Phát hành bản mới: build bằng `ruby tools/build.rb`, chép RBZ vào thư mục này, cập nhật `update_manifest.json` (version, download_url, sha256, size, changelog) rồi commit lên nhánh main.
