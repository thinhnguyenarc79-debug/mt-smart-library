#!/usr/bin/env bash
# Chạy toàn bộ kiểm thử (Ruby + giao diện headless nếu có Chrome/Playwright).
set -e
cd "$(dirname "$0")/.."
ruby tools/build.rb
cd tests
for f in test_core.rb test_indexer_http.rb test_search_engine.rb test_gltf.rb test_convert.rb test_updater.rb test_app.rb test_boot.rb; do
  echo "== $f"
  ruby -W0 "$f"
done
if command -v node >/dev/null 2>&1 && [ -x /usr/bin/google-chrome ]; then
  echo "== UI (Chrome headless)"
  node ui/ui_test.js "${SHOTS:-/tmp}"
  echo "== Ô nhập liệu (Chrome headless)"
  node ui/input_test.js "${SHOTS:-/tmp}"
fi
