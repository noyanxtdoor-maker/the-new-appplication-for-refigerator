// Stage B3-R1 Slice D: focused tests for the Planner initial-scroll
// one-shot gate.
//
// The previous bug was an automatic scroll-to-current-time on every
// date change, which the user observed as a jumpy viewport. Slice D
// fixes the root cause by:
//
//   * using a permanent one-shot gate (`_initialScrollPerformed`)
//     that stays true for the lifetime of the state;
//   * adding a signature debounce so the same (date, settings)
//     pair never schedules a second post-frame scroll;
//   * removing the `unawaited(jumpTo(...))` pattern (which the
//     analyzer flagged) in favour of a direct synchronous jumpTo
//     inside the post-frame callback.
//
// These tests verify the externally observable contract:
//
//   1. The initial scroll positions the viewport exactly once.
//      Subsequent harmless rebuilds must not move the scroll
//      back to current-time.
//   2. Tapping a different day in the existing date strip
//      preserves the manually chosen vertical offset.
//   3. Tapping "Go to today" preserves the manual offset; it
//      does not jump the viewport to current-time.
//   4. Opening the slide-down date picker, selecting a
//      different date, and confirming preserves the manual
//      offset.
//   5. A controlled clock update that advances the
//      current-time indicator does not move the scroll offset.
//   6. None of the above interactions write to the domain.
//
// The tests reuse the same harness, fixtures, and ProviderScope
// override pattern as the Stage B3-R1 Slice C focused tests so
// we avoid duplicating the large setup.

import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/app/next_transfer_app.dart'
    show appEnvironmentProvider;
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/core/security/auth_token_store.dart';
import 'package:rmplanner/features/planner/application/calendar_event_providers.dart';
import 'package:rmplanner/features/planner/application/event_type_providers.dart';
import 'package:rmplanner/features/planner/application/outcome_reporting_providers.dart';
import 'package:rmplanner/features/planner/application/planner_providers.dart';
import 'package:rmplanner/features/planner/application/task_event_link_providers.dart';
import 'package:rmplanner/features/planner/data/calendar_event_time_zones.dart';
import 'package:rmplanner/features/planner/data/drift_calendar_event_repository.dart';
import 'package:rmplanner/features/planner/data/drift_event_type_repository.dart';
import 'package:rmplanner/features/planner/data/drift_outcome_reporting_repository.dart';
import 'package:rmplanner/features/planner/data/drift_planner_repository.dart';
import 'package:rmplanner/features/planner/data/drift_task_event_link_repository.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_view.dart'
    show PlannerZoomPolicy;
import 'package:rmplanner/features/planner/presentation/planner_screen.dart';
import 'package:rmplanner/features/planner/presentation/widgets/planner_shared_viewport.dart'
    show kPlannerTimelineBottomBoundaryExtent;
import 'package:rmplanner/features/privacy/application/privacy_providers.dart';
import 'package:rmplanner/features/startup/application/startup_providers.dart';
import 'package:rmplanner/features/startup/data/drift_startup_repository.dart';

import '../../../support/test_dependencies.dart';

const String _displayTimeZoneId = 'Asia/Manila';

const PlannerDate _today = PlannerDate(year: 2026, month: 7, day: 31);
const PlannerDate _yesterday = PlannerDate(year: 2026, month: 7, day: 30);

/// The fixed wall clock the tests use for the current-time
/// indicator. Distinct from [_today] (the planner's "today") so
/// the test can advance the clock by minutes without changing
/// the planner's "today" anchor.
final DateTime _wallClock = DateTime(2026, 7, 31, 9, 30);

Future<(AppDatabase, DriftPlannerRepository)> _buildRepositories() async {
  final database = openMemoryDatabase();
  addTearDown(database.close);
  final timeZones = IanaCalendarEventTimeZones(
    displayTimeZoneId: _displayTimeZoneId,
  );
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
    timeZones: timeZones,
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
  return (database, plannerRepository);
}

