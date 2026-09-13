import 'package:characters/characters.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/background/background_work_request.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/notifications/canonical_reminder_delivery_gateway.dart';
import 'package:rmplanner/core/notifications/notification_gateway.dart';
import 'package:rmplanner/features/notifications/application/reminder_delivery_service.dart';
import 'package:rmplanner/features/notifications/application/reminder_enrichment_resolver.dart';
import 'package:rmplanner/features/notifications/application/reminder_notification_renderer.dart';
import 'package:rmplanner/features/notifications/application/reminder_reconciler.dart';
import 'package:rmplanner/features/notifications/data/drift_notification_foundation_repository.dart';
import 'package:rmplanner/features/notifications/data/drift_reminder_enrichment_source.dart';
import 'package:rmplanner/features/notifications/domain/reminder_policy.dart';

import '../../../support/test_dependencies.dart';

void main() {
  // OAT15 — one shared Event eligibility predicate, not a 15-minute constant.
  // S = start, E = end, T = S - L.  Deliverable while T <= now < E.
  final start = DateTime.utc(2026, 9, 11, 10);
  final end = DateTime.utc(2026, 9, 11, 11);

  ReminderEventRelevance classify({
    required DateTime now,
    required DateTime target,
    DateTime? quiet,
    DateTime? s,
    DateTime? e,
  }) => ReminderDeliveryEligibility.classifyEvent(
    nowUtc: now,
    startsAtUtc: s ?? start,
    endsAtUtc: e ?? end,
    targetUtc: target,
    quietAdjustedUtc: quiet ?? target,
  );

  group('OAT15 section 64 Event-end relevance window', () {
    test('offset 0 targets the Event start and is valid at exactly T = S', () {
      final target = ReminderDeliveryEligibility.eventTarget(
        startsAtUtc: start,
        offsetMinutes: 0,
      );
      expect(target, start);
      expect(classify(now: start, target: target), ReminderEventRelevance.due);
      expect(
        classify(
          now: start.add(const Duration(milliseconds: 1)),
          target: target,
        ),
        ReminderEventRelevance.due,
      );
    });

    test('reminder stays deliverable during the Event, up to just before E', () {
      final target = ReminderDeliveryEligibility.eventTarget(
        startsAtUtc: start,
        offsetMinutes: 0,
      );
      expect(
        classify(
          now: end.subtract(const Duration(milliseconds: 1)),
          target: target,
        ),
        ReminderEventRelevance.due,
      );
    });

    test('now == E or later is obsolete with zero new post', () {
      final target = ReminderDeliveryEligibility.eventTarget(
        startsAtUtc: start,
        offsetMinutes: 0,
      );
      expect(classify(now: end, target: target), ReminderEventRelevance.obsolete);
      expect(
        classify(now: end.add(const Duration(hours: 1)), target: target),
        ReminderEventRelevance.obsolete,
      );
    });

    test('long lead is NOT expired by a fixed 15-minute rule', () {
      final target = ReminderDeliveryEligibility.eventTarget(
        startsAtUtc: start,
        offsetMinutes: 60,
      );
      expect(target, start.subtract(const Duration(hours: 1)));
      // target + 15 minutes is still 45 minutes before the Event starts.
      expect(
        classify(now: target.add(const Duration(minutes: 15)), target: target),
        ReminderEventRelevance.due,
        reason: 'a target+15 expiry would wrongly drop this long-lead reminder',
      );
    });

    test('before the quiet-adjusted target the reminder is armed', () {
      final target = ReminderDeliveryEligibility.eventTarget(
        startsAtUtc: start,
        offsetMinutes: 30,
      );
      expect(
        classify(
          now: target.subtract(const Duration(minutes: 1)),
          target: target,
        ),
        ReminderEventRelevance.schedule,
      );
    });

    test('Quiet Hours delaying to/after S suppresses; Q == T stays valid', () {
      final target = ReminderDeliveryEligibility.eventTarget(
        startsAtUtc: start,
        offsetMinutes: 60,
      );
      // Quiet end lands on the Event start: Q > T and Q >= S -> suppressed.
      expect(
        classify(now: target, target: target, quiet: start),
        ReminderEventRelevance.quietSuppressed,
      );
      // Quiet end past the Event start: still suppressed.
      expect(
        classify(
          now: target,
          target: target,
          quiet: start.add(const Duration(minutes: 10)),
        ),
        ReminderEventRelevance.quietSuppressed,
      );
      // Q == T (no actual delay) is never suppression: it is due at T.
      expect(
        classify(now: target, target: target, quiet: target),
        ReminderEventRelevance.due,
      );
    });

    test('invalid Event bounds and negative offsets are rejected', () {
      expect(
        () => ReminderDeliveryEligibility.eventTarget(
          startsAtUtc: start,
          offsetMinutes: -1,
        ),
        throwsArgumentError,
      );
      expect(
        () => classify(now: start, target: start, e: start),
        throwsArgumentError,
        reason: 'E must be strictly after S',
      );
    });

    test('isDeliverable mirrors the due classification', () {
      final target = ReminderDeliveryEligibility.eventTarget(
        startsAtUtc: start,
        offsetMinutes: 0,
      );
      expect(
        ReminderDeliveryEligibility.isDeliverable(
          nowUtc: start,
          startsAtUtc: start,
          endsAtUtc: end,
          targetUtc: target,
          quietAdjustedUtc: target,
        ),
        isTrue,
      );
      expect(
        ReminderDeliveryEligibility.isDeliverable(
          nowUtc: end,
          startsAtUtc: start,
          endsAtUtc: end,
          targetUtc: target,
          quietAdjustedUtc: target,
        ),
        isFalse,
      );
    });
  });

  group('T28/T29/T31 enrichment sanitization and frozen copy', () {
    test('T31 Generic copy is exactly neutral with zero enrichment tokens', () {
      final rendered = ReminderNotificationRenderer.generic;
      expect(rendered.title, '🔔 Next Transfer');
      expect(rendered.body, 'You have a new notification.');
      expect(rendered.body, isNot(contains('Follow up')));
      expect(rendered.body, isNot(contains('Location:')));
      expect(rendered.body, isNot(contains('SENTINEL')));
    });

    test('normal Detailed Event copy matches the baseline template', () {
      final rendered = ReminderNotificationRenderer.eventDetailed(
        startDisplay: DateTime(2026, 9, 11, 9),
        endDisplay: DateTime(2026, 9, 11, 10, 30),
      );
      expect(rendered.title, '📅 Event reminder');
      expect(rendered.body, '9:00 AM–10:30 AM');
    });

    test('follow-up, notes and location each add exactly one line in order', () {
      final rendered = ReminderNotificationRenderer.eventDetailed(
        startDisplay: DateTime(2026, 9, 11, 9),
        endDisplay: DateTime(2026, 9, 11, 10),
        notes: 'Bring the folder',
        followUpName: 'Ana',
        locationText: '123 Main St',
      );
      expect(
        rendered.body,
        '9:00 AM–10:00 AM\nFollow up with Ana.\nBring the folder\n'
        'Location: 123 Main St',
      );
    });

    test('T28 missing enrichment keeps the normal current copy', () {
      final rendered = ReminderNotificationRenderer.eventDetailed(
        startDisplay: DateTime(2026, 9, 11, 9),
        endDisplay: DateTime(2026, 9, 11, 10),
      );
      expect(rendered.body, '9:00 AM–10:00 AM');
      expect(rendered.body, isNot(contains('Follow up')));
      expect(rendered.body, isNot(contains('Location:')));
    });

    test('Task Detailed never gains a location line', () {
      final rendered = ReminderNotificationRenderer.taskDetailed(
        dueMinute: 9 * 60 + 5,
        notes: 'Call the clinic',
        followUpName: 'Ana',
      );
      expect(rendered.title, '✅ Task reminder');
      expect(rendered.body, 'Due 9:05 AM\nFollow up with Ana.\nCall the clinic');
      expect(rendered.body, isNot(contains('Location:')));
    });

    test('T29 URI/coordinate locations are rejected; addresses survive', () {
      expect(
        ReminderEnrichmentSanitizer.sanitizeLocation('123 Main St'),
        '123 Main St',
      );
      expect(
        ReminderEnrichmentSanitizer.sanitizeLocation('14.5995, 120.9842'),
        isNull,
      );
      expect(
        ReminderEnrichmentSanitizer.sanitizeLocation(
          'https://maps.example.com/place',
        ),
        isNull,
      );
      expect(
        ReminderEnrichmentSanitizer.sanitizeLocation('geo:14.5,120.9'),
        isNull,
      );
      expect(
        ReminderEnrichmentSanitizer.sanitizeLocation('14.5995° N'),
        isNull,
      );
      expect(ReminderEnrichmentSanitizer.sanitizeLocation('   '), isNull);
      expect(ReminderEnrichmentSanitizer.sanitizeLocation(null), isNull);
    });

    test('names collapse whitespace, strip bidi controls, cap graphemes', () {
      expect(
        ReminderEnrichmentSanitizer.sanitizeName('  Ana\n  Reyes  '),
        'Ana Reyes',
      );
      expect(ReminderEnrichmentSanitizer.sanitizeName('A\u202Eb'), 'Ab');
      expect(ReminderEnrichmentSanitizer.sanitizeName('   '), isNull);
      final capped = ReminderEnrichmentSanitizer.sanitizeName(
        List<String>.filled(200, 'x').join(),
      )!;
      expect(capped.characters.length, ReminderEnrichmentSanitizer.maxNameGraphemes);
      expect(capped.endsWith('…'), isTrue);
    });
  });

  group('OAT5/OAT6 live Contact freshness through the real Drift port', () {
    late AppDatabase database;
    late String profileId;
    late DriftReminderEnrichmentSource source;
    late ReminderEnrichmentResolver resolver;

    Future<void> seedContact({
      required String id,
      required String name,
      String lifecycle = 'active',
    }) => database
        .into(database.contacts)
        .insert(
          ContactsCompanion.insert(
            id: id,
            profileId: profileId,
            displayName: name,
            lifecycleState: Value(lifecycle),
            createdAtUtc: DateTime.utc(2026, 9, 1),
            updatedAtUtc: DateTime.utc(2026, 9, 1),
          ),
        );

    Future<void> seedEventLink({
      required String id,
      required String contactId,
      String occurrenceId = 'series',
      String status = 'active',
    }) => database
        .into(database.eventContactLinks)
        .insert(
          EventContactLinksCompanion.insert(
            id: id,
            profileId: profileId,
            eventId: 'event-1',
            occurrenceId: Value(occurrenceId),
            contactId: contactId,
            status: Value(status),
            createdAtUtc: DateTime.utc(2026, 9, 1),
            updatedAtUtc: DateTime.utc(2026, 9, 1),
          ),
        );

    Future<String?> resolveName({
      String sourceId = 'event-1',
      String occurrenceId = 'series',
      String contactId = 'contact-1',
    }) => resolver.followUpName(
      profileId: profileId,
      sourceKind: ReminderSourceKind.calendarEvent,
      sourceId: sourceId,
      occurrenceId: occurrenceId,
      contactId: contactId,
    );

    setUp(() async {
      database = openMemoryDatabase();
      final profile = await buildTestRepository(
        database: database,
      ).completeOnboarding();
      profileId = profile.id;
      source = DriftReminderEnrichmentSource(database: database);
      resolver = ReminderEnrichmentResolver(source);
    });

    tearDown(() => database.close());

    test('OAT5 a rename is read as the CURRENT name, never a stale one', () async {
      await seedContact(id: 'contact-1', name: 'Ana Reyes');
      await seedEventLink(id: 'link-1', contactId: 'contact-1');
      expect(await resolveName(), 'Ana Reyes');

      await (database.update(
        database.contacts,
      )..where((table) => table.id.equals('contact-1'))).write(
        const ContactsCompanion(displayName: Value('Ana Cruz')),
      );
      expect(
        await resolveName(),
        'Ana Cruz',
        reason: 'the resolver must read live truth, not a snapshot',
      );
    });

    test('OAT6 two renames keep only the newest name', () async {
      await seedContact(id: 'contact-1', name: 'First');
      await seedEventLink(id: 'link-1', contactId: 'contact-1');
      await (database.update(
        database.contacts,
      )..where((table) => table.id.equals('contact-1'))).write(
        const ContactsCompanion(displayName: Value('Second')),
      );
      await (database.update(
        database.contacts,
      )..where((table) => table.id.equals('contact-1'))).write(
        const ContactsCompanion(displayName: Value('Third')),
      );
      expect(await resolveName(), 'Third');
    });

    test('archived / merged / deleted Contacts never resolve', () async {
      await seedContact(id: 'contact-1', name: 'Ana', lifecycle: 'archived');
      await seedEventLink(id: 'link-1', contactId: 'contact-1');
      expect(await resolveName(), isNull);

      await (database.update(
        database.contacts,
      )..where((table) => table.id.equals('contact-1'))).write(
        const ContactsCompanion(
          lifecycleState: Value('active'),
          mergedIntoContactId: Value('contact-9'),
        ),
      );
      expect(await resolveName(), isNull);
    });

    test('blank display name is not enrichment', () async {
      await seedContact(id: 'contact-1', name: '   ');
      await seedEventLink(id: 'link-1', contactId: 'contact-1');
      expect(await resolveName(), isNull);
    });

    test('occurrence "removed" drops the link; series stays live', () async {
      await seedContact(id: 'contact-1', name: 'Ana');
      await seedEventLink(id: 'link-series', contactId: 'contact-1');
      await seedEventLink(
        id: 'link-occurrence',
        contactId: 'contact-1',
        occurrenceId: 'occ-1',
        status: 'removed',
      );
      expect(await resolveName(), 'Ana');
      expect(
        await resolveName(occurrenceId: 'occ-1'),
        isNull,
        reason: 'the exact occurrence explicitly removed this Contact',
      );
    });

    test('unlinked Contact does not resolve', () async {
      await seedContact(id: 'contact-1', name: 'Ana');
      expect(await resolveName(), isNull);
    });

    test('a Contact bound by id, not by name', () async {
      await seedContact(id: 'contact-1', name: 'Same Name');
      await seedContact(id: 'contact-2', name: 'Same Name');
      await seedEventLink(id: 'link-2', contactId: 'contact-2');
      expect(await resolveName(contactId: 'contact-2'), 'Same Name');
      expect(
        await resolveName(contactId: 'contact-1'),
        isNull,
        reason: 'the unlinked twin must not resolve',
      );
    });
  });

  group('T25/T26/T32/T33 delivery service spine (section 32)', () {
    final target = DateTime.utc(2026, 9, 11, 10);
    final clock = FixedClock(DateTime.utc(2026, 9, 11, 10));

    late AppDatabase database;
    late String profileId;
    late String key;
    late DriftNotificationFoundationRepository repository;
    late _FakeDeliveryGateway gateway;
    late _FakeSourceReader source;
    late ReminderDeliveryService service;

    Future<void> seedWork({
      String revision = 'm7w_generic',
      BackgroundWorkState state = BackgroundWorkState.scheduled,
    }) async {
      await repository.upsertWorkRequest(
        BackgroundWorkRequest(
          stableKey: key,
          profileId: profileId,
          category: BackgroundWorkCategory.reminderRecovery,
          ownerKind: BackgroundWorkOwnerKind.occurrence,
          ownerId: 'event-1',
          occurrenceId: 'occ-1',
          sourceRevision: revision,
          scheduledForUtc: target,
          state: state,
          platformNotificationId: 41,
          attemptCount: 0,
          snoozeCount: 0,
          createdAtUtc: DateTime.utc(2026, 9, 11, 9),
          updatedAtUtc: DateTime.utc(2026, 9, 11, 9),
        ),
      );
    }

    ReminderDeliverySnapshot snapshot({
      bool sourceActive = true,
      bool showDetails = true,
      DateTime? start,
      DateTime? end,
      String? followUpName,
      String? locationText,
    }) => ReminderDeliverySnapshot(
      sourceKind: ReminderSourceKind.calendarEvent,
      sourceId: 'event-1',
      occurrenceId: 'occ-1',
      sourceActive: sourceActive,
      categoryEnabled: true,
      showDetails: showDetails,
      startUtc: start ?? DateTime.utc(2026, 9, 11, 10),
      endUtc: end ?? DateTime.utc(2026, 9, 11, 11),
      followUpName: followUpName,
      locationText: locationText,
    );

    setUp(() async {
      database = openMemoryDatabase();
      profileId = (await buildTestRepository(
        database: database,
      ).completeOnboarding()).id;
      // The durable row carries a real profile FK, so the stable key and the
      // row's profileId must both come from the onboarded profile.
      key = ReminderReconciler.stableKey(
        sourceKind: ReminderSourceKind.calendarEvent,
        profileId: profileId,
        occurrenceId: 'occ-1',
      );
      repository = DriftNotificationFoundationRepository(
        database: database,
        clock: clock,
      );
      gateway = _FakeDeliveryGateway();
      source = _FakeSourceReader();
      service = ReminderDeliveryService(
        repository: repository,
        gateway: gateway,
        source: source,
        clock: clock,
      );
    });

    tearDown(() => database.close());

    Future<ReminderDeliveryOutcome> deliver({
      int? scheduledUtcMs,
      String revision = 'm7w_generic',
      String? stableKey,
    }) => service.deliver(
      stableKey: stableKey ?? key,
      scheduledUtcMs: scheduledUtcMs ?? target.millisecondsSinceEpoch,
      sourceRevision: revision,
    );

    test('T25 malformed input is a terminal handled no-op', () async {
      expect(
        await deliver(stableKey: 'not-a-key'),
        ReminderDeliveryOutcome.handledObsolete,
      );
      expect(
        await deliver(revision: 'has spaces'),
        ReminderDeliveryOutcome.handledObsolete,
      );
      expect(gateway.shown, isEmpty);
    });

    test('T26 a superseded generation never posts or rewrites the row', () async {
      await seedWork(revision: 'm7w_newer');
      expect(
        await deliver(revision: 'm7w_older'),
        ReminderDeliveryOutcome.superseded,
      );
      expect(gateway.shown, isEmpty);
      final row = await repository.readWorkRequest(key);
      expect(row?.state, BackgroundWorkState.scheduled);
      expect(row?.sourceRevision, 'm7w_newer');
    });

    test('a terminal episode is never replayed', () async {
      await seedWork(state: BackgroundWorkState.completed);
      expect(await deliver(), ReminderDeliveryOutcome.handledObsolete);
      expect(gateway.shown, isEmpty);
    });

    test('a non-worker (native) row is not delivered by the worker', () async {
      await seedWork(revision: 'generic');
      expect(await deliver(revision: 'generic'), ReminderDeliveryOutcome.handledObsolete);
      expect(gateway.shown, isEmpty);
    });

    test('T32 an inactive source suppresses without posting', () async {
      await seedWork();
      source.snapshot = snapshot(sourceActive: false);
      expect(await deliver(), ReminderDeliveryOutcome.suppressed);
      expect(gateway.shown, isEmpty);
      expect(
        (await repository.readWorkRequest(key))?.state,
        BackgroundWorkState.cancelledObsolete,
      );
    });

    test('T32 an Event past its end suppresses under section 64', () async {
      await seedWork();
      source.snapshot = snapshot(
        start: DateTime.utc(2026, 9, 11, 8),
        end: DateTime.utc(2026, 9, 11, 9),
      );
      expect(await deliver(), ReminderDeliveryOutcome.suppressed);
      expect(gateway.shown, isEmpty);
    });

    test('a source read failure is a bounded retry, never a stale post', () async {
      await seedWork();
      source.throwOnRead = true;
      expect(await deliver(), ReminderDeliveryOutcome.retryable);
      expect(gateway.shown, isEmpty);
      final row = await repository.readWorkRequest(key);
      expect(row?.state, BackgroundWorkState.retryScheduled);
      expect(row?.attemptCount, 1);
    });

    test('happy path posts once and records a completed receipt', () async {
      await seedWork();
      source.snapshot = snapshot(
        followUpName: 'Ana',
        locationText: '123 Main St',
      );
      expect(await deliver(), ReminderDeliveryOutcome.posted);
      expect(gateway.shown, hasLength(1));
      expect(gateway.shown.single.platformId, 41);
      expect(gateway.shown.single.title, '📅 Event reminder');
      expect(
        gateway.shown.single.body,
        '10:00 AM–11:00 AM\nFollow up with Ana.\nLocation: 123 Main St',
      );
      expect(
        (await repository.readWorkRequest(key))?.state,
        BackgroundWorkState.completed,
      );
    });

    test('Generic preview posts the exact neutral copy only', () async {
      await seedWork();
      source.snapshot = snapshot(
        showDetails: false,
        followUpName: 'Ana',
        locationText: '123 Main St',
      );
      expect(await deliver(), ReminderDeliveryOutcome.posted);
      expect(gateway.shown.single.title, '🔔 Next Transfer');
      expect(gateway.shown.single.body, 'You have a new notification.');
    });

    test('T33 an ambiguous post is uncertain, not a false success', () async {
      await seedWork();
      source.snapshot = snapshot();
      gateway.throwOnShow = true;
      expect(await deliver(), ReminderDeliveryOutcome.uncertain);
      expect(
        (await repository.readWorkRequest(key))?.state,
        BackgroundWorkState.failedActionRequired,
      );
    });
  });
}

final class _FakeDeliveryGateway implements CanonicalReminderDeliveryGateway {
  final List<LocalNotificationRequest> shown = <LocalNotificationRequest>[];
  bool throwOnShow = false;

  @override
  Future<bool> hasPendingReminder(
    int platformId,
    DateTime scheduledAtUtc,
  ) async => false;

  @override
  Future<bool> hasDisplayedReminder(int platformId) async => false;

  @override
  Future<void> showCanonicalReminder(LocalNotificationRequest request) async {
    if (throwOnShow) throw StateError('ambiguous post');
    shown.add(request);
  }
}

final class _FakeSourceReader implements ReminderDeliverySourceReader {
  ReminderDeliverySnapshot? snapshot;
  bool throwOnRead = false;

  @override
  Future<ReminderDeliverySnapshot?> read({
    required String profileId,
    required ReminderSourceKind sourceKind,
    required String sourceId,
    required String occurrenceId,
  }) async {
    if (throwOnRead) throw StateError('source read failed');
    return snapshot;
  }
}
