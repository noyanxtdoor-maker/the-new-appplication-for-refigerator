#!/usr/bin/env bash
# Baseline probe: runs given suites against the CLEAN HEAD baseline worktree.
set -u
export PATH="/c/Users/sherl/AppData/Local/NextTransferFlutter/flutter/bin:$PATH"
cd "C:/Users/sherl/Downloads/NT_B5_DEVELOP__baseline-7b1395c-20260910" || exit 99

env "PROGRAMFILES(X86)=C:\\Program Files (x86)" \
    http_proxy= https_proxy= HTTP_PROXY= HTTPS_PROXY= \
    NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost \
  flutter test --no-pub "$@" --reporter json > "C:/Users/sherl/Downloads/NT_B5_DEVELOP__deepseek-m7m8-20260911/.m7c_evidence/baseline_probe.json" 2>&1
echo "EXIT=$?"
