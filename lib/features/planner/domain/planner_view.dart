/// The Planner's presentation modes.
///
/// Owner decision (2026-09-20): `tasks` was retired.  Tasks have exactly ONE
/// canonical home — the Tasks screen — and the Planner's overflow `Tasks` row
/// now opens that screen instead of rendering a second Tasks list here.
/// [fromStoredName] tolerates the retired value still sitting in an existing
/// `plannerPreferences.preferredPresentation` row.
enum PlannerPresentation {
  schedule,
  day,
  week,
  awaitingReports;

  /// Resolves a persisted presentation name.
  ///
  /// A retired or unknown value resolves to [PlannerPresentation.day] — the
  /// documented historical default — instead of throwing, so an existing saved
  /// value can never strand or crash the Planner.
  static PlannerPresentation fromStoredName(String? name) {
    for (final value in values) {
      if (value.name == name) {
        return value;
      }
    }
    return PlannerPresentation.day;
  }
}

final class PlannerContentFilters {
  const PlannerContentFilters({
    required this.events,
    required this.backupEvents,
    required this.tasks,
    required this.completedTasks,
  });

  const PlannerContentFilters.defaults()
    : events = true,
      backupEvents = true,
      tasks = true,
      completedTasks = false;

  final bool events;
  final bool backupEvents;
  final bool tasks;
  final bool completedTasks;

  PlannerContentFilters copyWith({
    bool? events,
    bool? backupEvents,
    bool? tasks,
    bool? completedTasks,
  }) {
    final nextTasks = tasks ?? this.tasks;
    return PlannerContentFilters(
      events: events ?? this.events,
      backupEvents: backupEvents ?? this.backupEvents,
      tasks: nextTasks,
      completedTasks: nextTasks ? completedTasks ?? this.completedTasks : false,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PlannerContentFilters &&
      other.events == events &&
      other.backupEvents == backupEvents &&
      other.tasks == tasks &&
      other.completedTasks == completedTasks;

  @override
  int get hashCode => Object.hash(events, backupEvents, tasks, completedTasks);
}

enum PlannerSelectionKind { event, task }

final class PlannerSelectionId {
  const PlannerSelectionId({required this.kind, required this.id});

  final PlannerSelectionKind kind;
  final String id;

  @override
  bool operator ==(Object other) =>
      other is PlannerSelectionId && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);
}

abstract final class PlannerZoomPolicy {
  // Discrete preset anchors used by the Planner Settings dropdown
  // and by the Settings screen's preset classification. The pinch
  // gesture can move continuously between these anchors and beyond
  // them up to the viewport-derived min/max clamp range below.
  static const double compactHourHeight = 44;
  static const double normalHourHeight = 60;
  static const double expandedHourHeight = 88;

  // Absolute safety floor/ceiling for the persisted timeline hour
  // height (logical px per one-hour interval). These are NOT the
  // runtime pinch limits: those are derived from the actual usable
  // timeline viewport each gesture (see [minimumHourHeightFor] /
  // [maximumHourHeightFor]) so the whole configured planning window
  // fits at maximum zoom-out and ~2.5-3 hours fit at maximum
  // zoom-in (PMG parity). The absolute range only guards against
  // corrupt settings, very small devices, and extreme text scaling.
  static const double absoluteMinimumHourHeight = 20;
  static const double absoluteMaximumHourHeight = 320;

  /// Target number of one-hour intervals visible in the usable
  /// timeline viewport at the closest zoom. PMG's close view shows
  /// roughly 2.5-3 full hourly intervals; 2.75 sits in the middle
  /// of that owner-approved band.
  static const double maxZoomInVisibleHours = 2.75;

  /// Clamp to the absolute safety range (settings persistence,
  /// corrupt-value protection). Runtime pinch uses
  /// [clampForViewport] instead.
  static double clampAbsolute(double value) => value
      .clamp(absoluteMinimumHourHeight, absoluteMaximumHourHeight)
      .toDouble();

