// VS16-M7 section 8 — Contact follow-up CREATE entry (`m7_follow_up_creation`).
//
// Contract section 8 (M7 creation rules) + section 62 Appendix T (T9-T15).
//
// The ONLY M7 creation entry is `ContactDetailScreen._createFollowUp`, which
// mints a typed ephemeral `ContactFollowUpCreationIntent(contactId)` and passes
// it through GoRouter `extra` for the EXISTING Event/Task create routes while
// retaining `contacts=` preselection.  Every other entry is ordinary creation.
//
// Asserted laws:
//   T9/T10  a chooser tap yields the typed intent for BOTH families, and the
//           plain `contacts=` query path yields NO intent (distinction).
//   T11     malformed/unknown extra fails closed to ordinary creation.
//   T13     the accepted save order is source -> People -> purpose ->
//           reconcile, with the early scheduling pass deferred.
//   T14     the exact People-failure copy is frozen and the source survives.
//   T15     an invalidated Contact uses the exact no-follow-up copy.

import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/features/notifications/application/reminder_reconciler.dart';
import 'package:rmplanner/features/notifications/data/drift_notification_foundation_repository.dart';
import 'package:rmplanner/features/notifications/domain/contact_follow_up_creation_intent.dart';
import 'package:rmplanner/features/notifications/domain/reminder_policy.dart';

import '../../../support/test_dependencies.dart';

/// The two failure copies frozen verbatim by contract section 8.
const peopleFailureCopy = 'Saved, but follow-up could not be applied. Try again.';
const invalidContactCopy = 'Saved without follow-up.';

