import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/background/background_work_request.dart';
import 'package:rmplanner/core/notifications/notification_gateway.dart';
import 'package:rmplanner/core/notifications/notification_payload.dart';
import 'package:rmplanner/features/notifications/application/reminder_reconciler.dart';
import 'package:rmplanner/features/notifications/data/drift_notification_foundation_repository.dart';
import 'package:rmplanner/features/notifications/domain/notification_preferences.dart';
import 'package:rmplanner/features/notifications/domain/reminder_policy.dart';
import 'package:rmplanner/features/planner/application/calendar_event_repository.dart';
import 'package:rmplanner/features/planner/application/event_reminder_horizon_reconciler.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_day.dart';

import '../../../support/test_dependencies.dart';

void main() {
  final now = DateTime.utc(2026, 9, 6, 10);
  const today = PlannerDate(year: 2026, month: 9, day: 6);

  test(
    'expected existing reminder and platform identity are preserved',
    () async {
      final harness = await _Harness.create(
        now: now,
        items: <PlannerCalendarItem>[
          _eventItem(
            id: 'occurrence-a',
            eventId: 'event-a',
            date: today,
            startsAtUtc: DateTime.utc(2026, 9, 6, 11),
          ),
        ],
      );
      await harness.seedEventWork(
        occurrenceId: 'occurrence-a',
        eventId: 'event-a',
        scheduledForUtc: DateTime.utc(2026, 9, 6, 10, 45),
        platformId: 91,
      );

      await harness.reconcile(today: today);
      await harness.reconcile(today: today);

      final work = await harness.repository.readWorkRequest(
        harness.eventKey('occurrence-a'),
      );
      expect(work?.state, BackgroundWorkState.scheduled);
      expect(work?.platformNotificationId, 91);
      expect(harness.gateway.scheduleCalls, 0);
      expect(harness.gateway.cancelledIds, isEmpty);
    },
  );

  test(
    'obsolete allocated reminder is cancelled and marked obsolete',
    () async {
      final harness = await _Harness.create(now: now);
      await harness.seedEventWork(
        occurrenceId: 'occurrence-obsolete',
        eventId: 'event-a',
        scheduledForUtc: DateTime.utc(2026, 9, 8, 9),
        platformId: 77,
      );

      await harness.reconcile(today: today);

      expect(harness.gateway.cancelledIds, <int>[77]);
      expect(
        (await harness.repository.readWorkRequest(
          harness.eventKey('occurrence-obsolete'),
        ))?.state,
        BackgroundWorkState.cancelledObsolete,
      );
    },
  );

  test(
    'cancelled and deleted canonical occurrences remove reminders',
    () async {
      final harness = await _Harness.create(
        now: now,
        items: <PlannerCalendarItem>[
          _eventItem(
            id: 'occurrence-cancelled',
            eventId: 'event-a',
            date: today.addDays(1),
            startsAtUtc: DateTime.utc(2026, 9, 7, 11),
            state: PlannerEventState.cancelled,
          ),
        ],
      );
      await harness.seedEventWork(
        occurrenceId: 'occurrence-cancelled',
        eventId: 'event-a',
        scheduledForUtc: DateTime.utc(2026, 9, 7, 10, 45),
        platformId: 31,
      );
      await harness.seedEventWork(
        occurrenceId: 'occurrence-deleted',
        eventId: 'event-a',
        scheduledForUtc: DateTime.utc(2026, 9, 8, 10, 45),
        platformId: 32,
      );

      await harness.reconcile(today: today);

      expect(harness.gateway.cancelledIds, <int>[31, 32]);
      for (final occurrenceId in <String>[
        'occurrence-cancelled',
        'occurrence-deleted',
      ]) {
        expect(
          (await harness.repository.readWorkRequest(
            harness.eventKey(occurrenceId),
          ))?.state,
          BackgroundWorkState.cancelledObsolete,
        );
      }
    },
  );

  test(
    'reschedule retires old identity and creates new identity once',
    () async {
      final harness = await _Harness.create(
        now: now,
        items: <PlannerCalendarItem>[
          _eventItem(
            id: 'occurrence-old',
            eventId: 'event-old',
            date: today,
            startsAtUtc: DateTime.utc(2026, 9, 6, 11),
            state: PlannerEventState.rescheduled,
          ),
          _eventItem(
            id: 'occurrence-new',
            eventId: 'event-new',
            date: today.addDays(1),
            startsAtUtc: DateTime.utc(2026, 9, 7, 12),
          ),
        ],
      );
      await harness.seedEventWork(
        occurrenceId: 'occurrence-old',
        eventId: 'event-old',
        scheduledForUtc: DateTime.utc(2026, 9, 6, 10, 45),
        platformId: 41,
      );

      await harness.reconcile(today: today);
      final newAfterFirst = await harness.repository.readWorkRequest(
        harness.eventKey('occurrence-new'),
      );
      await harness.reconcile(today: today);

      expect(harness.gateway.cancelledIds, <int>[41]);
      expect(
        (await harness.repository.readWorkRequest(
          harness.eventKey('occurrence-old'),
        ))?.state,
        BackgroundWorkState.cancelledObsolete,
      );
      expect(newAfterFirst?.state, BackgroundWorkState.scheduled);
      expect(newAfterFirst?.platformNotificationId, isNotNull);
      expect(
        (await harness.repository.readWorkRequest(
          harness.eventKey('occurrence-new'),
        ))?.platformNotificationId,
        newAfterFirst?.platformNotificationId,
      );
      expect(harness.gateway.scheduleCalls, 1);
    },
  );

  test('source scope leaves unrelated Event and Task work untouched', () async {
    final harness = await _Harness.create(now: now);
    await harness.seedEventWork(
      occurrenceId: 'occurrence-a',
      eventId: 'event-a',
      scheduledForUtc: DateTime.utc(2026, 9, 8, 9),
      platformId: 51,
    );
    await harness.seedEventWork(
      occurrenceId: 'occurrence-b',
      eventId: 'event-b',
      scheduledForUtc: DateTime.utc(2026, 9, 8, 10),
      platformId: 52,
    );
    await harness.seedTaskWork(
      occurrenceId: 'task-occurrence',
      taskId: 'task-a',
      scheduledForUtc: DateTime.utc(2026, 9, 8, 11),
      platformId: 53,
    );

    await harness.reconcile(today: today, eventId: 'event-a');

    expect(harness.gateway.cancelledIds, <int>[51]);
    expect(
      (await harness.repository.readWorkRequest(
        harness.eventKey('occurrence-b'),
      ))?.state,
      BackgroundWorkState.scheduled,
    );
    expect(
      (await harness.repository.readWorkRequest(
        harness.taskKey('task-occurrence'),
      ))?.state,
      BackgroundWorkState.scheduled,
    );
  });
}

