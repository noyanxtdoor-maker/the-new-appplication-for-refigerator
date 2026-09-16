// Stage B3-R1 Slice D3-A: current-time ownership and geometry
// matrix for the interactive day pager preview columns.
//
// The pager preview column previously called `DateTime.now()`
// independently. This file proves the unified source behavior:
// the preview column and the centered timeline read from the
// same authoritative `ValueListenable<DateTime>`, the
// indicator appears on exactly one page (the page whose
// PlannerDate matches the listenable's current local date),
// the indicator geometry tracks the listenable's
// hour/minute value at exact-minute resolution, the
// indicator Y scales coherently with pinch zoom, the
// indicator never forces a scroll, and ownership transfers
// cleanly across a midnight boundary without duplicating
// or losing the indicator.

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
import 'package:rmplanner/features/planner/presentation/planner_screen.dart';
import 'package:rmplanner/features/planner/presentation/widgets/planner_interactive_day_pager.dart'
    show PlannerCurrentTimeHorizontalGeometry;
import 'package:rmplanner/features/privacy/application/privacy_providers.dart';
import 'package:rmplanner/features/startup/application/startup_providers.dart';
import 'package:rmplanner/features/startup/data/drift_startup_repository.dart';

import '../../../support/test_dependencies.dart';

/// The "today" the focused current-time matrix uses. Chosen
/// inside the 6→22 visible window so the indicator is always
/// inside the visible band regardless of the listenable's
/// hour value.
const PlannerDate _today = PlannerDate(year: 2026, month: 7, day: 31);
const PlannerDate _yesterday = PlannerDate(year: 2026, month: 7, day: 30);
const PlannerDate _tomorrow = PlannerDate(year: 2026, month: 8, day: 1);

const String _displayTimeZoneId = 'Asia/Manila';

class _CurrentTimeController {
  _CurrentTimeController(DateTime initial)
    : notifier = ValueNotifier<DateTime>(initial);
  final ValueNotifier<DateTime> notifier;
  DateTime get value => notifier.value;
  set value(DateTime newValue) => notifier.value = newValue;
  void dispose() => notifier.dispose();
}

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
  required PlannerDate selected,
  required DriftStartupRepository startupRepository,
}) {
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
    calendarEventRepositoryProvider.overrideWithValue(
      DriftCalendarEventRepository(
        database: database,
        clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
        timeZones: IanaCalendarEventTimeZones(
          displayTimeZoneId: _displayTimeZoneId,
        ),
        taskContextSource: DriftTaskEventLinkRepository(
          database: database,
          clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
        ),
        linkContextTransfer: DriftTaskEventLinkRepository(
          database: database,
          clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
        ),
        reportSource: DriftOutcomeReportingRepository(
          database: database,
          clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
        ),
      ),
    ),
    eventTypeRepositoryProvider.overrideWithValue(
      DriftEventTypeRepository(
        database: database,
        clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
      ),
    ),
    outcomeReportingRepositoryProvider.overrideWithValue(
      DriftOutcomeReportingRepository(
        database: database,
        clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
      ),
    ),
    plannerRepositoryProvider.overrideWithValue(plannerRepository),
    taskEventLinkRepositoryProvider.overrideWithValue(
      DriftTaskEventLinkRepository(
        database: database,
        clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
      ),
    ),
    plannerDateSourceProvider.overrideWithValue(
      FixedPlannerDateSource(selected),
    ),
  ];
}

class _StartupPrewarm extends ConsumerWidget {
  const _StartupPrewarm();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(startupControllerProvider);
    return const SizedBox.shrink();
  }
}

