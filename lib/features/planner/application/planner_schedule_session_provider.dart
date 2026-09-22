import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_schedule_session.dart';

/// P3 (2026-09-22) — transient state for the Event form's scheduling session.
///
/// OWNER LAW: the session is in-memory only.  It is deliberately NOT persisted,
/// so losing it to process death discards the provisional schedule instead of
/// resurrecting a half-made decision; the form's own draft is untouched until
/// `Confirm` returns a [PlannerScheduleResult] and the ordinary Save writes.
final plannerScheduleSessionProvider =
    NotifierProvider<PlannerScheduleSessionController, PlannerScheduleSession?>(
      PlannerScheduleSessionController.new,
    );

final class PlannerScheduleSessionController
    extends Notifier<PlannerScheduleSession?> {
  @override
  PlannerScheduleSession? build() => null;

  void begin(PlannerScheduleSession session) {
    state = session;
  }

  /// Move/resize from the Planner timeline.  The start is clamped to the day
  /// (the canvas cannot start an Event before 00:00) and the end keeps at least
  /// the fifteen-minute minimum the rest of the app enforces, so a drag can
  /// never produce a broken interval.
  void updateSchedule({
    required PlannerDate date,
    required int startMinute,
    required int endMinute,
  }) {
    final current = state;
    if (current == null) {
      return;
    }
    final resolvedStart = startMinute.clamp(0, 1439).toInt();
    final minimumEnd = resolvedStart + 15;
    final resolvedEnd = endMinute < minimumEnd ? minimumEnd : endMinute;
    state = current.copyWith(
      date: date,
      startMinute: resolvedStart,
      endMinute: resolvedEnd.clamp(15, 2880).toInt(),
    );
  }

  /// Keeps the block's duration when the session moves across dates.
  void updateDate(PlannerDate date) {
    final current = state;
    if (current != null) {
      state = current.copyWith(date: date);
    }
  }

  PlannerScheduleResult? confirm() {
    final current = state;
    if (current == null) {
      return null;
    }
    state = null;
    return PlannerScheduleResult(
      date: current.date,
      startMinute: current.startMinute,
      endMinute: current.endMinute,
    );
  }

  void clear() {
    state = null;
  }
}
