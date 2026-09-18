// VS16 M7 — transport selection and targeted enriched delivery
// (Appendix T, T-C). Fail-first targets: transport exclusivity, fresh
// enrichment re-read, and privacy-safe fallbacks.
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/background/background_work_gateway.dart';
import 'package:rmplanner/core/background/background_work_request.dart';
import 'package:rmplanner/core/database/app_database.dart'
    hide NotificationPreferences;
import 'package:rmplanner/core/notifications/canonical_reminder_delivery_gateway.dart';
import 'package:rmplanner/core/notifications/notification_gateway.dart';
import 'package:rmplanner/core/notifications/notification_payload.dart';
import 'package:rmplanner/features/notifications/application/reminder_delivery_service.dart';
import 'package:rmplanner/features/notifications/application/reminder_reconciler.dart';
import 'package:rmplanner/features/notifications/data/drift_notification_foundation_repository.dart';
import 'package:rmplanner/features/notifications/data/drift_reminder_enrichment_source.dart';
import 'package:rmplanner/features/notifications/domain/notification_preferences.dart';
import 'package:rmplanner/features/notifications/domain/reminder_policy.dart';
import 'package:rmplanner/features/planner/application/calendar_event_repository.dart';
import 'package:rmplanner/features/planner/application/planner_repository.dart';
import 'package:rmplanner/features/planner/data/drift_event_type_repository.dart';
import 'package:rmplanner/features/planner/domain/calendar_event.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_day.dart';
import 'package:rmplanner/features/planner/domain/planner_task.dart';
import 'package:rmplanner/features/privacy/data/drift_privacy_repository.dart';
import 'package:rmplanner/features/privacy/domain/permission_summary.dart';
import 'package:rmplanner/features/privacy/domain/privacy_settings.dart';

import '../../../support/test_dependencies.dart';

