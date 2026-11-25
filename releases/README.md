# Kênh cập nhật online — MT SMART LIBRARY PRO

Trong plugin: ⟳ CẬP NHẬT › mục 2 › Nguồn = **URL manifest JSON**, nhập (sau khi bật GitHub Pages cho repo):

```
https://thinhnguyenarc79-debug.github.io/mt-smart-library/releases/update_manifest.json
```

Không dùng đường dẫn `raw.githubusercontent.com/.../main/...` làm nguồn: CDN có thể trả bản cũ trong nhiều giờ (đã gặp ngày 24/11/2026).
`download_url` trong manifest luôn gắn theo mã commit (bất biến) để tránh cache.

| Phiên bản | File | SHA256 |
|---|---|---|
| 1.0.12 (mới nhất) | MT_SMART_LIBRARY_PRO_v1.0.12.rbz | 45d125d10bb01cd8e441edd5bb867b7148a4d00c44fed78c30082fbc355e8faa |
| 1.0.11 | MT_SMART_LIBRARY_PRO_v1.0.11.rbz | 36bc294aa5b0d4c6f8fc47e2d81f23390b92962b7447ee3c82453b3a691ef6cb |
| 1.0.10 | MT_SMART_LIBRARY_PRO_v1.0.10.rbz | e0a48faf485ebe423816e910df7cd32c5ea0d4591777e9987cd0e2f580193dcf |
| 1.0.9 | MT_SMART_LIBRARY_PRO_v1.0.9.rbz | 3647ddd083afef4aca97292753d6c8c4807be85f08813d568abb3437b8239c74 |
| 1.0.8 | MT_SMART_LIBRARY_PRO_v1.0.8.rbz | e780a6f8555f0509ec3b9411ad35bd488615aaaddb8252adff69b09543bd828c |
| 1.0.7 | MT_SMART_LIBRARY_PRO_v1.0.7.rbz | d718c6ac4a58eaab83748731d52746f45ec8a0ae2bf99729381364c73206aa33 |
| 1.0.6 | MT_SMART_LIBRARY_PRO_v1.0.6.rbz | 242adb339c0dd7dbe4a73e746105ac11c310596bedbfc5bece981b2a3ac7b785 |
| 1.0.5 | MT_SMART_LIBRARY_PRO_v1.0.5.rbz | fb41bdfe5fabf5818ff6638b850cbd1a885d2cbba641f0a6e9c0b61f7b8b3da7 |
| 1.0.4 | MT_SMART_LIBRARY_PRO_v1.0.4.rbz | c08d235690fbcfecaf16a3387b7d3026db2fd0245476df230c3d8f70b159ff71 |
| 1.0.3 | MT_SMART_LIBRARY_PRO_v1.0.3.rbz | 9124599b60d6133ab7d9d89c7a2940d1bb6631b4de47fdcde1c19de99097b305 |
| 1.0.2 | MT_SMART_LIBRARY_PRO_v1.0.2.rbz | a5e88849efbd8f7ff2a1b5b36e4089f16ce4fafcc750cc04bf1cb4c4bf706f38 |
| 1.0.1 | MT_SMART_LIBRARY_PRO_v1.0.1.rbz | 4c3db1331f9b4c229bb6a679a941d27f16d6399afc2eb74c58746351f552f9bd |

Phát hành bản mới: (1) commit RBZ vào thư mục này; (2) cập nhật `update_manifest.json` với `download_url` =
`https://raw.githubusercontent.com/thinhnguyenarc79-debug/mt-smart-library/<SHA commit bước 1>/releases/<file>.rbz`, sha256, size, version, changelog; (3) commit + push.
