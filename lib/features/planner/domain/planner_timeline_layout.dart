import 'dart:math' as math;

import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_day.dart';
import 'package:rmplanner/features/planner/domain/planner_settings.dart';

/// The Planner timeline canvas always spans the full civil day.
///
/// The configured planning window (PlannerSettings.visibleStartHour /
/// visibleEndHour) is a soft planning window used for the default
/// initial scroll position and the maximum-zoom-out fit target; it no
/// longer clips the canvas. Times before the configured start and after
/// the configured end remain reachable, creatable, and editable within
/// the 00:00 - 24:00 civil-day bounds (PMG parity).
const int kPlannerCivilDayStartHour = 0;
const int kPlannerCivilDayEndHour = 24;
const int kPlannerCivilDayStartMinute = 0;
const int kPlannerCivilDayEndMinute = 24 * 60;

/// R5-03 owner-defined horizontal priority classes.
///
/// The enum order is the required left-to-right order when Events truly
/// overlap. It is a derived projection only: Backup remains the existing
/// persisted semantic flag and dominant is never stored.
enum PlannerTimelineLaneClass {
  normalRegular,
  normalDominant,
  backupRegular,
  backupDominant,
}

final class PlannerTimelinePlacement {
  const PlannerTimelinePlacement({
    required this.event,
    required this.column,
    required this.columnCount,
    this.widthFactor,
    this.offsetFactor,
    this.spanStart,
    this.spanCount,
  });

  final PlannerCalendarItem event;
  final int column;
  final int columnCount;

  /// Optional normalized width/offset retained for renderer compatibility.
  /// R5's four priority classes use the canonical column/span path.
  final double? widthFactor;
  final double? offsetFactor;

  /// PMG-style free-space expansion (Delta 3): the first grid lane the
  /// Event's rectangle starts in and how many adjacent base lanes it spans.
  /// Derived per-Event from the Event's OWN time interval against each
  /// adjacent lane's real occupants, so an Event widens into free lanes and
  /// stops only at a real overlapping blocker or the local interval grid
  /// boundary. When null the renderer falls back to [column]/[columnCount].
  final int? spanStart;
  final int? spanCount;
}

final class _PlannerTimelinePlacementSnapshot {
  const _PlannerTimelinePlacementSnapshot({
    required this.eventId,
    required this.column,
    required this.columnCount,
    required this.widthFactor,
    required this.offsetFactor,
    required this.spanStart,
    required this.spanCount,
  });

  final String eventId;
  final int column;
  final int columnCount;
  final double? widthFactor;
  final double? offsetFactor;
  final int? spanStart;
  final int? spanCount;
}

/// Pixel geometry shared by the centered timeline and the pager previews.
///
/// Keeping the minute-to-pixel conversion in one production helper prevents
/// a visual minimum-height rule from silently changing the duration that an
/// Event represents. A 15-minute Event therefore always occupies exactly
/// one quarter of the active hour height.
abstract final class PlannerTimelineGeometry {
  static const int minutesPerHour = 60;
  static const int quarterHourMinutes = 15;

  static double pixelsPerMinute(double hourHeight) {
    return hourHeight / minutesPerHour;
  }

  static double yForMinute({
    required int minute,
    required int visibleStartMinute,
    required double hourHeight,
  }) {
    return (minute - visibleStartMinute) * pixelsPerMinute(hourHeight);
  }

  static double heightForDuration({
    required int durationMinutes,
    required double hourHeight,
  }) {
    return durationMinutes * pixelsPerMinute(hourHeight);
  }

  static double quarterHourHeight(double hourHeight) {
    return heightForDuration(
      durationMinutes: quarterHourMinutes,
      hourHeight: hourHeight,
    );
  }

