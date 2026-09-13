import json
import sys
import collections


def norm(p):
    p = p.replace('\\', '/')
    marker = '/test/'
    i = p.rfind(marker)
    return p[i + len(marker):] if i >= 0 else p


def load(path):
    suites = {}
    tests = {}
    results = []
    with open(path, 'r', encoding='utf-8', errors='replace') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except Exception:
                continue
            t = ev.get('type')
            if t == 'suite':
                s = ev.get('suite', {})
                suites[s.get('id')] = norm(s.get('path', ''))
            elif t == 'testStart':
                tt = ev.get('test', {})
                tests[tt.get('id')] = (tt.get('name', ''), tt.get('suiteID'))
            elif t == 'testDone':
                tid = ev.get('testID')
                if ev.get('hidden'):
                    continue
                name, sid = tests.get(tid, ('?', None))
                results.append({
                    'name': name,
                    'suite': suites.get(sid, '?'),
                    'result': ev.get('result'),
                    'skipped': bool(ev.get('skipped')),
                })
    return results


def summarize(label, results):
    c = collections.Counter()
    fails = []
    for r in results:
        if r['skipped']:
            c['skipped'] += 1
        else:
            c[r['result'] or 'unknown'] += 1
        if r['result'] in ('failure', 'error'):
            fails.append((r['suite'], r['name'], r['result']))
    print(f"== {label}: total={len(results)} counts={dict(c)}")
    return fails


b = load(sys.argv[1])
cand = load(sys.argv[2])
bf = summarize('BASELINE ', b)
cf = summarize('CANDIDATE', cand)

bset = set((s, n) for s, n, _ in bf)
cset = set((s, n) for s, n, _ in cf)
new = sorted(cset - bset)
fixed = sorted(bset - cset)
print(f"\nNEW FAILURES/ERRORS ({len(new)}):")
for s, n in new[:60]:
    print('  +', s, '::', n)
print(f"\nRESOLVED (baseline fail, now pass) ({len(fixed)}):")
for s, n in fixed[:60]:
    print('  -', s, '::', n)

bskips = set((r['suite'], r['name']) for r in b if r['skipped'])
cskips = set((r['suite'], r['name']) for r in cand if r['skipped'])
print(f"\nBASELINE SKIPS ({len(bskips)}):")
for s, n in sorted(bskips):
    print('  =', s, '::', n)
print(f"\nNEW SKIPS ({len(cskips - bskips)}):")
for s, n in sorted(cskips - bskips):
    print('  +', s, '::', n)
