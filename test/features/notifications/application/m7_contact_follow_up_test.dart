// VS16 M7 — explicit Contact follow-up purpose law (Appendix T, T-A/T-B).
//
// Fail-first targets: T4 (timing-only policy writes must not clear purpose).
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/database/app_database.dart'
    hide NotificationPreferences;
import 'package:rmplanner/core/ids/identifier_source.dart';
import 'package:rmplanner/features/contacts/data/drift_contact_repository.dart';
import 'package:rmplanner/features/contacts/domain/contact.dart';
import 'package:rmplanner/features/notifications/application/reminder_reconciler.dart';
import 'package:rmplanner/features/notifications/data/drift_notification_foundation_repository.dart';
import 'package:rmplanner/features/notifications/domain/reminder_policy.dart';

import '../../../support/test_dependencies.dart';

void main() {
  late AppDatabase database;
  late DriftNotificationFoundationRepository repository;
  late ReminderReconciler reconciler;
  late String profileId;

  setUp(() async {
    database = openMemoryDatabase();
    addTearDown(database.close);
    final clock = FixedClock(DateTime.utc(2026, 9, 10, 12));
    repository = DriftNotificationFoundationRepository(
      database: database,
      clock: clock,
    );
    reconciler = ReminderReconciler(
      repository: repository,
      gateway: FakeNotificationGateway(),
      clock: clock,
    );
    profileId = (await buildTestRepository(
      database: database,
    ).completeOnboarding()).id;
  });

  test('T1/T2 purpose validation pins explicit Contact identity', () {
    expect(
      () => ReminderPolicy(
        id: 'p1',
        profileId: profileId,
        sourceKind: ReminderSourceKind.task,
        sourceId: 'task-1',
        occurrenceId: 'series',
        purpose: ReminderPurpose.contactFollowUp,
        mode: ReminderPolicyMode.inherit,
        createdAtUtc: DateTime.utc(2026),
        updatedAtUtc: DateTime.utc(2026),
      ).validate(),
      throwsArgumentError,
    );
    expect(
      () => ReminderPolicy(
        id: 'p2',
        profileId: profileId,
        sourceKind: ReminderSourceKind.task,
        sourceId: 'task-1',
        occurrenceId: 'series',
        purpose: ReminderPurpose.standard,
        contactId: 'contact-1',
        mode: ReminderPolicyMode.inherit,
        createdAtUtc: DateTime.utc(2026),
        updatedAtUtc: DateTime.utc(2026),
      ).validate(),
      throwsArgumentError,
    );
  });

  test('T4 timing-only save preserves explicit purpose (F02)', () async {
    await reconciler.applySourcePurpose(
      profileId: profileId,
      sourceKind: ReminderSourceKind.task,
      sourceId: 'task-1',
      purpose: ReminderPurpose.contactFollowUp,
      contactId: 'contact-1',
    );
    await reconciler.savePolicy(
      profileId: profileId,
      sourceKind: ReminderSourceKind.task,
      sourceId: 'task-1',
      occurrenceId: ReminderPolicy.seriesOccurrenceId,
      mode: ReminderPolicyMode.offset,
      offsetMinutes: 30,
    );
    final rows = await repository.readPolicies(
      profileId: profileId,
      sourceKind: ReminderSourceKind.task,
      sourceId: 'task-1',
    );
    expect(rows, hasLength(1));
    expect(rows.single.purpose, ReminderPurpose.contactFollowUp);
    expect(rows.single.contactId, 'contact-1');
    expect(rows.single.mode, ReminderPolicyMode.offset);
    expect(rows.single.offsetMinutes, 30);
  });

  test('T5 explicit standard clears Contact identity', () async {
    await reconciler.applySourcePurpose(
      profileId: profileId,
      sourceKind: ReminderSourceKind.calendarEvent,
      sourceId: 'event-1',
      purpose: ReminderPurpose.contactFollowUp,
      contactId: 'contact-1',
    );
    await reconciler.savePolicy(
      profileId: profileId,
      sourceKind: ReminderSourceKind.calendarEvent,
      sourceId: 'event-1',
      occurrenceId: ReminderPolicy.seriesOccurrenceId,
      mode: ReminderPolicyMode.inherit,
      purpose: ReminderPurpose.standard,
    );
    final rows = await repository.readPolicies(
      profileId: profileId,
      sourceKind: ReminderSourceKind.calendarEvent,
      sourceId: 'event-1',
    );
    expect(rows.single.purpose, ReminderPurpose.standard);
    expect(rows.single.contactId, isNull);
  });

  test('T16 new occurrence override inherits the series purpose', () async {
    await reconciler.applySourcePurpose(
      profileId: profileId,
      sourceKind: ReminderSourceKind.calendarEvent,
      sourceId: 'event-1',
      purpose: ReminderPurpose.contactFollowUp,
      contactId: 'contact-1',
    );
    await reconciler.savePolicy(
      profileId: profileId,
      sourceKind: ReminderSourceKind.calendarEvent,
      sourceId: 'event-1',
      occurrenceId: 'occurrence-2',
      mode: ReminderPolicyMode.offset,
      offsetMinutes: 15,
    );
    final rows = await repository.readPolicies(
      profileId: profileId,
      sourceKind: ReminderSourceKind.calendarEvent,
      sourceId: 'event-1',
    );
    final occurrence = rows.singleWhere(
      (row) => row.occurrenceId == 'occurrence-2',
    );
    expect(occurrence.purpose, ReminderPurpose.contactFollowUp);
    expect(occurrence.contactId, 'contact-1');
    expect(occurrence.offsetMinutes, 15);
    // An EXISTING occurrence override keeps its own purpose on a timing edit.
    await reconciler.savePolicy(
      profileId: profileId,
      sourceKind: ReminderSourceKind.calendarEvent,
      sourceId: 'event-1',
      occurrenceId: 'occurrence-3',
      mode: ReminderPolicyMode.inherit,
      purpose: ReminderPurpose.standard,
    );
    await reconciler.savePolicy(
      profileId: profileId,
      sourceKind: ReminderSourceKind.calendarEvent,
      sourceId: 'event-1',
      occurrenceId: 'occurrence-3',
      mode: ReminderPolicyMode.offset,
      offsetMinutes: 45,
    );
    final rowsAfter = await repository.readPolicies(
      profileId: profileId,
      sourceKind: ReminderSourceKind.calendarEvent,
      sourceId: 'event-1',
    );
    final occurrence3 = rowsAfter.singleWhere(
      (row) => row.occurrenceId == 'occurrence-3',
    );
    expect(occurrence3.purpose, ReminderPurpose.standard);
    expect(occurrence3.contactId, isNull);
  });

  test('T17 source unlink clears purpose and preserves timing rows', () async {
    await reconciler.applySourcePurpose(
      profileId: profileId,
      sourceKind: ReminderSourceKind.task,
      sourceId: 'task-1',
      purpose: ReminderPurpose.contactFollowUp,
      contactId: 'contact-1',
    );
    await reconciler.savePolicy(
      profileId: profileId,
      sourceKind: ReminderSourceKind.task,
      sourceId: 'task-1',
      occurrenceId: 'task:task-1:2026-09-12',
      mode: ReminderPolicyMode.offset,
      offsetMinutes: 20,
    );
    await reconciler.clearContactPurpose(
      profileId: profileId,
      sourceKind: ReminderSourceKind.task,
      sourceId: 'task-1',
      contactId: 'contact-1',
    );
    final rows = await repository.readPolicies(
      profileId: profileId,
      sourceKind: ReminderSourceKind.task,
      sourceId: 'task-1',
    );
    expect(rows, hasLength(2));
    for (final row in rows) {
      expect(row.purpose, ReminderPurpose.standard);
      expect(row.contactId, isNull);
    }
    final dated = rows.singleWhere(
      (row) => row.occurrenceId == 'task:task-1:2026-09-12',
    );
    expect(dated.mode, ReminderPolicyMode.offset);
    expect(dated.offsetMinutes, 20);
  });

  test('T18 occurrence unlink blocks series purpose leakage', () async {
    await reconciler.applySourcePurpose(
      profileId: profileId,
      sourceKind: ReminderSourceKind.calendarEvent,
      sourceId: 'event-1',
      purpose: ReminderPurpose.contactFollowUp,
      contactId: 'contact-1',
    );
    await reconciler.clearContactPurpose(
      profileId: profileId,
      sourceKind: ReminderSourceKind.calendarEvent,
      sourceId: 'event-1',
      contactId: 'contact-1',
      occurrenceId: 'occurrence-unlinked',
    );
    final rows = await repository.readPolicies(
      profileId: profileId,
      sourceKind: ReminderSourceKind.calendarEvent,
      sourceId: 'event-1',
    );
    final exact = rows.singleWhere(
      (row) => row.occurrenceId == 'occurrence-unlinked',
    );
    expect(exact.purpose, ReminderPurpose.standard);
    expect(exact.contactId, isNull);
    expect(exact.mode, ReminderPolicyMode.inherit);
    // The series intent itself is untouched by an occurrence-only unlink.
    final series = rows.singleWhere(
      (row) => row.occurrenceId == ReminderPolicy.seriesOccurrenceId,
    );
    expect(series.purpose, ReminderPurpose.contactFollowUp);
  });

  test('T19 archive invalidates follow-up purpose and marks repair', () async {
    final contacts = DriftContactRepository(
      database: database,
      clock: FixedClock(DateTime.utc(2026, 9, 10, 12)),
      identifiers: const UuidIdentifierSource(),
    );
    final contact = await contacts.createContact(
      profileId: profileId,
      draft: ContactDraft(
        id: const UuidIdentifierSource().nextUuid(),
        firstName: 'Ada',
        lastName: 'Lovelace',
        displayName: 'Ada Lovelace',
        preferredContactMethod: ContactPreferredMethod.call,
        isFavorite: false,
      ),
    );
    await reconciler.applySourcePurpose(
      profileId: profileId,
      sourceKind: ReminderSourceKind.calendarEvent,
      sourceId: 'event-1',
      purpose: ReminderPurpose.contactFollowUp,
      contactId: contact.id,
    );
    await contacts.archiveContact(profileId: profileId, contactId: contact.id);
    final rows = await repository.readPolicies(
      profileId: profileId,
      sourceKind: ReminderSourceKind.calendarEvent,
      sourceId: 'event-1',
    );
    expect(rows.single.purpose, ReminderPurpose.standard);
    expect(rows.single.contactId, isNull);
    final marker = await repository.readWorkRequest(
      'reconcile:reminders:$profileId',
    );
    expect(marker, isNotNull);
    expect(marker!.state.name, 'queued');
  });

  test('T17b ordinary unlink clears only a missing chosen Contact', () async {
    await reconciler.applySourcePurpose(
      profileId: profileId,
      sourceKind: ReminderSourceKind.task,
      sourceId: 'task-1',
      purpose: ReminderPurpose.contactFollowUp,
      contactId: 'contact-1',
    );
    await reconciler.savePolicy(
      profileId: profileId,
      sourceKind: ReminderSourceKind.task,
      sourceId: 'task-1',
      occurrenceId: 'task:task-1:2026-09-12',
      mode: ReminderPolicyMode.offset,
      offsetMinutes: 20,
    );
    // Chosen Contact still linked: no clearing, no retargeting.
    final untouched = await reconciler.clearUnlinkedPurpose(
      profileId: profileId,
      sourceKind: ReminderSourceKind.task,
      sourceId: 'task-1',
      currentContactIds: const <String>{'contact-1'},
    );
    expect(untouched, isFalse);
    // Chosen Contact removed by an ordinary People commit.
    final cleared = await reconciler.clearUnlinkedPurpose(
      profileId: profileId,
      sourceKind: ReminderSourceKind.task,
      sourceId: 'task-1',
      currentContactIds: const <String>{'contact-2'},
    );
    expect(cleared, isTrue);
    final rows = await repository.readPolicies(
      profileId: profileId,
      sourceKind: ReminderSourceKind.task,
      sourceId: 'task-1',
    );
    expect(rows, hasLength(2));
    for (final row in rows) {
      expect(row.purpose, ReminderPurpose.standard);
      expect(row.contactId, isNull);
    }
    final dated = rows.singleWhere(
      (row) => row.occurrenceId == 'task:task-1:2026-09-12',
    );
    expect(dated.mode, ReminderPolicyMode.offset);
    expect(dated.offsetMinutes, 20);
  });

  test('T20 ordinary new source starts standard', () async {
    await reconciler.savePolicy(
      profileId: profileId,
      sourceKind: ReminderSourceKind.calendarEvent,
      sourceId: 'event-duplicate',
      occurrenceId: ReminderPolicy.seriesOccurrenceId,
      mode: ReminderPolicyMode.inherit,
    );
    final rows = await repository.readPolicies(
      profileId: profileId,
      sourceKind: ReminderSourceKind.calendarEvent,
      sourceId: 'event-duplicate',
    );
    expect(rows.single.purpose, ReminderPurpose.standard);
    expect(rows.single.contactId, isNull);
  });
}