void main() {
  group('M7 transport selection', () {
    late AppDatabase database;
    late DriftNotificationFoundationRepository repository;
    late RecordingBackgroundGateway background;
    late FakeNotificationGateway notifications;
    late String profileId;
    late FixedClock clock;

    setUp(() async {
      database = openMemoryDatabase();
      addTearDown(database.close);
      clock = FixedClock(DateTime.utc(2026, 9, 10, 9));
      repository = DriftNotificationFoundationRepository(
        database: database,
        clock: clock,
      );
      notifications = FakeNotificationGateway();
      background = RecordingBackgroundGateway();
      profileId = (await buildTestRepository(
        database: database,
      ).completeOnboarding()).id;
      await repository.savePreferences(
        profileId: profileId,
        preferences: const NotificationPreferences.defaults().copyWith(
          systemNotificationsEnabled: true,
          eventRemindersEnabled: true,
          taskRemindersEnabled: true,
        ),
      );
    });

    ReminderReconciler reconciler() => ReminderReconciler(
      repository: repository,
      gateway: notifications,
      clock: clock,
      backgroundWorkGateway: background,
    );

    Future<void> reconcileEnriched({
      bool enriched = true,
      int offset = 30,
      DateTime? start,
    }) => reconciler().reconcile(
      sourceKind: ReminderSourceKind.calendarEvent,
      profileId: profileId,
      sourceId: 'event-1',
      occurrenceId: 'occurrence-1',
      startsAtUtc: start ?? DateTime.utc(2026, 9, 10, 12),
      globalOffsetMinutes: offset,
      categoryEnabled: true,
      systemEnabled: true,
      sourceActive: true,
      genericTitle: '🔔 Next Transfer',
      genericBody: 'You have a new notification.',
      detailedTitle: '📅 Event reminder',
      detailedBody: '12:00 PM–1:00 PM',
      showDetails: true,
      renderRevision: 'event_detailed',
      sourceHasLocationEnrichment: enriched,
    );

    test(
      'T21/T34 enriched source enqueues one three-key worker spec',
      () async {
        await reconciler().applySourcePurpose(
          profileId: profileId,
          sourceKind: ReminderSourceKind.calendarEvent,
          sourceId: 'event-1',
          purpose: ReminderPurpose.contactFollowUp,
          contactId: 'contact-1',
        );
        await reconcileEnriched();
        expect(background.enqueued, hasLength(1));
        final spec = background.enqueued.single;
        expect(spec.taskName, 'nt.reminder.delivery');
        expect(spec.inputData.keys.toSet(), <String>{
          'stable_key',
          'scheduled_utc_ms',
          'source_revision',
        });
        expect(
          spec.inputData.keys.any(
            (key) =>
                key.contains('title') ||
                key.contains('body') ||
                key.contains('name') ||
                key.contains('location'),
          ),
          isFalse,
        );
        expect(notifications.scheduleCount, 0);
        final work = await repository.readWorkRequest(
          ReminderReconciler.stableKey(
            sourceKind: ReminderSourceKind.calendarEvent,
            profileId: profileId,
            occurrenceId: 'occurrence-1',
          ),
        );
        expect(work!.sourceRevision, endsWith('m7w_'));
        // T35: the native alarm for this platform id was removed.
        expect(
          notifications.cancelledIds,
          contains(work.platformNotificationId),
        );
      },
    );

    test('T24 identical worker invocation is a no-op when pending', () async {
      await reconciler().applySourcePurpose(
        profileId: profileId,
        sourceKind: ReminderSourceKind.calendarEvent,
        sourceId: 'event-1',
        purpose: ReminderPurpose.contactFollowUp,
        contactId: 'contact-1',
      );
      await reconcileEnriched();
      final spec = background.enqueued.single;
      background.inspectStates[spec.uniqueName] =
          BackgroundGatewayWorkState.scheduled;
      await reconcileEnriched();
      expect(background.enqueued, hasLength(1));
    });

    test('T22 sticky worker transport survives purpose unlink', () async {
      await reconciler().applySourcePurpose(
        profileId: profileId,
        sourceKind: ReminderSourceKind.calendarEvent,
        sourceId: 'event-1',
        purpose: ReminderPurpose.contactFollowUp,
        contactId: 'contact-1',
      );
      await reconcileEnriched();
      expect(background.enqueued, hasLength(1));
      await reconciler().clearContactPurpose(
        profileId: profileId,
        sourceKind: ReminderSourceKind.calendarEvent,
        sourceId: 'event-1',
        contactId: 'contact-1',
      );
      await reconcileEnriched(enriched: false);
      // The key stays on worker transport (sticky m7w_) without native alarm.
      expect(background.enqueued.length, greaterThanOrEqualTo(2));
      expect(notifications.scheduleCount, 0);
      final work = await repository.readWorkRequest(
        ReminderReconciler.stableKey(
          sourceKind: ReminderSourceKind.calendarEvent,
          profileId: profileId,
          occurrenceId: 'occurrence-1',
        ),
      );
      expect(work!.sourceRevision, endsWith('m7w_'));
    });
  });

  group('M7 enriched delivery', () {
    late _DeliveryHarness h;

    setUp(() async {
      h = await _DeliveryHarness.create();
    });

    test('T25/T34 three-key spec is the only accepted durable input', () {
      final spec = _specFor(h, revision: 'src1.m7w_');
      expect(spec.toBackgroundWorkSpec().inputData.keys.toSet(), <String>{
        'stable_key',
        'scheduled_utc_ms',
        'source_revision',
      });
      expect(
        spec.toBackgroundWorkSpec().inputData.values.whereType<String>().any(
          (value) => value.contains(' '),
        ),
        isFalse,
      );
      expect(spec.uniqueName.startsWith('nt.reminder.'), isTrue);
      expect(spec.revisionDigest16, hasLength(16));
    });

    test('T26 superseded revision never posts', () async {
      await h.withWork(revision: 'other.m7w_');
      final outcome = await h.service.deliver(
        stableKey: h.stableKey,
        scheduledAtUtc: h.target,
        sourceRevision: 'src1.m7w_',
      );
      expect(outcome, ReminderDeliveryOutcome.skipped);
      expect(h.gateway.shown, isEmpty);
    });

    test('T27 fresh rename shows the current name only', () async {
      await h.withWork();
      h.enrichment.displayName = 'Grace Hopper';
      await h.service.deliver(
        stableKey: h.stableKey,
        scheduledAtUtc: h.target,
        sourceRevision: 'src1.m7w_',
      );
      expect(
        h.gateway.shown.single.body,
        contains('Follow up with Grace Hopper.'),
      );
      h.gateway.shown.clear();
      h.enrichment.displayName = 'Ada Lovelace';
      await h.workScheduledAgain();
      await h.service.deliver(
        stableKey: h.stableKey,
        scheduledAtUtc: h.target,
        sourceRevision: 'src1.m7w_',
      );
      expect(
        h.gateway.shown.single.body,
        contains('Follow up with Ada Lovelace.'),
      );
      expect(h.gateway.shown.single.body, isNot(contains('Grace Hopper')));
    });

    test('T28 invalid enrichment falls back to normal current copy', () async {
      await h.withWork();
      h.enrichment.contact = null;
      h.enrichment.displayName = null;
      final outcome = await h.service.deliver(
        stableKey: h.stableKey,
        scheduledAtUtc: h.target,
        sourceRevision: 'src1.m7w_',
      );
      expect(outcome, ReminderDeliveryOutcome.delivered);
      expect(h.gateway.shown.single.body, isNot(contains('Follow up with')));
      // Normal Event copy is the time range plus the baseline notes line.
      expect(h.gateway.shown.single.body, contains('–'));
      expect(h.gateway.shown.single.body, contains('Private notes'));
    });

    test(
      'T29 coordinate/URI location is omitted; human address kept',
      () async {
        await h.withWork();
        h.enrichment.contact = null;
        h.occurrence = _occurrence(locationText: '37.7749, -122.4194');
        await h.service.deliver(
          stableKey: h.stableKey,
          scheduledAtUtc: h.target,
          sourceRevision: 'src1.m7w_',
        );
        expect(h.gateway.shown.single.body, isNot(contains('Location:')));
        h.gateway.shown.clear();
        h.occurrence = _occurrence(locationText: '117 Temple Street');
        await h.workScheduledAgain();
        await h.service.deliver(
          stableKey: h.stableKey,
          scheduledAtUtc: h.target,
          sourceRevision: 'src1.m7w_',
        );
        expect(
          h.gateway.shown.single.body,
          contains('Location: 117 Temple Street'),
        );
        h.gateway.shown.clear();
        h.occurrence = _occurrence(locationText: 'geo:37.7,-122.4');
        await h.workScheduledAgain();
        await h.service.deliver(
          stableKey: h.stableKey,
          scheduledAtUtc: h.target,
          sourceRevision: 'src1.m7w_',
        );
        expect(h.gateway.shown.single.body, isNot(contains('Location:')));
      },
    );

    test(
      'T30 missing source suppresses instead of inventing normal copy',
      () async {
        await h.withWork();
        h.occurrence = null;
        final outcome = await h.service.deliver(
          stableKey: h.stableKey,
          scheduledAtUtc: h.target,
          sourceRevision: 'src1.m7w_',
        );
        expect(outcome, ReminderDeliveryOutcome.suppressedObsolete);
        expect(h.gateway.shown, isEmpty);
        final work = await h.repository.readWorkRequest(h.stableKey);
        expect(work!.state, BackgroundWorkState.cancelledObsolete);
      },
    );

    test(
      'T31 privacy lock renders exact neutral copy with zero enrichment',
      () async {
        await h.withWork();
        await h.privacy.setNotificationPreviewMode(
          NotificationPreviewMode.showContent,
        );
        await h.privacy.setLockEnabled(true);
        await h.service.deliver(
          stableKey: h.stableKey,
          scheduledAtUtc: h.target,
          sourceRevision: 'src1.m7w_',
        );
        final body = h.gateway.shown.single.body;
        expect(h.gateway.shown.single.title, '🔔 Next Transfer');
        expect(body, 'You have a new notification.');
        for (final sentinel in <String>[
          'Grace Hopper',
          'Location:',
          '12:00 PM',
          'Private notes',
        ]) {
          expect(body, isNot(contains(sentinel)));
        }
      },
    );

    test('T32 moved target requests reconcile and posts nothing', () async {
      // Durable row still targets the old 60-minute lead while the current
      // policy moved it to 10 minutes before start.
      await h.withWork(
        offsetMinutes: 10,
        rowOffsetMinutes: 60,
        revision: 'src1.m7w_',
      );
      var reconciled = 0;
      final service = h.serviceWithReconcile(() => reconciled++);
      final outcome = await service.deliver(
        stableKey: h.stableKey,
        scheduledAtUtc: h.target,
        sourceRevision: 'src1.m7w_',
      );
      expect(outcome, ReminderDeliveryOutcome.suppressedObsolete);
      expect(reconciled, 1);
      expect(h.gateway.shown, isEmpty);
    });

    test(
      'T33 ambiguous post outcome is delivery_uncertain, never replayed',
      () async {
        await h.withWork();
        h.gateway.throwOnShow = true;
        final first = await h.service.deliver(
          stableKey: h.stableKey,
          scheduledAtUtc: h.target,
          sourceRevision: 'src1.m7w_',
        );
        expect(first, ReminderDeliveryOutcome.terminalFailed);
        final work = await h.repository.readWorkRequest(h.stableKey);
        expect(work!.state, BackgroundWorkState.failedActionRequired);
        expect(work.lastFailureCategory, 'delivery_uncertain');
        h.gateway.throwOnShow = false;
        final second = await h.service.deliver(
          stableKey: h.stableKey,
          scheduledAtUtc: h.target,
          sourceRevision: 'src1.m7w_',
        );
        expect(second, ReminderDeliveryOutcome.skipped);
        expect(h.gateway.shown, isEmpty);
      },
    );
  });
}