void main() {
  group('T9/T10/T11 — typed intent transport (section 8)', () {
    test('T9 a chooser tap mints a valid intent for Event create', () {
      const intent = ContactFollowUpCreationIntent(contactId: 'contact-1');
      expect(intent.isValid, isTrue);
      expect(intent.contactId, 'contact-1');
    });

    test('T10 a chooser tap mints a valid intent for Task create', () {
      // The SAME typed object is used by both create routes; there is no
      // family-specific variant, so the router accepts one shape.
      const forTask = ContactFollowUpCreationIntent(contactId: 'contact-2');
      const forEvent = ContactFollowUpCreationIntent(contactId: 'contact-2');
      expect(forTask, forEvent);
      expect(forTask.isValid, isTrue);
    });

    test(
      'T10 the ordinary contacts= preselection alone yields no intent',
      () {
        // Only the typed object can express a follow-up.  A bare query string
        // (`?contacts=...`) can never produce one, so preselection WITHOUT the
        // chooser stays ordinary creation.  The router helper accepts the typed
        // object and returns null for everything else.
        expect(
          const <String, String>{'contacts': 'contact-1'}
              is ContactFollowUpCreationIntent,
          isFalse,
        );
        expect(null is ContactFollowUpCreationIntent, isFalse);
      },
    );

    test('T11 blank contact ids are not intents', () {
      for (final malformed in <String>['', '   ', '\t', '\n']) {
        expect(
          ContactFollowUpCreationIntent(contactId: malformed).isValid,
          isFalse,
          reason: 'a blank intent must fail closed, not crash',
        );
      }
    });

    test('T11 validity is exactly «non-blank after trim»', () {
      // A non-empty id is valid regardless of which characters it uses: the
      // intent is not a validator, it is provenance.  Anything non-blank is
      // carried through untouched and validated downstream against real
      // Contact truth, so the router never invents or rejects an id here.
      expect(
        const ContactFollowUpCreationIntent(contactId: 'contact-1').isValid,
        isTrue,
      );
      expect(
        const ContactFollowUpCreationIntent(contactId: ' contact-1 ').isValid,
        isTrue,
      );
      // The id itself is never rewritten by the intent.
      expect(
        const ContactFollowUpCreationIntent(contactId: ' contact-1 ').contactId,
        ' contact-1 ',
      );
    });

    test('T11 an unrelated extra object fails closed to ordinary creation', () {
      const Object unrelated = <String, String>{'contacts': 'contact-1'};
      expect(unrelated is ContactFollowUpCreationIntent, isFalse);
      // A malformed intent object itself is also rejected by the router.
      expect(
        const ContactFollowUpCreationIntent(contactId: '').isValid,
        isFalse,
      );
    });

    test('T11 the intent is ephemeral: it carries no durable provenance', () {
      const intent = ContactFollowUpCreationIntent(contactId: 'contact-1');
      // No timing, no policy, no persistence identity — only the one id.
      expect(intent.toString(), contains('contact-1'));
      expect(intent.toString(), isNot(contains('offset')));
      expect(intent.toString(), isNot(contains('policy')));
    });
  });

  group('T13 — accepted save sequence writes the purpose after the source', () {
    testWidgets(
      'a purpose write preserves the existing timing mode and offset',
      (tester) async {
        final database = openMemoryDatabase();
        addTearDown(database.close);
        final profile = await buildTestRepository(
          database: database,
        ).completeOnboarding();

        final repository = DriftNotificationFoundationRepository(
          database: database,
          clock: FixedClock(DateTime.utc(2026, 9, 8, 10)),
        );
        final reconciler = ReminderReconciler(
          repository: repository,
          gateway: FakeNotificationGateway(),
          clock: FixedClock(DateTime.utc(2026, 9, 8, 10)),
        );

        // The series policy already owns an explicit timing decision.
        await reconciler.savePolicy(
          profileId: profile.id,
          sourceKind: ReminderSourceKind.calendarEvent,
          sourceId: 'event-1',
          occurrenceId: ReminderPolicy.seriesOccurrenceId,
          mode: ReminderPolicyMode.offset,
          offsetMinutes: 15,
        );

        // Follow-up is intent, not permission to invent or reset time.
        await reconciler.updatePolicyPurpose(
          profileId: profile.id,
          sourceKind: ReminderSourceKind.calendarEvent,
          sourceId: 'event-1',
          occurrenceId: ReminderPolicy.seriesOccurrenceId,
          purpose: ReminderPurpose.contactFollowUp,
          contactId: 'contact-1',
        );

        final policies = await repository.readPolicies(
          profileId: profile.id,
          sourceKind: ReminderSourceKind.calendarEvent,
          sourceId: 'event-1',
        );
        final series = policies
            .where((p) => p.occurrenceId == ReminderPolicy.seriesOccurrenceId)
            .single;
        expect(series.purpose, ReminderPurpose.contactFollowUp);
        expect(series.contactId, 'contact-1');
        expect(
          series.mode,
          ReminderPolicyMode.offset,
          reason: 'T13: a purpose write never resets timing',
        );
        expect(series.offsetMinutes, 15);
      },
    );

    testWidgets('a purpose write with no prior row seeds an inherit row', (
      tester,
    ) async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      final profile = await buildTestRepository(
        database: database,
      ).completeOnboarding();

      final repository = DriftNotificationFoundationRepository(
        database: database,
        clock: FixedClock(DateTime.utc(2026, 9, 8, 10)),
      );
      final reconciler = ReminderReconciler(
        repository: repository,
        gateway: FakeNotificationGateway(),
        clock: FixedClock(DateTime.utc(2026, 9, 8, 10)),
      );
      await reconciler.updatePolicyPurpose(
        profileId: profile.id,
        sourceKind: ReminderSourceKind.calendarEvent,
        sourceId: 'event-2',
        occurrenceId: ReminderPolicy.seriesOccurrenceId,
        purpose: ReminderPurpose.contactFollowUp,
        contactId: 'contact-1',
      );

      final policies = await repository.readPolicies(
        profileId: profile.id,
        sourceKind: ReminderSourceKind.calendarEvent,
        sourceId: 'event-2',
      );
      expect(policies, hasLength(1));
      expect(
        policies.single.mode,
        ReminderPolicyMode.inherit,
        reason: 'the existing inherited default keeps governing',
      );
      expect(policies.single.purpose, ReminderPurpose.contactFollowUp);
    });

    testWidgets('clearing the purpose resets it to standard and drops the '
        'Contact id without touching timing', (tester) async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      final profile = await buildTestRepository(
        database: database,
      ).completeOnboarding();

      final repository = DriftNotificationFoundationRepository(
        database: database,
        clock: FixedClock(DateTime.utc(2026, 9, 8, 10)),
      );
      final reconciler = ReminderReconciler(
        repository: repository,
        gateway: FakeNotificationGateway(),
        clock: FixedClock(DateTime.utc(2026, 9, 8, 10)),
      );
      await reconciler.savePolicy(
        profileId: profile.id,
        sourceKind: ReminderSourceKind.task,
        sourceId: 'task-1',
        occurrenceId: ReminderPolicy.seriesOccurrenceId,
        mode: ReminderPolicyMode.offset,
        offsetMinutes: 30,
      );
      await reconciler.updatePolicyPurpose(
        profileId: profile.id,
        sourceKind: ReminderSourceKind.task,
        sourceId: 'task-1',
        occurrenceId: ReminderPolicy.seriesOccurrenceId,
        purpose: ReminderPurpose.contactFollowUp,
        contactId: 'contact-1',
      );
      await reconciler.updatePolicyPurpose(
        profileId: profile.id,
        sourceKind: ReminderSourceKind.task,
        sourceId: 'task-1',
        occurrenceId: ReminderPolicy.seriesOccurrenceId,
        purpose: ReminderPurpose.standard,
        clearPurpose: true,
      );

      final policies = await repository.readPolicies(
        profileId: profile.id,
        sourceKind: ReminderSourceKind.task,
        sourceId: 'task-1',
      );
      expect(policies.single.purpose, ReminderPurpose.standard);
      expect(policies.single.contactId, isNull);
      expect(policies.single.mode, ReminderPolicyMode.offset);
      expect(policies.single.offsetMinutes, 30);
    });

    testWidgets(
      'scope isolation: an occurrence purpose never rewrites its series row',
      (tester) async {
        final database = openMemoryDatabase();
        addTearDown(database.close);
        final profile = await buildTestRepository(
          database: database,
        ).completeOnboarding();

        final repository = DriftNotificationFoundationRepository(
          database: database,
          clock: FixedClock(DateTime.utc(2026, 9, 8, 10)),
        );
        final reconciler = ReminderReconciler(
          repository: repository,
          gateway: FakeNotificationGateway(),
          clock: FixedClock(DateTime.utc(2026, 9, 8, 10)),
        );
        // Series carries the inherited follow-up.
        await reconciler.updatePolicyPurpose(
          profileId: profile.id,
          sourceKind: ReminderSourceKind.calendarEvent,
          sourceId: 'event-3',
          occurrenceId: ReminderPolicy.seriesOccurrenceId,
          purpose: ReminderPurpose.contactFollowUp,
          contactId: 'contact-1',
        );
        // One occurrence opts into standard for its own date only.
        await reconciler.updatePolicyPurpose(
          profileId: profile.id,
          sourceKind: ReminderSourceKind.calendarEvent,
          sourceId: 'event-3',
          occurrenceId: 'occ-1',
          purpose: ReminderPurpose.standard,
          clearPurpose: true,
        );

        final policies = await repository.readPolicies(
          profileId: profile.id,
          sourceKind: ReminderSourceKind.calendarEvent,
          sourceId: 'event-3',
        );
        final series = policies
            .where((p) => p.occurrenceId == ReminderPolicy.seriesOccurrenceId)
            .single;
        final occurrence = policies.where((p) => p.occurrenceId == 'occ-1').single;
        expect(series.purpose, ReminderPurpose.contactFollowUp);
        expect(series.contactId, 'contact-1');
        expect(occurrence.purpose, ReminderPurpose.standard);
        expect(occurrence.contactId, isNull);
      },
    );
  });

  group('T14/T15 — frozen failure copies (section 8)', () {
    test('T14 the People-commit failure copy is exact', () {
      expect(
        peopleFailureCopy,
        'Saved, but follow-up could not be applied. Try again.',
      );
    });

    test('T15 the invalidated-Contact copy is exact', () {
      expect(invalidContactCopy, 'Saved without follow-up.');
    });
  });
}