  /// Resolve the visible Event rectangle from true time duration.
  ///
  /// Combined geometry delta: the visible slice is the canonical intersection
  /// `max(eventStart, dayStart) .. min(eventEnd, dayEnd)` (PMG boundary
  /// clipping) and the rendered height is EXACTLY `durationMinutes *
  /// pixelsPerMinute` at every zoom level. No minimum-height inflation, no
  /// quarter-hour forcing, and no `clamp(lower, upper)` calls remain in this
  /// path, so a 15-minute Event always occupies exactly one quarter of the
  /// active hour and an Event near the final 24:00 boundary renders its true
  /// clipped sliver instead of throwing `Invalid argument(s): 48.0`.
  static PlannerTimelineEventGeometry event({
    required int startMinute,
    required int endMinute,
    required int visibleStartMinute,
    required int visibleEndMinute,
    required double hourHeight,
  }) {
    var clippedStart = math.max(startMinute, visibleStartMinute);
    var clippedEnd = math.min(endMinute, visibleEndMinute);
    // No-intersection collapse: an Event entirely outside the displayed day
    // has no slice, but its collapsed zero-height slice must sit ON the
    // nearest day boundary (final 24:00 boundary for post-midnight drags,
    // top boundary for pre-day Events) so nothing is ever positioned past
    // the 00:00-24:00 canvas. A genuine zero-duration Event inside the day
    // keeps its own position (neither boundary condition matches).
    if (clippedEnd <= clippedStart) {
      if (startMinute >= visibleEndMinute) {
        clippedStart = visibleEndMinute;
        clippedEnd = visibleEndMinute;
      } else if (endMinute <= visibleStartMinute) {
        clippedStart = visibleStartMinute;
        clippedEnd = visibleStartMinute;
      }
    }
    final durationMinutes = math.max(0, clippedEnd - clippedStart);
    final top = yForMinute(
      minute: clippedStart,
      visibleStartMinute: visibleStartMinute,
      hourHeight: hourHeight,
    );
    final logicalHeight = heightForDuration(
      durationMinutes: durationMinutes,
      hourHeight: hourHeight,
    );
    // An Event entirely outside the displayed day has no intersection: its
    // zero-height slice must still sit ON the canvas (top boundary for
    // pre-day Events, final boundary for post-midnight Events) so no geometry
    // is ever rendered past 00:00-24:00 and `bottom` never leaves the canvas.
    final visibleBottom = yForMinute(
      minute: visibleEndMinute,
      visibleStartMinute: visibleStartMinute,
      hourHeight: hourHeight,
    );
    final clampedTop = math.min(math.max(top, 0.0), visibleBottom).toDouble();
    return PlannerTimelineEventGeometry(
      clippedStartMinute: clippedStart,
      clippedEndMinute: clippedEnd,
      top: clampedTop,
      logicalHeight: logicalHeight,
      height: logicalHeight,
    );
  }
}

final class PlannerTimelineEventGeometry {
  const PlannerTimelineEventGeometry({
    required this.clippedStartMinute,
    required this.clippedEndMinute,
    required this.top,
    required this.logicalHeight,
    required this.height,
  });

  final int clippedStartMinute;
  final int clippedEndMinute;
  final double top;
  final double logicalHeight;
  final double height;

  double get bottom => top + height;
}

abstract final class PlannerTimelineLayout {
  // R6-04: the horizontal lane solution is entirely zoom-invariant. Retain a
  // tiny bounded cache of value-only snapshots so raw pinch frames rebind the
  // existing columns/spans to current Event objects instead of repeatedly
  // solving the same overlap graph. No widget, repository object, or Event
  // instance is retained, and the exact logical signature invalidates on any
  // identity/start/end/Backup-class change.
  static const int _arrangementCacheLimit = 12;
  static final Map<String, List<_PlannerTimelinePlacementSnapshot>>
  _arrangementCache = <String, List<_PlannerTimelinePlacementSnapshot>>{};

