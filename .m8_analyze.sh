#!/usr/bin/env bash
cd "C:/Users/sherl/Downloads/NT_B5_DEVELOP__deepseek-m7m8-20260911"
export PATH="/c/Users/sherl/AppData/Local/NextTransferFlutter/flutter/bin:$PATH"
export HTTP_PROXY= HTTPS_PROXY= http_proxy= https_proxy=
export NO_PROXY="127.0.0.1,localhost" no_proxy="127.0.0.1,localhost"
/c/Users/sherl/AppData/Local/NextTransferFlutter/flutter/bin/flutter.bat analyze --no-pub --fatal-infos lib test
echo "ANALYZE_EXIT=$?"
