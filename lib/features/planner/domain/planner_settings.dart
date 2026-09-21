import 'package:rmplanner/features/planner/domain/planner_view.dart';

enum PlannerInitialScrollBehavior { currentTime, visibleStart, dayStart }

enum EventCreationPresentation { fullScreen, sheet }

final class PlannerSettings {
  const PlannerSettings({
    required this.defaultDurationMinutes,
    required this.visibleStartHour,
    required this.visibleEndHour,
    required this.use24HourTime,
    required this.snapMinutes,
    required this.showCurrentTime,
    required this.initialScrollBehavior,
    required this.creationPresentation,
    required this.quickEditEnabled,
    required this.showCompletedItems,
    required this.showCancelledItems,
    required this.weekStartDay,
    required this.preferredPresentation,
    required this.contentFilters,
    required this.timelineHourHeight,
    this.defaultEventTypeId,
    this.defaultReminderMinutes,
  });

  const PlannerSettings.defaults()
    : defaultEventTypeId = null,
      // Delta 4.2R R8 owner override: new Events default to 30 minutes
      // (replacing the temporary Delta 4.2 60-minute default).
      defaultDurationMinutes = 30,
      defaultReminderMinutes = null,
      visibleStartHour = 6,
      visibleEndHour = 22,
      use24HourTime = false,
      snapMinutes = 15,
      showCurrentTime = true,
      initialScrollBehavior = PlannerInitialScrollBehavior.currentTime,
      creationPresentation = EventCreationPresentation.sheet,
      quickEditEnabled = true,
      showCompletedItems = true,
      showCancelledItems = false,
      weekStartDay = DateTime.monday,
      preferredPresentation = PlannerPresentation.day,
      contentFilters = const PlannerContentFilters.defaults(),
      timelineHourHeight = PlannerZoomPolicy.normalHourHeight;

  final String? defaultEventTypeId;
  final int defaultDurationMinutes;
  final int? defaultReminderMinutes;
  final int visibleStartHour;
  final int visibleEndHour;
  final bool use24HourTime;
  final int snapMinutes;
  final bool showCurrentTime;
  final PlannerInitialScrollBehavior initialScrollBehavior;
  final EventCreationPresentation creationPresentation;
  final bool quickEditEnabled;
  final bool showCompletedItems;
  final bool showCancelledItems;
  final int weekStartDay;
  final PlannerPresentation preferredPresentation;
  final PlannerContentFilters contentFilters;
  final double timelineHourHeight;

  /// The configured visible window's start, as civil-day minutes.
  ///
  /// P1 (2026-09-21): this is the ONE effective range origin. The Planner
  /// renderer, pager previews, scroll extent, initial focus, current-time
  /// coordinates, pinch extent, drag ghost and resize hit testing all measure
  /// from it. It is a PRESENTATION range only — factual Event minutes remain
  /// civil-day based and are never rewritten to fit this window.
  int get visibleStartMinute => visibleStartHour * 60;

  /// The configured visible window's end, as civil-day minutes.
  ///
  /// 24 means next-day midnight, so a 0–24 window spans the whole civil day
  /// and a 6–18 window ends at 6:00 PM. The final boundary label is inclusive.
  int get visibleEndMinute => visibleEndHour * 60;

  /// Span of the configured visible window in minutes. Always positive for a
  /// validated instance ([validate] rejects end <= start).
  int get visibleSpanMinutes => visibleEndMinute - visibleStartMinute;

  /// Span of the configured visible window in whole hours.
  int get visibleSpanHours => visibleSpanMinutes ~/ 60;

  /// Whether the Planner should paint the current-time indicator.
  ///
  /// P1 removed the "Show current-time line" control but KEPT the feature. The
  /// persisted `showCurrentTime` column is retained at its old value, and an old
  /// stored `false` must not strand the indicator hidden now that no control can
  /// turn it back on. The effective value is therefore always true; the raw
  /// column is untouched (no migration, no profile-wide rewrite).
  bool get effectiveShowCurrentTime => true;

