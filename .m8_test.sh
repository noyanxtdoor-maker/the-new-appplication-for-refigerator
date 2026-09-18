#!/usr/bin/env bash
# Owner: VS16 M8 engineering session (task-owned scratch helper).
# Purpose: run the established Flutter 3.44.7 test suite from Git Bash on
# Windows.  Three ENVIRONMENT defects are repaired here; none touches product
# code:
#   1. `PROGRAMFILES(X86)` is absent, which crashes flutter_tools'
#      visual_studio.dart when it resolves the MSVC compiler for native assets.
#   2. HTTP_PROXY/HTTPS_PROXY point at the agent host, so Dart's HTTP client
#      routes the loopback `flutter_tester` WebSocket upgrade through a proxy
#      ("Invalid WebSocket upgrade request").
#   3. An interrupted run can leave an orphaned flutter_tester.exe holding
#      build/native_assets/windows/sqlite3.dll, which makes the NEXT run fail
#      with "Deletion failed ... errno = 0".  Any orphan is reaped on exit.
# Task-owned scratch helper; safe to delete once M8 engineering is closed.
cd "C:/Users/sherl/Downloads/NT_B5_DEVELOP__deepseek-m7m8-20260911"
export PATH="/c/Users/sherl/AppData/Local/NextTransferFlutter/flutter/bin:$PATH"
export HTTP_PROXY= HTTPS_PROXY= http_proxy= https_proxy=
export NO_PROXY="127.0.0.1,localhost" no_proxy="127.0.0.1,localhost"
cleanup() { taskkill /F /IM flutter_tester.exe >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM
/c/Users/sherl/AppData/Local/NextTransferFlutter/flutter/bin/flutter.bat \
  test --no-pub "$@"
status=$?
cleanup
exit $status
