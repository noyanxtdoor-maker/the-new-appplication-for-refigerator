#!/usr/bin/env python3
"""Summarize a `flutter test --reporter json` (JSONL) evidence file.

Usage: summarize.py <evidence.json> [...]
"""
import json
import sys


def summarize(path: str) -> int:
    tests: dict[int, list] = {}
    errors: list[tuple] = []
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            kind = event.get("type")
            if kind == "testStart":
                tests[event["test"]["id"]] = [event["test"]["name"], "unknown"]
            elif kind == "testDone":
                tid = event.get("testID")
                if tid in tests and not event.get("hidden"):
                    tests[tid][1] = event.get("result", "unknown")
            elif kind == "error":
                errors.append((event.get("testID"), event.get("error", "")))

    # The synthetic per-suite "loading ..." entry is not a real test.
    real = {k: v for k, v in tests.items() if not v[0].startswith("loading ")}
    passed = sum(1 for v in real.values() if v[1] == "success")
    failed = {k: v for k, v in real.items() if v[1] not in ("success", "unknown")}
    print(f"{path}: passed {passed} of {len(real)}")
    for name, result in failed.values():
        print(f"  FAIL[{result}]: {name}")
    for tid, message in errors:
        label = tests.get(tid, ["<suite-level>"])[0]
        print(f"  ERROR in: {label}")
        print("    " + message.strip().replace("\n", "\n    ")[:1500])
    return 1 if (failed or errors) else 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        raise SystemExit(2)
    worst = 0
    for target in sys.argv[1:]:
        worst = max(worst, summarize(target))
    raise SystemExit(worst)