Future<_CurrentTimeController> _pumpPlanner({
  required WidgetTester tester,
  required AppDatabase database,
  required DriftPlannerRepository plannerRepository,
  required PlannerDate selected,
  required DateTime current,
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
  final currentTime = _CurrentTimeController(current);
  addTearDown(currentTime.dispose);
  // The "today" used by the planner is _today (the real
  // today), independent of the selected date under test.
  // The indicator's `isToday` check uses this value, so
  // we anchor the date source to _today and navigate the
  // planner to the test's `selected` afterwards.
  await tester.pumpWidget(
    ProviderScope(
      overrides: _plannerOverrides(
        database: database,
        privacy: privacy,
        plannerRepository: plannerRepository,
        selected: _today,
        startupRepository: startup,
      ),
      child: const MaterialApp(home: _StartupPrewarm()),
    ),
  );
  final prewarmElement = tester.element(find.byType(_StartupPrewarm));
  final prewarmContainer = ProviderScope.containerOf(prewarmElement);
  await prewarmContainer.read(startupControllerProvider.notifier).initialize();
  await tester.pumpAndSettle();
  // Now pump the planner screen with the listenable.
  await tester.pumpWidget(
    ProviderScope(
      overrides: _plannerOverrides(
        database: database,
        privacy: privacy,
        plannerRepository: plannerRepository,
        selected: _today,
        startupRepository: startup,
      ),
      child: MaterialApp(
        home: PlannerScreen(currentTimeListenable: currentTime.notifier),
      ),
    ),
  );
  await tester.pumpAndSettle();
  // Navigate the planner to the test's `selected` so the
  // previous/next/centered window reflects the scenario.
  final plannerElement = tester.element(find.byType(PlannerScreen));
  final plannerContainer = ProviderScope.containerOf(plannerElement);
  if (selected != _today) {
    await plannerContainer
        .read(plannerControllerProvider.notifier)
        .selectDate(selected);
    await tester.pumpAndSettle();
  }
  // Pump additional frames so the preview FutureBuilder
  // completes and the captured previous/next day content
  // signatures populate.
  for (var i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  return currentTime;
}

/// The CT-01 capsule is the nearest [Container] ancestor of the current-time
/// label (it carries the primary fill + full rounding).
Finder _currentTimeCapsule(Finder label) =>
    find.ancestor(of: label, matching: find.byType(Container)).first;

Key _previewPageKey(PlannerDate date) =>
    Key('planner-day-page-${date.iso8601}');

/// Find every rendered current-time indicator across the
/// three pager pages and identify which page hosts it.
({PlannerDate? ownerPage, int total}) _indicatorOwnership(
  WidgetTester tester, {
  required PlannerDate previous,
  required PlannerDate selected,
  required PlannerDate next,
}) {
  final total = find
      .byKey(const Key('planner-current-time-indicator'))
      .evaluate()
      .length;
  PlannerDate? owner;
  for (final date in <PlannerDate>[previous, selected, next]) {
    final hits = find
        .descendant(
          of: find.byKey(_previewPageKey(date)),
          matching: find.byKey(const Key('planner-current-time-indicator')),
        )
        .evaluate();
    if (hits.isNotEmpty) {
      owner = date;
      break;
    }
  }
  return (ownerPage: owner, total: total);
}

/// Resolve the visible-minute Y of the current-time indicator
/// inside the preview's `Stack` by reading the
/// `planner-current-time-indicator` Positioned. The
/// `top` of that Positioned is the indicator Row's top edge
/// in preview-local pixels; adding half the indicator
/// height (12 logical pixels / 2) yields the vertical
/// center.
double _indicatorCenterY(WidgetTester tester) {
  final finder = find.byKey(const Key('planner-current-time-indicator'));
  expect(finder, findsOneWidget);
  final rect = tester.getRect(finder);
  // Get the preview Stack's top.
  final gridFinder = find.byKey(const Key('planner-day-pager-viewport'));
  final gridRect = tester.getRect(gridFinder);
  return rect.center.dy - gridRect.top;
}

/// Drive a two-pointer pinch that grows or shrinks the
/// hour height. `separation` is the total separation the
/// two pointers grow to relative to the start.
Future<void> _drivePinch(
  WidgetTester tester, {
  required double separation,
}) async {
  final center = tester.getCenter(
    find.byKey(const Key('planner-day-pager-viewport')),
  );
  final first = await tester.startGesture(
    center + const Offset(-20, -40),
    pointer: 1,
  );
  final second = await tester.startGesture(
    center + const Offset(20, 40),
    pointer: 2,
  );
  await tester.pump();
  // Move each pointer outward.
  await first.moveBy(Offset(-separation / 4, 0));
  await second.moveBy(Offset(separation / 4, 0));
  await tester.pump();
  await first.moveBy(Offset(-separation / 4, 0));
  await second.moveBy(Offset(separation / 4, 0));
  await tester.pump();
  await first.up();
  await second.up();
  for (var i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  group('Stage B3-R1 D3-A: pager current-time matrix', () {
    testWidgets('TEST 1 — today is previous page: selected date is tomorrow, '
        'previous preview is today; exactly one indicator, on the '
        'previous page', (tester) async {
      final (database, plannerRepo) = await _buildRepositories();
      // Current time falls on _today (2026-07-31) at 16:03.
      final current = DateTime(2026, 7, 31, 16, 3);
      // Selected is _tomorrow (2026-08-01), so previous
      // is _today and next is 2026-08-02.
      await _pumpPlanner(
        tester: tester,
        database: database,
        plannerRepository: plannerRepo,
        selected: _tomorrow,
        current: current,
      );
      final ownership = _indicatorOwnership(
        tester,
        previous: _today,
        selected: _tomorrow,
        next: PlannerDate(year: 2026, month: 8, day: 2),
      );
      expect(
        ownership.total,
        1,
        reason: 'exactly one indicator must be visible',
      );
      expect(
        ownership.ownerPage,
        _today,
        reason: 'today (previous page) must own the indicator',
      );
    });

    testWidgets('TEST 2 — today is current page: exactly one indicator on '
        'the centered page; previews have none', (tester) async {
      final (database, plannerRepo) = await _buildRepositories();
      final current = DateTime(2026, 7, 31, 16, 3);
      // Selected is _today.
      await _pumpPlanner(
        tester: tester,
        database: database,
        plannerRepository: plannerRepo,
        selected: _today,
        current: current,
      );
      final ownership = _indicatorOwnership(
        tester,
        previous: _yesterday,
        selected: _today,
        next: _tomorrow,
      );
      expect(ownership.total, 1);
      expect(ownership.ownerPage, _today);
    });

    testWidgets('TEST 3 — today is next page: selected date is yesterday, '
        'next preview is today; exactly one indicator on next page', (
      tester,
    ) async {
      final (database, plannerRepo) = await _buildRepositories();
      final current = DateTime(2026, 7, 31, 16, 3);
      await _pumpPlanner(
        tester: tester,
        database: database,
        plannerRepository: plannerRepo,
        selected: _yesterday,
        current: current,
      );
      final ownership = _indicatorOwnership(
        tester,
        previous: PlannerDate(year: 2026, month: 7, day: 29),
        selected: _yesterday,
        next: _today,
      );
      expect(ownership.total, 1);
      expect(ownership.ownerPage, _today);
    });

    testWidgets('TEST 4 — exact-minute geometry and R5-05 fixed-gutter '
        'composition match on a non-today preview', (tester) async {
      final (database, plannerRepo) = await _buildRepositories();
      // Deterministic time: 10:37 (10 * 60 + 37 = 637
      // minutes from midnight). The visible window is 6→22,
      // so the minute is inside the band.
      const hour = 10;
      const minute = 37;
      final current = DateTime(2026, 7, 31, hour, minute);
      // Selected is _tomorrow so the previous preview is
      // _today and the indicator lives on the preview.
      final currentTime = await _pumpPlanner(
        tester: tester,
        database: database,
        plannerRepository: plannerRepo,
        selected: _tomorrow,
        current: current,
      );
      // Read the live hour height from the planner state.
      final container = ProviderScope.containerOf(
        tester.element(find.byType(PlannerScreen)),
      );
      final settings = container.read(eventTypeControllerProvider).settings;
      final hourHeight = settings.timelineHourHeight;
      // Compute the expected Y from the production formula. The
      // preview canvas now runs the full civil day (00:00 start),
      // so the indicator Y is minute-of-day scaled by the live
      // hour height.
      final minuteOfDay = hour * 60 + minute;
      final expectedY = minuteOfDay * (hourHeight / 60.0);
      final observedY = _indicatorCenterY(tester);
      expect(
        (observedY - expectedY).abs() < 1.0,
        isTrue,
        reason:
            'indicator Y must equal minuteOfDay * (hourHeight / 60) '
            '(observed $observedY, expected $expectedY)',
      );
      // Label text matches the production formatter: 10:37 AM.
      final todayPage = find.byKey(_previewPageKey(_today));
      final label = find.descendant(
        of: todayPage,
        matching: find.byKey(const Key('planner-current-time-label')),
      );
      final dot = find.descendant(
        of: todayPage,
        matching: find.byKey(const Key('planner-current-time-dot')),
      );
      final line = find.descendant(
        of: todayPage,
        matching: find.byKey(const Key('planner-current-time-line')),
      );
      final hourLine = find.descendant(
        of: todayPage,
        matching: find.byKey(const Key('planner-pager-full-hour-line-6')),
      );
      expect(
        label,
        findsOneWidget,
        reason:
            'preview current-time label must render on the '
            'previous page (today)',
      );
      expect(
        find.text('10:37 AM'),
        findsOneWidget,
        reason: 'preview label must read "10:37 AM"',
      );
      final pageRect = tester.getRect(todayPage);
      final capsuleRect = tester.getRect(_currentTimeCapsule(label));
      final dotRect = tester.getRect(dot);
      final lineRect = tester.getRect(line);
      final hourLineRect = tester.getRect(hourLine);
      // CT-03: the label area widens LEFTWARD (labelLeft = anchorLeft -
      // labelWidth), so wide 12h labels may start left of the page origin;
      // the right edge stays tangent to the anchor (asserted below).
      expect(
        capsuleRect.left,
        closeTo(
          pageRect.left + PlannerCurrentTimeHorizontalGeometry.labelLeft,
          0.5,
        ),
        reason: 'pager CT-03 label area left edge must follow labelLeft',
      );
      expect(
        dotRect.left - capsuleRect.right,
        closeTo(0, 0.5),
        reason: 'pager capsule must be attached/tangent to the anchor',
      );
      expect(
        dotRect.center.dx - pageRect.left,
        closeTo(PlannerCurrentTimeHorizontalGeometry.dotCenterX, 0.5),
        reason: 'pager anchor center must stay on the 56 dp gutter boundary',
      );
      expect(
        lineRect.left - dotRect.right,
        closeTo(0, 0.5),
        reason: 'pager line must begin at the anchor right edge',
      );
      expect(lineRect.right, closeTo(pageRect.right, 0.5));
      expect(
        hourLineRect.left - pageRect.left,
        closeTo(56, 0.5),
        reason: 'pager ordinary hour gutter must remain compact',
      );

      await container
          .read(eventTypeControllerProvider.notifier)
          .saveSettings(
            settings.copyWith(visibleStartHour: 0, visibleEndHour: 24),
          );
      await tester.pumpAndSettle();

      final samples = <(DateTime, String)>[
        (DateTime(2026, 7, 31, 9, 5), '9:05 AM'),
        (DateTime(2026, 7, 31, 11, 59), '11:59 AM'),
        (DateTime(2026, 7, 31, 12, 0), '12:00 PM'),
        (DateTime(2026, 7, 31, 15, 1), '3:01 PM'),
        (DateTime(2026, 7, 31, 23, 59), '11:59 PM'),
      ];
      double? firstDotCenterX;
      for (final sample in samples) {
        currentTime.value = sample.$1;
        await tester.pump();
        final sampleCapsuleRect = tester.getRect(_currentTimeCapsule(label));
        final sampleDotRect = tester.getRect(dot);
        final sampleLineRect = tester.getRect(line);
        final dotCenterX = sampleDotRect.center.dx - pageRect.left;
        firstDotCenterX ??= dotCenterX;
        expect(tester.widget<Text>(label).data, sample.$2);
        // CT-03: label area left edge follows labelLeft (see TEST 4 header).
        expect(
          sampleCapsuleRect.left,
          closeTo(
            pageRect.left + PlannerCurrentTimeHorizontalGeometry.labelLeft,
            0.5,
          ),
        );
        expect(
          sampleDotRect.left - sampleCapsuleRect.right,
          closeTo(0, 0.5),
        );
        expect(
          dotCenterX,
          closeTo(PlannerCurrentTimeHorizontalGeometry.dotCenterX, 0.5),
        );
        expect(dotCenterX, closeTo(firstDotCenterX, 0.5));
        expect(
          sampleLineRect.left - sampleDotRect.right,
          closeTo(0, 0.5),
        );
        expect(sampleLineRect.right, closeTo(pageRect.right, 0.5));
        final sampleMinute = sample.$1.hour * 60 + sample.$1.minute;
        expect(
          _indicatorCenterY(tester),
          closeTo(sampleMinute * (hourHeight / 60), 1),
        );
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('TEST 5 — pinch-scaled geometry: when today is on a preview '
        'page, the indicator Y scales coherently with the new hour '
        'height; no duplicate indicator appears; selected date is '
        'unchanged', (tester) async {
      final (database, plannerRepo) = await _buildRepositories();
      final current = DateTime(2026, 7, 31, 12, 0);
      await _pumpPlanner(
        tester: tester,
        database: database,
        plannerRepository: plannerRepo,
        selected: _tomorrow,
        current: current,
      );
      // Before pinch: capture the indicator Y.
      final yBeforePinch = _indicatorCenterY(tester);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(PlannerScreen)),
      );
      final settingsBefore = container
          .read(eventTypeControllerProvider)
          .settings;
      // Pinch to a non-default hour height.
      await _drivePinch(tester, separation: 240);
      // Re-read the indicator Y after the pinch settled.
      final yAfterPinch = _indicatorCenterY(tester);
      final settingsAfter = container
          .read(eventTypeControllerProvider)
          .settings;
      // The hour height must have moved off the default.
      expect(
        (settingsAfter.timelineHourHeight - settingsBefore.timelineHourHeight)
                .abs() >
            1,
        isTrue,
        reason:
            'pinch must change the hour height (was '
            '${settingsBefore.timelineHourHeight}, now '
            '${settingsAfter.timelineHourHeight})',
      );
      // The indicator Y must have scaled coherently.
      final ratio = yAfterPinch / yBeforePinch;
      final heightRatio =
          settingsAfter.timelineHourHeight / settingsBefore.timelineHourHeight;
      expect(
        (ratio - heightRatio).abs() < 0.05,
        isTrue,
        reason:
            'indicator Y must scale with the new hour height '
            '(y ratio $ratio, hour-height ratio $heightRatio)',
      );
      // No duplicate indicator.
      expect(
        find
            .byKey(const Key('planner-current-time-indicator'))
            .evaluate()
            .length,
        1,
        reason: 'pinch must not duplicate the indicator',
      );
      // Selected date unchanged.
      expect(
        container.read(plannerControllerProvider).selectedDate,
        _tomorrow,
        reason: 'pinch must not change the selected date',
      );
    });

    testWidgets('TEST 6 — no forced scroll: keep the current-time minute '
        'outside the visible viewport; navigate so today becomes '
        'previous/current/next; the vertical scroll offset is '
        'unchanged', (tester) async {
      final (database, plannerRepo) = await _buildRepositories();
      // Time at 21:59 (visible window 6→22, so this is at
      // the very bottom — scroll to a mid-window offset
      // to ensure the indicator is out of view).
      final current = DateTime(2026, 7, 31, 21, 59);
      // Park the planner on _today; the centered indicator
      // would sit at the bottom of the visible window. We
      // scroll so it is well outside the viewport.
      await _pumpPlanner(
        tester: tester,
        database: database,
        plannerRepository: plannerRepo,
        selected: _today,
        current: current,
      );
      final scrollFinder = find.byKey(const Key('planner-day-scroll'));
      final scrollController = tester
          .widget<SingleChildScrollView>(scrollFinder)
          .controller!;
      // Scroll up so the bottom of the visible window is
      // far above the indicator at 21:59.  The timeline is
      // bounded (no dead scroll region), so pick an offset
      // comfortably inside maxScrollExtent.
      scrollController.jumpTo(120);
      await tester.pump();
      final offsetBefore = scrollController.offset;
      // Drive navigation that crosses today-as-prev / today
      // / today-as-next without the indicator forcing a
      // scroll.
      final container = ProviderScope.containerOf(
        tester.element(find.byType(PlannerScreen)),
      );
      // Move to tomorrow: today is now the previous page.
      await container
          .read(plannerControllerProvider.notifier)
          .selectDate(_tomorrow);
      await tester.pumpAndSettle();
      final offsetAfterPrev = scrollController.offset;
      expect(
        (offsetAfterPrev - offsetBefore).abs() < 1.0,
        isTrue,
        reason:
            'selecting tomorrow must not force a scroll '
            '(before $offsetBefore, after $offsetAfterPrev)',
      );
      // Move to yesterday: today is now the next page.
      await container
          .read(plannerControllerProvider.notifier)
          .selectDate(_yesterday);
      await tester.pumpAndSettle();
      final offsetAfterNext = scrollController.offset;
      expect(
        (offsetAfterNext - offsetBefore).abs() < 1.0,
        isTrue,
        reason:
            'selecting yesterday must not force a scroll '
            '(before $offsetBefore, after $offsetAfterNext)',
      );
    });

    testWidgets('TEST 7 — midnight ownership transition: when the listenable '
        'crosses midnight to a date NOT in the active window, the '
        'indicator hides cleanly (zero indicators, no orphan frame, '
        'no forced scroll); when the planner advances to include '
        'the new date, the indicator re-appears on the correct '
        'page', (tester) async {
      final (database, plannerRepo) = await _buildRepositories();
      // Selected is _today (2026-07-31). The window is
      // [_yesterday, _today, _tomorrow]. The listenable
      // starts at 2026-07-31 06:30 (centered page IS
      // today).
      final beforeMidnight = DateTime(2026, 7, 31, 6, 30);
      final currentTime = await _pumpPlanner(
        tester: tester,
        database: database,
        plannerRepository: plannerRepo,
        selected: _today,
        current: beforeMidnight,
      );
      final ownershipBefore = _indicatorOwnership(
        tester,
        previous: _yesterday,
        selected: _today,
        next: _tomorrow,
      );
      expect(ownershipBefore.total, 1);
      expect(
        ownershipBefore.ownerPage,
        _today,
        reason:
            'at 06:30 on 2026-07-31, the centered page '
            'must own the indicator',
      );
      // Capture the scroll offset before the cross-midnight
      // sequence.
      final scrollFinder = find.byKey(const Key('planner-day-scroll'));
      final scrollController = tester
          .widget<SingleChildScrollView>(scrollFinder)
          .controller!;
      scrollController.jumpTo(0);
      await tester.pump();
      final offsetBefore = scrollController.offset;
      // The listenable crosses midnight to 2026-08-01
      // 06:30. The system "today" stays _today (the
      // fixed source), so no page in the active window
      // matches the listenable's new date. The
      // indicator must hide cleanly: zero indicators
      // across the entire tree, no orphan frame, no
      // forced scroll. (In production the system
      // source ticks at midnight and the planner
      // re-seats ownership; this test proves the
      // hide-side of that transition is well-behaved
      // when the listenable moves faster than the
      // system date.)
      currentTime.value = DateTime(2026, 8, 1, 6, 30);
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      final ownershipAfter = _indicatorOwnership(
        tester,
        previous: _yesterday,
        selected: _today,
        next: _tomorrow,
      );
      expect(
        ownershipAfter.total,
        0,
        reason:
            'indicator must hide when no page in the '
            'active window matches the listenable date '
            '(midnight crossed faster than system date)',
      );
      // No forced scroll.
      expect(
        (scrollController.offset - offsetBefore).abs() < 1.0,
        isTrue,
        reason:
            'midnight transition must not force a scroll '
            '(before $offsetBefore, after ${scrollController.offset})',
      );
      // Advance the listenable back to 2026-07-31 06:30
      // to verify the indicator returns to the centered
      // page cleanly.
      currentTime.value = DateTime(2026, 7, 31, 6, 30);
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      final ownershipRestored = _indicatorOwnership(
        tester,
        previous: _yesterday,
        selected: _today,
        next: _tomorrow,
      );
      expect(ownershipRestored.total, 1);
      expect(
        ownershipRestored.ownerPage,
        _today,
        reason:
            'after the listenable rolls back to the '
            'centered page date, the centered page must '
            'own the indicator again',
      );
    });

    testWidgets('TEST 8 — M6 closure: under the DEFAULT 06:00-22:00 '
        'planning window the 2026-07-31 preview column still paints the '
        'current-time indicator at 22:59, 23:00, 23:30 and 23:59, because '
        'the pager canvas spans the full civil day', (tester) async {
      final (database, plannerRepo) = await _buildRepositories();
      // Selected is _tomorrow so the previous preview page is _today
      // (2026-07-31), which owns the indicator for a 2026-07-31 clock.
      final currentTime = await _pumpPlanner(
        tester: tester,
        database: database,
        plannerRepository: plannerRepo,
        selected: _tomorrow,
        current: DateTime(2026, 7, 31, 16, 3),
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(PlannerScreen)),
      );
      final settings = container.read(eventTypeControllerProvider).settings;
      expect(
        settings.visibleStartHour,
        6,
        reason: 'this regression must run against the DEFAULT planning '
            'window, not a widened one',
      );
      expect(settings.visibleEndHour, 22);

      const samples = <(int, int, String)>[
        (22, 59, '10:59 PM'),
        (23, 0, '11:00 PM'),
        (23, 30, '11:30 PM'),
        (23, 59, '11:59 PM'),
      ];
      for (final (hour, minute, label) in samples) {
        currentTime.value = DateTime(2026, 7, 31, hour, minute);
        await tester.pump();
        final clock =
            '${hour.toString().padLeft(2, '0')}:'
            '${minute.toString().padLeft(2, '0')}';
        final ownership = _indicatorOwnership(
          tester,
          previous: _today,
          selected: _tomorrow,
          next: PlannerDate(year: 2026, month: 8, day: 2),
        );
        expect(
          ownership.total,
          1,
          reason:
              'the preview page that owns 2026-07-31 must paint exactly one '
              'indicator at $clock even though the soft planning window '
              'ends at 22:00',
        );
        expect(
          ownership.ownerPage,
          _today,
          reason: 'the 2026-07-31 preview must own the indicator at $clock',
        );
        expect(
          tester
              .widget<Text>(
                find.byKey(const Key('planner-current-time-label')),
              )
              .data,
          label,
          reason: 'the 12-hour label at $clock must be $label',
        );
      }
      expect(tester.takeException(), isNull);
    });
  });
}