  static List<PlannerTimelinePlacement> arrange(
    List<PlannerCalendarItem> events, {
    double? hourHeight,
  }) {
    final timed =
        events
            .where(
              (event) => event.startLocal != null && event.endLocal != null,
            )
            .toList(growable: false)
          ..sort(_compareCanonicalInterval);
    final signature = _arrangementSignature(timed);
    final cached = _arrangementCache.remove(signature);
    if (cached != null) {
      _arrangementCache[signature] = cached;
      final eventById = <String, PlannerCalendarItem>{
        for (final event in timed) event.id: event,
      };
      if (eventById.length == timed.length &&
          cached.every(
            (placement) => eventById.containsKey(placement.eventId),
          )) {
        return <PlannerTimelinePlacement>[
          for (final placement in cached)
            PlannerTimelinePlacement(
              event: eventById[placement.eventId]!,
              column: placement.column,
              columnCount: placement.columnCount,
              widthFactor: placement.widthFactor,
              offsetFactor: placement.offsetFactor,
              spanStart: placement.spanStart,
              spanCount: placement.spanCount,
            ),
        ];
      }
    }
    final result = <PlannerTimelinePlacement>[];
    for (final group in _overlapGroups(timed, hourHeight: hourHeight)) {
      final assigned = <PlannerCalendarItem, int>{};
      var columnCount = 1;
      final orderedGroup = orderedByLanePriority(group);
      // R5-03: assign each Event after every lower-class Event that it
      // ACTUALLY overlaps. This is a precedence-constrained interval layout,
      // not a permutation of transitive base columns. Non-overlapping Events
      // reuse columns, while overlapping same-class Events use deterministic
      // subcolumns. The expansion pass below reclaims lanes that have no real
      // blocker for the Event's own interval.
      for (final event in orderedGroup) {
        final eventClass = laneClassOf(event);
        final unavailable = <int>{};
        var minimumColumn = 0;
        for (final entry in assigned.entries) {
          final other = entry.key;
          if (!_overlaps(other, event)) {
            continue;
          }
          unavailable.add(entry.value);
          if ((_isTaskPresentationItem(other) &&
                  !_isTaskPresentationItem(event)) ||
              (!_isTaskPresentationItem(other) &&
                  !_isTaskPresentationItem(event) &&
                  laneClassOf(other).index < eventClass.index)) {
            minimumColumn = math.max(minimumColumn, entry.value + 1);
          }
        }
        var column = minimumColumn;
        while (unavailable.contains(column)) {
          column += 1;
        }
        assigned[event] = column;
        if (column + 1 > columnCount) {
          columnCount = column + 1;
        }
      }
      // Delta 3 PASS 2 / R5-03 free-space expansion: after the class-ordered
      // base lanes are fixed, each
      // Event widens into adjacent lanes that hold no Event overlapping ITS
      // OWN interval.  Transitive cluster membership never creates a false
      // blocker, and the span never crosses a lane occupied by a real
      // overlapping Event (including the reserved dominant/backup lanes).
      // The result is deterministic: the same lanes + intervals always
      // produce the same spans after drag, resize, zoom, swipe, and restart.
      final expansion = columnCount < 2
          ? const <String, ({int spanStart, int spanEnd})>{}
          : _expandGroupFreeSpace(group, assigned, columnCount: columnCount);
      for (final event in group) {
        final span = expansion[event.id];
        result.add(
          PlannerTimelinePlacement(
            event: event,
            column: assigned[event]!,
            columnCount: columnCount,
            spanStart: span?.spanStart,
            spanCount: span == null ? null : span.spanEnd - span.spanStart + 1,
          ),
        );
      }
    }
    _arrangementCache[signature] = <_PlannerTimelinePlacementSnapshot>[
      for (final placement in result)
        _PlannerTimelinePlacementSnapshot(
          eventId: placement.event.id,
          column: placement.column,
          columnCount: placement.columnCount,
          widthFactor: placement.widthFactor,
          offsetFactor: placement.offsetFactor,
          spanStart: placement.spanStart,
          spanCount: placement.spanCount,
        ),
    ];
    while (_arrangementCache.length > _arrangementCacheLimit) {
      _arrangementCache.remove(_arrangementCache.keys.first);
    }
    return result;
  }

  static String _arrangementSignature(List<PlannerCalendarItem> events) {
    final buffer = StringBuffer('${events.length}|');
    for (final event in events) {
      final id = event.id;
      buffer
        ..write(id.length)
        ..write(':')
        ..write(id)
        ..write(':')
        ..write(event.startLocal!.microsecondsSinceEpoch)
        ..write(':')
        ..write(event.endLocal!.microsecondsSinceEpoch)
        ..write(':')
        ..write(event.isBackupAppointment ? '1' : '0')
        ..write('|');
    }
    return buffer.toString();
  }

