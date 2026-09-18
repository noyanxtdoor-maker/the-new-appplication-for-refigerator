"""Restore user data: delete only the exceptions/operations created by
accidental adb swipe gestures during the walkthrough (window 08:20-08:25),
then compare the resulting exception set against the pre-walkthrough DB.
"""
import sqlite3
import shutil
import sys

WINDOW = (1786062000, 1786062300)

SRC = r"C:/Users/sherl/AppData/Local/Temp/nexttransfer-walk/db/backup_modified.sqlite"
DST = r"C:/Users/sherl/AppData/Local/Temp/nexttransfer-walk/db/restored.sqlite"
PRE = r"C:/Users/sherl/AppData/Local/Temp/nexttransfer-walk/db/live3.sqlite"

shutil.copyfile(SRC, DST)
conn = sqlite3.connect(DST)
c = conn.cursor()

c.execute(
    "SELECT id, event_id, start_minute, end_minute, status, created_at_utc "
    "FROM calendar_event_exceptions WHERE created_at_utc >= ? AND created_at_utc <= ?",
    WINDOW,
)
exc = c.fetchall()
print("exceptions in window:", len(exc))
for r in exc:
    print("  ", r)

c.execute(
    "SELECT operation_id, event_id, command, created_at_utc "
    "FROM calendar_event_operations WHERE created_at_utc >= ? AND created_at_utc <= ?",
    WINDOW,
)
ops = c.fetchall()
print("operations in window:", len(ops))
for r in ops:
    print("  ", r)

# Only delete if the counts match the 8+8 we expect.
if len(exc) != 8 or len(ops) != 8:
    print("ABORT: expected exactly 8+8, got", len(exc), len(ops))
    sys.exit(1)

c.execute(
    "DELETE FROM calendar_event_exceptions WHERE created_at_utc >= ? AND created_at_utc <= ?",
    WINDOW,
)
c.execute(
    "DELETE FROM calendar_event_operations WHERE created_at_utc >= ? AND created_at_utc <= ?",
    WINDOW,
)
conn.commit()
print("deleted", len(exc), "exceptions +", len(ops), "operations")

# Compare remaining exception set against the pre-walkthrough snapshot.
pre = sqlite3.connect(PRE)
pc = pre.cursor()
pc.execute("SELECT id FROM calendar_event_exceptions ORDER BY id")
pre_ids = {r[0] for r in pc.fetchall()}
c.execute("SELECT id FROM calendar_event_exceptions ORDER BY id")
now_ids = {r[0] for r in c.fetchall()}
print("pre-walkthrough exceptions:", len(pre_ids))
print("post-restore exceptions:", len(now_ids))
print("exception set identical to pre-walkthrough:", pre_ids == now_ids)

print("integrity:", conn.execute("PRAGMA integrity_check").fetchone()[0])
print("version:", conn.execute("PRAGMA user_version").fetchone()[0])
conn.close()
pre.close()
