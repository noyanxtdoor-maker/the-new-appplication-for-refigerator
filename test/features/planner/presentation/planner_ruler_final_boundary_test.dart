// P1 owner-review correction C (2026-09-21) — final configured boundary ruler
// rhythm.
//
// Owner-observed defect: for a non-midnight configured end boundary (e.g.
// 4 AM -> 9 PM, 1 AM -> 11 PM) the final two hour labels were visibly crowded
// and the normal one-hour rhythm was lost at the bottom boundary.
//
// Proven source cause: the centered timeline bottom-aligned the FINAL boundary
// label inside the last hour cell (there is no cell below it), so the final
// pair of label anchors sat only `hourHeight - labelHeight - 2` apart while
// every interior pair sat `hourHeight` apart. The small bottom boundary
// allowance that exists for exactly this label was OUTSIDE the pager clip, so
// the label could not simply be drawn below its line.
//
// These tests measure REAL rendered geometry (not label strings):
//   * every adjacent pair of hour labels is one `hourHeight` apart — at
//     compact, normal, expanded and live pinch heights, for 4->21 and 1->23;
//   * the final label sits just BELOW the final line (never inside the last
//     hour cell);
//   * the final label is fully inside the clipped pager box and reachable
//     inside the scroll viewport, and so is every preview-column final label;
//   * the accepted full-day / hidden-midnight behaviour is unchanged.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/planner/application/event_type_providers.dart';
import 'package:rmplanner/features/planner/data/calendar_event_time_zones.dart';
import 'package:rmplanner/features/planner/data/drift_calendar_event_repository.dart';
import 'package:rmplanner/features/planner/data/drift_outcome_reporting_repository.dart';
import 'package:rmplanner/features/planner/data/drift_planner_repository.dart';
import 'package:rmplanner/features/planner/data/drift_task_event_link_repository.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/presentation/widgets/planner_shared_viewport.dart'
    show kPlannerTimelineBottomBoundaryExtent;

import '../../../support/test_dependencies.dart';

const Size _testViewport = Size(862, 1824);
const double _testDevicePixelRatio = 2;
const String _displayTimeZoneId = 'Asia/Manila';

const PlannerDate _selected = PlannerDate(year: 2026, month: 7, day: 27);

/// Wire a memory-backed Planner stack and pump the real production app on the
/// Planner route, mirroring the focused pager tests.
Future<ProviderContainer> _pumpApp(WidgetTester tester) async {
  final database = openMemoryDatabase();
  addTearDown(database.close);
  final linkRepository = DriftTaskEventLinkRepository(
    database: database,
    clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
  );
  final outcomeReportingRepository = DriftOutcomeReportingRepository(
    database: database,
    clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
  );
  final calendarRepository = DriftCalendarEventRepository(
    database: database,
    clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
    timeZones: IanaCalendarEventTimeZones(
      displayTimeZoneId: _displayTimeZoneId,
    ),
    taskContextSource: linkRepository,
    linkContextTransfer: linkRepository,
    reportSource: outcomeReportingRepository,
  );
  final plannerRepository = DriftPlannerRepository(
    database: database,
    clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
    calendarSource: calendarRepository,
    taskContextSource: linkRepository,
    historicalEffectReader: outcomeReportingRepository,
  );
  final privacy = TestPrivacyDependencies(database: database);
  final startup = buildTestRepository(
    database: database,
    privacyGate: privacy.gate,
  );
  await startup.completeOnboarding();
  tester.view.physicalSize = _testViewport;
  tester.view.devicePixelRatio = _testDevicePixelRatio;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    privacy.buildApp(
      environment: const AppEnvironment(
        name: AppEnvironmentName.production,
        label: 'PRODUCTION',
      ),
      diagnostics: SanitizedDiagnostics(),
      startupRepository: startup,
      plannerRepository: plannerRepository,
      plannerDateSource: const FixedPlannerDateSource(_selected),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('Planner'));
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(
    tester.element(find.byType(MaterialApp).first),
  );
}

