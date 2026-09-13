import os
import re
import subprocess

out = subprocess.run(
    ['git', 'status', '--porcelain'], capture_output=True, text=True
).stdout
modified, untracked = set(), set()
for line in out.splitlines():
    st = line[:2]
    p = line[3:].strip().strip('"')
    if p.endswith('.dart') and p.startswith('lib/'):
        (untracked if st.strip() == '??' else modified).add(p)

changed = modified | untracked


def direct_rmplanner_imports(path):
    txt = open(path, encoding='utf-8', errors='replace').read()
    res = []
    for m in re.finditer(r"import\s+'package:rmplanner/([^']+)'", txt):
        res.append('lib/' + m.group(1))
    for m in re.finditer(r"import\s+'([^']+)'", txt):
        t = m.group(1)
        if t.startswith('package:') or t.startswith('dart:'):
            continue
        base = os.path.normpath(os.path.join(os.path.dirname(path), t))
        res.append(base.replace(os.sep, '/'))
    return sorted(set(res))


print('=== DIRECT (1-level) imports of lib/features/maps/** that M7 changed ===')
any_hit = False
for dp, _, fs in os.walk('lib/features/maps'):
    for f in sorted(fs):
        if not f.endswith('.dart'):
            continue
        p = os.path.join(dp, f).replace(os.sep, '/')
        hits = [i for i in direct_rmplanner_imports(p) if i in changed]
        if hits:
            any_hit = True
            print(' ', p)
            for h in hits:
                tag = 'MOD' if h in modified else 'NEW'
                print('      ->', tag, h)
if not any_hit:
    print('  (none — every direct dependency of every Maps file is unchanged)')

print()
print('=== DIRECT imports of lib/app/theme/** that M7 changed ===')
any_hit = False
for dp, _, fs in os.walk('lib/app/theme'):
    for f in sorted(fs):
        if not f.endswith('.dart'):
            continue
        p = os.path.join(dp, f).replace(os.sep, '/')
        hits = [i for i in direct_rmplanner_imports(p) if i in changed]
        if hits:
            any_hit = True
            print(' ', p, '->', hits)
if not any_hit:
    print('  (none)')

print()
print('=== Files that IMPORT a maps file (reverse deps) and were changed by M7 ===')
map_files = set()
for dp, _, fs in os.walk('lib/features/maps'):
    for f in fs:
        if f.endswith('.dart'):
            map_files.add(os.path.join(dp, f).replace(os.sep, '/'))

for c in sorted(changed):
    if not os.path.exists(c):
        continue
    imps = set(direct_rmplanner_imports(c))
    inter = imps & map_files
    if inter:
        print(' ', c, '-> imports', sorted(inter))
