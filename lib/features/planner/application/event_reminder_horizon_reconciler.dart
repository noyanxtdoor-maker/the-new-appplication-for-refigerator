import 'package:rmplanner/core/background/background_work_request.dart';
import 'package:rmplanner/core/time/app_clock.dart';
import 'package:rmplanner/features/notifications/application/notification_foundation_repository.dart';
import 'package:rmplanner/features/notifications/application/reminder_reconciler.dart';
import 'package:rmplanner/features/notifications/domain/reminder_policy.dart';
import 'package:rmplanner/features/planner/application/calendar_event_repository.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_day.dart';

typedef ReconcileEventOccurrence =
    Future<void> Function({
      required String eventId,
      required PlannerDate originalDate,
    });

/// Compares the canonical bounded Event projection with active durable
/// reminder work. Recurrence and exception arithmetic stay entirely inside
/// [CalendarEventRangeSource].
final class EventReminderHorizonReconciler {
  const EventReminderHorizonReconciler({
    required this.rangeSource,
    required this.repository,
    required this.reminderReconciler,
    required this.clock,
    required this.reconcileOccurrence,
  });

  static const int horizonDays = 42;
  static const int maximumLeadDays = 7;
  static const int upperWindowBufferDays = 2;

  final CalendarEventRangeSource rangeSource;
  final NotificationFoundationRepository repository;
  final ReminderReconciler reminderReconciler;
  final AppClock clock;
  final ReconcileEventOccurrence reconcileOccurrence;

  Future<void> reconcile({
    required String profileId,
    required PlannerDate today,
    String? eventId,
  }) async {
    final endDate = today.addDays(horizonDays);
    final canonical = await rangeSource.readRange(
      profileId: profileId,
      startDate: today,
      endDate: endDate,
    );
    final expectedKeys = <String>{};
    final processedOccurrenceIds = <String>{};
    final nowUtc = clock.nowUtc();

    for (final item in canonical) {
      final canonicalEventId = item.eventId;
      final originalDate = item.originalDate;
      final startsAtUtc = item.startUtc;
      if (canonicalEventId == null ||
          originalDate == null ||
          (eventId != null && canonicalEventId != eventId) ||
          item.timing != PlannerEventTiming.timed ||
          item.state != PlannerEventState.scheduled ||
          startsAtUtc == null ||
          !_withinEventRelevance(
            nowUtc: nowUtc,
            startUtc: startsAtUtc,
            endUtc: item.endUtc,
          ) ||
          !processedOccurrenceIds.add(item.id)) {
        continue;
      }

      await reconcileOccurrence(
        eventId: canonicalEventId,
        originalDate: originalDate,
      );
      final key = ReminderReconciler.stableKey(
        sourceKind: ReminderSourceKind.calendarEvent,
        profileId: profileId,
        occurrenceId: item.id,
      );
      final work = await repository.readWorkRequest(key);
      if (work != null && _isActive(work.state)) {
        expectedKeys.add(key);
      }
    }

    final durable = await repository.readReminderWork(
      profileId: profileId,
      sourceKind: ReminderSourceKind.calendarEvent,
      sourceId: eventId,
      windowStartUtc: today.asLocalDate
          .subtract(const Duration(days: maximumLeadDays))
          .toUtc(),
      windowEndUtc: endDate.addDays(upperWindowBufferDays).asLocalDate.toUtc(),
    );
    for (final work in durable) {
      final occurrenceId = work.occurrenceId;
      if (occurrenceId == null || expectedKeys.contains(work.stableKey)) {
        continue;
      }
      await reminderReconciler.cancel(
        sourceKind: ReminderSourceKind.calendarEvent,
        profileId: profileId,
        occurrenceId: occurrenceId,
      );
    }
  }

  /// Section 64: an occurrence stays in the horizon while its Event window is
  /// still relevant (now < E), so a currently due Event is no longer discarded
  /// by the obsolete `start > now` filter.  When E is unavailable the legacy
  /// future-start rule is preserved.
  static bool _withinEventRelevance({
    required DateTime nowUtc,
    required DateTime startUtc,
    required DateTime? endUtc,
  }) => endUtc != null && endUtc.isAfter(startUtc)
      ? nowUtc.isBefore(endUtc)
      : startUtc.isAfter(nowUtc);

  static bool _isActive(BackgroundWorkState state) => switch (state) {
    BackgroundWorkState.completed ||
    BackgroundWorkState.queued ||
    BackgroundWorkState.waitingForConstraints ||
    BackgroundWorkState.delayedBySystem ||
    BackgroundWorkState.retryScheduled ||
    BackgroundWorkState.scheduled => true,
    _ => false,
  };
}
