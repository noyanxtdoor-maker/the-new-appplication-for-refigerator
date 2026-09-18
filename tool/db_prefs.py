#!/usr/bin/env python
"""Inspect event color preferences stored on device."""
import sqlite3

DB = r'C:/Users/sherl/AppData/Local/Temp/nexttransfer-walk/db/next_transfer.sqlite'
conn = sqlite3.connect(DB)
c = conn.cursor()

c.execute("SELECT name FROM sqlite_master WHERE type='table' AND name LIKE '%color%'")
tables = [r[0] for r in c.fetchall()]
print('color tables:', tables)

for t in tables:
    c.execute(f'PRAGMA table_info({t})')
    cols = [r[1] for r in c.fetchall()]
    print(f'\n== {t} columns: {cols} ==')
    c.execute(f'SELECT * FROM {t}')
    rows = c.fetchall()
    for r in rows[:30]:
        # hexify color-ish columns
        out = []
        for v, name in zip(r, cols):
            if isinstance(v, int) and 'rgb' in name.lower() or isinstance(v, int) and 'argb' in name.lower() or isinstance(v, int) and 'color' in name.lower():
                out.append(f'{name}=#{v & 0xFFFFFF:06X}')
            else:
                out.append(f'{name}={v!r}')
        print('  ', ' '.join(out))

conn.close()