CanonicalReminderWorkSpec _specFor(
  _DeliveryHarness h, {
  required String revision,
}) => CanonicalReminderWorkSpec(
  platformId: 42,
  stableKey: h.stableKey,
  scheduledAtUtc: h.target,
  sourceRevision: revision,
);

CalendarEventOccurrence _occurrence({
  String? locationText,
  DateTime? startUtc,
  CalendarEventStatus status = CalendarEventStatus.scheduled,
}) {
  final start = startUtc ?? DateTime.utc(2026, 9, 10, 12);
  final end = start.add(const Duration(hours: 1));
  return CalendarEventOccurrence(
    id: 'occurrence-1',
    eventId: 'event-1',
    profileId: 'profile',
    title: 'Private event title',
    notes: 'Private notes',
    timing: CalendarEventTiming.timed,
    originalDate: PlannerDate(year: 2026, month: 9, day: 10),
    displayDate: PlannerDate(year: 2026, month: 9, day: 10),
    status: status,
    requiresReport: false,
    recurrence: const CalendarRecurrenceRule(
      frequency: CalendarRecurrenceFrequency.none,
    ),
    startUtc: start,
    endUtc: end,
    startDisplay: start.toLocal(),
    endDisplay: end.toLocal(),
    locationText: locationText,
  );
}

