#!/usr/bin/env bash
# VS16 M7 corrective test runner.
#
# Two environment issues must both be handled or `flutter test` aborts:
#
# 1. The Flutter Windows tool requires %PROGRAMFILES(X86)% to be present.
#    Git Bash cannot `export` a name containing parentheses, so it is injected
#    through `env`.
# 2. A system HTTP proxy is configured (http://127.0.0.1:62489). The tool
#    communicates with the `flutter_tester` child over a LOCALHOST WebSocket;
#    the proxy intercepts that upgrade and the run dies with
#    "WebSocketException: Invalid WebSocket upgrade request". The proxy is
#    therefore cleared for the test process only.
#
# Usage: run_tests.sh <output.json> [flutter test args...]
#
# SAFETY: the output path is validated. An earlier invocation swapped the
# arguments and clobbered an untracked test source file with JSON output. The
# guard below refuses to write anywhere except a *.json path under the evidence
# directory, so a mis-ordered call can never destroy a source file again.
set -u
export PATH="/c/Users/sherl/AppData/Local/NextTransferFlutter/flutter/bin:$PATH"
cd "C:/Users/sherl/Downloads/NT_B5_DEVELOP__deepseek-m7m8-20260911" || exit 99

OUT="${1:-}"
if [ -z "$OUT" ]; then
  echo "ERROR: first argument must be the JSON output path" >&2
  echo "Usage: run_tests.sh .m7c_evidence/<name>.json <flutter test args...>" >&2
  exit 96
fi
shift || true

# --- output-path guard -------------------------------------------------------
case "$OUT" in
  *.dart)
    echo "REFUSING: output path '$OUT' looks like a Dart source file." >&2
    exit 97
    ;;
  *.json) ;;
  *)
    echo "REFUSING: output path '$OUT' must end in .json." >&2
    exit 97
    ;;
esac
case "$OUT" in
  .m7c_evidence/*|./.m7c_evidence/*|/*.json) ;;
  *)
    echo "REFUSING: output path '$OUT' must live under .m7c_evidence/." >&2
    exit 97
    ;;
esac
if [ ! -d "$(dirname "$OUT")" ]; then
  echo "REFUSING: output directory '$(dirname "$OUT")' does not exist." >&2
  exit 97
fi
if [ -f "$OUT" ] && ! head -c 1 "$OUT" | grep -q '{' 2>/dev/null; then
  echo "REFUSING: '$OUT' exists and is not JSON." >&2
  exit 97
fi
# -----------------------------------------------------------------------------

env "PROGRAMFILES(X86)=C:\\Program Files (x86)" \
    http_proxy= https_proxy= HTTP_PROXY= HTTPS_PROXY= \
    NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost \
  flutter test --no-pub "$@" --reporter json > "$OUT" 2>&1
echo "EXIT=$?"
