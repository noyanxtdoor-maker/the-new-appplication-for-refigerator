import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_day.dart';
import 'package:rmplanner/features/planner/domain/planner_display_geometry.dart';
import 'package:rmplanner/features/planner/domain/planner_timeline_layout.dart';
import 'package:rmplanner/features/planner/domain/planner_view.dart';

/// WP-A approved readability-aware display law (owner lock, implementation
/// pack 2026-08-19). Proves the new transition endpoint for the ordinary
/// 15 <= D < 60 minute timed footprint while preserving every unchanged
/// invariant (factual start, stored duration, logical overlap, later
/// placement, packing, Task/Event parity, civil-day cap, hourly ruler).
void main() {
  const date = PlannerDate(year: 2026, month: 8, day: 19);
  const viewportHeight = 700.0;
  const configuredHours = 24;

  PlannerCalendarItem event(String id, int startMinute, int endMinute) {
    final midnight = DateTime(2026, 8, 19);
    return PlannerCalendarItem(
      id: id,
      title: id,
      date: date,
      timing: PlannerEventTiming.timed,
      state: PlannerEventState.scheduled,
      requiresReport: false,
      hasOutcomeReport: false,
      startLocal: midnight.add(Duration(minutes: startMinute)),
      endLocal: midnight.add(Duration(minutes: endMinute)),
    );
  }

  List<PlannerDisplayPlacement> resolve(
    List<PlannerCalendarItem> events, {
    required double hourHeight,
    Map<String, int>? previewStartMinutes,
    Map<String, int>? previewEndMinutes,
  }) {
    return PlannerDisplayGeometry.resolve(
      events: events,
      hourHeight: hourHeight,
      viewportHeight: viewportHeight,
      configuredHours: configuredHours,
      previewStartMinutes: previewStartMinutes,
      previewEndMinutes: previewEndMinutes,
    );
  }

  double readabilityEnd(int duration) {
    final end = kPlannerMinimalReadableBlockHeight * 60.0 / duration;
    return end < PlannerZoomPolicy.normalHourHeight
        ? PlannerZoomPolicy.normalHourHeight
        : end;
  }

  group('WP-A readability-aware law - 15 minute Event and Task', () {
    const durationMinutes = 15;
    const hourHeights = <double>[
      44,
      45,
      50,
      55,
      58,
      59,
      60,
      64,
      68,
      71,
      72,
      88,
    ];

    test('rendered display height never falls below 18px before handoff', () {
      for (final hourHeight in hourHeights) {
        final placements = resolve(<PlannerCalendarItem>[
          event('event-15', 8 * 60, 8 * 60 + durationMinutes),
          event('task-footprint:task-15', 12 * 60, 12 * 60 + durationMinutes),
        ], hourHeight: hourHeight);
        for (final id in ['event-15', 'task-footprint:task-15']) {
          final placement = placements.singleWhere((p) => p.event.id == id);
          final pixelsPerMinute = PlannerTimelineGeometry.pixelsPerMinute(
            hourHeight,
          );
          final renderedHeight = placement.height;
          final displayDuration = renderedHeight / pixelsPerMinute;
          if (hourHeight < 72) {
            // Still in the extended transition: display duration is between
            // factual and the one-hour floor, and the RENDERED height is at
            // least the 18px readability point.
            expect(
              displayDuration,
              greaterThan(durationMinutes.toDouble()),
              reason: '$id display duration keeps rising above factual at '
                  '$hourHeight px/hour',
            );
            expect(
              displayDuration,
              lessThan(60.0 + 1e-9),
              reason: '$id display duration stays below the one-hour floor at '
                  '$hourHeight px/hour',
            );
            expect(
              renderedHeight,
              greaterThanOrEqualTo(kPlannerMinimalReadableBlockHeight - 0.001),
              reason: '$id rendered height must stay readable at '
                  '$hourHeight px/hour',
            );
          }
        }
      }
    });

    test('H=72 hands off to factual 15 minutes = exactly 18px', () {
      const hourHeight = 72.0;
      final placements = resolve(<PlannerCalendarItem>[
        event('event-15', 8 * 60, 8 * 60 + durationMinutes),
        event('task-footprint:task-15', 12 * 60, 12 * 60 + durationMinutes),
      ], hourHeight: hourHeight);
      final pixelsPerMinute = PlannerTimelineGeometry.pixelsPerMinute(
        hourHeight,
      );
      for (final id in ['event-15', 'task-footprint:task-15']) {
        final placement = placements.singleWhere((p) => p.event.id == id);
        expect(
          placement.height,
          closeTo(durationMinutes * pixelsPerMinute, 0.001),
          reason: '$id factual display duration at H=72',
        );
        expect(
          placement.height,
          closeTo(kPlannerMinimalReadableBlockHeight, 0.001),
          reason: '$id rendered height is exactly 18px at handoff',
        );
      }
    });

    test('H>72 and H<=44 stay factual/compact with no hard jump', () {
      // Compact floor.
      final compact = resolve(<PlannerCalendarItem>[
        event('event-15', 8 * 60, 8 * 60 + durationMinutes),
      ], hourHeight: PlannerZoomPolicy.compactHourHeight).single;
      expect(
        compact.height,
        closeTo(PlannerZoomPolicy.compactHourHeight, 0.001),
      );
      // Deep zoom stays factual.
      final detailed = resolve(<PlannerCalendarItem>[
        event('event-15', 8 * 60, 8 * 60 + durationMinutes),
      ], hourHeight: 120.0).single;
      expect(
        detailed.height,
        closeTo(durationMinutes * 120.0 / 60.0, 0.001),
      );
      // Continuity: adjacent samples never jump by more than the local slope.
      for (var i = 1; i < hourHeights.length; i++) {
        final a = resolve(<PlannerCalendarItem>[
          event('e', 8 * 60, 8 * 60 + durationMinutes),
        ], hourHeight: hourHeights[i - 1]).single;
        final b = resolve(<PlannerCalendarItem>[
          event('e', 8 * 60, 8 * 60 + durationMinutes),
        ], hourHeight: hourHeights[i]).single;
        expect(
          (b.height - a.height).abs(),
          lessThan(PlannerZoomPolicy.normalHourHeight),
          reason: 'no hard block-size jump between ${hourHeights[i - 1]} and '
              '${hourHeights[i]} px/hour',
        );
      }
    });

    test('monotonic display duration toward factual through the transition', () {
      double displayDurationAt(double hourHeight) {
        final p = resolve(<PlannerCalendarItem>[
          event('e', 8 * 60, 8 * 60 + durationMinutes),
        ], hourHeight: hourHeight).single;
        return p.height /
            PlannerTimelineGeometry.pixelsPerMinute(hourHeight);
      }

      var previous = double.infinity;
      for (final hourHeight in hourHeights) {
        final current = displayDurationAt(hourHeight);
        expect(current, lessThanOrEqualTo(previous + 1e-9));
        previous = current;
      }
      expect(displayDurationAt(44), closeTo(60, 0.000001));
      expect(displayDurationAt(72), closeTo(durationMinutes, 0.000001));
      expect(displayDurationAt(88), closeTo(durationMinutes, 0.000001));
    });
  });

  group('WP-A readability-aware law - other durations', () {
    test('18 minute handoff stays at H=60', () {
      const durationMinutes = 18;
      final at60 = resolve(<PlannerCalendarItem>[
        event('e18', 8 * 60, 8 * 60 + durationMinutes),
      ], hourHeight: 60.0).single;
      expect(
        at60.height,
        closeTo(durationMinutes, 0.001),
        reason: '18m reaches factual exactly at H=60 (18px)',
      );
      expect(readabilityEnd(durationMinutes), closeTo(60, 0.000001));
    });

    test('30/45/50 minute old H=60 factual endpoint is unchanged', () {
      for (final durationMinutes in <int>[30, 45, 50]) {
        final at60 = resolve(<PlannerCalendarItem>[
          event('e$durationMinutes', 8 * 60, 8 * 60 + durationMinutes),
        ], hourHeight: 60.0).single;
        expect(
          at60.height,
          closeTo(durationMinutes, 0.001),
          reason: '$durationMinutes m factual at H=60',
        );
        expect(readabilityEnd(durationMinutes), closeTo(60, 0.000001));
      }
    });

    test('60/90 minute durations are always factual', () {
      for (final durationMinutes in <int>[60, 90]) {
        for (final hourHeight in <double>[44, 52, 60, 88]) {
          final placement = resolve(<PlannerCalendarItem>[
            event('e$durationMinutes', 8 * 60, 8 * 60 + durationMinutes),
          ], hourHeight: hourHeight).single;
          final pixelsPerMinute = PlannerTimelineGeometry.pixelsPerMinute(
            hourHeight,
          );
          expect(
            placement.height,
            closeTo(durationMinutes * pixelsPerMinute, 0.001),
            reason: '$durationMinutes m factual at $hourHeight px/hour',
          );
        }
      }
    });
  });

  group('WP-A invariants preserved', () {
    test('factual start and stored duration never change', () {
      final placements = resolve(<PlannerCalendarItem>[
        event('short', 8 * 60, 8 * 60 + 15),
      ], hourHeight: 60.0);
      final p = placements.single;
      expect(p.event.startLocal, DateTime(2026, 8, 19, 8));
      expect(
        p.event.endLocal!.difference(p.event.startLocal!),
        const Duration(minutes: 15),
      );
      expect(p.top, closeTo(8 * 60, 0.001));
    });

    test('later timed items stay at factual later times', () {
      final placements = resolve(<PlannerCalendarItem>[
        event('short', 10 * 60, 10 * 60 + 15),
        event('later', 10 * 60 + 30, 11 * 60),
      ], hourHeight: 60.0);
      final short = placements.singleWhere((p) => p.event.id == 'short');
      final later = placements.singleWhere((p) => p.event.id == 'later');
      expect(short.top, closeTo(10 * 60, 0.001));
      expect(later.top, closeTo(10 * 60 + 30, 0.001));
      expect(later.height, closeTo(30, 0.001));
    });

    test('logical overlap still produces separate lanes (Task/Event parity)', () {
      final placements = resolve(<PlannerCalendarItem>[
        event('long', 9 * 60, 12 * 60),
        event('task-footprint:overlap', 10 * 60, 10 * 60 + 15),
      ], hourHeight: 60.0);
      final long = placements.singleWhere((p) => p.event.id == 'long');
      final task = placements.singleWhere(
        (p) => p.event.id == 'task-footprint:overlap',
      );
      expect(long.columnCount, 2);
      expect(task.columnCount, 2);
      expect(long.column, isNot(task.column));
    });

    test('display packing still slices colliding enlarged cards', () {
      final placements = resolve(<PlannerCalendarItem>[
        event('a', 8 * 60, 8 * 60 + 15),
        event('b', 8 * 60 + 15, 8 * 60 + 30),
      ], hourHeight: 60.0);
      final a = placements.singleWhere((p) => p.event.id == 'a');
      final b = placements.singleWhere((p) => p.event.id == 'b');
      expect(a.widthFactor, isNotNull);
      expect(b.widthFactor, isNotNull);
      expect(
        a.widthFactor! + a.offsetFactor!,
        lessThanOrEqualTo(b.offsetFactor! + 0.0001),
      );
    });

    test('preview (Task parity) uses the same transition law', () {
      final placements = resolve(<PlannerCalendarItem>[
        event('moving', 8 * 60, 9 * 60),
      ], hourHeight: 60.0, previewStartMinutes: const <String, int>{
        'moving': 8 * 60 + 15,
      }, previewEndMinutes: const <String, int>{'moving': 8 * 60 + 30});
      final p = placements.single;
      // 15-minute preview interval at H=60 is still in the extended
      // transition (34.2857 min display duration).
      expect(
        p.height,
        closeTo(34.28571428571429, 0.001),
        reason: '15m preview follows the same readability-aware law',
      );
      expect(p.top, closeTo((8 * 60 + 15), 0.001));
      expect(p.event.startLocal, DateTime(2026, 8, 19, 8));
      expect(p.event.endLocal, DateTime(2026, 8, 19, 9));
    });

    test('civil-day cap still clamps the final hour', () {
      final placements = resolve(<PlannerCalendarItem>[
        event('final-hour', 23 * 60, 24 * 60),
      ], hourHeight: 60.0);
      final p = placements.single;
      expect(p.bottom, closeTo(24 * 60, 0.001));
      expect(p.height, closeTo(60, 0.001));
    });

    test('hourly-only ruler geometry is unchanged (one px per minute)', () {
      expect(PlannerTimelineGeometry.pixelsPerMinute(60), closeTo(1, 0.0001));
      expect(PlannerTimelineGeometry.pixelsPerMinute(44), closeTo(44 / 60, 0.0001));
      expect(
        PlannerTimelineGeometry.quarterHourHeight(60),
        closeTo(15, 0.0001),
      );
    });
  });
}