Future<void> _configureRange(
  WidgetTester tester,
  ProviderContainer container, {
  required int startHour,
  required int endHour,
  required double hourHeight,
}) async {
  final controller = container.read(eventTypeControllerProvider.notifier);
  final settings = container.read(eventTypeControllerProvider).settings;
  final saved = await controller.saveSettings(
    settings.copyWith(
      visibleStartHour: startHour,
      visibleEndHour: endHour,
      timelineHourHeight: hourHeight,
    ),
  );
  expect(saved, isTrue, reason: 'settings save must succeed');
  await tester.pumpAndSettle();
}

Finder _label(int hour) => find.byKey(Key('planner-time-label-$hour'));

Finder _grid() => find.byKey(const Key('planner-time-grid'));

Finder _pager() => find.byKey(const Key('planner-day-pager-viewport'));

/// The hour boundaries the ruler actually dresses (midnight stays hidden).
List<int> _renderedHours(int startHour, int endHour) => <int>[
  for (var hour = startHour; hour <= endHour; hour++)
    if (hour != 0 && hour != 24) hour,
];

ScrollableState _dayScrollable(WidgetTester tester) {
  return tester.state<ScrollableState>(
    find
        .descendant(
          of: find.byKey(const Key('planner-day-scroll')),
          matching: find.byType(Scrollable),
        )
        .first,
  );
}

