import json, sys
def norm(p):
    p = p.replace('\\', '/')
    m = '/test/'
    i = p.rfind(m)
    return p[i+len(m):] if i >= 0 else p
def load(path):
    suites, tests, out = {}, {}, set()
    for line in open(path, encoding='utf-8', errors='replace'):
        line = line.strip()
        if not line: continue
        try: ev = json.loads(line)
        except Exception: continue
        t = ev.get('type')
        if t == 'suite':
            s = ev.get('suite', {}); suites[s.get('id')] = norm(s.get('path',''))
        elif t == 'testStart':
            tt = ev.get('test', {}); tests[tt.get('id')] = tt.get('name','')
        elif t == 'testDone' and not ev.get('hidden'):
            out.add((suites.get(tests.get(ev.get('testID'),'')), tests.get(ev.get('testID'),'')))
    return out
b = load(sys.argv[1]); c = load(sys.argv[2])
missing = sorted(b - c)
added = sorted(c - b)
print('baseline names', len(b), 'candidate names', len(c))
print('MISSING from candidate (%d):' % len(missing))
for s,n in missing[:40]: print('  -', s, '::', n)
print('ADDED in candidate (%d):' % len(added))
for s,n in added[:40]: print('  +', s, '::', n)
