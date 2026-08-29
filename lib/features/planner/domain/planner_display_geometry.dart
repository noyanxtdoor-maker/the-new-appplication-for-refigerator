import 'dart:math' as math;

import 'package:flutter/foundation.dart' show immutable;

import 'package:rmplanner/features/planner/domain/planner_day.dart';
import 'package:rmplanner/features/planner/domain/planner_timeline_layout.dart';
import 'package:rmplanner/features/planner/domain/planner_view.dart';

/// Longest factual duration that receives the shared display-only short-block
/// zoom presentation. Every factual sub-hour item follows the same law. The
/// projection is
///
/// * H <= 44: 60 visual minutes;
/// * 44 < H < 60: continuous interpolation from 60 to factual duration;
/// * H >= 60: factual duration.
///
/// The law is
/// PRESENTATION ONLY: stored duration, drag/resize math, overlap, reporting,
/// and recurrence all keep the exact canonical minutes.
const int kPlannerMaxZoomReadabilityDurationMinutes = 59;

@immutable
final class _PlannerDisplayInterval {
  const _PlannerDisplayInterval({
    required this.startMinute,
    required this.endMinute,
  });

  final double startMinute;
  final double endMinute;
}

/// Exact display placement derived from the Planner's canonical minute grid.
///
/// Delta 4.2A deliberately has no second visual-time model. Zoom changes only
/// pixels-per-minute: painted top, bottom, height, and horizontal overlap
/// regions always come from the same logical interval used by persistence,
/// drag, resize, conflict, and reporting behavior.
///
/// Delta 4.2R R10 adds ONE display-only exception at the extreme zoom-out end
/// (see [PlannerDisplayGeometry.resolve]): a short Event may occupy its whole
/// hour row so its title/time stay readable. That readability footprint is
/// resolved strictly inside this display layer and is never exposed to the
/// logical domain.
@immutable
final class PlannerDisplayPlacement {
  const PlannerDisplayPlacement({
    required this.event,
    required this.top,
    required this.height,
    required this.column,
    required this.columnCount,
    this.widthFactor,
    this.offsetFactor,
    this.spanStart,
    this.spanCount,
    this.squareTop = false,
    this.squareBottom = false,
  });

  final PlannerCalendarItem event;

  /// Exact clipped top in logical pixels.
  final double top;

  /// Exact clipped temporal height in logical pixels.
  final double height;

  /// Canonical lane (0-based) used for the x position.
  final int column;

  /// Canonical lane count for this logical overlap region.
  final int columnCount;

  /// Optional normalized width/offset for the locked primary/Backup split.
  final double? widthFactor;
  final double? offsetFactor;

  /// Delta 3 local free-space expansion from the canonical logical layout.
  final int? spanStart;
  final int? spanCount;

  /// Delta 4.2R R12: when the Event's rendered bottom is exactly contiguous
  /// with the rendered top of another block (A.end == B.start), the shared
  /// boundary must touch with no decorative rounded-corner notch. These flags
  /// zero the corner radius on the contiguous edge only.
  final bool squareTop;
  final bool squareBottom;

  double get bottom => top + height;
}