final class _DeliveryHarness {
  _DeliveryHarness._({
    required this.database,
    required this.repository,
    required this.privacy,
    required this.profileId,
    required this.gateway,
    required this.background,
    required this.enrichment,
    required this.events,
    required this.planner,
    required this.eventTypes,
    required this.permission,
    required this.clock,
  });

  final AppDatabase database;
  final DriftNotificationFoundationRepository repository;
  final DriftPrivacyRepository privacy;
  final String profileId;
  final _DeliveryGateway gateway;
  final RecordingBackgroundGateway background;
  final _FakeEnrichment enrichment;
  final _FakeOccurrenceLookup events;
  final _FakePlanner planner;
  final DriftEventTypeRepository eventTypes;
  final FakePermissionGateway permission;
  final FixedClock clock;
  CalendarEventOccurrence? occurrence;

  static Future<_DeliveryHarness> create() async {
    final database = openMemoryDatabase();
    addTearDown(database.close);
    // Delivery runs at/after the nominal target (11:00) but before the Event
    // start (12:00), exactly like a delayed WorkManager invocation.
    final clock = FixedClock(DateTime.utc(2026, 9, 10, 11, 30));
    final profile = await buildTestRepository(
      database: database,
    ).completeOnboarding();
    final repository = DriftNotificationFoundationRepository(
      database: database,
      clock: clock,
    );
    await repository.savePreferences(
      profileId: profile.id,
      preferences: const NotificationPreferences.defaults().copyWith(
        systemNotificationsEnabled: true,
        eventRemindersEnabled: true,
        taskRemindersEnabled: true,
      ),
    );
    final privacy = DriftPrivacyRepository(database: database, clock: clock);
    await privacy.setNotificationPreviewMode(
      NotificationPreviewMode.showContent,
    );
    final harness = _DeliveryHarness._(
      database: database,
      repository: repository,
      privacy: privacy,
      profileId: profile.id,
      gateway: _DeliveryGateway(),
      background: RecordingBackgroundGateway(),
      enrichment: _FakeEnrichment(),
      events: _FakeOccurrenceLookup(),
      planner: _FakePlanner(),
      eventTypes: DriftEventTypeRepository(database: database, clock: clock),
      permission: FakePermissionGateway(
        states: const <OptionalPermission, OperatingSystemPermissionState>{
          OptionalPermission.notifications:
              OperatingSystemPermissionState.granted,
        },
      ),
      clock: clock,
    );
    harness.enrichment.displayName = 'Ada Lovelace';
    harness.occurrence = _occurrence();
    harness.events.source = () => harness.occurrence;
    return harness;
  }