void main() {
  group('final configured boundary ruler rhythm', () {
    testWidgets(
      'non-midnight ranges keep a one-hour label interval all the way to the '
      'final boundary at every zoom height',
      (tester) async {
        final container = await _pumpApp(tester);

        for (final (startHour, endHour) in const <(int, int)>[
          (4, 21),
          (1, 23),
        ]) {
          for (final hourHeight in const <double>[44, 60, 88, 121]) {
            await _configureRange(
              tester,
              container,
              startHour: startHour,
              endHour: endHour,
              hourHeight: hourHeight,
            );

            final hours = _renderedHours(startHour, endHour);
            final reason = 'range $startHour->$endHour at $hourHeight px';

            // Every adjacent pair of hour labels keeps the one-hour rhythm.
            for (var index = 1; index < hours.length; index++) {
              final previousTop = tester.getRect(_label(hours[index - 1])).top;
              final currentTop = tester.getRect(_label(hours[index])).top;
              expect(
                currentTop - previousTop,
                closeTo(hourHeight, 0.01),
                reason: '$reason: ${hours[index - 1]} -> ${hours[index]}',
              );
            }

            final gridRect = tester.getRect(_grid());
            final pagerRect = tester.getRect(_pager());

            // The exact owner-reported pair: the final two labels.
            final finalRect = tester.getRect(_label(hours.last));
            final penultimateRect = tester.getRect(
              _label(hours[hours.length - 2]),
            );
            expect(
              finalRect.top - penultimateRect.top,
              closeTo(hourHeight, 0.01),
              reason: '$reason: the final two labels must be one hour apart',
            );

            // The final boundary label is drawn just BELOW the final line —
            // it is never tucked inside the last hour cell.
            expect(
              finalRect.top,
              greaterThanOrEqualTo(gridRect.bottom),
              reason: '$reason: the final label must sit below the final line',
            );

            // ...and it stays inside the clipped pager box, which is exactly
            // the canvas plus the bottom boundary allowance.
            expect(
              gridRect.bottom,
              closeTo(
                pagerRect.bottom - kPlannerTimelineBottomBoundaryExtent,
                0.01,
              ),
              reason: '$reason: the clip must include the boundary allowance',
            );
            expect(
              finalRect.bottom,
              lessThanOrEqualTo(pagerRect.bottom + 0.01),
              reason: '$reason: the final label must not be clipped',
            );

            // Preview/settled parity: the preview columns label the same final
            // boundary, and none of those labels may be cut off either.
            final finalLabelText = _hourText(hours.last);
            final matches = find.text(finalLabelText).evaluate().length;
            expect(
              matches,
              greaterThanOrEqualTo(2),
              reason: '$reason: previews must label $finalLabelText too',
            );
            for (var index = 0; index < matches; index++) {
              expect(
                tester.getRect(find.text(finalLabelText).at(index)).bottom,
                lessThanOrEqualTo(pagerRect.bottom + 0.01),
                reason: '$reason: preview final label must not be clipped',
              );
            }
          }
        }
      },
    );

    testWidgets(
      'the final boundary label is reachable inside the scroll viewport',
      (tester) async {
        final container = await _pumpApp(tester);
        await _configureRange(
          tester,
          container,
          startHour: 4,
          endHour: 21,
          hourHeight: 60,
        );

        final scrollable = _dayScrollable(tester);
        scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
        await tester.pump();

        final viewport = tester.getRect(
          find.byKey(const Key('planner-day-scroll')),
        );
        final finalRect = tester.getRect(_label(21));
        expect(finalRect.top, greaterThanOrEqualTo(viewport.top - 0.5));
        expect(
          finalRect.bottom,
          lessThanOrEqualTo(viewport.bottom + 0.5),
          reason:
              'the final boundary label must be fully visible at the '
              'bottom of the scrollable',
        );
      },
    );

    testWidgets(
      'a live pinch keeps the final pair one hour apart at the live height',
      (tester) async {
        final container = await _pumpApp(tester);
        await _configureRange(
          tester,
          container,
          startHour: 4,
          endHour: 21,
          hourHeight: 60,
        );

        final canvas = tester.getRect(
          find.byKey(const Key('planner-zoom-surface')),
        );
        final viewport = tester.getRect(
          find.byKey(const Key('planner-day-scroll')),
        );
        final visible = canvas.intersect(viewport);
        expect(visible.height, greaterThan(60));
        final center = visible.center;

        final first = await tester.startGesture(
          center - const Offset(0, 40),
          pointer: 1,
        );
        final second = await tester.startGesture(
          center + const Offset(0, 40),
          pointer: 2,
        );
        await tester.pump();
        for (var step = 0; step < 3; step++) {
          await first.moveBy(const Offset(0, -20));
          await second.moveBy(const Offset(0, 20));
          await tester.pump();
        }
        await tester.pumpAndSettle();
        await first.up();
        await second.up();
        await tester.pumpAndSettle();

        final gridRect = tester.getRect(_grid());
        final liveHeight = gridRect.height / (21 - 4);
        expect(liveHeight, greaterThan(60));

        final finalRect = tester.getRect(_label(21));
        final penultimateRect = tester.getRect(_label(20));
        expect(
          finalRect.top - penultimateRect.top,
          closeTo(liveHeight, 0.01),
          reason: 'the final pair must keep the live pinch rhythm',
        );
        expect(finalRect.top, greaterThanOrEqualTo(gridRect.bottom));
        expect(
          finalRect.bottom,
          lessThanOrEqualTo(tester.getRect(_pager()).bottom + 0.01),
        );
      },
    );

    testWidgets('the accepted full-day hidden-midnight ruler is unchanged', (
      tester,
    ) async {
      final container = await _pumpApp(tester);
      await _configureRange(
        tester,
        container,
        startHour: 0,
        endHour: 24,
        hourHeight: 60,
      );

      final hours = _renderedHours(0, 24);
      for (var index = 1; index < hours.length; index++) {
        final previousTop = tester.getRect(_label(hours[index - 1])).top;
        final currentTop = tester.getRect(_label(hours[index])).top;
        expect(currentTop - previousTop, closeTo(60, 0.01));
      }

      // Midnight boundaries stay hidden — no 12 AM label, no synthetic row.
      expect(_label(0), findsNothing);
      expect(_label(24), findsNothing);
      expect(find.text('12 AM'), findsNothing);

      // 11 PM is the final rendered label and stays INSIDE the canvas, which
      // is the accepted full-day layout this correction must not disturb.
      final gridRect = tester.getRect(_grid());
      expect(
        tester.getRect(_label(23)).bottom,
        lessThanOrEqualTo(gridRect.bottom),
      );
    });
  });
}

/// The ruler's own label formatter, mirrored so the parity check looks for the
/// same text the production ruler renders.
String _hourText(int hour) {
  if (hour == 24) {
    return '12 AM';
  }
  final normalized = hour == 0
      ? 12
      : hour > 12
      ? hour - 12
      : hour;
  return '$normalized ${normalized >= 12 ? 'PM' : 'AM'}';
}
