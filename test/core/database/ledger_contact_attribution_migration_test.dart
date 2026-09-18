import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/features/planner/domain/outcome_reporting.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../support/test_dependencies.dart';

/// VS-11B1 (OPD-3-004): v28 -> v29 adds ONE nullable column
/// (activity_ledger_entries.contact_id). Additive only: existing rows stay
/// valid, no historical per-Contact fact is invented, row counts are
/// preserved, and PRAGMA quick_check stays ok.
void main() {
  test(
    'VS-11B1: v28 to v29 adds only nullable contact_id on the Activity Ledger',
    () async {
      final sqliteDatabase = sqlite3.openInMemory();
      try {
        final version28 = AppDatabase.forTesting(
          NativeDatabase.opened(sqliteDatabase, closeUnderlyingOnClose: false),
          schemaVersionOverride: 28,
        );
        final profile = await buildTestRepository(
          database: version28,
        ).completeOnboarding();
        final now = DateTime.utc(2026, 8, 17, 12);
        // Two pre-v29 submitted reports (the ledger rows reference them).
        for (final (reportId, label, slotKey) in <(String, String, String)>[
          ('bbbbbbbb-0000-4000-8000-000000000101', 'Legacy visit', 'e:1'),
          ('bbbbbbbb-0000-4000-8000-000000000102', 'Legacy run', 'e:2'),
        ]) {
          await version28.into(version28.outcomeReports).insert(
            OutcomeReportsCompanion.insert(
              id: reportId,
              profileId: profile.id,
              sourceType: 'calendar_event',
              sourceId: 'cccccccc-0000-4000-8000-000000000101',
              sourceLabel: label,
              sourceSlotKey: slotKey,
              status: OutcomeReportStatus.submitted.name,
              activityDate: '2026-08-17',
              createdAtUtc: now,
              updatedAtUtc: now,
              submittedAtUtc: Value<DateTime?>(now),
              effectiveSlotKey: Value<String?>(slotKey),
            ),
          );
        }
        // A pre-v29 non-Contact ledger row (classic contribution).
        await version28.into(version28.activityLedgerEntries).insert(
          ActivityLedgerEntriesCompanion.insert(
            id: 'aaaaaaaa-0000-4000-8000-000000000101',
            profileId: profile.id,
            sourceReportId: 'bbbbbbbb-0000-4000-8000-000000000101',
            entryType: ActivityLedgerEntryType.contribution.name,
            indicatorKey: 'meaningful_connections',
            valueScaled: 1,
            valueScale: 0,
            unit: 'count',
            activityDate: '2026-08-17',
            ruleKey: 'life-indicator:meaningful_connections:1:0:count',
            idempotencyKey: 'aaaaaaaa-0000-4000-8000-000000000101',
            recordedAtUtc: now,
          ),
        );
        // A second classic ledger row on another indicator.
        await version28.into(version28.activityLedgerEntries).insert(
          ActivityLedgerEntriesCompanion.insert(
            id: 'aaaaaaaa-0000-4000-8000-000000000102',
            profileId: profile.id,
            sourceReportId: 'bbbbbbbb-0000-4000-8000-000000000102',
            entryType: ActivityLedgerEntryType.contribution.name,
            indicatorKey: 'exercise',
            valueScaled: 1,
            valueScale: 0,
            unit: 'count',
            activityDate: '2026-08-17',
            ruleKey: 'life-indicator:exercise:1:0:count',
            idempotencyKey: 'aaaaaaaa-0000-4000-8000-000000000102',
            recordedAtUtc: now,
          ),
        );

        // Drop contact_id to recreate the exact v28 boundary (the current
        // table declaration necessarily carries the newest column even when
        // the schema version is overridden).
        await version28.customStatement(
          'ALTER TABLE activity_ledger_entries DROP COLUMN contact_id',
        );
        final before = await version28
            .select(version28.activityLedgerEntries)
            .get();
        expect(before, hasLength(2));
        await version28.close();

        final version29 = AppDatabase.forTesting(
          NativeDatabase.opened(sqliteDatabase, closeUnderlyingOnClose: false),
          schemaVersionOverride: 29,
        );
        expect(
          await version29.customSelect('PRAGMA user_version').getSingle()
              .then((row) => row.read<int>('user_version')),
          29,
        );
        final columns = await version29
            .customSelect('PRAGMA table_info(activity_ledger_entries)')
            .get();
        final contactColumn = columns
            .where((row) => row.read<String>('name') == 'contact_id')
            .toList();
        expect(contactColumn, hasLength(1));
        expect(contactColumn.single.read<int>('notnull'), 0,
            reason: 'contact_id is nullable (additive)');

        // Row counts preserved; pre-v29 rows remain valid with NULL
        // attribution and are NOT fabricated into per-Contact facts.
        final rows = await version29
            .select(version29.activityLedgerEntries)
            .get();
        expect(rows, hasLength(2));
        for (final row in rows) {
          expect(row.contactId, isNull);
          expect(row.entryType, ActivityLedgerEntryType.contribution.name);
        }
        final quickCheck = await version29
            .customSelect('PRAGMA quick_check')
            .getSingle();
        expect(quickCheck.read<String>('quick_check'), 'ok');
        await version29.close();
      } finally {
        sqliteDatabase.close();
      }
    },
  );
}