abstract final class PlannerDisplayGeometry {
  /// Resolves exact full-day placements for [events].
  ///
  /// [viewportHeight] and [configuredHours] remain in the call contract so
  /// the mounted center timeline and read-only pager previews share one API.
  /// They define the runtime maximum zoom-out hour height (the smallest
  /// height that still fits the configured planning window); at that extreme
  /// the Delta 4.2R R10 readability floor may engage for short Events.
  /// [previewStartMinutes] and [previewEndMinutes] alter only the exact
  /// minute endpoints used to paint a live gesture preview; Delta 4.2B owns
  /// recomputing logical lanes while those endpoints move.
  static List<PlannerDisplayPlacement> resolve({
    required List<PlannerCalendarItem> events,
    required double hourHeight,
    required double viewportHeight,
    required int configuredHours,
    Map<String, int>? previewStartMinutes,
    Map<String, int>? previewEndMinutes,
  }) {
    final timed = events
        .where((event) => event.startLocal != null && event.endLocal != null)
        .toList(growable: false);
    // Delta 4.2R2 R2-06: no global "maximum zoom only" gate. The overview
    // mode is decided per-Event from its OWN canonical rendered height
    // against the readability pixel threshold (see _withDisplayInterval), so
    // there is no intermediate-zoom dead zone. `viewportHeight` and
    // `configuredHours` stay in the contract for the runtime zoom clamp; the
    // display pass itself only needs the live hour height.

    // R4-06: horizontal lanes are owned ONLY by exact logical [start, end)
    // intervals. A live drag/resize preview substitutes its exact preview
    // minutes, but the readability floor must never enter this list: doing so
    // made visually enlarged short Events reserve lanes against neighbors
    // they did not logically overlap.
    final layoutEvents = <PlannerCalendarItem>[
      for (final event in timed)
        _withPreviewInterval(
          event,
          startMinute: previewStartMinutes?[event.id],
          endMinute: previewEndMinutes?[event.id],
        ),
    ];
    // The display map is a separate, presentation-only projection. It keeps
    // the factual top anchored to the current logical/preview start, while
    // resolving a fractional visual end from the live hour height. It never
    // rewrites a CalendarItem or DateTime, so drag, resize, recurrence,
    // reporting, and canonical lane ownership retain their exact minutes.
    final displayById = <String, _PlannerDisplayInterval>{
      for (final event in layoutEvents)
        event.id: _displayInterval(
          startMinute: event.startLocal!.hour * 60 + event.startLocal!.minute,
          endMinute: plannerEndMinuteOfDay(event.startLocal!, event.endLocal!),
          hourHeight: hourHeight,
        ),
    };
    final originalById = <String, PlannerCalendarItem>{
      for (final event in timed) event.id: event,
    };
    final canonical = PlannerTimelineLayout.arrange(
      layoutEvents,
      hourHeight: hourHeight,
    );
    if (canonical.isEmpty) {
      return const <PlannerDisplayPlacement>[];
    }

    // R3 display-lane packing: resolve per-event widthFactor/offsetFactor for
    // same-lane display-band collisions (see class doc). The result is a map
    // of event id -> (subColumn, subCount) for packed events only.
    final packed = _resolveDisplayLanePacking(
      canonical: canonical,
      displayById: displayById,
    );
    final geometry = <String, ({double top, double height})>{
      for (final entry in displayById.entries)
        entry.key: _displayGeometry(entry.value, hourHeight: hourHeight),
    };

    // Delta 4.2R R12: detect truly contiguous rendered boundaries
    // (A.end == B.start on the display grid, with horizontally overlapping
    // rectangles) so both blocks square their corners on the shared edge and
    // no decorative rounded-corner notch creates a false vertical gap.
    final squareTopOf = <String, bool>{};
    final squareBottomOf = <String, bool>{};
    for (final placement in canonical) {
      final endMinute = displayById[placement.event.id]!.endMinute;
      for (final other in canonical) {
        if (identical(placement, other)) {
          continue;
        }
        final otherStartMinute = displayById[other.event.id]!.startMinute;
        if ((endMinute - otherStartMinute).abs() < 0.000001 &&
            _horizontallyOverlapping(placement, other)) {
          squareBottomOf[placement.event.id] = true;
          squareTopOf[other.event.id] = true;
        }
      }
    }

    return <PlannerDisplayPlacement>[
      for (final placement in canonical)
        PlannerDisplayPlacement(
          event: originalById[placement.event.id]!,
          top: geometry[placement.event.id]!.top,
          height: geometry[placement.event.id]!.height,
          column: placement.column,
          columnCount: placement.columnCount,
          widthFactor: packed.containsKey(placement.event.id)
              ? packed[placement.event.id]!.widthFactor
              : placement.widthFactor,
          offsetFactor: packed.containsKey(placement.event.id)
              ? packed[placement.event.id]!.offsetFactor
              : placement.offsetFactor,
          // Packed Events drop the canonical free-space span so the renderers
          // use the display-lane widthFactor/offsetFactor slice (the span
          // path takes precedence in both renderers and would otherwise paint
          // every packed card over the same full-lane rectangle).
          spanStart: packed.containsKey(placement.event.id)
              ? null
              : placement.spanStart,
          spanCount: packed.containsKey(placement.event.id)
              ? null
              : placement.spanCount,
          squareTop: squareTopOf[placement.event.id] ?? false,
          squareBottom: squareBottomOf[placement.event.id] ?? false,
        ),
    ];
  }

  static PlannerCalendarItem _withPreviewInterval(
    PlannerCalendarItem event, {
    int? startMinute,
    int? endMinute,
  }) {
    final eventStart = event.startLocal!.hour * 60 + event.startLocal!.minute;
    final eventEnd = plannerEndMinuteOfDay(event.startLocal!, event.endLocal!);
    final previewStart = startMinute ?? eventStart;
    final previewEnd = endMinute ?? eventEnd;
    if (previewStart == eventStart && previewEnd == eventEnd) {
      return event;
    }
    return _withMinutes(
      event,
      startMinute: previewStart,
      endMinute: previewEnd,
    );
  }

