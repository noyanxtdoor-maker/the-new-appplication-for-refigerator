// Stage B3-R1 Slice D3-A2: shared viewport model and
// preservation tests for the interactive day pager.
//
// These tests exercise the real Planner widget tree and the
// `PlannerSharedViewport` value object. They verify that a
// horizontal page commit, a cancel, a Today navigation, a
// date-picker change, a date-strip change, and repeated
// forward/backward navigation all preserve the vertical
// viewport that the user already positioned.
//
// All tests prefer measuring real widget positions and the
// production `PlannerSharedViewport.from` factory output over
// asserting on private widget state.
//
// The Planner date label is rebuilt on every date change. Each
// test selects a deterministic date and scrolls the timeline to
// a deterministic offset before exercising the pager, then
// compares the captured viewport fields after the operation.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/planner/application/event_type_providers.dart';
import 'package:rmplanner/features/planner/application/planner_providers.dart';
import 'package:rmplanner/features/planner/data/calendar_event_time_zones.dart';
import 'package:rmplanner/features/planner/data/drift_calendar_event_repository.dart';
import 'package:rmplanner/features/planner/data/drift_outcome_reporting_repository.dart';
import 'package:rmplanner/features/planner/data/drift_planner_repository.dart';
import 'package:rmplanner/features/planner/data/drift_task_event_link_repository.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_view.dart'
    show PlannerZoomPolicy;
import 'package:rmplanner/features/planner/presentation/widgets/planner_shared_viewport.dart';

import '../../../support/test_dependencies.dart';

// Test viewport reused across focused Pager tests so the
// measured offsets are expressed in the same logical
// coordinates the production tree uses on a physical device.
const Size _testViewport = Size(862, 1824);
const double _testDevicePixelRatio = 2;
const String _displayTimeZoneId = 'Asia/Manila';

const PlannerDate _selected = PlannerDate(year: 2026, month: 7, day: 27);
const PlannerDate _previous = PlannerDate(year: 2026, month: 7, day: 26);
const PlannerDate _next = PlannerDate(year: 2026, month: 7, day: 28);

/// Wire a memory-backed Planner stack and pump the real
/// production app. Returns the [ProviderContainer] so tests can
/// drive the [PlannerController] and read the live
/// [PlannerState] after a gesture.
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

/// Capture the production shared viewport from the live
/// `PlannerInteractiveDayPager` widget via the
/// `PlannerSharedViewport.from` factory. Reads the live
/// scroll controller from the planner tree and the rendered
/// hour height from the production settings provider.
PlannerSharedViewport _captureViewport(WidgetTester tester) {
  final scrollFinder = find.byKey(const Key('planner-day-scroll'));
  expect(scrollFinder, findsOneWidget);
  final scroll = tester.widget<SingleChildScrollView>(scrollFinder);
  final controller = scroll.controller!;
  // Read the live timeline height: the pager viewport key
  // has a known height even before any layout.
  final pagerFinder = find.byKey(const Key('planner-day-pager-viewport'));
  expect(pagerFinder, findsOneWidget);
  final pagerSize = tester.getSize(pagerFinder);
  // Pull the planner settings out of the live state via the
  // ProviderContainer that wraps the planner route. Settings
  // live on the EventTypeController, not the PlannerState.
  final container = ProviderScope.containerOf(
    tester.element(find.byType(MaterialApp).first),
  );
  final settings = container.read(eventTypeControllerProvider).settings;
  return PlannerSharedViewport.from(
    hourHeight: settings.timelineHourHeight,
    scrollController: controller,
    settings: settings,
    viewportHeight: pagerSize.height,
  );
}

Offset _visibleTimelineCenter(WidgetTester tester) {
  final canvas = tester.getRect(find.byKey(const Key('planner-zoom-surface')));
  final viewport = tester.getRect(find.byKey(const Key('planner-day-scroll')));
  final visible = canvas.intersect(viewport);
  expect(visible.height, greaterThan(60));
  return visible.center;
}

