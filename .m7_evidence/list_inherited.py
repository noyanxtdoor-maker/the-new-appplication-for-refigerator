import json
import sys
import collections


def norm(p):
    p = p.replace('\\', '/')
    m = '/test/'
    i = p.rfind(m)
    return p[i + len(m):] if i >= 0 else p


def load(path):
    suites, tests, results = {}, {}, []
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
            elif t == 'testDone' and not ev.get('hidden'):
                name, sid = tests.get(ev.get('testID'), ('?', None))
                results.append((suites.get(sid, '?'), name, ev.get('result')))
    return results


res = load(sys.argv[1])
g = collections.defaultdict(lambda: collections.Counter())
for suite, name, r in res:
    if r in ('failure', 'error'):
        g[suite][r] += 1
print('INHERITED FAILURES/ERRORS BY SUITE:')
for suite in sorted(g):
    c = g[suite]
    print(f"  {suite}: failure={c['failure']} error={c['error']}")