  /// Delta 3 PASS 2 — free-space expansion for one overlap group.
  ///
  /// For every Event in [group] (keyed by its assigned base lane in
  /// [assigned]) the Event's rectangle expands left and right over adjacent
  /// lanes while that lane holds no Event whose canonical interval overlaps
  /// this Event's own interval.  Expansion stops at the first real blocker,
  /// so a transitive chain (A overlaps B, B overlaps C, A does not overlap
  /// C) never forces A to stay narrow because of C.  The span is always
  /// within the group grid `0..columnCount-1`, so class ordering stays
  /// respected without display-only arithmetic.
  static Map<String, ({int spanStart, int spanEnd})> _expandGroupFreeSpace(
    List<PlannerCalendarItem> group,
    Map<PlannerCalendarItem, int> assigned, {
    required int columnCount,
  }) {
    final byLane = <int, List<PlannerCalendarItem>>{};
    for (final entry in assigned.entries) {
      byLane
          .putIfAbsent(entry.value, () => <PlannerCalendarItem>[])
          .add(entry.key);
    }

    bool laneFreeFor(PlannerCalendarItem event, int lane) {
      for (final other in byLane[lane] ?? const <PlannerCalendarItem>[]) {
        if (identical(other, event)) {
          continue;
        }
        if (event.startLocal!.isBefore(other.endLocal!) &&
            other.startLocal!.isBefore(event.endLocal!)) {
          return false;
        }
      }
      return true;
    }

    final result = <String, ({int spanStart, int spanEnd})>{};
    for (final event in group) {
      final lane = assigned[event]!;
      var spanStart = lane;
      var spanEnd = lane;
      // The class-aware base assignment already places every real lower-class
      // blocker to the left. Any Event may reclaim genuinely free adjacent
      // lanes and stops at the first canonical overlap blocker.
      while (spanStart > 0 && laneFreeFor(event, spanStart - 1)) {
        spanStart -= 1;
      }
      while (spanEnd < columnCount - 1 && laneFreeFor(event, spanEnd + 1)) {
        spanEnd += 1;
      }
      result[event.id] = (spanStart: spanStart, spanEnd: spanEnd);
    }
    return result;
  }

  static List<List<PlannerCalendarItem>> _overlapGroups(
    List<PlannerCalendarItem> events, {
    double? hourHeight,
  }) {
    final groups = <List<PlannerCalendarItem>>[];
    var current = <PlannerCalendarItem>[];
    DateTime? furthestEnd;
    for (final event in events) {
      if (current.isNotEmpty &&
          furthestEnd != null &&
          !event.startLocal!.isBefore(furthestEnd)) {
        groups.add(current);
        current = <PlannerCalendarItem>[];
        furthestEnd = null;
      }
      current.add(event);
      final visualEnd = _visualEnd(event, hourHeight: hourHeight);
      if (furthestEnd == null || visualEnd.isAfter(furthestEnd)) {
        furthestEnd = visualEnd;
      }
    }
    if (current.isNotEmpty) {
      groups.add(current);
    }
    return groups;
  }

  /// Returns the end used only for lane calculation: the canonical logical
  /// end. Lane grouping and assignment are therefore INDEPENDENT of zoom
  /// (combined delta locked rule) — only the vertical pixel scale changes
  /// with zoom, never group membership, lane count, or lane order. The
  /// Event's stored and displayed times remain unchanged.
  static DateTime _visualEnd(PlannerCalendarItem event, {double? hourHeight}) {
    return event.endLocal!;
  }

  static bool _overlaps(PlannerCalendarItem left, PlannerCalendarItem right) {
    return left.startLocal!.isBefore(right.endLocal!) &&
        right.startLocal!.isBefore(left.endLocal!);
  }