  String get stableKey => ReminderReconciler.stableKey(
    sourceKind: ReminderSourceKind.calendarEvent,
    profileId: profileId,
    occurrenceId: 'occurrence-1',
  );

  DateTime get target =>
      DateTime.utc(2026, 9, 10, 12).subtract(const Duration(minutes: 60));

  ReminderDeliveryService get service => serviceWithReconcile(null);

  ReminderDeliveryService serviceWithReconcile(void Function()? onReconcile) =>
      ReminderDeliveryService(
        repository: repository,
        deliveryGateway: gateway,
        notificationGateway: gateway,
        events: events,
        tasks: planner,
        eventTypes: eventTypes,
        privacy: privacy,
        permission: permission,
        enrichmentSource: enrichment,
        clock: clock,
        requestFullReconcile: onReconcile == null
            ? null
            : () async => onReconcile(),
      );

  Future<void> withWork({
    String revision = 'src1.m7w_',
    int offsetMinutes = 60,
    int? rowOffsetMinutes,
  }) async {
    await repository.upsertPolicy(
      ReminderPolicy(
        id: 'policy-1',
        profileId: profileId,
        sourceKind: ReminderSourceKind.calendarEvent,
        sourceId: 'event-1',
        occurrenceId: ReminderPolicy.seriesOccurrenceId,
        purpose: ReminderPurpose.contactFollowUp,
        contactId: 'contact-1',
        mode: ReminderPolicyMode.offset,
        offsetMinutes: offsetMinutes,
        createdAtUtc: clock.nowUtc(),
        updatedAtUtc: clock.nowUtc(),
      ),
    );
    final scheduled = DateTime.utc(
      2026,
      9,
      10,
      12,
    ).subtract(Duration(minutes: rowOffsetMinutes ?? offsetMinutes));
    await repository.upsertWorkRequest(
      BackgroundWorkRequest(
        stableKey: stableKey,
        profileId: profileId,
        category: BackgroundWorkCategory.reminderRecovery,
        ownerKind: BackgroundWorkOwnerKind.occurrence,
        ownerId: 'event-1',
        occurrenceId: 'occurrence-1',
        sourceRevision: revision,
        scheduledForUtc: scheduled,
        state: BackgroundWorkState.scheduled,
        platformNotificationId: 42,
        attemptCount: 0,
        snoozeCount: 0,
        createdAtUtc: clock.nowUtc(),
        updatedAtUtc: clock.nowUtc(),
      ),
    );
  }

  Future<void> workScheduledAgain() async {
    final work = (await repository.readWorkRequest(stableKey))!;
    await repository.upsertWorkRequest(
      work.copyWith(
        state: BackgroundWorkState.scheduled,
        attemptCount: 0,
        clearLastFailureCategory: true,
        clearCompletedAtUtc: true,
      ),
    );
  }
}