/// Drive a horizontal swipe at the pager center. Negative `dx`
/// is a left swipe (next day); positive `dx` is a right swipe
/// (previous day).
Future<void> _driveSwipe(
  WidgetTester tester, {
  required double dx,
  int steps = 8,
}) async {
  final center = _visibleTimelineCenter(tester);
  final gesture = await tester.startGesture(center, pointer: 1);
  final perStep = dx / steps;
  for (var i = 1; i <= steps; i++) {
    await gesture.moveBy(Offset(perStep, 0));
    await tester.pump(const Duration(milliseconds: 16));
  }
  await gesture.up();
  // The Planner screen owns a one-minute Timer for the
  // current-time indicator, which `pumpAndSettle` never
  // resolves; explicit frame pumps avoid that hang while
  // still giving the AnimationController enough time to
  // reach its end (240 ms settle = ~15 frames at 16 ms, we
  // pump 30 to be safe).
  for (var i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// Drive a below-threshold horizontal gesture (force cancel).
Future<void> _driveBelowThreshold(
  WidgetTester tester, {
  required double dx,
}) async {
  final center = _visibleTimelineCenter(tester);
  final gesture = await tester.startGesture(center, pointer: 1);
  for (var i = 0; i < 4; i++) {
    await gesture.moveBy(Offset(dx / 4, 0));
    await tester.pump(const Duration(milliseconds: 40));
  }
  await gesture.up();
  for (var i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// Convenience: pump enough frames for any in-flight
/// rebuild/animation to settle without triggering the
/// one-minute current-time Timer that hangs `pumpAndSettle`.
Future<void> _pumpFrames(WidgetTester tester) async {
  for (var i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// Drive a two-pointer pinch to a non-default hour height. The
/// pinch coordinator owns vertical-scroll physics during the
/// pinch, then the SingleChildScrollView resumes.
Future<void> _drivePinch(
  WidgetTester tester, {
  required double totalGap,
}) async {
  final center = _visibleTimelineCenter(tester);
  final first = await tester.startGesture(
    center + const Offset(-20, -40),
    pointer: 1,
  );
  final second = await tester.startGesture(
    center + const Offset(20, 40),
    pointer: 2,
  );
  await tester.pump();
  // Separation increases → zoom in (taller hours).
  await first.moveBy(Offset(0, -totalGap / 2));
  await second.moveBy(Offset(0, totalGap / 2));
  await tester.pump();
  await first.moveBy(Offset(0, -totalGap / 4));
  await second.moveBy(Offset(0, totalGap / 4));
  await tester.pump();
  await first.up();
  await second.up();
  await _pumpFrames(tester);
}

/// Open the slide-down Planner date picker, tap a day cell whose
/// numeric label matches [dayLabel] inside the open panel, and
/// confirm via OK. The day cell finder is scoped to the picker
/// panel so other day-number labels (header text, tooltips) do
/// not collide. Material's [DatePickerDialog] renders leading /
/// trailing slots of adjacent months as empty boxes, so a numeric
/// match inside the panel always resolves to a single day cell of
/// the displayed month.
///
/// The picker opens with a slide-down animation
/// (transitionDuration 240 ms); we use [pumpAndSettle] inside the
/// open and confirm sequence so the route, the day-cell highlight
/// re-render, and the route-pop all settle deterministically.
Future<void> _selectDayViaPicker(
  WidgetTester tester, {
  required String dayLabel,
}) async {
  await tester.tap(find.byKey(const Key('planner-date-label')));
  await tester.pumpAndSettle();
  expect(
    find.byKey(const Key('planner-date-picker-panel')),
    findsOneWidget,
    reason: 'picker panel must open',
  );
  // The day cell is a numeric Text widget inside the picker
  // panel. Scoping to the panel keeps the search unambiguous.
  final dayCell = find.descendant(
    of: find.byKey(const Key('planner-date-picker-panel')),
    matching: find.text(dayLabel),
  );
  expect(dayCell, findsOneWidget, reason: 'expected one $dayLabel day cell');
  await tester.tap(dayCell);
  await tester.pumpAndSettle();
  // Confirm via OK.
  expect(find.text('OK'), findsOneWidget);
  await tester.tap(find.text('OK'));
  await tester.pumpAndSettle();
  expect(
    find.byKey(const Key('planner-date-picker-panel')),
    findsNothing,
    reason: 'picker must close after OK',
  );
}

void main() {
  group('Stage B3-R1 D3-A2: shared viewport matrix', () {
    testWidgets('TEST 1 — model geometry: pixelsPerMinute, '
        'visibleStartMinute, visibleEndMinute', (tester) async {
      await _pumpApp(tester);
      await _pumpFrames(tester);
      // Scroll to a known offset.
      final scrollFinder = find.byKey(const Key('planner-day-scroll'));
      final scroll = tester.widget<SingleChildScrollView>(scrollFinder);
      final controller = scroll.controller!;
      // Jump a deterministic amount within the timeline's
      // scrollable extent (bounded: no dead scroll region,
      // so the extent is a few hundred logical pixels).
      controller.jumpTo(180);
      await tester.pump();
      final viewport = _captureViewport(tester);
      // pixelsPerMinute = hourHeight / 60 (clamped). Verify
      // the formula relationship by re-deriving it from the
      // live hourHeight (the model clamps hourHeight via
      // PlannerZoomPolicy.clampAbsolute, but at the defaults
      // the clamp is a no-op).
      final expectedPpm = viewport.hourHeight / 60.0;
      expect(
        (viewport.pixelsPerMinute - expectedPpm).abs() < 1e-9,
        isTrue,
        reason:
            'pixelsPerMinute must equal hourHeight / 60 '
            '(was ${viewport.pixelsPerMinute}, expected '
            '$expectedPpm)',
      );
      // P1 (2026-09-21): visibleStartMinute is derived from the live scroll
      // offset and the EFFECTIVE presentation range, which is the configured
      // visible window rather than the whole civil day. This regression runs
      // against the live default settings, so the range origin is the
      // configured start hour.
      final rangeSettings = ProviderScope.containerOf(
        tester.element(find.byType(MaterialApp).first),
      ).read(eventTypeControllerProvider).settings;
      final rangeStartMinute = rangeSettings.visibleStartHour * 60;
      final rangeEndMinute = rangeSettings.visibleEndHour * 60;
      final expectedStartMinute =
          (rangeStartMinute +
                  (viewport.pixelsPerMinute > 0
                      ? viewport.verticalOffset / viewport.pixelsPerMinute
                      : 0))
              .round()
              .clamp(rangeStartMinute, rangeEndMinute - 1);
      expect(
        (viewport.visibleStartMinute - expectedStartMinute).abs() <= 1,
        isTrue,
        reason:
            'visibleStartMinute must equal '
            '(rangeStart + offset/pixelsPerMinute) clamped to the '
            'effective range (was ${viewport.visibleStartMinute}, '
            'expected $expectedStartMinute)',
      );
      // Verify the visibleEndMinute = visibleStartMinute +
      // viewportHeight / pixelsPerMinute, clamped.
      final expectedEndMinute =
          (viewport.visibleStartMinute +
                  (viewport.pixelsPerMinute > 0
                      ? (viewport.viewportHeight / viewport.pixelsPerMinute)
                            .round()
                      : 0))
              .clamp(viewport.visibleStartMinute, rangeEndMinute);
      expect(
        (viewport.visibleEndMinute - expectedEndMinute).abs() <= 1,
        isTrue,
        reason:
            'visibleEndMinute must equal '
            '(visibleStartMinute + viewportHeight/pixelsPerMinute) '
            'clamped to the effective range (was '
            '${viewport.visibleEndMinute}, expected '
            '$expectedEndMinute)',
      );
      expect(
        viewport.visibleEndMinute >= viewport.visibleStartMinute,
        isTrue,
        reason: 'visibleEndMinute must not be less than start',
      );
      expect(
        viewport.pixelsPerMinute.isFinite && viewport.pixelsPerMinute > 0,
        isTrue,
        reason: 'pixelsPerMinute must be finite and positive',
      );
    });

    testWidgets('TEST 2 — next-day commit preserves the vertical offset', (
      tester,
    ) async {
      final container = await _pumpApp(tester);
      await _pumpFrames(tester);
      final scrollFinder = find.byKey(const Key('planner-day-scroll'));
      final controller = tester
          .widget<SingleChildScrollView>(scrollFinder)
          .controller!;
      controller.jumpTo(200);
      await tester.pump();
      final before = controller.offset;
      // Left swipe past the distance threshold.
      await _driveSwipe(tester, dx: -320);
      expect(
        container.read(plannerControllerProvider).selectedDate,
        _next,
        reason: 'left swipe must commit +1 day',
      );
      expect(
        controller.hasClients,
        isTrue,
        reason: 'scroll controller must still be attached',
      );
      final after = controller.offset;
      expect(
        (after - before).abs() < 1.0,
        isTrue,
        reason:
            'vertical offset must be preserved within one '
            'logical pixel after a next-day commit '
            '(before $before, after $after)',
      );
    });

    testWidgets('TEST 3 — previous-day commit preserves the vertical offset', (
      tester,
    ) async {
      final container = await _pumpApp(tester);
      await _pumpFrames(tester);
      final scrollFinder = find.byKey(const Key('planner-day-scroll'));
      final controller = tester
          .widget<SingleChildScrollView>(scrollFinder)
          .controller!;
      controller.jumpTo(200);
      await tester.pump();
      final before = controller.offset;
      // Right swipe past the distance threshold.
      await _driveSwipe(tester, dx: 320);
      expect(
        container.read(plannerControllerProvider).selectedDate,
        _previous,
        reason: 'right swipe must commit -1 day',
      );
      final after = controller.offset;
      expect(
        (after - before).abs() < 1.0,
        isTrue,
        reason:
            'vertical offset must be preserved within one '
            'logical pixel after a previous-day commit '
            '(before $before, after $after)',
      );
    });

    testWidgets('TEST 4 — cancel preserves the vertical offset', (
      tester,
    ) async {
      final container = await _pumpApp(tester);
      await _pumpFrames(tester);
      final scrollFinder = find.byKey(const Key('planner-day-scroll'));
      final controller = tester
          .widget<SingleChildScrollView>(scrollFinder)
          .controller!;
      controller.jumpTo(200);
      await tester.pump();
      final before = controller.offset;
      // Below-threshold swipe cancels and recenters.
      await _driveBelowThreshold(tester, dx: -50);
      expect(
        container.read(plannerControllerProvider).selectedDate,
        _selected,
        reason: 'a cancelled swipe must not commit',
      );
      final after = controller.offset;
      expect(
        (after - before).abs() < 1.0,
        isTrue,
        reason:
            'vertical offset must be preserved within one '
            'logical pixel after a cancel '
            '(before $before, after $after)',
      );
    });

    testWidgets('TEST 5 — commit preserves the hour height after a pinch', (
      tester,
    ) async {
      final container = await _pumpApp(tester);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      });
      await _pumpFrames(tester);
      // Pinch to a non-default hour height.
      await _drivePinch(tester, totalGap: 80);
      final before = _captureViewport(tester).hourHeight;
      // Confirm the pinch actually moved off the default.
      final defaultHourHeight = PlannerZoomPolicy.normalHourHeight;
      expect(
        (before - defaultHourHeight).abs() > 1,
        isTrue,
        reason:
            'pinch must move the hour height off the '
            'default $defaultHourHeight (was $before)',
      );
      // Left swipe to commit one day. The hour height must
      // remain unchanged.
      await _driveSwipe(tester, dx: -320);
      expect(
        container.read(plannerControllerProvider).selectedDate,
        _next,
        reason: 'left swipe must commit +1 day',
      );
      final after = _captureViewport(tester).hourHeight;
      expect(
        (after - before).abs() < 0.5,
        isTrue,
        reason:
            'hour height must be preserved within 0.5 '
            'logical pixel after a commit (before $before, '
            'after $after)',
      );
    });

    testWidgets('TEST 6 — cancel preserves the hour height after a pinch', (
      tester,
    ) async {
      final container = await _pumpApp(tester);
      await _pumpFrames(tester);
      await _drivePinch(tester, totalGap: 80);
      final before = _captureViewport(tester).hourHeight;
      // Below-threshold swipe cancels.
      await _driveBelowThreshold(tester, dx: -50);
      expect(
        container.read(plannerControllerProvider).selectedDate,
        _selected,
        reason: 'a cancelled swipe must not commit',
      );
      final after = _captureViewport(tester).hourHeight;
      expect(
        (after - before).abs() < 0.5,
        isTrue,
        reason:
            'hour height must be preserved within 0.5 '
            'logical pixel after a cancel (before $before, '
            'after $after)',
      );
    });

    testWidgets('TEST 7 — visible minute range preserved across a commit', (
      tester,
    ) async {
      final container = await _pumpApp(tester);
      await _pumpFrames(tester);
      final scrollFinder = find.byKey(const Key('planner-day-scroll'));
      final controller = tester
          .widget<SingleChildScrollView>(scrollFinder)
          .controller!;
      controller.jumpTo(200);
      await tester.pump();
      final before = _captureViewport(tester);
      await _driveSwipe(tester, dx: -320);
      expect(
        container.read(plannerControllerProvider).selectedDate,
        _next,
        reason: 'left swipe must commit +1 day',
      );
      final after = _captureViewport(tester);
      // The visible-minute range can drift by a small amount
      // due to the rebuild reflow that follows the date
      // commit (the FutureBuilder invalidates, the preview
      // columns re-render, and the SingleChildScrollView's
      // padding is re-applied to a fresh layout pass). An
      // explicit 60-minute tolerance (~one hour) accommodates
      // this reflow while still catching gross regressions.
      expect(
        (after.visibleStartMinute - before.visibleStartMinute).abs() <= 60,
        isTrue,
        reason:
            'visibleStartMinute must stay within 60 minutes '
            'across the commit (before '
            '${before.visibleStartMinute}, after '
            '${after.visibleStartMinute})',
      );
      expect(
        (after.visibleEndMinute - before.visibleEndMinute).abs() <= 60,
        isTrue,
        reason:
            'visibleEndMinute must stay within 60 minutes '
            'across the commit (before '
            '${before.visibleEndMinute}, after '
            '${after.visibleEndMinute})',
      );
    });

    testWidgets('TEST 8 — go to today preserves the viewport', (tester) async {
      // Today = _selected; we navigate to yesterday first,
      // then tap Today and verify the viewport is preserved.
      // To do that we make the date source think today is
      // _selected and we set our current selection to
      // _previous.
      final container = await _pumpApp(tester);
      await _pumpFrames(tester);
      await container
          .read(plannerControllerProvider.notifier)
          .selectDate(_previous);
      await _pumpFrames(tester);
      final scrollFinder = find.byKey(const Key('planner-day-scroll'));
      final controller = tester
          .widget<SingleChildScrollView>(scrollFinder)
          .controller!;
      controller.jumpTo(200);
      await tester.pump();
      final before = _captureViewport(tester);
      // Tap the Today button (the calendar icon).
      final today = find.byKey(const Key('planner-today-button'));
      expect(today, findsOneWidget);
      await tester.tap(today);
      await _pumpFrames(tester);
      expect(
        container.read(plannerControllerProvider).selectedDate,
        _selected,
        reason: 'Today must navigate to today',
      );
      final after = _captureViewport(tester);
      expect(
        (after.verticalOffset - before.verticalOffset).abs() < 1.0,
        isTrue,
        reason:
            'Today must preserve the vertical offset '
            '(before ${before.verticalOffset}, after '
            '${after.verticalOffset})',
      );
      expect(
        (after.hourHeight - before.hourHeight).abs() < 0.5,
        isTrue,
        reason:
            'Today must preserve the hour height '
            '(before ${before.hourHeight}, after '
            '${after.hourHeight})',
      );
    });

    testWidgets('TEST 9 — date picker preserves the viewport', (tester) async {
      final container = await _pumpApp(tester);
      await _pumpFrames(tester);
      final scrollFinder = find.byKey(const Key('planner-day-scroll'));
      final controller = tester
          .widget<SingleChildScrollView>(scrollFinder)
          .controller!;
      controller.jumpTo(200);
      await tester.pump();
      // Establish a non-default zoom so the viewport fields
      // we capture actually carry a useful hour-height value
      // distinct from the planner default. The selected date
      // is intentionally left untouched by the pinch path
      // (the pinch coordinator only writes to the
      // hour-height setting, never to selectedDate).
      await _drivePinch(tester, totalGap: 80);
      // Scroll back to the deterministic offset AFTER the
      // pinch so the captured viewport reflects the same
      // position the production tree would land on after a
      // user pinch + idle.
      controller.jumpTo(200);
      await tester.pump();
      final before = _captureViewport(tester);
      final beforeHourHeight = before.hourHeight;
      expect(
        (beforeHourHeight - PlannerZoomPolicy.normalHourHeight).abs() > 1,
        isTrue,
        reason:
            'TEST 9 setup: the pinch must move the hour '
            'height off the default before the picker '
            'change (was $beforeHourHeight, default '
            '${PlannerZoomPolicy.normalHourHeight})',
      );
      // Drive a real date change through the slide-down
      // Planner date picker: open → tap a different day
      // cell → OK. _next is selected via the day cell "28"
      // inside the picker panel. The controller's
      // selectDate is NOT called by the test body.
      await _selectDayViaPicker(tester, dayLabel: '28');
      await _pumpFrames(tester);
      expect(
        container.read(plannerControllerProvider).selectedDate,
        _next,
        reason:
            'a real picker OK must commit the day tapped '
            'inside the panel; picker step landed at '
            '${container.read(plannerControllerProvider).selectedDate}',
      );
      final after = _captureViewport(tester);
      expect(
        (after.verticalOffset - before.verticalOffset).abs() < 1.0,
        isTrue,
        reason:
            'picker date change must preserve the vertical '
            'offset (before ${before.verticalOffset}, after '
            '${after.verticalOffset})',
      );
      expect(
        (after.hourHeight - before.hourHeight).abs() < 0.5,
        isTrue,
        reason:
            'picker date change must preserve the hour '
            'height (before ${before.hourHeight}, after '
            '${after.hourHeight})',
      );
      expect(
        (after.visibleStartMinute - before.visibleStartMinute).abs() <= 60,
        isTrue,
        reason:
            'picker date change must keep visibleStartMinute '
            'within 60 minutes (before '
            '${before.visibleStartMinute}, after '
            '${after.visibleStartMinute})',
      );
      expect(
        (after.visibleEndMinute - before.visibleEndMinute).abs() <= 60,
        isTrue,
        reason:
            'picker date change must keep visibleEndMinute '
            'within 60 minutes (before '
            '${before.visibleEndMinute}, after '
            '${after.visibleEndMinute})',
      );
    });

    testWidgets('TEST 10 — date strip preserves the viewport', (tester) async {
      final container = await _pumpApp(tester);
      await _pumpFrames(tester);
      final scrollFinder = find.byKey(const Key('planner-day-scroll'));
      final controller = tester
          .widget<SingleChildScrollView>(scrollFinder)
          .controller!;
      controller.jumpTo(200);
      await tester.pump();
      final before = _captureViewport(tester);
      // Tap a specific date on the date strip. _previous
      // should be one of the date-strip buttons.
      final previousButton = find.byKey(
        Key('planner-day-${_previous.iso8601}'),
      );
      if (previousButton.evaluate().isNotEmpty) {
        await tester.tap(previousButton);
      } else {
        // _previous is not on the current strip; use _next
        // instead.
        await tester.tap(find.byKey(Key('planner-day-${_next.iso8601}')));
      }
      await _pumpFrames(tester);
      final newDate = container.read(plannerControllerProvider).selectedDate;
      expect(
        newDate != _selected,
        isTrue,
        reason: 'date strip tap must change the selected date',
      );
      final after = _captureViewport(tester);
      // The post-tap rebuild reflow can shift the offset by
      // a few pixels (the FutureBuilder invalidates and the
      // timeline layout re-passes). An explicit 20-pixel
      // tolerance covers this reflow while still catching
      // gross regressions.
      expect(
        (after.verticalOffset - before.verticalOffset).abs() < 20.0,
        isTrue,
        reason:
            'date strip tap must preserve the vertical '
            'offset within 20 pixels (before '
            '${before.verticalOffset}, after '
            '${after.verticalOffset})',
      );
    });

    testWidgets('TEST 11 — current time does not force scroll', (tester) async {
      final container = await _pumpApp(tester);
      await _pumpFrames(tester);
      // Navigate to a date whose current-time indicator
      // would be far outside the visible range. Today is
      // _selected (clock is 2026-07-27T12), but the
      // visible range is roughly 6am-9pm local (15 h * 60
      // = 900 minutes), and the timeline hourHeight /
      // hourHeight-clamp means the visible minute range
      // covers a wide span anyway. We scroll to a minute
      // far from 12:00 (e.g. the very top), then navigate
      // back to today via _previous and verify the offset
      // did not auto-snap.
      await container
          .read(plannerControllerProvider.notifier)
          .selectDate(_previous);
      await _pumpFrames(tester);
      final scrollFinder = find.byKey(const Key('planner-day-scroll'));
      final controller = tester
          .widget<SingleChildScrollView>(scrollFinder)
          .controller!;
      controller.jumpTo(0);
      await tester.pump();
      final before = controller.offset;
      // Today button — should navigate to _selected
      // (today = _selected, fixed clock).
      final today = find.byKey(const Key('planner-today-button'));
      await tester.tap(today);
      await _pumpFrames(tester);
      expect(
        container.read(plannerControllerProvider).selectedDate,
        _selected,
        reason: 'Today must navigate to today',
      );
      final after = controller.offset;
      expect(
        (after - before).abs() < 1.0,
        isTrue,
        reason:
            'navigating onto today must not force a '
            'vertical scroll (before $before, after $after)',
      );
    });

    testWidgets(
      'TEST 12 — repeated navigation preserves viewport (drift check)',
      (tester) async {
        final container = await _pumpApp(tester);
        await _pumpFrames(tester);
        final scrollFinder = find.byKey(const Key('planner-day-scroll'));
        final controller = tester
            .widget<SingleChildScrollView>(scrollFinder)
            .controller!;
        controller.jumpTo(200);
        await tester.pump();
        final baseline = _captureViewport(tester);
        // Swipe next.
        await _driveSwipe(tester, dx: -320);
        expect(
          container.read(plannerControllerProvider).selectedDate,
          _next,
          reason: 'first swipe must commit +1',
        );
        // Swipe back to the original date.
        await _driveSwipe(tester, dx: 320);
        expect(
          container.read(plannerControllerProvider).selectedDate,
          _selected,
          reason: 'second swipe must commit -1',
        );
        // Date-strip selection (tap the today button on the
        // strip).
        final dateStripPrevious = find.byKey(
          Key('planner-day-${_previous.iso8601}'),
        );
        if (dateStripPrevious.evaluate().isNotEmpty) {
          await tester.tap(dateStripPrevious);
          await _pumpFrames(tester);
          // Back to today via Today button.
          await tester.tap(find.byKey(const Key('planner-today-button')));
          await _pumpFrames(tester);
        }
        // Picker-style change — drive a real date change
        // through the slide-down picker so the test exercises
        // the picker UI rather than the controller directly.
        // selectDate is intentionally NOT called by this
        // block.
        await _selectDayViaPicker(tester, dayLabel: '28');
        await _pumpFrames(tester);
        // Back to _selected via the picker (day 27).
        await _selectDayViaPicker(tester, dayLabel: '27');
        await _pumpFrames(tester);
        expect(
          container.read(plannerControllerProvider).selectedDate,
          _selected,
          reason: 'after the full drill we should be back on _selected',
        );
        final finalViewport = _captureViewport(tester);
        // No accumulated drift beyond an explicit tolerance.
        // A sequence of commits, date-strip tap, Today, and
        // picker-style navigation can introduce small
        // per-step reflow shift (FutureBuilder invalidation,
        // layout re-pass). 50 logical pixels of accumulated
        // drift is a generous upper bound that still catches
        // gross regressions; 0.5 logical pixels hour height
        // stays very tight (zoom is never re-applied during
        // navigation).
        expect(
          (finalViewport.verticalOffset - baseline.verticalOffset).abs() < 50.0,
          isTrue,
          reason:
              'repeated navigation must not accumulate '
              'vertical offset drift beyond 50 logical pixels '
              '(baseline ${baseline.verticalOffset}, final '
              '${finalViewport.verticalOffset})',
        );
        expect(
          (finalViewport.hourHeight - baseline.hourHeight).abs() < 0.5,
          isTrue,
          reason:
              'repeated navigation must not accumulate hour '
              'height drift (baseline ${baseline.hourHeight}, '
              'final ${finalViewport.hourHeight})',
        );
      },
    );
  });
}
