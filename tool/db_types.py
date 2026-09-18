#!/usr/bin/env python
"""Show activity_types rows with hex colors."""
import sqlite3

DB = r'C:/Users/sherl/AppData/Local/Temp/nexttransfer-walk/db/next_transfer.sqlite'
conn = sqlite3.connect(DB)
c = conn.cursor()

c.execute('PRAGMA table_info(activity_types)')
cols = [r[1] for r in c.fetchall()]
print('activity_types columns:', cols)

c.execute('SELECT * FROM activity_types ORDER BY rowid')
rows = c.fetchall()
for r in rows:
    out = []
    for v, name in zip(r, cols):
        if isinstance(v, int) and ('color' in name.lower() or 'argb' in name.lower() or 'rgb' in name.lower()):
            out.append(f'{name}=#{v & 0xFFFFFF:06X}')
        else:
            out.append(f'{name}={v!r}')
    print('  ', ' '.join(out))
conn.close()
