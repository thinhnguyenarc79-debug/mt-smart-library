# Kênh cập nhật online — MT SMART LIBRARY PRO

Trong plugin: ⟳ CẬP NHẬT › mục 2 › Nguồn = **URL manifest JSON**, nhập (sau khi bật GitHub Pages cho repo):

```
https://thinhnguyenarc79-debug.github.io/mt-smart-library/releases/update_manifest.json
```

Không dùng đường dẫn `raw.githubusercontent.com/.../main/...` làm nguồn: CDN có thể trả bản cũ trong nhiều giờ (đã gặp ngày 24/11/2026).
`download_url` trong manifest luôn gắn theo mã commit (bất biến) để tránh cache.

| Phiên bản | File | SHA256 |
|---|---|---|
| 1.0.4 (mới nhất) | MT_SMART_LIBRARY_PRO_v1.0.4.rbz | c08d235690fbcfecaf16a3387b7d3026db2fd0245476df230c3d8f70b159ff71 |
| 1.0.3 | MT_SMART_LIBRARY_PRO_v1.0.3.rbz | 9124599b60d6133ab7d9d89c7a2940d1bb6631b4de47fdcde1c19de99097b305 |
| 1.0.2 | MT_SMART_LIBRARY_PRO_v1.0.2.rbz | a5e88849efbd8f7ff2a1b5b36e4089f16ce4fafcc750cc04bf1cb4c4bf706f38 |
| 1.0.1 | MT_SMART_LIBRARY_PRO_v1.0.1.rbz | 4c3db1331f9b4c229bb6a679a941d27f16d6399afc2eb74c58746351f552f9bd |

Phát hành bản mới: (1) commit RBZ vào thư mục này; (2) cập nhật `update_manifest.json` với `download_url` =
`https://raw.githubusercontent.com/thinhnguyenarc79-debug/mt-smart-library/<SHA commit bước 1>/releases/<file>.rbz`, sha256, size, version, changelog; (3) commit + push.