  /// Whether long-press move / edge-drag resize direct manipulation is
  /// enabled.
  ///
  /// P1 owner correction (2026-09-21) removed the "Quick edit on timeline"
  /// SETTING surface but KEPT the capability: direct manipulation is standard
  /// Planner behavior, not a user preference. The persisted
  /// `quick_edit_enabled` column is retained at its old value, and an old
  /// stored `false` must not strand quick edit disabled now that no control
  /// can turn it back on. The effective value is therefore always true; the
  /// raw column is untouched here (no migration, no profile-wide rewrite) and
  /// converges on the next ordinary settings save.
  bool get effectiveQuickEditEnabled => true;

  PlannerSettings copyWith({
    String? defaultEventTypeId,
    bool clearDefaultEventType = false,
    int? defaultDurationMinutes,
    int? defaultReminderMinutes,
    bool clearDefaultReminder = false,
    int? visibleStartHour,
    int? visibleEndHour,
    bool? use24HourTime,
    int? snapMinutes,
    bool? showCurrentTime,
    PlannerInitialScrollBehavior? initialScrollBehavior,
    EventCreationPresentation? creationPresentation,
    bool? quickEditEnabled,
    bool? showCompletedItems,
    bool? showCancelledItems,
    int? weekStartDay,
    PlannerPresentation? preferredPresentation,
    PlannerContentFilters? contentFilters,
    double? timelineHourHeight,
  }) {
    return PlannerSettings(
      defaultEventTypeId: clearDefaultEventType
          ? null
          : defaultEventTypeId ?? this.defaultEventTypeId,
      defaultDurationMinutes:
          defaultDurationMinutes ?? this.defaultDurationMinutes,
      defaultReminderMinutes: clearDefaultReminder
          ? null
          : defaultReminderMinutes ?? this.defaultReminderMinutes,
      visibleStartHour: visibleStartHour ?? this.visibleStartHour,
      visibleEndHour: visibleEndHour ?? this.visibleEndHour,
      use24HourTime: use24HourTime ?? this.use24HourTime,
      snapMinutes: snapMinutes ?? this.snapMinutes,
      showCurrentTime: showCurrentTime ?? this.showCurrentTime,
      initialScrollBehavior:
          initialScrollBehavior ?? this.initialScrollBehavior,
      creationPresentation: creationPresentation ?? this.creationPresentation,
      quickEditEnabled: quickEditEnabled ?? this.quickEditEnabled,
      showCompletedItems: showCompletedItems ?? this.showCompletedItems,
      showCancelledItems: showCancelledItems ?? this.showCancelledItems,
      weekStartDay: weekStartDay ?? this.weekStartDay,
      preferredPresentation:
          preferredPresentation ?? this.preferredPresentation,
      contentFilters: contentFilters ?? this.contentFilters,
      timelineHourHeight: PlannerZoomPolicy.clampAbsolute(
        timelineHourHeight ?? this.timelineHourHeight,
      ),
    );
  }

  void validate() {
    if (defaultDurationMinutes < 15 || defaultDurationMinutes > 24 * 60) {
      throw ArgumentError.value(
        defaultDurationMinutes,
        'defaultDurationMinutes',
      );
    }
    // Delta 4.2R R8: the default duration lives on the 15-minute product
    // grid — Custom values change in exact 15-minute increments only.
    if (defaultDurationMinutes % 15 != 0) {
      throw ArgumentError.value(
        defaultDurationMinutes,
        'defaultDurationMinutes',
        'Default duration must be a multiple of 15 minutes.',
      );
    }
    if (visibleStartHour < 0 ||
        visibleStartHour > 23 ||
        visibleEndHour < 1 ||
        visibleEndHour > 24 ||
        visibleEndHour <= visibleStartHour) {
      throw ArgumentError('Visible end hour must be after start hour.');
    }
    if (!const <int>{5, 10, 15, 30, 60}.contains(snapMinutes)) {
      throw ArgumentError.value(snapMinutes, 'snapMinutes');
    }
    if (weekStartDay < DateTime.monday || weekStartDay > DateTime.sunday) {
      throw ArgumentError.value(weekStartDay, 'weekStartDay');
    }
    if (timelineHourHeight < PlannerZoomPolicy.absoluteMinimumHourHeight ||
        timelineHourHeight > PlannerZoomPolicy.absoluteMaximumHourHeight) {
      throw ArgumentError.value(timelineHourHeight, 'timelineHourHeight');
    }
  }
}
