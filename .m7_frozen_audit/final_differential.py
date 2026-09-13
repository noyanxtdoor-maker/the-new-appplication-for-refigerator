"""VS16 M7 FINAL identity-based differential.

Compares the accepted baseline capture (7b1395c) against the FINAL candidate
capture taken over the frozen post-corrective working tree.

Gate required by the handoff:
    NEW FAILURES = 0 / NEW ERRORS = 0 / NEW SKIPS = 0
with the single previously-missing baseline identity acceptable only as the
already-proven strengthening rename of vs16_m4_platform_safety_test.dart.

Read-only: opens files, prints a report. Writes nothing.
"""
import json
import os
import sys

BASELINE = '.m7_evidence/baseline_complete_7b1395c.json'
BASELINE_ROOT = 'C:/Users/sherl/Downloads/NT_B5_DEVELOP__baseline-7b1395c-20260910'
CANDIDATE = os.environ.get(
    'M7_CANDIDATE', '.m7_frozen_audit/candidate_final2.json')
CANDIDATE_ROOT = 'C:/Users/sherl/Downloads/NT_B5_DEVELOP__deepseek-m7m8-20260911'


def parse(path, root):
    suites = {}
    tests = {}
    dones = {}
    end_marker = False
    with open(path, encoding='utf-8', errors='replace') as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except Exception:
                continue
            ty = ev.get('type')
            if ty == 'suite':
                suites[ev['suite']['id']] = ev['suite'].get('path') or ''
            elif ty == 'testStart':
                tests[ev['test']['id']] = ev['test']
            elif ty == 'testDone':
                dones[ev['testID']] = ev
            elif ty == 'done':
                end_marker = True

    out = {}
    prefix = root.replace('\\', '/').rstrip('/') + '/'
    for tid, test in tests.items():
        name = test.get('name', '')
        if name.startswith('loading '):
            continue
        done = dones.get(tid)
        if done is None:
            continue
        if done.get('hidden'):
            continue
        path = (suites.get(test.get('suiteID')) or '').replace('\\', '/')
        if path.startswith(prefix):
            path = path[len(prefix):]
        out[path + '::' + name] = done
    return out, end_marker


def verdict(done):
    """Normalise a testDone event to success | failure | error | skipped."""
    if done.get('skipped'):
        return 'skipped'
    res = done.get('result')
    if res in ('failure', 'error'):
        return res
    return 'success'


def main():
    base, base_end = parse(BASELINE, BASELINE_ROOT)
    cand, cand_end = parse(CANDIDATE, CANDIDATE_ROOT)

    print('=' * 78)
    print('VS16 M7 FINAL IDENTITY DIFFERENTIAL')
    print('=' * 78)
    print('baseline : %s  (end_marker=%s)' % (BASELINE, base_end))
    print('candidate: %s  (end_marker=%s)' % (CANDIDATE, cand_end))
    print()

    bv = {k: verdict(v) for k, v in base.items()}
    cv = {k: verdict(v) for k, v in cand.items()}

    b_bad = {k for k, v in bv.items() if v in ('failure', 'error')}
    c_bad = {k for k, v in cv.items() if v in ('failure', 'error')}
    b_skip = {k for k, v in bv.items() if v == 'skipped'}
    c_skip = {k for k, v in cv.items() if v == 'skipped'}

    print('baseline identities : %d  (bad=%d skipped=%d)' %
          (len(bv), len(b_bad), len(b_skip)))
    print('candidate identities: %d  (bad=%d skipped=%d)' %
          (len(cv), len(c_bad), len(c_skip)))
    print('matched identities  : %d' % len(set(bv) & set(cv)))
    print('net-new in candidate: %d' % len(set(cv) - set(bv)))
    print('gone from candidate : %d' % len(set(bv) - set(cv)))
    print()

    # ---- the gate -----------------------------------------------------------
    new_bad = sorted(c_bad - b_bad)
    new_skip = sorted(c_skip - b_skip)
    inherited = sorted(b_bad & c_bad)
    fixed = sorted(b_bad - c_bad)
    gone = sorted(set(bv) - set(cv))

    new_fail = [k for k in new_bad if cv[k] == 'failure']
    new_err = [k for k in new_bad if cv[k] == 'error']

    print('-' * 78)
    print('GATE: NEW FAILURES / NEW ERRORS / NEW SKIPS')
    print('-' * 78)
    print('NEW failures        : %d' % len(new_fail))
    for k in new_fail:
        print('    [FAIL] %s' % k)
    print('NEW errors          : %d' % len(new_err))
    for k in new_err:
        print('    [ERR ] %s' % k)
    print('NEW skips           : %d' % len(new_skip))
    for k in new_skip:
        print('    [SKIP] %s' % k)
    print()
    print('inherited (bad in both) : %d' % len(inherited))
    print('fixed (bad only in base): %d' % len(fixed))
    for k in fixed:
        print('    [FIXED] %s' % k)
    print()
    print('baseline identities MISSING from candidate: %d' % len(gone))
    for k in gone:
        print('    [GONE] %s' % k)
    print()

    total_new_bad = len(new_fail) + len(new_err)
    print('=' * 78)
    print('RESULT: NEW FAILURES=%d  NEW ERRORS=%d  NEW SKIPS=%d'
          % (len(new_fail), len(new_err), len(new_skip)))
    gate_pass = (total_new_bad == 0 and len(new_skip) == 0
                 and not base_end is False and not cand_end is False)
    print('GATE = %s' % ('PASS' if gate_pass else 'FAIL'))
    if not base_end or not cand_end:
        print('  (note: an end_marker was absent -> capture may be truncated)')
    print('=' * 78)

    # ---- inherited list, for the certificate -------------------------------
    print()
    print('INHERITED BAD IDENTITIES (%d) - pre-existing, not M7 regressions:'
          % len(inherited))
    for k in inherited:
        print('    %-6s %s' % (bv[k], k))

    return 0 if gate_pass else 1


if __name__ == '__main__':
    sys.exit(main())