final class _DeliveryGateway
    implements NotificationGateway, CanonicalReminderDeliveryGateway {
  final shown = <LocalNotificationRequest>[];
  final scheduled = <LocalNotificationRequest>[];
  final pendingIds = <int>{};
  bool throwOnShow = false;

  @override
  Stream<NotificationResponseIntent> get responses => const Stream.empty();

  @override
  Future<void> initialize() async {}

  @override
  Future<void> schedule(LocalNotificationRequest request) async =>
      scheduled.add(request);

  @override
  Future<void> cancel(int platformId) async => pendingIds.remove(platformId);

  @override
  Future<List<PendingLocalNotification>> pending() async => pendingIds
      .map((id) => PendingLocalNotification(platformId: id))
      .toList(growable: false);

  @override
  NotificationResponseIntent? takeInitialResponse() => null;

  @override
  Future<bool> hasPendingReminder(
    int platformId,
    DateTime scheduledAtUtc,
  ) async => pendingIds.contains(platformId);

  @override
  Future<bool> hasDisplayedReminder(int platformId) async =>
      pendingIds.contains(platformId);

  @override
  Future<void> showCanonicalReminder(LocalNotificationRequest request) async {
    if (throwOnShow) throw StateError('ambiguous platform outcome');
    shown.add(request);
  }
}

final class RecordingBackgroundGateway implements BackgroundWorkGateway {
  final enqueued = <BackgroundWorkSpec>[];
  final inspectStates = <String, BackgroundGatewayWorkState>{};
  final cancelled = <String>[];

  @override
  Future<void> initialize() async {}

  @override
  Future<void> enqueueUnique(BackgroundWorkSpec work) async {
    work.validate();
    enqueued.add(work);
  }

  @override
  Future<void> cancelUnique(String uniqueName) async =>
      cancelled.add(uniqueName);

  @override
  Future<BackgroundGatewayWorkState> inspect(String uniqueName) async =>
      inspectStates[uniqueName] ?? BackgroundGatewayWorkState.absent;
}

final class _FakeEnrichment implements ReminderEnrichmentSource {
  String? displayName = 'Ada Lovelace';
  ReminderEnrichmentContact? contact;

  @override
  Future<ReminderEnrichmentContact?> readFollowUpContact({
    required String profileId,
    required ReminderSourceKind sourceKind,
    required String sourceId,
    required String occurrenceId,
    required String contactId,
  }) async {
    final configured = contact;
    if (configured != null) return configured;
    final name = displayName;
    if (name == null) return null;
    return ReminderEnrichmentContact(
      contactId: contactId,
      displayName: name,
      updatedAtUtc: DateTime.utc(2026, 9, 10),
    );
  }
}

final class _FakeOccurrenceLookup implements CalendarEventOccurrenceIdLookup {
  CalendarEventOccurrence? occurrence;
  CalendarEventOccurrence? Function()? source;

  @override
  Future<CalendarEventOccurrence?> readOccurrenceById({
    required String profileId,
    required String eventId,
    required String occurrenceId,
  }) async => source?.call() ?? occurrence;
}

final class _FakePlanner implements PlannerRepository {
  @override
  Future<PlannerTask?> readTask({
    required String profileId,
    required String taskId,
  }) async => null;

  @override
  Future<PlannerDay> readDay({
    required String profileId,
    required PlannerDate selectedDate,
    required PlannerDate today,
  }) async => throw UnimplementedError();

  @override
  Future<PlannerTask> saveTask({
    required String profileId,
    required PlannerTaskDraft draft,
    bool confirmLinkedTypeTransfer = false,
  }) async => throw UnimplementedError();

  @override
  Future<TaskStatusChangeOutcome> changeTaskStatus({
    required String profileId,
    required String taskId,
    required PlannerTaskStatus target,
    required String operationId,
    String? reason,
    bool confirmLinkedTypeTransfer = false,
  }) async => throw UnimplementedError();

  @override
  Future<TaskHardDeleteOutcome> hardDeleteTask({
    required String profileId,
    required String taskId,
  }) async => TaskHardDeleteOutcome.notFound;
}
