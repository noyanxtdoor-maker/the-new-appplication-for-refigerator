#!/usr/bin/env python3
"""VS16 M7 v47 corrective -- named regression differential.

Compares a candidate `flutter test --reporter json` capture against the ACCEPTED
pristine baseline capture using a NORMALIZED TEST IDENTITY:

    <suite-relative-path>::<full-visible-test-name>

Raw counts are deliberately NOT the acceptance criterion: the candidate adds
suites and tests, so counts move for legitimate reasons. Identity matching
isolates the only number that matters -- net NEW badness.

"Bad" = testDone(result != success) OR skipped, excluding hidden pseudo-tests
(the `loading <path>` entries the JSON reporter emits per suite).
"""

from __future__ import annotations

import json
import sys
from pathlib import Path


def normalize_suite(path: str, roots: list[str]) -> str:
    p = path.replace("\\", "/")
    for root in roots:
        r = root.replace("\\", "/").rstrip("/") + "/"
        if p.startswith(r):
            p = p[len(r):]
            break
    return p


def parse(capture: Path, roots: list[str]) -> dict[str, dict]:
    suites: dict[int, str] = {}
    tests: dict[int, dict] = {}
    done: dict[int, dict] = {}
    end_marker = False

    with capture.open("r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                continue
            t = ev.get("type")
            if t == "suite":
                suites[ev["suite"]["id"]] = ev["suite"]["path"]
            elif t == "testStart":
                tests[ev["test"]["id"]] = ev["test"]
            elif t == "testDone":
                done[ev["testID"]] = ev
            elif t == "done":
                end_marker = True

    result: dict[str, dict] = {}
    for tid, test in tests.items():
        suite_id = test.get("suiteID")
        suite_path = suites.get(suite_id, "")
        name = test.get("name", "")
        if name.startswith("loading "):
            continue  # hidden pseudo-test, not a real assertion
        identity = f"{normalize_suite(suite_path, roots)}::{name}"
        d = done.get(tid, {})
        hidden = d.get("hidden", False)
        if hidden:
            continue
        r = d.get("result", "missing")
        skipped = bool(d.get("skipped", False))
        bad = (r != "success") or skipped
        result[identity] = {
            "result": r,
            "skipped": skipped,
            "bad": bad,
            "suite": normalize_suite(suite_path, roots),
        }
    return {"tests": result, "suites": len(suites), "end_marker": end_marker}


def main() -> int:
    baseline_path = Path(sys.argv[1])
    candidate_path = Path(sys.argv[2])
    baseline_root = sys.argv[3]
    candidate_root = sys.argv[4]

    base = parse(baseline_path, [baseline_root])
    cand = parse(candidate_path, [candidate_root])

    b, c = base["tests"], cand["tests"]
    b_bad = {k for k, v in b.items() if v["bad"]}
    c_bad = {k for k, v in c.items() if v["bad"]}

    new_bad = sorted(c_bad - b_bad)
    fixed = sorted(b_bad - c_bad)
    inherited = sorted(b_bad & c_bad)
    missing = sorted(set(b) - set(c))

    def split(names):
        f = [n for n in names if c.get(n, {}).get("result") == "failure"]
        e = [n for n in names if c.get(n, {}).get("result") == "error"]
        s = [n for n in names if c.get(n, {}).get("skipped")]
        return f, e, s

    nf, ne, ns = split(new_bad)

    lines = []
    lines.append("baseline: tests=%d suites=%d bad=%d end_marker=%s"
                 % (len(b), base["suites"], len(b_bad), base["end_marker"]))
    lines.append("candidate: tests=%d suites=%d bad=%d end_marker=%s"
                 % (len(c), cand["suites"], len(c_bad), cand["end_marker"]))
    lines.append("")
    lines.append("NEW failures/errors/skips NOT present in baseline: %d" % len(new_bad))
    lines.append("  NEW FAILURES = %d" % len(nf))
    lines.append("  NEW ERRORS   = %d" % len(ne))
    lines.append("  NEW SKIPS    = %d" % len(ns))
    lines.append("")
    lines.append("inherited (bad in both): %d" % len(inherited))
    lines.append("fixed (bad only in baseline): %d" % len(fixed))
    lines.append("baseline names MISSING from candidate: %d" % len(missing))
    lines.append("")
    if new_bad:
        lines.append("--- NEW BAD NAMES ---")
        lines.extend("  NEW  " + n for n in new_bad)
        lines.append("")
    if missing:
        lines.append("--- BASELINE NAMES MISSING FROM CANDIDATE ---")
        lines.extend("  GONE " + n for n in missing[:80])
        lines.append("")
    lines.append("--- FIXED (bad only in baseline) ---")
    lines.extend("  FIXED " + n for n in fixed)
    lines.append("")
    lines.append("--- INHERITED (bad in both) ---")
    lines.extend("  INHERITED " + n for n in inherited)

    out = "\n".join(lines)
    print(out)
    Path(".m7_v47_evidence/v47_named_differential.txt").write_text(out, encoding="utf-8")

    verdict_ok = not new_bad and not missing
    print("\nVERDICT: NEW_FAILURES=%d NEW_ERRORS=%d NEW_SKIPS=%d MISSING=%d -> %s"
          % (len(nf), len(ne), len(ns), len(missing),
             "PASS" if verdict_ok else "FAIL"))
    return 0 if verdict_ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
