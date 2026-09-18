#!/usr/bin/env python
"""List events in the on-device DB for the current week + event types."""
import sqlite3
import sys

DB = r'C:/Users/sherl/AppData/Local/Temp/nexttransfer-walk/db/next_transfer.sqlite'
conn = sqlite3.connect(DB)
c = conn.cursor()

# Discover tables
c.execute("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
tables = [r[0] for r in c.fetchall()]
print('== tables ==')
print(' '.join(tables))

if 'calendar_events' in tables:
    c.execute('PRAGMA table_info(calendar_events)')
    cols = [r[1] for r in c.fetchall()]
    print('\n== calendar_events columns ==')
    print(' '.join(cols))
    c.execute('SELECT * FROM calendar_events LIMIT 20')
    rows = c.fetchall()
    print(f'\n== calendar_events rows ({len(rows)}) ==')
    for r in rows:
        print(r)

if 'event_types' in tables:
    c.execute('PRAGMA table_info(event_types)')
    cols = [r[1] for r in c.fetchall()]
    print('\n== event_types columns ==')
    print(' '.join(cols))
    c.execute('SELECT * FROM event_types ORDER BY rowid LIMIT 30')
    rows = c.fetchall()
    print(f'\n== event_types rows ({len(rows)}) ==')
    for r in rows:
        print(r)

conn.close()
