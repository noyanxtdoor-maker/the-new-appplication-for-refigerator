import os
import re
import subprocess

REPO = '.'

out = subprocess.run(
    ['git', 'status', '--porcelain'], capture_output=True, text=True
).stdout

modified = set()
untracked = set()
for line in out.splitlines():
    st = line[:2]
    p = line[3:].strip().strip('"')
    if p.endswith('.dart') and p.startswith('lib/'):
        if st.strip() == '??':
            untracked.add(p)
        else:
            modified.add(p)

print('M7-MODIFIED lib dart files:', len(modified))
print('M7-NEW (untracked) lib dart files:', len(untracked))


def imports_of(path):
    try:
        txt = open(path, encoding='utf-8', errors='replace').read()
    except OSError:
        return []
    res = []
    for m in re.finditer(r"import\s+'package:rmplanner/([^']+)'", txt):
        res.append('lib/' + m.group(1))
    for m in re.finditer(r"import\s+'([^']+)'", txt):
        t = m.group(1)
        if t.startswith('package:') or t.startswith('dart:'):
            continue
        base = os.path.normpath(os.path.join(os.path.dirname(path), t))
        res.append(base.replace(os.sep, '/'))
    return res


def closure(roots):
    seen = set()
    stack = list(roots)
    while stack:
        f = stack.pop()
        if f in seen or not f.endswith('.dart'):
            continue
        if not os.path.exists(f):
            continue
        seen.add(f)
        stack.extend(imports_of(f))
    return seen


AREAS = [
    'lib/features/maps',
    'lib/features/planner/presentation',
    'lib/features/planner/domain',
    'lib/features/contacts',
    'lib/features/goals',
    'lib/features/settings',
    'lib/app/theme',
]

for area in AREAS:
    if not os.path.isdir(area):
        print('\n=== %s === (absent)' % area)
        continue
    roots = []
    for dp, _, fs in os.walk(area):
        for f in fs:
            if f.endswith('.dart'):
                roots.append(os.path.join(dp, f).replace(os.sep, '/'))
    cl = closure(roots)
    hit_mod = sorted(cl & modified)
    hit_new = sorted(cl & untracked)
    print('\n=== %s ===' % area)
    print('  files in closure      :', len(cl))
    print('  closure n MODIFIED    :', len(hit_mod))
    for h in hit_mod:
        print('      MOD', h)
    print('  closure n NEW(untracked):', len(hit_new))
    for h in hit_new:
        print('      NEW', h)
