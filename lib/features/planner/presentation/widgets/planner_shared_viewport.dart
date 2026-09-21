// Planner shared viewport model (Stage B3-R1 Slice D3-A).
//
// The interactive day pager translates pages horizontally while
// preserving the vertical viewport. Vertical scroll, hour height,
// pixels-per-minute, and the visible minute range are all facts
// about *the* planner, not about *a* page — so they live on a
// single immutable value object that the pager, the timeline,
// and the test harness can each read from the same source.
//
// The model is intentionally minimal: it does not own a second
// scroll controller, it does not persist anything, and it does
// not know anything about the database. It is the smallest
// coherent viewport description that the Phase 16 test suite
// can lock onto without depending on private widget state.
//
// The actual sources of truth remain:
//   - the existing Planner `_dayScrollController` (vertical
//     scroll offset);
//   - the existing Planner hour-height policy
//     (`PlannerZoomPolicy`);
//   - the effective presentation range (`PlannerEffectiveRange`
//     from `planner_timeline_layout.dart`), which is derived from the
//     configured visible hours and replaces the whole civil day as the
//     visible-range clamp (P1, 2026-09-21).
// This model only reads from them.

import 'package:flutter/widgets.dart';

import 'package:rmplanner/features/planner/domain/planner_settings.dart';
import 'package:rmplanner/features/planner/domain/planner_timeline_layout.dart';
import 'package:rmplanner/features/planner/domain/planner_view.dart';

/// Small visual allowance after the final configured time boundary. It keeps
/// the last full-hour label and line reachable above the shell navigation and
/// FAB without adding a synthetic hour to the timeline geometry.
const double kPlannerTimelineBottomBoundaryExtent = 24;

@immutable
final class PlannerSharedViewport {
  const PlannerSharedViewport({
    required this.hourHeight,
    required this.verticalOffset,
    required this.viewportHeight,
    required this.pixelsPerMinute,
    required this.visibleStartMinute,
    required this.visibleEndMinute,
  });

  /// Hour height in logical pixels. The same value is used by
  /// the centered page and both preview pages during a swipe,
  /// so a horizontal page change cannot drift the timeline
  /// geometry. Bounded by `PlannerZoomPolicy.minimumHourHeight`
  /// and `maximumHourHeight`.
  final double hourHeight;

  /// The current vertical scroll offset of the shared
  /// SingleChildScrollView, in logical pixels. The pager reads
  /// this value once per gesture and on every rebuild so a
  /// commit can be measured against the exact starting offset
  /// and the visible-minute-range checks have a stable
  /// reference point.
  final double verticalOffset;

  /// The visible vertical extent of the SingleChildScrollView
  /// in logical pixels. Captured once per layout so the
  /// visible-minute range is independent of any layout jitter
  /// that might occur during a settle animation.
  final double viewportHeight;

  /// Pixels per minute of the timeline, derived from
  /// `hourHeight / 60`. The current-time indicator, the Event
  /// blocks, the empty-time create surface, and the swipe
  /// commit checks all consume this single derived value.
  final double pixelsPerMinute;

  /// The minute-of-day at the top of the visible timeline,
  /// computed from the current scroll offset and hour height.
  /// Clamped to the civil-day canvas (00:00-24:00).
  final int visibleStartMinute;

  /// The minute-of-day at the bottom of the visible timeline,
  /// derived from `visibleStartMinute + viewportHeight /
  /// pixelsPerMinute`. Always greater than
  /// `visibleStartMinute`; clamped to the civil-day upper bound.
  final int visibleEndMinute;

  /// An empty viewport for tests that do not need real layout
  /// inputs.
  static const PlannerSharedViewport empty = PlannerSharedViewport(
    hourHeight: PlannerZoomPolicy.normalHourHeight,
    verticalOffset: 0,
    viewportHeight: 0,
    pixelsPerMinute: PlannerZoomPolicy.normalHourHeight / 60,
    visibleStartMinute: 0,
    visibleEndMinute: 0,
  );

  /// Build a viewport snapshot from the existing Planner
  /// inputs. Returns a value whose fields are read-only — the
  /// caller cannot mutate the source of truth through the
  /// returned value.
  ///
  /// `scrollController` may be unattached (no clients yet) in
  /// narrow test paths; in that case the offset defaults to 0
  /// so the model still describes a valid (zeroed) viewport.
  /// `settings` supplies the effective presentation range via
  /// [PlannerEffectiveRange], which is the visible-range clamp.
  static PlannerSharedViewport from({
    required double hourHeight,
    required ScrollController scrollController,
    required PlannerSettings settings,
    required double viewportHeight,
    PlannerEffectiveRange? visibleRange,
  }) {
    final clampedHeight = PlannerZoomPolicy.clampAbsolute(hourHeight);
    final pixelsPerMinute = clampedHeight / 60.0;
    final offset = scrollController.hasClients ? scrollController.offset : 0.0;
    // P1 (2026-09-21): the timeline canvas IS the configured effective
    // window, so the visible-minute clamp is the configured range rather
    // than the whole civil day. A 6 AM-6 PM window therefore reports visible
    // minutes inside 06:00-18:00, and pixel 0 is the configured start hour.
    final range = visibleRange ?? PlannerEffectiveRange.of(settings);
    final visibleStartBase = range.startMinute;
    final visibleEndCap = range.endMinute;
    final unclampedStart =
        visibleStartBase + (pixelsPerMinute > 0 ? offset / pixelsPerMinute : 0);
    final visibleStartMinute = unclampedStart.round().clamp(
      visibleStartBase,
      visibleEndCap - 1,
    );
    final visibleSpanMinutes = pixelsPerMinute > 0
        ? (viewportHeight / pixelsPerMinute).round()
        : 0;
    final visibleEndMinute = (visibleStartMinute + visibleSpanMinutes).clamp(
      visibleStartMinute,
      visibleEndCap,
    );
    return PlannerSharedViewport(
      hourHeight: clampedHeight,
      verticalOffset: offset,
      viewportHeight: viewportHeight,
      pixelsPerMinute: pixelsPerMinute,
      visibleStartMinute: visibleStartMinute,
      visibleEndMinute: visibleEndMinute,
    );
  }

  PlannerSharedViewport copyWith({
    double? hourHeight,
    double? verticalOffset,
    double? viewportHeight,
    double? pixelsPerMinute,
    int? visibleStartMinute,
    int? visibleEndMinute,
  }) {
    return PlannerSharedViewport(
      hourHeight: hourHeight ?? this.hourHeight,
      verticalOffset: verticalOffset ?? this.verticalOffset,
      viewportHeight: viewportHeight ?? this.viewportHeight,
      pixelsPerMinute: pixelsPerMinute ?? this.pixelsPerMinute,
      visibleStartMinute: visibleStartMinute ?? this.visibleStartMinute,
      visibleEndMinute: visibleEndMinute ?? this.visibleEndMinute,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PlannerSharedViewport &&
      other.hourHeight == hourHeight &&
      other.verticalOffset == verticalOffset &&
      other.viewportHeight == viewportHeight &&
      other.pixelsPerMinute == pixelsPerMinute &&
      other.visibleStartMinute == visibleStartMinute &&
      other.visibleEndMinute == visibleEndMinute;

  @override
  int get hashCode => Object.hash(
    hourHeight,
    verticalOffset,
    viewportHeight,
    pixelsPerMinute,
    visibleStartMinute,
    visibleEndMinute,
  );
}
