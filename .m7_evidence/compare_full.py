import json, sys, collections

def norm(p):
    p = (p or '').replace('\\', '/')
    i = p.rfind('/test/')
    return p[i+6:] if i >= 0 else p

def load(path):
    suites, tests, results = {}, {}, []
    with open(path, encoding='utf-8', errors='replace') as f:
        for line in f:
            line = line.strip()
            if not line.startswith('{'):
                continue
            try:
                ev = json.loads(line)
            except Exception:
                continue
            t = ev.get('type')
            if t == 'suite':
                s = ev.get('suite', {})
                suites[s.get('id')] = norm(s.get('path'))
            elif t == 'testStart':
                tt = ev.get('test', {})
                tests[tt.get('id')] = (tt.get('name', ''), tt.get('suiteID'))
            elif t == 'testDone' and not ev.get('hidden'):
                name, sid = tests.get(ev.get('testID'), (None, None))
                if name is None:
                    continue
                results.append((suites.get(sid, '?'), norm(name), ev.get('result'),
                                bool(ev.get('skipped'))))
    return results

base = load(sys.argv[1])
cand = load(sys.argv[2])

def key(suite, name):
    return suite + '::' + name

def bad(rs):
    d = {}
    for suite, name, result, skipped in rs:
        if skipped:
            d[key(suite, name)] = 'skip'
        elif result in ('failure', 'error'):
            d[key(suite, name)] = result
    return d

bb, cb = bad(base), bad(cand)
print('baseline: total=%d suites=%d bad=%d' % (len(base), len({s for s,_,_,_ in base}), len(bb)))
print('candidate: total=%d suites=%d bad=%d' % (len(cand), len({s for s,_,_,_ in cand}), len(cb)))

base_keys = {key(s,n) for s,n,_,_ in base}
new_failures = sorted(k for k in cb if k not in base_keys)
fixed = sorted(k for k in bb if k not in cb)
still = sorted(k for k in bb if k in cb)
print()
print('NEW failures/errors/skips NOT present in baseline: %d' % len(new_failures))
for k in new_failures:
    print('  NEW %-10s %s' % (cb[k], k))
print()
print('inherited (bad in both): %d' % len(still))
print('fixed (bad only in baseline): %d' % len(fixed))
for k in fixed:
    print('  FIXED %s' % k)
