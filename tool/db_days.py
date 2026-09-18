#!/usr/bin/env python
"""Summarize event counts by date + goal_id population."""
import sqlite3

DB = r'C:/Users/sherl/AppData/Local/Temp/nexttransfer-walk/db/next_transfer.sqlite'
conn = sqlite3.connect(DB)
c = conn.cursor()

c.execute("""
  SELECT start_date, COUNT(*), SUM(CASE WHEN goal_id IS NOT NULL THEN 1 ELSE 0 END)
  FROM calendar_events GROUP BY start_date ORDER BY start_date
""")
print('== events by date (date, count, with_goal_id) ==')
for r in c.fetchall():
    print(r)

c.execute('SELECT COUNT(*) FROM calendar_events')
print('total events:', c.fetchone()[0])
c.execute('SELECT COUNT(*) FROM calendar_events WHERE goal_id IS NOT NULL')
print('events with goal_id:', c.fetchone()[0])

conn.close()
