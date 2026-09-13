import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/background/background_work_request.dart';
import 'package:rmplanner/core/background/reminder_recovery_request.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/ids/identifier_source.dart';
import 'package:rmplanner/core/time/app_clock.dart';
import 'package:rmplanner/features/contacts/data/drift_contact_repository.dart';
import 'package:rmplanner/features/contacts/domain/contact.dart';
import 'package:rmplanner/features/notifications/data/drift_notification_foundation_repository.dart';
import 'package:rmplanner/features/notifications/domain/reminder_policy.dart';

import '../../../support/test_dependencies.dart';

/// M7 section 10 / 27 / 53 P22 — Contact mutation invalidation.
///
/// A Contact archive, recently-delete or merge removes that Contact from live
/// link truth, so any `contactFollowUp` purpose that named it can no longer
/// resolve at delivery time.  These tests pin the two halves of that law:
///
/// * the durable policy row is invalidated (standard/null) in the SAME
///   transaction as the lifecycle change, and
/// * the section 27 repair intent commits with it, so a later platform failure
///   cannot lose the need to re-resolve the reminder.
///
/// A merge must NOT retarget the purpose at the survivor: a follow-up names a
/// specific human, and silently pointing it at somebody else is exactly the
/// class of error the section 10 verification exists to prevent.
final class _MutableClock implements AppClock {
  _MutableClock(this._now);

  DateTime _now;

  void advance(Duration by) => _now = _now.add(by);

  @override
  DateTime nowUtc() => _now;
}