PlannerCalendarItem _eventItem({
  required String id,
  required String eventId,
  required PlannerDate date,
  required DateTime startsAtUtc,
  PlannerEventState state = PlannerEventState.scheduled,
}) => PlannerCalendarItem(
  id: id,
  eventId: eventId,
  originalDate: date,
  title: eventId,
  date: date,
  timing: PlannerEventTiming.timed,
  state: state,
  requiresReport: false,
  hasOutcomeReport: false,
  startUtc: startsAtUtc,
  endUtc: startsAtUtc.add(const Duration(hours: 1)),
);

final class _RangeSource implements CalendarEventRangeSource {
  const _RangeSource(this.items);

  final List<PlannerCalendarItem> items;

  @override
  Future<List<PlannerCalendarItem>> readRange({
    required String profileId,
    required PlannerDate startDate,
    required PlannerDate endDate,
  }) async => items;
}

final class _RecordingNotificationGateway implements NotificationGateway {
  int scheduleCalls = 0;
  final List<int> cancelledIds = <int>[];

  @override
  Stream<NotificationResponseIntent> get responses => const Stream.empty();

  @override
  Future<void> initialize() async {}

  @override
  Future<void> schedule(LocalNotificationRequest request) async {
    scheduleCalls += 1;
  }

  @override
  Future<void> cancel(int platformId) async {
    cancelledIds.add(platformId);
  }

  @override
  Future<List<PendingLocalNotification>> pending() async => const [];

  @override
  NotificationResponseIntent? takeInitialResponse() => null;
}

final class _Harness {
  _Harness({
    required this.profileId,
    required this.repository,
    required this.gateway,
    required this.coordinator,
  });

