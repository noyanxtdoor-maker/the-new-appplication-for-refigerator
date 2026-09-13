import json

def parse(p, root):
    s = {}
    t = {}
    d = {}
    for line in open(p, encoding='utf-8', errors='replace'):
        line = line.strip()
        if not line:
            continue
        try:
            ev = json.loads(line)
        except Exception:
            continue
        ty = ev.get('type')
        if ty == 'suite':
            s[ev['suite']['id']] = ev['suite']['path']
        elif ty == 'testStart':
            t[ev['test']['id']] = ev['test']
        elif ty == 'testDone':
            d[ev['testID']] = ev
    out = {}
    r = root.replace(chr(92), '/').rstrip('/') + '/'
    for tid, test in t.items():
        n = test.get('name', '')
        if n.startswith('loading '):
            continue
        dd = d.get(tid, {})
        if dd.get('hidden'):
            continue
        path = s.get(test.get('suiteID'), '').replace(chr(92), '/')
        if path.startswith(r):
            path = path[len(r):]
        out[path + '::' + n] = dd
    return out

b = parse('.m7_evidence/baseline_complete_7b1395c.json',
          'C:/Users/sherl/Downloads/NT_B5_DEVELOP__baseline-7b1395c-20260910')
c = parse('.m7_frozen_audit/candidate_full2.json',
          'C:/Users/sherl/Downloads/NT_B5_DEVELOP__deepseek-m7m8-20260911')
print("baseline identities:", len(b), "candidate identities:", len(c))
print("matched:", len(set(b) & set(c)),
      "net-new in candidate:", len(set(c) - set(b)),
      "gone:", len(set(b) - set(c)))
newsuites = [k for k in sorted(set(c) - set(b))
             if 'auto_face_north' in k or 'v47_migration_concurrency' in k]
print("new-suite identities:", len(newsuites))
for k in newsuites:
    print("   ", c[k].get('result'), "|", k)