void main() {
  late AppDatabase database;
  late _MutableClock clock;
  late ReminderRecoveryRequest marker;
  late DriftContactRepository contacts;
  late DriftNotificationFoundationRepository notifications;
  late String profileId;

  setUp(() async {
    database = openMemoryDatabase();
    clock = _MutableClock(DateTime.utc(2026, 9, 11, 10));
    marker = ReminderRecoveryRequest(
      database: database,
      clock: clock,
      identifiers: const UuidIdentifierSource(),
    );
    contacts = DriftContactRepository(
      database: database,
      clock: clock,
      identifiers: const UuidIdentifierSource(),
      reminderRepair: marker,
    );
    notifications = DriftNotificationFoundationRepository(
      database: database,
      clock: clock,
    );
    profileId = (await buildTestRepository(
      database: database,
    ).completeOnboarding()).id;
  });

  tearDown(() => database.close());

  Future<String> seedContact(String name) async {
    final id = const UuidIdentifierSource().nextUuid();
    await contacts.createContact(
      profileId: profileId,
      draft: ContactDraft(
        id: id,
        firstName: name,
        lastName: 'Person',
        displayName: name,
        preferredContactMethod: ContactPreferredMethod.call,
        isFavorite: false,
        requiresNewManualContactValidation: false,
      ),
    );
    return id;
  }

  /// Seeds a `contactFollowUp` purpose with EXPLICIT timing, so the
  /// invalidation's "timing is never touched" half is observable.
  Future<void> seedFollowUp(String contactId, {String occurrenceId = 'series'}) {
    return notifications.upsertPolicy(
      ReminderPolicy(
        id: const UuidIdentifierSource().nextUuid(),
        profileId: profileId,
        sourceKind: ReminderSourceKind.calendarEvent,
        sourceId: 'event-1',
        occurrenceId: occurrenceId,
        purpose: ReminderPurpose.contactFollowUp,
        contactId: contactId,
        mode: ReminderPolicyMode.offset,
        offsetMinutes: 30,
        createdAtUtc: clock.nowUtc(),
        updatedAtUtc: clock.nowUtc(),
      ),
    );
  }

  Future<ReminderPolicy?> policyAt(String occurrenceId) async {
    final policies = await notifications.readPolicies(
      profileId: profileId,
      sourceKind: ReminderSourceKind.calendarEvent,
      sourceId: 'event-1',
    );
    return policies
        .where((policy) => policy.occurrenceId == occurrenceId)
        .firstOrNull;
  }

  Future<BackgroundWorkRequest?> readMarker() =>
      notifications.readWorkRequest(
        ReminderRecoveryRequest.stableKeyFor(profileId),
      );

  Future<List<ReminderPolicyRow>> allPolicyRows() =>
      database.select(database.reminderPolicies).get();

  test('P22 archive invalidates the follow-up purpose and marks repair', () async {
    final contactId = await seedContact('Ada');
    await seedFollowUp(contactId);

    await contacts.archiveContact(profileId: profileId, contactId: contactId);

    final policy = await policyAt('series');
    expect(policy, isNotNull);
    expect(
      policy!.purpose,
      ReminderPurpose.standard,
      reason: 'an archived Contact cannot be a live follow-up target',
    );
    expect(policy.contactId, isNull);
    expect(
      policy.mode,
      ReminderPolicyMode.offset,
      reason: 'timing is never reset by a lifecycle invalidation',
    );
    expect(policy.offsetMinutes, 30);

    final markerRow = await readMarker();
    expect(markerRow, isNotNull);
    expect(markerRow!.category, BackgroundWorkCategory.reminderRecovery);
    expect(markerRow.ownerKind, BackgroundWorkOwnerKind.profile);
  });

  test('P22 recently-deleted invalidates every affected purpose at once', () async {
    final first = await seedContact('Ada');
    final second = await seedContact('Grace');
    final untouched = await seedContact('Katherine');
    await seedFollowUp(first);
    await seedFollowUp(second, occurrenceId: '2026-09-20');
    await seedFollowUp(untouched, occurrenceId: '2026-09-21');

    await contacts.moveContactsToRecentlyDeleted(
      profileId: profileId,
      contactIds: <String>[first, second],
    );

    expect((await policyAt('series'))!.purpose, ReminderPurpose.standard);
    expect((await policyAt('2026-09-20'))!.purpose, ReminderPurpose.standard);
    expect(
      (await policyAt('2026-09-21'))!.purpose,
      ReminderPurpose.contactFollowUp,
      reason: 'an unrelated live Contact keeps its purpose',
    );
    expect(await readMarker(), isNotNull);
  });

  test('P22 merge retires absorbed purposes and never retargets the survivor', () async {
    final survivor = await seedContact('Ada');
    final absorbed = await seedContact('Grace');
    await seedFollowUp(absorbed);

    await contacts.mergeContacts(
      profileId: profileId,
      survivorId: survivor,
      absorbedIds: <String>[absorbed],
      choices: const ContactMergeChoices(<String, String>{}),
    );

    final policy = await policyAt('series');
    expect(
      policy!.purpose,
      ReminderPurpose.standard,
      reason: 'the absorbed Contact no longer exists as link truth',
    );
    expect(
      policy.contactId,
      isNull,
      reason: 'a merge must never silently redirect a follow-up at the survivor',
    );
    expect(
      await allPolicyRows().then(
        (rows) => rows.where(
          (row) => row.contactId == survivor,
        ).length,
      ),
      0,
      reason: 'no purpose may be rewritten to name the survivor',
    );
    expect(await readMarker(), isNotNull);
  });

  test('P22 rename marks repair but keeps the live purpose intact', () async {
    final contactId = await seedContact('Ada');
    await seedFollowUp(contactId);

    await contacts.updateContactIdentityAndMethods(
      profileId: profileId,
      contactId: contactId,
      firstName: 'Ada',
      lastName: 'Lovelace',
      displayName: 'Ada Lovelace',
      preferredContactMethod: ContactPreferredMethod.call,
      methods: const <ContactMethodDraft>[],
    );

    final policy = await policyAt('series');
    expect(
      policy!.purpose,
      ReminderPurpose.contactFollowUp,
      reason: 'a rename is not a lifecycle change',
    );
    expect(policy.contactId, contactId);
    expect(
      await readMarker(),
      isNotNull,
      reason: 'the rename changes the resolved Contact fingerprint',
    );
  });

  test('P22 restore returns the Contact to live truth and marks repair', () async {
    final contactId = await seedContact('Ada');
    await contacts.archiveContact(profileId: profileId, contactId: contactId);
    final afterArchive = await readMarker();

    clock.advance(const Duration(minutes: 5));
    await contacts.restoreContact(profileId: profileId, contactId: contactId);

    final markerRow = await readMarker();
    expect(markerRow, isNotNull);
    expect(
      markerRow!.createdAtUtc,
      afterArchive!.createdAtUtc,
      reason: 'a restore collapses into the SAME pending reconciliation',
    );
    final detail = await contacts.readContactDetail(
      profileId: profileId,
      contactId: contactId,
    );
    expect(detail.contact.lifecycleState, ContactLifecycleState.active);
  });

  test('P22 a rolled-back lifecycle change leaves no invalidation and no marker', () async {
    final contactId = await seedContact('Ada');
    await seedFollowUp(contactId);

    await expectLater(
      database.transaction(() async {
        await database
            .update(database.reminderPolicies)
            .write(
              const ReminderPoliciesCompanion(
                purpose: Value<String>('standard'),
                contactId: Value<String?>(null),
              ),
            );
        await marker.mark(database, profileId: profileId);
        throw StateError('abort');
      }),
      throwsA(isA<StateError>()),
    );

    final policy = await policyAt('series');
    expect(
      policy!.purpose,
      ReminderPurpose.contactFollowUp,
      reason: 'the invalidation shares the mutation transaction',
    );
    expect(await readMarker(), isNull);
  });
}