  /// Stable lane-priority ordering for an overlap group, shared by the
  /// canonical arrangement and the overview display pass so lanes never jump
  /// between zoom levels (P-01C zoom-stability rule).
  ///
  /// R5 order (left to right): Normal Regular, Normal Dominant, Backup
  /// Regular, Backup Dominant. All within-class ordering uses the same
  /// deterministic comparator, so the canonical day view and compressed
  /// overview render identical lane roles from identical data.
  static List<PlannerCalendarItem> orderedByLanePriority(
    List<PlannerCalendarItem> group,
  ) {
    return group.toList(growable: false)..sort((left, right) {
      final leftIsTask = _isTaskPresentationItem(left);
      final rightIsTask = _isTaskPresentationItem(right);
      if (leftIsTask != rightIsTask) {
        return leftIsTask ? -1 : 1;
      }
      final classOrder = laneClassOf(
        left,
      ).index.compareTo(laneClassOf(right).index);
      return classOrder != 0
          ? classOrder
          : _compareCanonicalInterval(left, right);
    });
  }

  /// Task footprints and Task creation drafts are presentation projections;
  /// their stable prefixes deliberately sit outside persisted Event identity.
  static bool _isTaskPresentationItem(PlannerCalendarItem item) {
    return item.id.startsWith('task-footprint:') ||
        item.id.startsWith('task-draft:');
  }

  /// Derives the R5 lane class from canonical logical facts only.
  /// Exactly 60 minutes is REGULAR; 61 minutes and above is DOMINANT.
  static PlannerTimelineLaneClass laneClassOf(PlannerCalendarItem event) {
    final durationMinutes = event.endLocal!
        .difference(event.startLocal!)
        .inMinutes;
    final dominant = durationMinutes > 60;
    if (event.isBackupAppointment) {
      return dominant
          ? PlannerTimelineLaneClass.backupDominant
          : PlannerTimelineLaneClass.backupRegular;
    }
    return dominant
        ? PlannerTimelineLaneClass.normalDominant
        : PlannerTimelineLaneClass.normalRegular;
  }

  /// Stable within-class tie-break: canonical start, canonical end, then ID.
  /// Title, color, incoming list order, and display/readability height never
  /// enter this comparison.
  static int _compareCanonicalInterval(
    PlannerCalendarItem left,
    PlannerCalendarItem right,
  ) {
    final startOrder = left.startLocal!.compareTo(right.startLocal!);
    if (startOrder != 0) {
      return startOrder;
    }
    final endOrder = left.endLocal!.compareTo(right.endLocal!);
    if (endOrder != 0) {
      return endOrder;
    }
    return left.id.compareTo(right.id);
  }
}

/// Normalized minute-of-day (1..1440) for a wall-clock end instant.
///
/// A 00:00 end with positive duration is the day-end 24:00 boundary (minute
/// 1440), so an 11 PM-12 AM Event keeps its full slice and never collapses to
/// minute 0 (which would render as a zero-height block at the top of the
/// canvas).  A valid timed Event always ends after it starts, so a midnight
/// end is unambiguous even for a full-day Event from 00:00 to 24:00.
int plannerEndMinuteOfDay(DateTime start, DateTime end) {
  final endMinute = end.hour * 60 + end.minute;
  if (endMinute == 0 && end.isAfter(start)) {
    return 1440;
  }
  return endMinute;
}

int snapPlannerMinute(int minute, int snapMinutes) {
  final snapped = (minute / snapMinutes).round() * snapMinutes;
  return snapped.clamp(0, 1439);
}

int plannerInitialScrollMinute({
  required PlannerSettings settings,
  required PlannerDate selectedDate,
  required DateTime now,
  int? firstRelevantEventMinute,
}) {
  // The canvas spans the full civil day, so the initial target is a
  // minute-of-day clamped to 00:00-23:45. The configured start is the
  // default anchor; the rest of the day remains reachable by scrolling.
  final visibleStart = settings.visibleStartHour * 60;
  final requested = switch (settings.initialScrollBehavior) {
    PlannerInitialScrollBehavior.currentTime
        when selectedDate == PlannerDate.fromDateTime(now) =>
      now.hour * 60 + now.minute,
    PlannerInitialScrollBehavior.currentTime =>
      firstRelevantEventMinute ?? visibleStart,
    PlannerInitialScrollBehavior.visibleStart ||
    PlannerInitialScrollBehavior.dayStart => visibleStart,
  };
  return requested.clamp(
    kPlannerCivilDayStartMinute,
    kPlannerCivilDayEndMinute - 15,
  );
}
