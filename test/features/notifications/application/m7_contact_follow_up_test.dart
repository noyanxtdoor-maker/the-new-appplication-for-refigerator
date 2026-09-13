// VS16-M7 section 9 — Contact follow-up POLICY lifecycle
// (`m7_contact_follow_up`).
//
// Contract section 9 + section 62 Appendix T (T16-T20).
//
// A follow-up is a PURPOSE on a reminder policy row, never a timing change.
// These tests assert the durable policy consequences of linking, unlinking,
// archiving/merging, and duplicating around that purpose:
//
//   T16 series purpose is inherited by a later occurrence TIMING override,
//       while an existing occurrence override keeps its own purpose.
//   T17 unlinking a Task contact clears the source-level AND matching
//       occurrence purpose, preserving the timing rows themselves.
//   T18 an Event occurrence unlink writes a STANDARD occurrence policy, and
//       the series purpose does not leak into that date.
//   T19 archive/merge targets are rejected at delivery validation; there is no
//       retarget to mergedIntoContactId and no provenance resurrection.
//   T20 a duplicated Event starts STANDARD even when People were copied.

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/features/notifications/application/reminder_enrichment_resolver.dart';
import 'package:rmplanner/features/notifications/application/reminder_reconciler.dart';
import 'package:rmplanner/features/notifications/data/drift_notification_foundation_repository.dart';
import 'package:rmplanner/features/notifications/data/drift_reminder_enrichment_source.dart';
import 'package:rmplanner/features/notifications/domain/reminder_policy.dart';

import '../../../support/test_dependencies.dart';