  /// Whether the two placements' horizontal rectangles overlap. The rendered
  /// x-range is derived from the canonical span (free-space expansion) when
  /// present, otherwise from the base lane, so only blocks that actually
  /// share a vertical boundary region square their corners.
  static bool _horizontallyOverlapping(
    PlannerTimelinePlacement left,
    PlannerTimelinePlacement right,
  ) {
    double leftStart(PlannerTimelinePlacement p) {
      final span = p.spanStart ?? p.column;
      return span / p.columnCount;
    }

    double leftEnd(PlannerTimelinePlacement p) {
      final spanEnd = (p.spanStart ?? p.column) + (p.spanCount ?? 1);
      return spanEnd / p.columnCount;
    }

    return leftStart(left) < leftEnd(right) && leftStart(right) < leftEnd(left);
  }

  /// Display-lane packing for the shared fractional short-block projection.
  ///
  /// Returns event id -> (offsetFactor, widthFactor) for every Event whose
  /// ENLARGED display band collides with another Event in the SAME canonical
  /// lane. Colliding Events are packed into horizontal DISPLAY sub-columns
  /// (greedy interval partitioning sorted by display start, logical start as
  /// tiebreak) so expanded one-hour cards never cover one another, while
  /// isolated short Events keep full width. Fractions are expressed relative
  /// to the full content width using the canonical lane frame (the widest
  /// canonical columnCount in the component, so packed cards never paint over
  /// a logically-overlapping neighbor in another lane):
  ///
  ///   offsetFactor = (column * k + i) / (columnCount * k)
  ///   widthFactor  = 1 / (columnCount * k)
  ///
  /// This matches the widthFactor/offsetFactor path shared by the centered
  /// timeline renderer and the pager preview renderer, so centered/preview
  /// parity is preserved. The packing is presentation-only: canonical lanes,
  /// drag/resize math, tap ownership, recurrence, and persistence keep the
  /// logical intervals (placement.event stays the original domain item).
  static Map<String, ({double offsetFactor, double widthFactor})>
      _resolveDisplayLanePacking({
    required List<PlannerTimelinePlacement> canonical,
    required Map<String, _PlannerDisplayInterval> displayById,
  }) {
    final displayStartOf = <String, double>{};
    final displayEndOf = <String, double>{};
    for (final entry in displayById.entries) {
      displayStartOf[entry.key] = entry.value.startMinute;
      displayEndOf[entry.key] = entry.value.endMinute;
    }
    final byColumn = <int, List<PlannerTimelinePlacement>>{};
    for (final placement in canonical) {
      byColumn
          .putIfAbsent(placement.column, () => <PlannerTimelinePlacement>[])
          .add(placement);
    }
    final packed = <String, ({double offsetFactor, double widthFactor})>{};
    for (final placements in byColumn.values) {
      placements.sort((a, b) {
        final aStart = displayStartOf[a.event.id]!;
        final bStart = displayStartOf[b.event.id]!;
        if (aStart != bStart) {
          return aStart.compareTo(bStart);
        }
        final aLogical =
            a.event.startLocal!.hour * 60 + a.event.startLocal!.minute;
        final bLogical =
            b.event.startLocal!.hour * 60 + b.event.startLocal!.minute;
        return aLogical.compareTo(bLogical);
      });
      // Connected components of display overlap. Entries are sorted by
      // display start, so an entry joins the current component iff it starts
      // before the component's current maximum display end (transitive).
      var component = <PlannerTimelinePlacement>[];
      var componentMaxEnd = 0.0;
      void flush() {
        if (component.length >= 2) {
          _packComponent(
            component,
            displayStartOf: displayStartOf,
            displayEndOf: displayEndOf,
            packed: packed,
          );
        }
        component = <PlannerTimelinePlacement>[];
        componentMaxEnd = 0;
      }

      for (final placement in placements) {
        final start = displayStartOf[placement.event.id]!;
        final end = displayEndOf[placement.event.id]!;
        if (component.isEmpty) {
          component = <PlannerTimelinePlacement>[placement];
          componentMaxEnd = end;
        } else if (start < componentMaxEnd) {
          component.add(placement);
          componentMaxEnd = math.max(componentMaxEnd, end);
        } else {
          flush();
          component = <PlannerTimelinePlacement>[placement];
          componentMaxEnd = end;
        }
      }
      flush();
    }
    return packed;
  }

