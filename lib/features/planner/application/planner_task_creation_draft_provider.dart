import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';

/// Task-only counterpart to the accepted Event creation draft.  It carries a
/// single scheduled minute because Tasks have no persisted duration and never
/// expose Event resize semantics.
final plannerTaskCreationDraftProvider =
    NotifierProvider<
      PlannerTaskCreationDraftController,
      PlannerTaskCreationDraft?
    >(PlannerTaskCreationDraftController.new);

final class PlannerTaskCreationDraft {
  const PlannerTaskCreationDraft({
    required this.id,
    required this.date,
    required this.minute,
    this.title = '',
    this.taskId,
  });

  final String id;
  final PlannerDate date;
  final int minute;
  final String title;

  /// Non-null only when the draft represents an existing Task opened from
  /// Planner. It never changes the Task's stable identity.
  final String? taskId;

  PlannerTaskCreationDraft copyWith({
    PlannerDate? date,
    int? minute,
    String? title,
  }) {
    return PlannerTaskCreationDraft(
      id: id,
      date: date ?? this.date,
      minute: minute ?? this.minute,
      title: title ?? this.title,
      taskId: taskId,
    );
  }
}

final class PlannerTaskCreationDraftController
    extends Notifier<PlannerTaskCreationDraft?> {
  @override
  PlannerTaskCreationDraft? build() => null;

  void begin({
    required String id,
    required PlannerDate date,
    required int minute,
    String title = '',
    String? taskId,
  }) {
    state = PlannerTaskCreationDraft(
      id: id,
      date: date,
      minute: minute.clamp(0, 1439),
      title: title,
      taskId: taskId,
    );
  }

  void updateMinute(int minute) {
    final current = state;
    final normalized = minute.clamp(0, 1439);
    if (current == null || current.minute == normalized) return;
    state = current.copyWith(minute: normalized);
  }

  void updateDate(PlannerDate date) {
    final current = state;
    if (current == null || current.date == date) return;
    state = current.copyWith(date: date);
  }

  void updateTitle(String title) {
    final current = state;
    if (current == null || current.title == title) return;
    state = current.copyWith(title: title);
  }

  void clear(String id) {
    if (state?.id == id) state = null;
  }

  void clearCurrentAfterLifecycle() {
    scheduleMicrotask(() {
      if (ref.mounted) state = null;
    });
  }
}