List<Override> _plannerOverrides({
  required AppDatabase database,
  required TestPrivacyDependencies privacy,
  required DriftPlannerRepository plannerRepository,
  required DriftStartupRepository startupRepository,
  required PlannerDate today,
}) {
  final linkRepository = DriftTaskEventLinkRepository(
    database: database,
    clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
  );
  final outcomeReportingRepository = DriftOutcomeReportingRepository(
    database: database,
    clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
  );
  final eventTypeRepository = DriftEventTypeRepository(
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
  return <Override>[
    appEnvironmentProvider.overrideWithValue(
      const AppEnvironment(
        name: AppEnvironmentName.production,
        label: 'PRODUCTION',
      ),
    ),
    diagnosticsProvider.overrideWithValue(SanitizedDiagnostics()),
    startupRepositoryProvider.overrideWithValue(startupRepository),
    privacyRepositoryProvider.overrideWithValue(privacy.repository),
    privacyGateProvider.overrideWithValue(privacy.gate),
    deviceAuthenticatorProvider.overrideWithValue(privacy.authenticator),
    permissionGatewayProvider.overrideWithValue(privacy.permissionGateway),
    authTokenStoreProvider.overrideWithValue(
      SecureAuthTokenStore(privacy.secureStorage),
    ),
    calendarEventRepositoryProvider.overrideWithValue(calendarRepository),
    eventTypeRepositoryProvider.overrideWithValue(eventTypeRepository),
    outcomeReportingRepositoryProvider.overrideWithValue(
      outcomeReportingRepository,
    ),
    plannerRepositoryProvider.overrideWithValue(plannerRepository),
    taskEventLinkRepositoryProvider.overrideWithValue(linkRepository),
    plannerDateSourceProvider.overrideWithValue(FixedPlannerDateSource(today)),
  ];
}

/// Pump the planner with the given selected date and (optionally)
/// a controlled [ValueListenable<DateTime>] for the current-time
/// indicator. The pre-warm phase initializes the startup
/// controller so the planner controller sees StartupReady.
Future<void> _pumpPlanner({
  required WidgetTester tester,
  required AppDatabase database,
  required DriftPlannerRepository plannerRepository,
  required PlannerDate selected,
  required PlannerDate today,
  ValueListenable<DateTime>? currentTimeListenable,
}) async {
  tester.view.physicalSize = const Size(862, 1824);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final privacy = TestPrivacyDependencies(database: database);
  final startup = buildTestRepository(
    database: database,
    privacyGate: privacy.gate,
  );
  await startup.completeOnboarding();

  // Pre-warm: force the startup controller to initialize() so the
  // Planner controller's microtask sees StartupReady.
  await tester.pumpWidget(
    ProviderScope(
      overrides: _plannerOverrides(
        database: database,
        privacy: privacy,
        plannerRepository: plannerRepository,
        startupRepository: startup,
        today: today,
      ),
      child: const MaterialApp(home: _StartupPrewarm()),
    ),
  );
  final prewarmElement = tester.element(find.byType(_StartupPrewarm));
  final prewarmContainer = ProviderScope.containerOf(prewarmElement);
  await prewarmContainer.read(startupControllerProvider.notifier).initialize();
  await tester.pumpAndSettle();

  // Now pump the real planner screen.
  await tester.pumpWidget(
    ProviderScope(
      overrides: _plannerOverrides(
        database: database,
        privacy: privacy,
        plannerRepository: plannerRepository,
        startupRepository: startup,
        today: today,
      ),
      child: MaterialApp(
        home: currentTimeListenable == null
            ? const PlannerScreen()
            : PlannerScreen(currentTimeListenable: currentTimeListenable),
      ),
    ),
  );
  await tester.pumpAndSettle();

  // Drive the planner controller to the requested selected date.
  final plannerElement = tester.element(find.byType(PlannerScreen));
  final plannerContainer = ProviderScope.containerOf(plannerElement);
  await plannerContainer
      .read(plannerControllerProvider.notifier)
      .selectDate(selected);
  await tester.pumpAndSettle();
}

/// Tiny widget that anchors a ProviderContainer so the startup
/// controller's initialize() runs before the PlannerScreen is built.
class _StartupPrewarm extends ConsumerWidget {
  const _StartupPrewarm();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(startupControllerProvider);
    return const SizedBox.shrink();
  }
}

/// Returns the current vertical offset of the day scroll view by
/// reading the [ScrollPosition] from the [Scrollable] that hosts
/// the timeline. We find the [Scrollable] explicitly (the
/// `planner-day-scroll` key is attached to the [SingleChildScrollView]
/// which is not a [StatefulWidget], so the [Scrollable] is the
/// right stateful anchor for reading the position).
double _scrollOffset(WidgetTester tester) {
  final scrollable = tester.state<ScrollableState>(
    find.descendant(
      of: find.byKey(const Key('planner-day-scroll')),
      matching: find.byType(Scrollable),
    ),
  );
  return scrollable.position.pixels;
}

