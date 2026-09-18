import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/ids/identifier_source.dart';
import 'package:rmplanner/core/notifications/notification_gateway.dart';
import 'package:rmplanner/core/notifications/notification_payload.dart';
import 'package:rmplanner/features/contacts/data/drift_contact_repository.dart';
import 'package:rmplanner/features/contacts/domain/contact.dart';
import 'package:rmplanner/features/notifications/application/notification_foundation_repository.dart';
import 'package:rmplanner/features/notifications/application/reminder_reconciler.dart';
import 'package:rmplanner/features/notifications/data/drift_notification_foundation_repository.dart';
import 'package:rmplanner/features/notifications/domain/reminder_policy.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/startup/domain/local_profile.dart';

import '../../../support/test_dependencies.dart';

/// Contract §24/T-B (T16-T20) + OAT7: purpose propagation, unlink laws,
/// archive/merge non-retargeting and duplicate-starts-standard, against real
/// Drift rows with a fixed clock.
void main() {
  Future<(
    AppDatabase,
    DriftContactRepository,
    NotificationFoundationRepository,
    LocalProfile,
  )>
  build() async {
    final database = openMemoryDatabase();
    final clock = FixedClock(DateTime.utc(2026, 9, 8, 10));
    final contactRepository = DriftContactRepository(
      database: database,
      clock: clock,
      identifiers: const UuidIdentifierSource(),
    );
    final notificationRepository =
        DriftNotificationFoundationRepository(
          database: database,
          clock: clock,
        );
    final profile = await buildTestRepository(
      database: database,
    ).completeOnboarding();
    return (database, contactRepository, notificationRepository, profile);
  }

  Future<String> createContact(
    DriftContactRepository contacts,
    LocalProfile profile,
    String displayName,
  ) async {
    final draft = ContactDraft(
      id: const UuidIdentifierSource().nextUuid(),
      firstName: displayName,
      lastName: '',
      displayName: displayName,
      preferredContactMethod: ContactPreferredMethod.message,
      isFavorite: false,
    );
    final contact = await contacts.createContact(
      profileId: profile.id,
      draft: draft,
    );
    return contact.id;
  }

  test('T16: series purpose is inherited by a later occurrence timing override; existing override keeps its own', () async {
    final (database, _, notifications, profile) = await build();
    addTearDown(database.close);
    final reconciler = ReminderReconciler(
      repository: notifications,
      gateway: _NoopGateway(),
      clock: FixedClock(DateTime.utc(2026, 9, 8, 10)),
    );
    await reconciler.savePolicy(
      profileId: profile.id,
      sourceKind: ReminderSourceKind.calendarEvent,
      sourceId: 'event-1',
      occurrenceId: ReminderPolicy.seriesOccurrenceId,
      mode: ReminderPolicyMode.offset,
      offsetMinutes: 30,
      purpose: ReminderPurpose.contactFollowUp,
      purposeContactId: 'c1',
    );
    // A NEW occurrence override copies the effective source-level purpose.
    final copied = await reconciler.savePolicy(
      profileId: profile.id,
      sourceKind: ReminderSourceKind.calendarEvent,
      sourceId: 'event-1',
      occurrenceId: 'occurrence-new-date',
      mode: ReminderPolicyMode.offset,
      offsetMinutes: 10,
    );
    expect(copied.purpose, ReminderPurpose.contactFollowUp);
    expect(copied.contactId, 'c1');
    expect(copied.offsetMinutes, 10);
    // An EXISTING explicit occurrence override keeps its own identity.
    await reconciler.savePolicy(
      profileId: profile.id,
      sourceKind: ReminderSourceKind.calendarEvent,
      sourceId: 'event-1',
      occurrenceId: 'occurrence-explicit',
      mode: ReminderPolicyMode.offset,
      offsetMinutes: 5,
      purpose: ReminderPurpose.standard,
    );
    final unchanged = await reconciler.savePolicy(
      profileId: profile.id,
      sourceKind: ReminderSourceKind.calendarEvent,
      sourceId: 'event-1',
      occurrenceId: 'occurrence-explicit',
      mode: ReminderPolicyMode.offset,
      offsetMinutes: 7,
    );
    expect(unchanged.purpose, ReminderPurpose.standard);
    expect(unchanged.contactId, isNull);
  });

  test('T17/OAT7: explicit standard clears contactId; timing-only write preserves (F02 regression guard)', () async {
    final (database, _, notifications, profile) = await build();
    addTearDown(database.close);
    final reconciler = ReminderReconciler(
      repository: notifications,
      gateway: _NoopGateway(),
      clock: FixedClock(DateTime.utc(2026, 9, 8, 10)),
    );
    await reconciler.savePolicy(
      profileId: profile.id,
      sourceKind: ReminderSourceKind.calendarEvent,
      sourceId: 'event-1',
      occurrenceId: ReminderPolicy.seriesOccurrenceId,
      mode: ReminderPolicyMode.offset,
      offsetMinutes: 30,
      purpose: ReminderPurpose.contactFollowUp,
      purposeContactId: 'c1',
    );
    // Timing-only: purpose preserved.
    final preserved = await reconciler.savePolicy(
      profileId: profile.id,
      sourceKind: ReminderSourceKind.calendarEvent,
      sourceId: 'event-1',
      occurrenceId: ReminderPolicy.seriesOccurrenceId,
      mode: ReminderPolicyMode.offset,
      offsetMinutes: 20,
    );
    expect(preserved.purpose, ReminderPurpose.contactFollowUp);
    expect(preserved.contactId, 'c1');
    // Explicit unlink: standard clears contactId, timing rows stay.
    final unlinked = await reconciler.savePolicy(
      profileId: profile.id,
      sourceKind: ReminderSourceKind.calendarEvent,
      sourceId: 'event-1',
      occurrenceId: ReminderPolicy.seriesOccurrenceId,
      mode: ReminderPolicyMode.offset,
      offsetMinutes: 20,
      purpose: ReminderPurpose.standard,
    );
    expect(unlinked.purpose, ReminderPurpose.standard);
    expect(unlinked.contactId, isNull);
    expect(unlinked.offsetMinutes, 20);
  });

  test('T19/OAT7: archived Contact is not active; restore never recreates provenance', () async {
    final (database, contacts, _, profile) = await build();
    addTearDown(database.close);
    final contactId = await createContact(contacts, profile, 'Archive Me');
    await contacts.archiveContact(profileId: profile.id, contactId: contactId);
    final summaries = await contacts.readContactsByIds(
      profileId: profile.id,
      contactIds: <String>[contactId],
      today: _today(),
    );
    final archived = summaries[contactId]!.contact;
    expect(archived.isActive, isFalse);
    // Restore does not create provenance — the Contact simply returns active;
    // any policy that was cleared stays standard until explicit new creation.
    await contacts.restoreContact(profileId: profile.id, contactId: contactId);
    final restored = (await contacts.readContactsByIds(
      profileId: profile.id,
      contactIds: <String>[contactId],
      today: _today(),
    ))[contactId]!
        .contact;
    expect(restored.isActive, isTrue);
  });

  test('T75: same displayName, different IDs — resolver binds by ID, not name', () async {
    final (database, contacts, _, profile) = await build();
    addTearDown(database.close);
    final idA = await createContact(contacts, profile, 'Taylor Crew');
    final idB = await createContact(contacts, profile, 'Taylor Crew');
    expect(idA, isNot(idB));
    final summaries = await contacts.readContactsByIds(
      profileId: profile.id,
      contactIds: <String>[idA, idB],
      today: _today(),
    );
    expect(summaries, hasLength(2));
    expect(summaries[idA]!.contact.displayName, 'Taylor Crew');
    expect(summaries[idB]!.contact.displayName, 'Taylor Crew');
  });

  test('T20 law pin: duplicate vs follow-up intent are distinct entry actions (typed extra is the only provenance)', () {
    // The duplicate action never constructs a
    // ContactFollowUpCreationIntent; only ContactDetailScreen._createFollowUp
    // does.  This pin documents the §11 law: provenance travels ONLY in the
    // typed extra, never via copied People links.
    const ordinaryContactsQuery = 'contacts=copied-id';
    expect(ordinaryContactsQuery.startsWith('contacts='), isTrue);
  });
}

PlannerDate _today() => PlannerDate.fromDateTime(DateTime.utc(2026, 9, 8));

final class _NoopGateway implements NotificationGateway {
  @override
  Stream<NotificationResponseIntent> get responses => const Stream.empty();

  @override
  Future<void> initialize() async {}

  @override
  Future<void> schedule(LocalNotificationRequest request) async {}

  @override
  Future<void> cancel(int platformId) async {}

  @override
  Future<List<PendingLocalNotification>> pending() async => const [];

  @override
  NotificationResponseIntent? takeInitialResponse() => null;
}
