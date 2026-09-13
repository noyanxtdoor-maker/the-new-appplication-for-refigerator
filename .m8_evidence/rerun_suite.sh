#!/usr/bin/env bash
# Task-owned scratch helper: refresh ONE suite with the SAME Flutter SDK,
# environment, reporter and cleanup law as .m8_diff.sh.
cd "C:/Users/sherl/Downloads/NT_B5_DEVELOP__deepseek-m7m8-20260911"
export PATH="/c/Users/sherl/AppData/Local/NextTransferFlutter/flutter/bin:$PATH"
export HTTP_PROXY= HTTPS_PROXY= http_proxy= https_proxy=
export NO_PROXY="127.0.0.1,localhost" no_proxy="127.0.0.1,localhost"
cleanup() { taskkill /F /IM flutter_tester.exe >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM
/c/Users/sherl/AppData/Local/NextTransferFlutter/flutter/bin/flutter.bat test --no-pub --reporter json "$1" \
  > "$2" 2> "$2.err"
echo "JSON_EXIT=$?"
cleanup