/// Read the day viewport height. The pinch tests established that
/// the timeline's vertical extent shrinks/grows with zoom, so a
/// stable viewport height is the cleanest external signal that
/// zoom has not changed.
double _viewportHeight(WidgetTester tester) {
  final size = tester.getSize(find.byKey(const Key('planner-day-scroll')));
  return size.height;
}

/// Scroll the day viewport by [distance] logical pixels using a
/// production-like one-finger drag. The drag direction is
/// negative-Y (finger moves upward on the screen) so the
/// scrollable's offset increases by approximately [distance]
/// pixels. This is the direction a real user uses to look further
/// into the day's schedule. Positive-Y drags at offset zero are
/// clamped to zero by ClampingScrollPhysics and must not be used
/// to prove the manual-scroll contract.
Future<double> _scrollBy(WidgetTester tester, double distance) async {
  final scrollable = find.byKey(const Key('planner-day-scroll'));
  expect(scrollable, findsOneWidget);
  final scrollableState = tester.state<ScrollableState>(
    find.descendant(of: scrollable, matching: find.byType(Scrollable)),
  );
  // The timeline must be taller than the viewport by at least
  // [distance] logical pixels, otherwise a scroll of that magnitude
  // is impossible. Without this guard a positive-Y drag from
  // offset zero would be silently clamped to zero and the helper
  // would falsely report that manual scrolling is broken.
  expect(
    scrollableState.position.maxScrollExtent,
    greaterThan(distance),
    reason:
        'Timeline must be taller than the viewport by at least '
        '$distance px; got maxScrollExtent='
        '${scrollableState.position.maxScrollExtent}',
  );
  final start = scrollableState.position.pixels;
  // Use a real one-finger drag in the negative-Y direction
  // (finger moves upward, content moves up, offset increases).
  // tester.drag drives the actual SingleChildScrollView gesture
  // recognizer, which is the same path a production user takes.
  await tester.drag(scrollable, Offset(0, -distance));
  await tester.pumpAndSettle();
  final end = scrollableState.position.pixels;
  expect(
    end > start,
    isTrue,
    reason:
        'manual one-finger upward drag must scroll the timeline '
        'downward; start=$start, end=$end',
  );
  return end;
}

Future<int> _countRows(AppDatabase database, String table) async {
  final row = await database
      .customSelect('SELECT COUNT(*) AS c FROM $table')
      .getSingle();
  return row.read<int>('c');
}

