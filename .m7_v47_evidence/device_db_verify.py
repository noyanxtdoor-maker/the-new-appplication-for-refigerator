"""VS16 M7 - read-only device database safety verification.

Compares a pre-install read-only pull of the owner's next_transfer.sqlite with a
post-install read-only pull, and asserts the non-destructive install contract:

  * schema version is still 47
  * PRAGMA integrity_check = ok
  * PRAGMA quick_check = ok
  * owner row counts are preserved

Opens both files in SQLite read-only mode (mode=ro) so nothing can be written.

Usage:
    python device_db_verify.py <pre.sqlite> <post.sqlite>
"""
import hashlib
import os
import sqlite3
import sys

# The owner-facing tables whose counts must be preserved exactly. Discovered
# from the pre-install pull of the live device database (45 tables total).
TABLES = [
    'activity_ledger_entries',
    'activity_type_indicator_mappings',
    'activity_types',
    'appearance_preferences',
    'background_work_requests',
    'calendar_event_exceptions',
    'calendar_event_operations',
    'calendar_events',
    'contact_availabilities',
    'contact_group_memberships',
    'contact_groups',
    'contact_methods',
    'contact_notes',
    'contact_tag_memberships',
    'contact_tags',
    'contacts',
    'event_contact_links',
    'event_occurrence_participants',
    'goal_achievement_events',
    'goal_activities',
    'goal_outbox_operations',
    'goals',
    'indicator_goal_revisions',
    'life_indicator_definitions',
    'local_profiles',
    'maps_preferences',
    'notification_preferences',
    'onboarding_checkpoints',
    'outcome_report_contribution_drafts',
    'outcome_reports',
    'permission_audits',
    'planner_preferences',
    'planner_tasks',
    'privacy_preferences',
    'reminder_policies',
    'saved_contact_filters',
    'saved_places',
    'task_contact_links',
    'task_event_link_history',
    'task_event_links',
    'task_goal_contributions',
    'task_status_changes',
    'weekly_indicator_target_revisions',
    'weekly_plan_goal_memberships',
    'weekly_plans',
]

# The five M7 "Detailed content" notification columns that must survive the
# replace-install. Their absence would silently break the M7 notification
# settings UI even though the schema version is unchanged.
DETAILED_COLUMNS = [
    'detailed_show_title',
    'detailed_show_description',
    'detailed_show_time',
    'detailed_show_contacts',
    'detailed_show_location',
]


def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def connect_ro(path):
    uri = 'file:%s?mode=ro' % path.replace('\\', '/')
    return sqlite3.connect(uri, uri=True)


def probe(path, label):
    print('-' * 74)
    print('%s: %s' % (label, path))
    print('  bytes  : %d' % os.path.getsize(path))
    print('  sha256 : %s' % sha256(path))
    if not os.path.exists(path):
        return None
    con = connect_ro(path)
    cur = con.cursor()
    info = {}

    for pragma, key in (('user_version', 'user_version'),
                        ('application_id', 'application_id')):
        try:
            info[key] = cur.execute('PRAGMA %s' % pragma).fetchone()[0]
        except Exception as exc:            # pragma: no cover
            info[key] = 'ERR:%s' % exc
    print('  user_version   : %s' % info['user_version'])
    print('  application_id : %s' % info['application_id'])

    try:
        rows = cur.execute('PRAGMA integrity_check').fetchall()
        info['integrity_check'] = ';'.join(r[0] for r in rows)
    except Exception as exc:                # pragma: no cover
        info['integrity_check'] = 'ERR:%s' % exc
    try:
        rows = cur.execute('PRAGMA quick_check').fetchall()
        info['quick_check'] = ';'.join(r[0] for r in rows)
    except Exception as exc:                # pragma: no cover
        info['quick_check'] = 'ERR:%s' % exc
    print('  integrity_check: %s' % info['integrity_check'])
    print('  quick_check    : %s' % info['quick_check'])

    present = {r[0] for r in cur.execute(
        "SELECT name FROM sqlite_master WHERE type='table'").fetchall()}
    info['tables'] = len(present)
    print('  tables         : %d' % len(present))

    counts = {}
    for table in TABLES:
        if table in present:
            try:
                counts[table] = cur.execute(
                    'SELECT COUNT(*) FROM "%s"' % table).fetchone()[0]
            except Exception as exc:        # pragma: no cover
                counts[table] = 'ERR:%s' % exc
    info['counts'] = counts
    for table in sorted(counts):
        print('    %-24s %s' % (table, counts[table]))

    # M7 Detailed-notification column presence (notification_preferences).
    try:
        np_cols = {r[1] for r in cur.execute(
            'PRAGMA table_info(notification_preferences)').fetchall()}
    except Exception as exc:                # pragma: no cover
        np_cols = set()
        print('  notification_preferences columns: ERR:%s' % exc)
    info['detailed_columns'] = {c: (c in np_cols) for c in DETAILED_COLUMNS}
    print('  M7 detailed_show_* columns:')
    for col in DETAILED_COLUMNS:
        print('    [%s] %s' % (
            'PRESENT' if info['detailed_columns'][col] else 'MISSING', col))

    con.close()
    return info


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    pre_path, post_path = sys.argv[1], sys.argv[2]

    pre = probe(pre_path, 'PRE-INSTALL')
    post = probe(post_path, 'POST-INSTALL')

    print()
    print('=' * 74)
    print('NON-DESTRUCTIVE INSTALL CONTRACT')
    print('=' * 74)
    if pre is None or post is None:
        print('FAIL: a database copy is missing')
        return 1

    checks = []
    checks.append(('schema version still 47',
                   pre['user_version'] == post['user_version'] == 47))
    checks.append(('integrity_check = ok',
                   post['integrity_check'] == 'ok'))
    checks.append(('quick_check = ok', post['quick_check'] == 'ok'))
    checks.append(('table count preserved',
                   pre['tables'] == post['tables']))

    all_tables = set(pre['counts']) | set(post['counts'])
    mismatched = [t for t in sorted(all_tables)
                  if pre['counts'].get(t) != post['counts'].get(t)]
    checks.append(('owner row counts preserved (%d tables)' % len(all_tables),
                   not mismatched))

    missing_detailed = [c for c in DETAILED_COLUMNS
                        if not post['detailed_columns'].get(c)]
    checks.append(('M7 detailed_show_* columns present (%d)' % len(
        DETAILED_COLUMNS), not missing_detailed))
    for name, ok in checks:
        print('  [%s] %s' % ('PASS' if ok else 'FAIL', name))
    for table in mismatched:
        print('      %s: %s -> %s' % (table,
                                      pre['counts'].get(table),
                                      post['counts'].get(table)))
    for col in missing_detailed:
        print('      MISSING COLUMN: %s' % col)

    overall = all(ok for _, ok in checks)
    print()
    print('OVERALL = %s' % ('PASS' if overall else 'FAIL'))
    print('=' * 74)
    return 0 if overall else 1


if __name__ == '__main__':
    sys.exit(main())