  static void _packComponent(
    List<PlannerTimelinePlacement> component, {
    required Map<String, double> displayStartOf,
    required Map<String, double> displayEndOf,
    required Map<String, ({double offsetFactor, double widthFactor})> packed,
  }) {
    // Greedy interval-column partition: each Event takes the first display
    // column whose last display end does not overlap it; otherwise a new
    // column opens.
    final lastEndByColumn = <double>[];
    final columnOf = <String, int>{};
    for (final placement in component) {
      final start = displayStartOf[placement.event.id]!;
      final end = displayEndOf[placement.event.id]!;
      var assigned = -1;
      for (var c = 0; c < lastEndByColumn.length; c++) {
        if (lastEndByColumn[c] <= start) {
          assigned = c;
          break;
        }
      }
      if (assigned == -1) {
        assigned = lastEndByColumn.length;
        lastEndByColumn.add(0.0);
      }
      lastEndByColumn[assigned] = end;
      columnOf[placement.event.id] = assigned;
    }
    final subCount = lastEndByColumn.length;
    final canonicalColumn = component.first.column;
    // Use the WIDEST canonical columnCount in the component: packed cards in
    // a multi-lane region must never paint over a logically-overlapping
    // neighbor in another lane, so the packing stays inside the narrowest
    // lane frame.
    var canonicalCount = 1;
    for (final placement in component) {
      canonicalCount = math.max(canonicalCount, placement.columnCount);
    }
    for (final placement in component) {
      final subColumn = columnOf[placement.event.id]!;
      final offsetFactor = (canonicalColumn * subCount + subColumn) /
          (canonicalCount * subCount);
      final widthFactor = 1 / (canonicalCount * subCount);
      packed[placement.event.id] = (
        offsetFactor: offsetFactor,
        widthFactor: widthFactor,
      );
    }
  }

  static _PlannerDisplayInterval _displayInterval({
    required int startMinute,
    required int endMinute,
    required double hourHeight,
  }) {
    final factualDuration = endMinute - startMinute;
    var displayDuration = factualDuration.toDouble();
    if (factualDuration <= kPlannerMaxZoomReadabilityDurationMinutes) {
      if (hourHeight <= PlannerZoomPolicy.compactHourHeight) {
        displayDuration = 60;
      } else if (hourHeight < PlannerZoomPolicy.normalHourHeight) {
        final transition = ((hourHeight - PlannerZoomPolicy.compactHourHeight) /
                (PlannerZoomPolicy.normalHourHeight -
                    PlannerZoomPolicy.compactHourHeight))
            .clamp(0.0, 1.0);
        displayDuration = 60 + (factualDuration - 60) * transition;
      }
    }
    // The factual visual top never moves. The civil-day clip is presentation
    // only and avoids a late short block painting beyond the day canvas.
    return _PlannerDisplayInterval(
      startMinute: startMinute.toDouble(),
      endMinute: math.min(
        kPlannerCivilDayEndMinute.toDouble(),
        startMinute + displayDuration,
      ),
    );
  }

  static ({double top, double height}) _displayGeometry(
    _PlannerDisplayInterval interval, {
    required double hourHeight,
  }) {
    final start = interval.startMinute
        .clamp(
          kPlannerCivilDayStartMinute.toDouble(),
          kPlannerCivilDayEndMinute.toDouble(),
        )
        .toDouble();
    final end = interval.endMinute
        .clamp(start, kPlannerCivilDayEndMinute.toDouble())
        .toDouble();
    final pixelsPerMinute = hourHeight / 60;
    return (
      top: (start - kPlannerCivilDayStartMinute) * pixelsPerMinute,
      height: (end - start) * pixelsPerMinute,
    );
  }

  static PlannerCalendarItem _withMinutes(
    PlannerCalendarItem event, {
    required int startMinute,
    required int endMinute,
  }) {
    final originalStart = event.startLocal!;
    final midnight = DateTime(
      originalStart.year,
      originalStart.month,
      originalStart.day,
    );
    return PlannerCalendarItem(
      id: event.id,
      title: event.title,
      date: event.date,
      timing: event.timing,
      state: event.state,
      requiresReport: event.requiresReport,
      hasOutcomeReport: event.hasOutcomeReport,
      startLocal: midnight.add(Duration(minutes: startMinute)),
      endLocal: midnight.add(Duration(minutes: endMinute)),
      startUtc: event.startUtc,
      endUtc: event.endUtc,
      locationText: event.locationText,
      isRecurring: event.isRecurring,
      replacementId: event.replacementId,
      linkedTaskIds: event.linkedTaskIds,
      eventId: event.eventId,
      originalDate: event.originalDate,
      timeZoneId: event.timeZoneId,
      displayTimeZoneId: event.displayTimeZoneId,
      activityTypeId: event.activityTypeId,
      activityTypeLabel: event.activityTypeLabel,
      activityTypeColorValue: event.activityTypeColorValue,
      isBackupAppointment: event.isBackupAppointment,
      backupForEventId: event.backupForEventId,
    );
  }
}