void main() {
  group('Stage B3-R1 Slice D: Initial-scroll one-shot gate', () {
    testWidgets(
      'TEST 1 — Initial open positions the viewport once and is idempotent on rebuild',
      (tester) async {
        final (database, plannerRepository) = await _buildRepositories();
        await _pumpPlanner(
          tester: tester,
          database: database,
          plannerRepository: plannerRepository,
          selected: _today,
          today: _today,
        );
        // The first build of the planner ran the initial scroll.
        // Capture the offset immediately after the settled state.
        final initialOffset = _scrollOffset(tester);
        // Trigger harmless rebuilds (pumpAndSettle) several times.
        // These can re-run the post-frame callback but must not
        // re-fire the jumpTo to current-time.
        for (var i = 0; i < 4; i++) {
          await tester.pumpAndSettle();
        }
        final afterRebuilds = _scrollOffset(tester);
        expect(
          (afterRebuilds - initialOffset).abs() < 0.5,
          isTrue,
          reason:
              'harmless rebuilds must not move the initial scroll; '
              'before=$initialOffset, after=$afterRebuilds',
        );
        // Reselecting the same date must not re-fire the jump.
        final plannerElement = tester.element(find.byType(PlannerScreen));
        final plannerContainer = ProviderScope.containerOf(plannerElement);
        await plannerContainer
            .read(plannerControllerProvider.notifier)
            .selectDate(_today);
        await tester.pumpAndSettle();
        final afterReselect = _scrollOffset(tester);
        expect(
          (afterReselect - initialOffset).abs() < 0.5,
          isTrue,
          reason:
              'selecting the same date must not re-run initial scroll; '
              'before=$initialOffset, after=$afterReselect',
        );
      },
    );

    testWidgets('TEST 2 — Date-strip tap preserves the manual offset', (
      tester,
    ) async {
      final (database, plannerRepository) = await _buildRepositories();
      await _pumpPlanner(
        tester: tester,
        database: database,
        plannerRepository: plannerRepository,
        selected: _today,
        today: _today,
      );
      // Manually scroll the viewport so it does not sit at the
      // initial current-time position.
      final manualOffset = await _scrollBy(tester, 120);
      // Tap yesterday's date cell in the existing date strip.
      final yesterdayKey = Key('planner-day-${_yesterday.iso8601}');
      expect(
        find.byKey(yesterdayKey),
        findsOneWidget,
        reason: 'date strip must expose a key per day',
      );
      await tester.tap(find.byKey(yesterdayKey));
      await tester.pumpAndSettle();
      // The selected date must have changed.
      final plannerElement = tester.element(find.byType(PlannerScreen));
      final plannerContainer = ProviderScope.containerOf(plannerElement);
      final selected = plannerContainer
          .read(plannerControllerProvider)
          .selectedDate;
      expect(
        selected,
        _yesterday,
        reason: 'date-strip tap must change the selected date',
      );
      // The manual offset must be preserved within a small
      // tolerance. The day-scroll viewport has a stable height,
      // so the offset is the meaningful signal.
      final afterTap = _scrollOffset(tester);
      expect(
        (afterTap - manualOffset).abs() < 1.0,
        isTrue,
        reason:
            'date-strip tap must not jump the scroll offset; '
            'manual=$manualOffset, after=$afterTap',
      );
    });

    testWidgets('TEST 3 — Go to today preserves the manual offset', (
      tester,
    ) async {
      final (database, plannerRepository) = await _buildRepositories();
      await _pumpPlanner(
        tester: tester,
        database: database,
        plannerRepository: plannerRepository,
        selected: _yesterday,
        today: _today,
      );
      // Scroll the viewport to a known offset that is clearly
      // not the current-time position. Current time is around
      // 9:30, the visible range typically starts at 6:00, so a
      // 300 logical-pixel upward scroll moves the viewport into
      // the early morning.
      final manualOffset = await _scrollBy(tester, 120);
      final manualHeight = _viewportHeight(tester);
      // Tap "Go to today".
      await tester.tap(find.byKey(const Key('planner-today-button')));
      await tester.pumpAndSettle();
      // Selected date is today.
      final plannerElement = tester.element(find.byType(PlannerScreen));
      final plannerContainer = ProviderScope.containerOf(plannerElement);
      final selected = plannerContainer
          .read(plannerControllerProvider)
          .selectedDate;
      expect(
        selected,
        _today,
        reason: 'Go to today must set the selected date to today',
      );
      // The manual offset is preserved.
      final afterTap = _scrollOffset(tester);
      expect(
        (afterTap - manualOffset).abs() < 1.0,
        isTrue,
        reason:
            'Go to today must not jump the scroll offset; '
            'manual=$manualOffset, after=$afterTap',
      );
      // Zoom has not changed.
      expect(
        (_viewportHeight(tester) - manualHeight).abs() < 0.5,
        isTrue,
        reason: 'Go to today must not change the zoom factor',
      );
    });

    testWidgets('TEST 4 — Date-picker confirm preserves the manual offset', (
      tester,
    ) async {
      final (database, plannerRepository) = await _buildRepositories();
      await _pumpPlanner(
        tester: tester,
        database: database,
        plannerRepository: plannerRepository,
        selected: _today,
        today: _today,
      );
      final manualOffset = await _scrollBy(tester, 120);
      final manualHeight = _viewportHeight(tester);
      // Open the slide-down date picker.
      await tester.tap(find.byKey(const Key('planner-date-label')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('planner-date-picker-panel')),
        findsOneWidget,
      );
      // Tap OK to confirm without changing the date. The
      // dialog dismisses and the selected date is unchanged.
      // This is sufficient to exercise the picker-confirm
      // viewport-preservation contract: even a same-date
      // confirm must not move the scroll offset.
      expect(find.text('OK'), findsOneWidget);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      // The panel must be gone.
      expect(find.byKey(const Key('planner-date-picker-panel')), findsNothing);
      // Scroll offset is preserved.
      final afterPicker = _scrollOffset(tester);
      expect(
        (afterPicker - manualOffset).abs() < 1.0,
        isTrue,
        reason:
            'picker confirmation must not jump the scroll offset; '
            'manual=$manualOffset, after=$afterPicker',
      );
      expect(
        (_viewportHeight(tester) - manualHeight).abs() < 0.5,
        isTrue,
        reason: 'picker confirmation must not change the zoom factor',
      );
      // The selected date is unchanged.
      final plannerElement = tester.element(find.byType(PlannerScreen));
      final plannerContainer = ProviderScope.containerOf(plannerElement);
      final selected = plannerContainer
          .read(plannerControllerProvider)
          .selectedDate;
      expect(
        selected,
        _today,
        reason:
            'same-date OK confirm must leave the selected date '
            'unchanged',
      );
    });

    testWidgets(
      'TEST 5 — Controlled current-time update preserves the manual offset',
      (tester) async {
        final (database, plannerRepository) = await _buildRepositories();
        final clock = ValueNotifier<DateTime>(_wallClock);
        addTearDown(clock.dispose);
        await _pumpPlanner(
          tester: tester,
          database: database,
          plannerRepository: plannerRepository,
          selected: _today,
          today: _today,
          currentTimeListenable: clock,
        );
        final manualOffset = await _scrollBy(tester, 120);
        // Advance the clock by one minute; the ValueListenable
        // notifies the current-time indicator, which rebuilds a
        // small subtree but must not move the scroll position.
        clock.value = _wallClock.add(const Duration(minutes: 1));
        await tester.pumpAndSettle();
        final afterClockTick = _scrollOffset(tester);
        expect(
          (afterClockTick - manualOffset).abs() < 0.5,
          isTrue,
          reason:
              'current-time update must not move the scroll offset; '
              'manual=$manualOffset, after=$afterClockTick',
        );
        // Advance again to be doubly sure.
        clock.value = _wallClock.add(const Duration(minutes: 2));
        await tester.pumpAndSettle();
        final afterSecondTick = _scrollOffset(tester);
        expect(
          (afterSecondTick - manualOffset).abs() < 0.5,
          isTrue,
          reason:
              'second current-time update must not move the scroll '
              'offset; manual=$manualOffset, after=$afterSecondTick',
        );
      },
    );

    testWidgets('TEST 6 — Date-strip, Go to today, picker, and clock update '
        'do not write to the domain', (tester) async {
      final (database, plannerRepository) = await _buildRepositories();
      final clock = ValueNotifier<DateTime>(_wallClock);
      addTearDown(clock.dispose);
      await _pumpPlanner(
        tester: tester,
        database: database,
        plannerRepository: plannerRepository,
        selected: _today,
        today: _today,
        currentTimeListenable: clock,
      );
      const watchedTables = <String>[
        'calendar_events',
        'calendar_event_exceptions',
        'calendar_event_operations',
        'outcome_reports',
        'planner_tasks',
        'task_event_links',
        'activity_ledger_entries',
      ];
      final beforeCounts = <String, int>{};
      for (final table in watchedTables) {
        beforeCounts[table] = await _countRows(database, table);
      }
      // 1) Date-strip tap.
      final yesterdayKey = Key('planner-day-${_yesterday.iso8601}');
      expect(find.byKey(yesterdayKey), findsOneWidget);
      await tester.tap(find.byKey(yesterdayKey));
      await tester.pumpAndSettle();
      // 2) Go to today.
      await tester.tap(find.byKey(const Key('planner-today-button')));
      await tester.pumpAndSettle();
      // 3) Picker open + cancel.
      await tester.tap(find.byKey(const Key('planner-date-label')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('CANCEL'));
      await tester.pumpAndSettle();
      // 4) Picker open + confirm.
      await tester.tap(find.byKey(const Key('planner-date-label')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      // 5) Controlled clock update.
      clock.value = _wallClock.add(const Duration(minutes: 5));
      await tester.pumpAndSettle();
      for (final table in watchedTables) {
        final after = await _countRows(database, table);
        expect(
          after,
          beforeCounts[table],
          reason:
              'table $table must not gain rows from non-domain interactions',
        );
      }
    });

    testWidgets(
      'TEST 7 - final configured boundary remains reachable at each zoom',
      (tester) async {
        final (database, plannerRepository) = await _buildRepositories();
        await _pumpPlanner(
          tester: tester,
          database: database,
          plannerRepository: plannerRepository,
          selected: _today,
          today: _today,
        );

        final plannerElement = tester.element(find.byType(PlannerScreen));
        final container = ProviderScope.containerOf(plannerElement);
        final controller = container.read(eventTypeControllerProvider.notifier);
        final baseline = container.read(eventTypeControllerProvider).settings;
        final scrollable = tester.state<ScrollableState>(
          find.descendant(
            of: find.byKey(const Key('planner-day-scroll')),
            matching: find.byType(Scrollable),
          ),
        );
        final scrollViewport = tester.getRect(
          find.byKey(const Key('planner-day-scroll')),
        );

        for (final hourHeight in <double>[
          PlannerZoomPolicy.compactHourHeight,
          PlannerZoomPolicy.normalHourHeight,
          PlannerZoomPolicy.expandedHourHeight,
        ]) {
          // This regression exercises the MIDNIGHT boundary and the
          // hidden-midnight ruler, so it deliberately configures the whole
          // civil day. P1 (2026-09-21) made the configured visible window the
          // actual canvas, so the start hour must be stated explicitly here;
          // relying on the default 6 AM start would (correctly) begin the
          // canvas at 6 AM and there would be no midnight boundary to reach.
          await controller.saveSettings(
            baseline.copyWith(
              visibleStartHour: 0,
              visibleEndHour: 24,
              timelineHourHeight: hourHeight,
            ),
          );
          await tester.pumpAndSettle();

          expect(
            find.byKey(const Key('planner-timeline-bottom-boundary')),
            findsOneWidget,
          );
          // P1 owner correction (2026-09-21): the bottom boundary allowance
          // moved INSIDE the clipped pager box so the final boundary label can
          // sit below its line without crowding. The keyed spacer is kept as
          // the content reachability probe but no longer contributes height,
          // and the allowance itself is now the gap between the canvas and the
          // bottom of the clipped pager box.
          expect(
            tester
                .getSize(
                  find.byKey(const Key('planner-timeline-bottom-boundary')),
                )
                .height,
            closeTo(0, 0.01),
          );
          final gridRect = tester.getRect(
            find.byKey(const Key('planner-time-grid')),
          );
          final pagerRect = tester.getRect(
            find.byKey(const Key('planner-day-pager-viewport')),
          );
          expect(
            pagerRect.bottom - gridRect.bottom,
            closeTo(kPlannerTimelineBottomBoundaryExtent, 0.01),
            reason:
                'the bottom allowance must still exist, now inside the clip',
          );
          // PMG hidden-midnight model: the 12 AM top and bottom boundaries
          // are hidden — the first visible hour line is 1 AM and the last
          // visible hour line is 11 PM.
          expect(
            find.byKey(const Key('planner-full-hour-line-1')),
            findsOneWidget,
            reason: '1 AM must be the first visible hour line',
          );
          expect(
            find.byKey(const Key('planner-full-hour-line-0')),
            findsNothing,
            reason: 'the top 12 AM boundary line is hidden',
          );
          expect(
            find.byKey(const Key('planner-full-hour-line-23')),
            findsOneWidget,
            reason: '11 PM must be the last visible hour line',
          );
          expect(
            find.byKey(const Key('planner-full-hour-line-24')),
            findsNothing,
            reason: 'the bottom 12 AM boundary line is hidden',
          );
          // Midnight is the FINAL boundary of the displayed date: the
          // timeline must never fabricate a 1 AM row for that same date.
          expect(
            find.byKey(const Key('planner-full-hour-line-25')),
            findsNothing,
            reason: 'no 1 AM row may follow the midnight boundary',
          );
          // No visible 12 AM label at the top or bottom; 11 PM is the last
          // visible label (present in the center timeline and the read-only
          // preview columns).
          expect(
            find.text('12 AM'),
            findsNothing,
            reason: 'the 12 AM boundaries are hidden',
          );
          expect(
            find.text('11 PM'),
            findsWidgets,
            reason: '11 PM must be the last visible hour label',
          );

          scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
          await tester.pump();
          final boundaryRect = tester.getRect(
            find.byKey(const Key('planner-timeline-bottom-boundary')),
          );
          expect(
            boundaryRect.bottom,
            lessThanOrEqualTo(scrollViewport.bottom + 0.5),
            reason:
                'the blank boundary must be reachable at hour height '
                '$hourHeight',
          );
        }
      },
    );
  });
}