  final String profileId;
  final DriftNotificationFoundationRepository repository;
  final _RecordingNotificationGateway gateway;
  final EventReminderHorizonReconciler coordinator;

  static Future<_Harness> create({
    required DateTime now,
    List<PlannerCalendarItem> items = const <PlannerCalendarItem>[],
  }) async {
    final database = openMemoryDatabase();
    addTearDown(database.close);
    final profile = await buildTestRepository(
      database: database,
    ).completeOnboarding();
    final clock = FixedClock(now);
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
    final gateway = _RecordingNotificationGateway();
    final reconciler = ReminderReconciler(
      repository: repository,
      gateway: gateway,
      clock: clock,
    );
    final range = _RangeSource(items);
    return _Harness(
      profileId: profile.id,
      repository: repository,
      gateway: gateway,
      coordinator: EventReminderHorizonReconciler(
        rangeSource: range,
        repository: repository,
        reminderReconciler: reconciler,
        clock: clock,
        reconcileOccurrence:
            ({required String eventId, required PlannerDate originalDate}) {
              final item = items.singleWhere(
                (candidate) =>
                    candidate.eventId == eventId &&
                    candidate.originalDate == originalDate &&
                    candidate.state == PlannerEventState.scheduled,
              );
              return reconciler.reconcile(
                sourceKind: ReminderSourceKind.calendarEvent,
                profileId: profile.id,
                sourceId: eventId,
                occurrenceId: item.id,
                startsAtUtc: item.startUtc,
                globalOffsetMinutes: 15,
                categoryEnabled: true,
                systemEnabled: true,
                sourceActive: true,
                genericTitle: 'Upcoming event',
                genericBody: 'Your event starts soon.',
              );
            },
      ),
    );
  }

  String eventKey(String occurrenceId) => ReminderReconciler.stableKey(
    sourceKind: ReminderSourceKind.calendarEvent,
    profileId: profileId,
    occurrenceId: occurrenceId,
  );

  String taskKey(String occurrenceId) => ReminderReconciler.stableKey(
    sourceKind: ReminderSourceKind.task,
    profileId: profileId,
    occurrenceId: occurrenceId,
  );

  Future<void> seedEventWork({
    required String occurrenceId,
    required String eventId,
    required DateTime scheduledForUtc,
    required int platformId,
  }) => _seedWork(
    key: eventKey(occurrenceId),
    ownerKind: BackgroundWorkOwnerKind.occurrence,
    ownerId: eventId,
    occurrenceId: occurrenceId,
    scheduledForUtc: scheduledForUtc,
    platformId: platformId,
  );

  Future<void> seedTaskWork({
    required String occurrenceId,
    required String taskId,
    required DateTime scheduledForUtc,
    required int platformId,
  }) => _seedWork(
    key: taskKey(occurrenceId),
    ownerKind: BackgroundWorkOwnerKind.task,
    ownerId: taskId,
    occurrenceId: occurrenceId,
    scheduledForUtc: scheduledForUtc,
    platformId: platformId,
  );

  Future<void> _seedWork({
    required String key,
    required BackgroundWorkOwnerKind ownerKind,
    required String ownerId,
    required String occurrenceId,
    required DateTime scheduledForUtc,
    required int platformId,
  }) async {
    await repository.upsertWorkRequest(
      BackgroundWorkRequest(
        stableKey: key,
        profileId: profileId,
        category: BackgroundWorkCategory.reminderRecovery,
        ownerKind: ownerKind,
        ownerId: ownerId,
        occurrenceId: occurrenceId,
        scheduledForUtc: scheduledForUtc,
        state: BackgroundWorkState.scheduled,
        platformNotificationId: platformId,
        // Section 6/33: a durable row records which transport owns it.  These
        // fixtures model an ordinary native row, so the seeded revision carries
        // the same m7n_ render token the reconciler writes.
        sourceRevision: 'm7n_generic',
        attemptCount: 0,
        snoozeCount: 0,
        createdAtUtc: DateTime.utc(2026, 9, 6, 9),
        updatedAtUtc: DateTime.utc(2026, 9, 6, 9),
      ),
    );
  }

  Future<void> reconcile({required PlannerDate today, String? eventId}) {
    return coordinator.reconcile(
      profileId: profileId,
      today: today,
      eventId: eventId,
    );
  }
}
