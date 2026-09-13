#!/usr/bin/env python3
"""Read-only Drift/SQLite snapshot analyzer for the Next Transfer v47 install.

Opens the database strictly READ-ONLY (URI mode=ro) so it can never mutate the
evidence copy. Reports the integrity gates, the schema version, table/row totals
and the representative owner-table row counts required by the v47 migration
verification contract.

Usage:  python analyze_db.py <path-to-sqlite-copy> <label>
"""

from __future__ import annotations

import json
import sqlite3
import sys
from pathlib import Path

REPRESENTATIVE_TABLES = [
    "contacts",
    "calendar_events",
    "calendar_event_exceptions",
    "calendar_event_operations",
    "planner_tasks",
    "goals",
    "outcome_reports",
    "background_work_requests",
    "reminder_policies",
    "saved_places",
    "event_contact_links",
    "notification_preferences",
    "privacy_preferences",
    "planner_preferences",
]

# The five v47 typed columns this repair introduces.
V47_COLUMNS = [
    "detailed_show_title",
    "detailed_show_description",
    "detailed_show_time",
    "detailed_show_contacts",
    "detailed_show_location",
]


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    db_path = Path(sys.argv[1])
    label = sys.argv[2]

    uri = f"file:{db_path.as_posix()}?mode=ro"
    con = sqlite3.connect(uri, uri=True)
    con.row_factory = sqlite3.Row
    cur = con.cursor()

    out: dict = {"label": label, "path": str(db_path), "bytes": db_path.stat().st_size}

    out["integrity_check"] = cur.execute("PRAGMA integrity_check").fetchone()[0]
    out["quick_check"] = cur.execute("PRAGMA quick_check").fetchone()[0]
    out["user_version"] = cur.execute("PRAGMA user_version").fetchone()[0]
    out["journal_mode"] = cur.execute("PRAGMA journal_mode").fetchone()[0]

    tables = [
        r[0]
        for r in cur.execute(
            "SELECT name FROM sqlite_master WHERE type='table' "
            "AND name NOT LIKE 'sqlite_%' ORDER BY name"
        ).fetchall()
    ]
    out["table_count"] = len(tables)

    total_rows = 0
    counts: dict[str, object] = {}
    for t in tables:
        try:
            n = cur.execute(f'SELECT COUNT(*) FROM "{t}"').fetchone()[0]
            counts[t] = n
            total_rows += n
        except sqlite3.Error as exc:
            counts[t] = f"ERROR: {exc}"
    out["total_row_count"] = total_rows
    out["all_table_counts"] = counts

    out["representative_counts"] = {
        t: counts.get(t, "TABLE ABSENT") for t in REPRESENTATIVE_TABLES
    }

    # notification_preferences schema + the five v47 columns
    try:
        cols = [
            r[1]
            for r in cur.execute(
                "PRAGMA table_info(notification_preferences)"
            ).fetchall()
        ]
    except sqlite3.Error:
        cols = []
    out["notification_preferences_columns"] = cols
    out["v47_columns_present"] = {c: (c in cols) for c in V47_COLUMNS}

    # Owner notification_preferences values (the five fields, if present)
    if cols:
        select_cols = [c for c in V47_COLUMNS if c in cols]
        base = [c for c in ("profile_id",) if c in cols]
        if select_cols:
            rows = cur.execute(
                f"SELECT {', '.join(base + select_cols)} "
                "FROM notification_preferences"
            ).fetchall()
            out["v47_values"] = [dict(r) for r in rows]
        else:
            out["v47_values"] = "v47 COLUMNS ABSENT"

    con.close()

    print(json.dumps(out, indent=2, default=str))
    Path(f".m7_v47_evidence/device/{label}_db_report.json").write_text(
        json.dumps(out, indent=2, default=str), encoding="utf-8"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