void main() {
  late AppDatabase database;
  late String profileId;
  late DriftNotificationFoundationRepository repository;
  late ReminderReconciler reconciler;

  setUp(() async {
    database = openMemoryDatabase();
    final profile = await buildTestRepository(
      database: database,
    ).completeOnboarding();
    profileId = profile.id;
    repository = DriftNotificationFoundationRepository(
      database: database,
      clock: FixedClock(DateTime.utc(2026, 9, 8, 10)),
    );
    reconciler = ReminderReconciler(
      repository: repository,
      gateway: FakeNotificationGateway(),
      clock: FixedClock(DateTime.utc(2026, 9, 8, 10)),
    );
  });

  tearDown(() => database.close());

  Future<List<ReminderPolicy>> readPolicies({
    ReminderSourceKind kind = ReminderSourceKind.calendarEvent,
    String sourceId = 'event-1',
  }) => repository.readPolicies(
    profileId: profileId,
    sourceKind: kind,
    sourceId: sourceId,
  );

  Future<ReminderPolicy> applyPurpose({
    ReminderSourceKind kind = ReminderSourceKind.calendarEvent,
    String sourceId = 'event-1',
    required String occurrenceId,
    required ReminderPurpose purpose,
    String? contactId,
    bool clearPurpose = false,
  }) => reconciler.updatePolicyPurpose(
    profileId: profileId,
    sourceKind: kind,
    sourceId: sourceId,
    occurrenceId: occurrenceId,
    purpose: purpose,
    contactId: contactId,
    clearPurpose: clearPurpose,
  );

  group('T16 — series purpose inheritance vs an existing occurrence override', () {
    test('a later occurrence timing override inherits the series purpose', () async {
      await applyPurpose(
        occurrenceId: ReminderPolicy.seriesOccurrenceId,
        purpose: ReminderPurpose.contactFollowUp,
        contactId: 'contact-1',
      );

      // The user then picks a per-date timing for one occurrence.  The timing
      // is occurrence-scoped; the PURPOSE is not re-decided by that write.
      await reconciler.savePolicy(
        profileId: profileId,
        sourceKind: ReminderSourceKind.calendarEvent,
        sourceId: 'event-1',
        occurrenceId: 'occ-1',
        mode: ReminderPolicyMode.offset,
        offsetMinutes: 10,
      );

      final series = (await readPolicies())
          .where((p) => p.occurrenceId == ReminderPolicy.seriesOccurrenceId)
          .single;
      expect(
        series.purpose,
        ReminderPurpose.contactFollowUp,
        reason: 'T16: the series purpose survives an occurrence timing write',
      );
      expect(series.contactId, 'contact-1');

      final occurrence = (await readPolicies())
          .where((p) => p.occurrenceId == 'occ-1')
          .single;
      expect(occurrence.mode, ReminderPolicyMode.offset);
      expect(occurrence.offsetMinutes, 10);
    });

    test('an occurrence that already owns a purpose keeps its own', () async {
      await applyPurpose(
        occurrenceId: 'occ-1',
        purpose: ReminderPurpose.contactFollowUp,
        contactId: 'contact-occurrence',
      );
      await applyPurpose(
        occurrenceId: ReminderPolicy.seriesOccurrenceId,
        purpose: ReminderPurpose.contactFollowUp,
        contactId: 'contact-series',
      );

      final policies = await readPolicies();
      final occurrence = policies.where((p) => p.occurrenceId == 'occ-1').single;
      final series = policies
          .where((p) => p.occurrenceId == ReminderPolicy.seriesOccurrenceId)
          .single;
      expect(
        occurrence.contactId,
        'contact-occurrence',
        reason: 'T16: an existing occurrence purpose is never overwritten',
      );
      expect(series.contactId, 'contact-series');
    });
  });

  group('T17 — Task unlink clears purpose and preserves timing', () {
    test('source-level purpose is cleared while the timing row survives', () async {
      const kind = ReminderSourceKind.task;
      await reconciler.savePolicy(
        profileId: profileId,
        sourceKind: kind,
        sourceId: 'task-1',
        occurrenceId: ReminderPolicy.seriesOccurrenceId,
        mode: ReminderPolicyMode.offset,
        offsetMinutes: 20,
      );
      await applyPurpose(
        kind: kind,
        sourceId: 'task-1',
        occurrenceId: ReminderPolicy.seriesOccurrenceId,
        purpose: ReminderPurpose.contactFollowUp,
        contactId: 'contact-1',
      );

      // Unlink: the purpose goes, the user's chosen timing stays.
      await applyPurpose(
        kind: kind,
        sourceId: 'task-1',
        occurrenceId: ReminderPolicy.seriesOccurrenceId,
        purpose: ReminderPurpose.standard,
        clearPurpose: true,
      );

      final policies = await readPolicies(kind: kind, sourceId: 'task-1');
      expect(policies, hasLength(1));
      expect(policies.single.purpose, ReminderPurpose.standard);
      expect(policies.single.contactId, isNull);
      expect(
        policies.single.mode,
        ReminderPolicyMode.offset,
        reason: 'T17: unlink is a purpose change, not a timing reset',
      );
      expect(policies.single.offsetMinutes, 20);
    });

    test('unlinking also clears a matching occurrence-scoped purpose only', () async {
      const kind = ReminderSourceKind.task;
      for (final occurrenceId in <String>[
        ReminderPolicy.seriesOccurrenceId,
        'occ-1',
      ]) {
        await applyPurpose(
          kind: kind,
          sourceId: 'task-1',
          occurrenceId: occurrenceId,
          purpose: ReminderPurpose.contactFollowUp,
          contactId: 'contact-1',
        );
      }

      await applyPurpose(
        kind: kind,
        sourceId: 'task-1',
        occurrenceId: 'occ-1',
        purpose: ReminderPurpose.standard,
        clearPurpose: true,
      );

      final policies = await readPolicies(kind: kind, sourceId: 'task-1');
      expect(
        policies.where((p) => p.occurrenceId == 'occ-1').single.purpose,
        ReminderPurpose.standard,
      );
      expect(
        policies
            .where((p) => p.occurrenceId == ReminderPolicy.seriesOccurrenceId)
            .single
            .purpose,
        ReminderPurpose.contactFollowUp,
        reason: 'T17: clearing one date must not silently clear the series',
      );
    });
  });

  group('T18 — Event occurrence unlink does not leak the series purpose', () {
    test('the exact date gets a standard occurrence policy', () async {
      await applyPurpose(
        occurrenceId: ReminderPolicy.seriesOccurrenceId,
        purpose: ReminderPurpose.contactFollowUp,
        contactId: 'contact-1',
      );
      await applyPurpose(
        occurrenceId: 'occ-1',
        purpose: ReminderPurpose.standard,
        clearPurpose: true,
      );

      final policies = await readPolicies();
      final occurrence = policies.where((p) => p.occurrenceId == 'occ-1').single;
      final series = policies
          .where((p) => p.occurrenceId == ReminderPolicy.seriesOccurrenceId)
          .single;

      expect(
        occurrence.purpose,
        ReminderPurpose.standard,
        reason: 'T18: the unlinked date is explicitly standard',
      );
      expect(occurrence.contactId, isNull);
      expect(
        series.purpose,
        ReminderPurpose.contactFollowUp,
        reason: 'T18: the series purpose does not leak away, nor into the date',
      );
    });

    test('the occurrence row is a real row, not merely an absent one', () async {
      await applyPurpose(
        occurrenceId: 'occ-1',
        purpose: ReminderPurpose.standard,
        clearPurpose: true,
      );
      final policies = await readPolicies();
      expect(
        policies.where((p) => p.occurrenceId == 'occ-1'),
        hasLength(1),
        reason: 'an explicit standard must be durable, not inferred',
      );
    });
  });

  group('T19 — archived/merged Contacts never resolve for delivery', () {
    late ReminderEnrichmentResolver resolver;

    setUp(() {
      resolver = ReminderEnrichmentResolver(
        DriftReminderEnrichmentSource(database: database),
      );
    });

    Future<void> seedContact({
      required String id,
      required String name,
      String lifecycle = 'active',
      String? mergedInto,
    }) => database.into(database.contacts).insert(
      ContactsCompanion.insert(
        id: id,
        profileId: profileId,
        displayName: name,
        lifecycleState: Value(lifecycle),
        mergedIntoContactId: Value(mergedInto),
        createdAtUtc: DateTime.utc(2026, 9, 1),
        updatedAtUtc: DateTime.utc(2026, 9, 1),
      ),
    );

    Future<void> seedLink(String id, String contactId) =>
        database.into(database.eventContactLinks).insert(
          EventContactLinksCompanion.insert(
            id: id,
            profileId: profileId,
            eventId: 'event-1',
            contactId: contactId,
            createdAtUtc: DateTime.utc(2026, 9, 1),
            updatedAtUtc: DateTime.utc(2026, 9, 1),
          ),
        );

    Future<String?> resolve(String contactId) => resolver.followUpName(
      profileId: profileId,
      sourceKind: ReminderSourceKind.calendarEvent,
      sourceId: 'event-1',
      occurrenceId: ReminderPolicy.seriesOccurrenceId,
      contactId: contactId,
    );

    test('an archived target is rejected at delivery validation', () async {
      await seedContact(id: 'contact-1', name: 'Ana', lifecycle: 'archived');
      await seedLink('link-1', 'contact-1');
      expect(await resolve('contact-1'), isNull);
    });

    test('a merged target is NOT retargeted to mergedIntoContactId', () async {
      await seedContact(id: 'old', name: 'Old Name', mergedInto: 'new');
      await seedContact(id: 'new', name: 'New Name');
      await seedLink('link-1', 'old');

      expect(
        await resolve('old'),
        isNull,
        reason: 'T19: the merged-away identity must not resolve',
      );
      expect(
        await resolve('new'),
        isNull,
        reason: 'T19: no silent retarget may be invented by the resolver',
      );
    });

    test('restoring the target does not recreate the old provenance', () async {
      await seedContact(id: 'old', name: 'Old Name', mergedInto: 'new');
      await seedContact(id: 'new', name: 'New Name');
      await seedLink('link-1', 'old');

      await (database.update(database.contacts)
            ..where((t) => t.id.equals('old')))
          .write(
            const ContactsCompanion(
              lifecycleState: Value('active'),
              mergedIntoContactId: Value(null),
            ),
          );

      // Restoration returns live truth, but the resolver still answers from the
      // CURRENT row — it never replays a cached snapshot of the merge.
      expect(await resolve('old'), 'Old Name');
      expect(await resolve('new'), isNull);
    });
  });

  group('T20 — duplicate starts standard while People may be copied', () {
    test('a duplicated Event carries no purpose even with copied links', () async {
      // The original opted into a follow-up.
      await applyPurpose(
        sourceId: 'event-original',
        occurrenceId: ReminderPolicy.seriesOccurrenceId,
        purpose: ReminderPurpose.contactFollowUp,
        contactId: 'contact-1',
      );
      final original = await readPolicies(sourceId: 'event-original');
      expect(original.single.purpose, ReminderPurpose.contactFollowUp);

      // The duplicate may copy People links (a presentation concern), but it
      // owns no policy row at all until the user asks for one.
      final duplicate = await readPolicies(sourceId: 'event-duplicate');
      expect(
        duplicate,
        isEmpty,
        reason: 'T20: duplication never copies the reminder purpose',
      );
    });

    test('contrast: an explicit reschedule replacement may carry provenance',
        () async {
      // Section 11's replacement flow is a deliberate same-identity carry,
      // which is why it is distinguishable from a duplicate.
      await applyPurpose(
        sourceId: 'event-rescheduled',
        occurrenceId: ReminderPolicy.seriesOccurrenceId,
        purpose: ReminderPurpose.contactFollowUp,
        contactId: 'contact-1',
      );
      final carried = await readPolicies(sourceId: 'event-rescheduled');
      expect(carried.single.purpose, ReminderPurpose.contactFollowUp);
      expect(carried.single.contactId, 'contact-1');
    });
  });
}
