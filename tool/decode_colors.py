import sqlite3

conn = sqlite3.connect(
    r"C:/Users/sherl/AppData/Local/Temp/nexttransfer-walk/db/live3.sqlite"
)
c = conn.cursor()


def hex_argb(argb):
    return "#%06X" % (argb & 0xFFFFFF)


print("ACTIVITY TYPES:")
c.execute(
    "SELECT stable_key, label, color_value FROM activity_types ORDER BY position"
)
for stable_key, label, color in c.fetchall():
    print(f"  {label:18s} {stable_key:24s} {hex_argb(color)}")

print()
print("AUG 6 EVENT SNAPSHOT COLORS (title, type label, snapshot, start-end):")
c.execute(
    """
    SELECT ce.title, at.label, ce.activity_type_color_value_snapshot,
           ce.start_minute, ce.end_minute
    FROM calendar_events ce
    LEFT JOIN activity_types at ON at.id = ce.activity_type_id
    WHERE ce.start_date = ?
    ORDER BY ce.start_minute
    """,
    ("2026-08-06",),
)
for title, label, snapshot, start, end in c.fetchall():
    print(f"  {start:4d}-{end:4d}  {label:18s} {hex_argb(snapshot)}")