  /// Maximum zoom-out: the smallest hour height that fits the whole
  /// configured planning window into [viewportHeight]. A 6:00 AM -
  /// 10:00 PM window (16 hours) on a ~700 dp viewport therefore
  /// bottoms out near ~44 dp per hour with the first and final
  /// configured boundaries visible in one viewport. Clamped to the
  /// absolute safety range for very short windows / small devices.
  static double minimumHourHeightFor({
    required double viewportHeight,
    required int configuredHours,
  }) {
    if (viewportHeight <= 0) {
      return absoluteMinimumHourHeight;
    }
    final windowHours = configuredHours.clamp(1, 24).toDouble();
    return (viewportHeight / windowHours)
        .clamp(absoluteMinimumHourHeight, absoluteMaximumHourHeight)
        .toDouble();
  }

  /// Maximum zoom-in: the hour height that shows
  /// [maxZoomInVisibleHours] one-hour intervals in [viewportHeight].
  /// A ~700 dp viewport therefore tops out near ~255 dp per hour so
  /// short Events can be inspected, moved, and resized closely.
  static double maximumHourHeightFor({required double viewportHeight}) {
    if (viewportHeight <= 0) {
      return absoluteMaximumHourHeight;
    }
    return (viewportHeight / maxZoomInVisibleHours)
        .clamp(absoluteMinimumHourHeight, absoluteMaximumHourHeight)
        .toDouble();
  }

  /// Runtime pinch clamp derived from the actual usable timeline
  /// viewport and the configured planning-window span. Falls back to
  /// the absolute safety range when the viewport is unknown.
  static double clampForViewport(
    double value, {
    required double viewportHeight,
    required int configuredHours,
  }) {
    if (viewportHeight <= 0) {
      return clampAbsolute(value);
    }
    return value
        .clamp(
          minimumHourHeightFor(
            viewportHeight: viewportHeight,
            configuredHours: configuredHours,
          ),
          maximumHourHeightFor(viewportHeight: viewportHeight),
        )
        .toDouble();
  }

  /// The pinch dead-zone contract was tightened in Stage B3-R1
  /// Slice D2. The previous 0.03 threshold was too wide and
  /// caused owner-observed behavior where a real two-finger
  /// pinch needed a non-trivial amount of finger travel before
  /// any zoom change became visible, especially in the
  /// pinch-in direction. The new threshold is owner-approved
  /// and required to satisfy the contract that
  /// (a) tiny pointer noise close to 1.0 still maps to 1.0,
  /// (b) a modest realistic scale change becomes visible, and
  /// (c) pinch-in and pinch-out thresholds are symmetric.
  ///
  /// The 0.012 value was selected because it is comfortably
  /// larger than the realistic sensor / pointer noise floor
  /// observed in Stage B1 device testing and the focused
  /// pinch-zoom suite, and it is comfortably smaller than the
  /// 1.5-percent human "intentional pinch" threshold. The
  /// practical allowed range is approximately 0.008-0.015;
  /// 0.012 sits in the middle.
  static const double scaleStartDeadZone = 0.012;

  /// Apply a small intentional dead zone around the start scale
  /// so finger jitter at the start of a pinch does not visibly
  /// bump the hour height before the user has actually started
  /// the gesture. Inside the dead zone, the returned scale is
  /// 1.0 (no change). Outside, the scale is preserved as-is.
  ///
  /// The mapping is symmetric: an `applyDeadZone(1 + d)` and
  /// `applyDeadZone(1 - d)` with the same `d` either both fall
  /// inside the dead zone or both pass through. This keeps the
  /// pinch-in and pinch-out responsiveness identical, which
  /// was the owner-visible defect of the previous 0.03 policy.
  static double applyDeadZone(double scale) {
    final delta = scale - 1.0;
    if (delta.abs() <= scaleStartDeadZone) {
      return 1.0;
    }
    return scale;
  }
}

enum PlannerZoomPreset { compact, normal, expanded }

extension PlannerZoomPresetValue on PlannerZoomPreset {
  double get hourHeight => switch (this) {
    PlannerZoomPreset.compact => PlannerZoomPolicy.compactHourHeight,
    PlannerZoomPreset.normal => PlannerZoomPolicy.normalHourHeight,
    PlannerZoomPreset.expanded => PlannerZoomPolicy.expandedHourHeight,
  };
}
