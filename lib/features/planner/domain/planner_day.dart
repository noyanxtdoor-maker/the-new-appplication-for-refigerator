import 'package:rmplanner/features/planner/domain/calendar_event.dart';
import 'package:rmplanner/features/planner/domain/event_contact_channel.dart';
import 'package:rmplanner/features/planner/domain/event_type.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_task.dart';

enum PlannerEventTiming { allDay, timed }

enum PlannerEventState {
  scheduled,
  completedHappened,
  partiallyCompleted,
  didNotHappen,
  cancelled,
  rescheduled,
}

final class PlannerCalendarItem {
  const PlannerCalendarItem({
    required this.id,
    required this.title,
    required this.date,
    required this.timing,
    required this.state,
    required this.requiresReport,
    required this.hasOutcomeReport,
    this.startLocal,
    this.endLocal,
    this.startUtc,
    this.endUtc,
    this.locationText,
    this.isRecurring = false,
    this.replacementId,
    this.linkedTaskIds = const <String>[],
    this.eventId,
    this.originalDate,
    this.timeZoneId,
    this.displayTimeZoneId,
    this.activityTypeId,
    this.activityTypeStableKey,
    this.activityTypeLabel,
    this.activityTypeColorValue,
    this.contactChannel,
    this.isBackupAppointment = false,
    this.backupForEventId,
  });

  final String id;
  final String title;
  final PlannerDate date;
  final PlannerEventTiming timing;
  final PlannerEventState state;
  final bool requiresReport;
  final bool hasOutcomeReport;
  final DateTime? startLocal;
  final DateTime? endLocal;
  final DateTime? startUtc;
  final DateTime? endUtc;
  final String? locationText;
  final bool isRecurring;
  final String? replacementId;
  final List<String> linkedTaskIds;
  final String? eventId;
  final PlannerDate? originalDate;
  final String? timeZoneId;
  final String? displayTimeZoneId;
  final String? activityTypeId;
  final String? activityTypeStableKey;
  final String? activityTypeLabel;
  final int? activityTypeColorValue;
  final EventContactChannel? contactChannel;
  final bool isBackupAppointment;
  final String? backupForEventId;

  /// Mirrors the Event form's single Contact-capable decision. A retained
  /// channel on an ordinary Event is not enough to make it a Contact Event.
  bool get isContactCapable {
    if (isBackupAppointment) {
      return false;
    }
    if (activityTypeStableKey == SystemEventTypeKeys.meaningfulConnection ||
        activityTypeStableKey == SystemEventTypeKeys.contact) {
      return true;
    }
    return activityTypeLabel?.trim().toLowerCase().contains('contact') == true;
  }

  /// Human-visible title with the Event Type label fallback.
  String get displayTitle => plannerItemDisplayTitle(
    storedTitle: title,
    eventTypeLabel: activityTypeLabel,
  );

  bool isAwaitingReport(DateTime nowLocal) {
    if (state != PlannerEventState.scheduled ||
        !requiresReport ||
        hasOutcomeReport) {
      return false;
    }
    if (timing == PlannerEventTiming.allDay) {
      return date.compareTo(PlannerDate.fromDateTime(nowLocal)) < 0;
    }
    final instant = endUtc;
    if (instant != null) {
      return instant.isBefore(nowLocal.toUtc());
    }
    final end = endLocal;
    return end != null && end.isBefore(nowLocal);
  }

  bool get isChange =>
      state == PlannerEventState.cancelled ||
      state == PlannerEventState.rescheduled;
}

final class PlannerChangeItem {
  const PlannerChangeItem({
    required this.id,
    required this.title,
    required this.label,
    required this.isTask,
    this.eventId,
    this.originalDate,
  });

  final String id;
  final String title;
  final String label;
  final bool isTask;
  final String? eventId;
  final PlannerDate? originalDate;
}

final class PlannerDay {
  const PlannerDay({
    required this.selectedDate,
    required this.allDayEvents,
    required this.timedEvents,
    required this.tasks,
    required this.overdueTasks,
    this.completedTasks = const <PlannerTask>[],
    required this.awaitingReportEvents,
    required this.changes,
  });

  final PlannerDate selectedDate;
  final List<PlannerCalendarItem> allDayEvents;
  final List<PlannerCalendarItem> timedEvents;
  final List<PlannerTask> tasks;
  final List<PlannerTask> overdueTasks;
  final List<PlannerTask> completedTasks;
  final List<PlannerCalendarItem> awaitingReportEvents;
  final List<PlannerChangeItem> changes;

  bool get isEmpty =>
      allDayEvents.isEmpty &&
      timedEvents.isEmpty &&
      tasks.isEmpty &&
      overdueTasks.isEmpty &&
      completedTasks.isEmpty &&
      awaitingReportEvents.isEmpty &&
      changes.isEmpty;
}
