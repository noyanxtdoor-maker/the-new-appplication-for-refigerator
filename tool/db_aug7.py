#!/usr/bin/env python
"""Show Aug 7 events."""
import sqlite3

DB = r'C:/Users/sherl/AppData/Local/Temp/nexttransfer-walk/db/next_transfer.sqlite'
conn = sqlite3.connect(DB)
c = conn.cursor()
c.execute("""
  SELECT title, timing, start_minute, end_minute, status,
         activity_type_stable_key_snapshot, activity_type_label_snapshot,
         activity_type_color_value_snapshot, goal_id
  FROM calendar_events WHERE start_date='2026-08-07' ORDER BY start_minute
""")
for r in c.fetchall():
    color = r[7]
    if color is not None:
        hexv = f'#{color & 0xFFFFFF:06X}'
    else:
        hexv = None
    print(f'{r[0]!r} {r[1]} {r[2]}-{r[3]} {r[4]} {r[5]!r} {r[6]!r} color={hexv} goal={r[8]}')
conn.close()
