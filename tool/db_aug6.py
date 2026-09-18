#!/usr/bin/env python
"""Show Aug 6 events details."""
import sqlite3

DB = r'C:/Users/sherl/AppData/Local/Temp/nexttransfer-walk/db/next_transfer.sqlite'
conn = sqlite3.connect(DB)
c = conn.cursor()

c.execute("""
  SELECT title, timing, start_date, start_minute, end_minute, status,
         is_backup_appointment, backup_relationship_provenance,
         activity_type_stable_key_snapshot, activity_type_label_snapshot,
         activity_type_color_value_snapshot, goal_id
  FROM calendar_events WHERE start_date='2026-08-06' ORDER BY start_minute
""")
rows = c.fetchall()
print(f'== Aug 6 events ({len(rows)}) ==')
for r in rows:
    print(r)

conn.close()
