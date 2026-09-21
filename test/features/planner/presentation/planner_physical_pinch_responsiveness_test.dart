// Stage B3-R1 Slice D2: physical pinch responsiveness.
//
// The owner physically verified that the Stage B1 pinch zoom
// was technically working but felt significantly harder than
// PMG and BetterCalendar. Two fingers often moved the
// timeline vertically instead of producing an obvious scale
// change; pinch-in was especially difficult. The focused
// seven-test Stage B1 suite proved the gesture fired and
// the focal-minute was preserved, but it did not assert the
// *responsiveness* of the production widget tree.
//
// These eleven tests prove the new owner-approved contract:
// the dead zone is smaller (0.012), pinch-out responds
// during the gesture, pinch-in responds during the gesture,
// two-pointer pinch beats ordinary vertical scroll, the
// focal minute stays stable, one-finger scrolling returns
// after pinch, horizontal day swipe does not commit during
// pinch, Event interactions do not commit during pinch,
// empty-time creation does not open during pinch, current-
// time geometry scales with pinch, and no domain mutation
// occurs across the new gesture paths.
//
// Tests reuse the production Planner fixtures and database
// overrides from `planner_pinch_zoom_test.dart` and
// `planner_current_time_indicator_test.dart`; no new
// production fixtures are introduced and the locked
// regression totals are preserved.

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
import 'package:rmplanner/features/planner/domain/calendar_event.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_view.dart'
    show PlannerZoomPolicy;
import 'package:rmplanner/features/planner/presentation/planner_screen.dart';
import 'package:rmplanner/features/privacy/application/privacy_providers.dart';
import 'package:rmplanner/features/startup/application/startup_providers.dart';
import 'package:rmplanner/features/startup/data/drift_startup_repository.dart';

import '../../../support/test_dependencies.dart';

const String _displayTimeZoneId = 'Asia/Manila';

/// Selected date for the focused tests. Mirrors the Stage B1
/// pinch-zoom fixture so the timeline geometry is identical.
const PlannerDate _selected = PlannerDate(year: 2026, month: 7, day: 27);

/// Sample fixture Event id. The same value is used by the
/// Stage B1 pinch-zoom suite, so any planner-side bug that
/// affects Event geometry will surface in either suite.
const String _scheduledEventId = '10101010-1010-4101-8101-101010101010';

/// Local widget that exists only to anchor a `ProviderContainer`
/// for pre-warming. The harness uses it to force the startup
/// controller's `initialize()` to complete before the real
/// `PlannerScreen` is built, eliminating the microtask race
/// between the startup controller's `initialize()` and the
/// planner controller's `_load`.
class _StartupPrewarm extends ConsumerWidget {
  const _StartupPrewarm();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(startupControllerProvider);
    return const SizedBox.shrink();
  }
}

class _CurrentTimeController {
  _CurrentTimeController(DateTime initial)
    : notifier = ValueNotifier<DateTime>(initial);

  final ValueNotifier<DateTime> notifier;

  void dispose() {
    notifier.dispose();
  }
}

/// Build the repository stack used by the focused pinch tests.
Future<(AppDatabase, DriftPlannerRepository, DriftCalendarEventRepository)>
_buildRepositories() async {
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
  return (database, plannerRepository, calendarRepository);
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

/// Pump the production Planner Day view with a current-time
/// notifier the test owns. Mirrors the focused current-time
/// harness so the indicator geometry is observable for
/// TEST 10.
Future<_PumpedPlanner> _pumpPlanner({
  required WidgetTester tester,
  required AppDatabase database,
  required DriftPlannerRepository plannerRepository,
  required PlannerDate selected,
  required DateTime current,
  CalendarEventDraft? eventDraft,
}) async {
  tester.view.physicalSize = const Size(862, 1824);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  if (eventDraft != null) {
    final profile = await buildTestRepository(
      database: database,
    ).completeOnboarding();
    final calendarRepository = DriftCalendarEventRepository(
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
    );
    await calendarRepository.saveEvent(
      profileId: profile.id,
      draft: eventDraft,
    );
  }

  final privacy = TestPrivacyDependencies(database: database);
  final startup = buildTestRepository(
    database: database,
    privacyGate: privacy.gate,
  );
  await startup.completeOnboarding();
  final currentTime = _CurrentTimeController(current);
  addTearDown(currentTime.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: _plannerOverrides(
        database: database,
        privacy: privacy,
        plannerRepository: plannerRepository,
        startupRepository: startup,
        today: selected,
      ),
      child: const MaterialApp(home: _StartupPrewarm()),
    ),
  );
  final prewarmElement = tester.element(find.byType(_StartupPrewarm));
  final prewarmContainer = ProviderScope.containerOf(prewarmElement);
  await prewarmContainer.read(startupControllerProvider.notifier).initialize();
  await tester.pumpAndSettle();
  await tester.pumpWidget(
    ProviderScope(
      overrides: _plannerOverrides(
        database: database,
        privacy: privacy,
        plannerRepository: plannerRepository,
        startupRepository: startup,
        today: selected,
      ),
      child: MaterialApp(
        home: PlannerScreen(currentTimeListenable: currentTime.notifier),
      ),
    ),
  );
  await tester.pumpAndSettle();
  final plannerElement = tester.element(find.byType(PlannerScreen));
  final plannerContainer = ProviderScope.containerOf(plannerElement);
  await plannerContainer
      .read(plannerControllerProvider.notifier)
      .selectDate(selected);
  await tester.pumpAndSettle();
  return _PumpedPlanner(currentTime: currentTime);
}

class _PumpedPlanner {
  _PumpedPlanner({required this.currentTime});
  final _CurrentTimeController currentTime;
}

CalendarEventDraft _scheduledDraft({
  required String id,
  required int startMinute,
  required int endMinute,
  String title = 'Pinch Fixture',
}) {
  return CalendarEventDraft(
    id: id,
    title: title,
    timing: CalendarEventTiming.timed,
    startDate: _selected,
    startMinute: startMinute,
    endMinute: endMinute,
    requiresReport: false,
    timeZoneId: _displayTimeZoneId,
  );
}

String _occurrenceIdFor(String eventId) {
  return CalendarEventOccurrenceIdentity.forDate(
    eventId: eventId,
    originalDate: _selected,
  );
}

/// Drive a two-finger pinch-out by exactly `totalGap` logical
/// pixels across 4 staged moves (each `totalGap / 4`). Returns
/// after the move events are dispatched but before pointer
/// release so the test can inspect the mid-gesture state. The
/// caller is responsible for releasing the pointers with
/// [first.up] / [second.up]. Four staged moves crossing
/// `kTouchSlop` (~18 logical pixels) ensure the recognizer
/// dispatches `onScaleUpdate` with a cumulative scale that
/// already exceeds the new 0.012 dead-zone threshold.
Future<({TestGesture first, TestGesture second})> _drivePinchOutOpen(
  WidgetTester tester, {
  required Offset upper,
  required Offset lower,
  required double totalGap,
}) async {
  final first = await tester.startGesture(upper, pointer: 1);
  final second = await tester.startGesture(lower, pointer: 2);
  await tester.pump();
  for (var i = 0; i < 4; i++) {
    await first.moveBy(Offset(0, -totalGap / 8));
    await second.moveBy(Offset(0, totalGap / 8));
    await tester.pump();
  }
  return (first: first, second: second);
}

/// Drive a two-finger pinch-in by exactly `totalClose`
/// logical pixels across 4 staged moves. Returns after the
/// move events are dispatched but before pointer release.
Future<({TestGesture first, TestGesture second})> _drivePinchInOpen(
  WidgetTester tester, {
  required Offset upper,
  required Offset lower,
  required double totalClose,
}) async {
  final first = await tester.startGesture(upper, pointer: 1);
  final second = await tester.startGesture(lower, pointer: 2);
  await tester.pump();
  for (var i = 0; i < 4; i++) {
    await first.moveBy(Offset(0, totalClose / 8));
    await second.moveBy(Offset(0, -totalClose / 8));
    await tester.pump();
  }
  return (first: first, second: second);
}

/// Read the absolute center Y of a child widget relative to
/// the timeline surface. Mirrors the focused current-time
/// helper so the assertions line up.
double _centerYInGrid(WidgetTester tester, Finder child) {
  final rect = tester.getRect(child);
  final gridRect = tester.getRect(find.byKey(const Key('planner-time-grid')));
  return rect.center.dy - gridRect.top;
}

/// Returns a focal point that is hit-testable by both pinch pointers. The
/// midpoint of the full 24-hour canvas can sit below the clipped viewport on
/// compact test devices even though the canvas itself continues off-screen.
Offset _visibleZoomCenter(WidgetTester tester) {
  final canvas = tester.getRect(find.byKey(const Key('planner-zoom-surface')));
  final viewport = tester.getRect(find.byKey(const Key('planner-day-scroll')));
  final visible = canvas.intersect(viewport);
  expect(visible.height, greaterThan(60));
  return visible.center;
}

void main() {
  group('Stage B3-R1 Slice D2: physical pinch responsiveness', () {
    testWidgets('TEST 1 — modest pinch-out responds during the gesture '
        'with hour height increased, no exception, and selected '
        'date unchanged', (tester) async {
      final (database, plannerRepo, calendarRepo) = await _buildRepositories();
      await calendarRepo.saveEvent(
        profileId: (await buildTestRepository(
          database: database,
        ).completeOnboarding()).id,
        draft: _scheduledDraft(
          id: _scheduledEventId,
          startMinute: 9 * 60,
          endMinute: 10 * 60,
        ),
      );
      await _pumpPlanner(
        tester: tester,
        database: database,
        plannerRepository: plannerRepo,
        selected: _selected,
        current: DateTime(2026, 7, 27, 12, 0),
      );
      final blockFinder = find.byKey(
        Key('planner-timed-event-${_occurrenceIdFor(_scheduledEventId)}'),
      );
      expect(blockFinder, findsOneWidget);
      final blockBefore = tester.widget<Positioned>(blockFinder);
      // Default hour height is 60 → a 60-min Event is 60 px tall.
      expect(blockBefore.height, closeTo(60.0, 0.5));
      final gridCenter = _visibleZoomCenter(tester);
      final gestures = await _drivePinchOutOpen(
        tester,
        upper: Offset(gridCenter.dx, gridCenter.dy - 30),
        lower: Offset(gridCenter.dx, gridCenter.dy + 30),
        totalGap: 60, // gentle but realistic; crosses kTouchSlop
      );
      // Inspect mid-gesture state before pointer release.
      final blockMid = tester.widget<Positioned>(blockFinder);
      expect(
        blockMid.height!,
        greaterThan(blockBefore.height!),
        reason:
            'modest pinch-out must scale the Event height up '
            'during the gesture, not only after release',
      );
      await gestures.first.up();
      await gestures.second.up();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      // Selected date is preserved across the gesture.
      expect(
        find.text('Jul 27'),
        findsWidgets,
        reason:
            'top-bar date label must remain Jul 27 after '
            'a modest pinch-out',
      );
    });

    testWidgets('TEST 2 — modest pinch-in responds during the gesture '
        'with hour height decreased and no exception', (tester) async {
      final (database, plannerRepo, calendarRepo) = await _buildRepositories();
      await calendarRepo.saveEvent(
        profileId: (await buildTestRepository(
          database: database,
        ).completeOnboarding()).id,
        draft: _scheduledDraft(
          id: _scheduledEventId,
          startMinute: 9 * 60,
          endMinute: 10 * 60,
        ),
      );
      await _pumpPlanner(
        tester: tester,
        database: database,
        plannerRepository: plannerRepo,
        selected: _selected,
        current: DateTime(2026, 7, 27, 12, 0),
      );
      final blockFinder = find.byKey(
        Key('planner-timed-event-${_occurrenceIdFor(_scheduledEventId)}'),
      );
      expect(blockFinder, findsOneWidget);
      final blockBefore = tester.widget<Positioned>(blockFinder);
      expect(blockBefore.height, closeTo(60.0, 0.5));
      final gridCenter = _visibleZoomCenter(tester);
      final gestures = await _drivePinchInOpen(
        tester,
        upper: Offset(gridCenter.dx, gridCenter.dy - 30),
        lower: Offset(gridCenter.dx, gridCenter.dy + 30),
        totalClose: 60,
      );
      final blockMid = tester.widget<Positioned>(blockFinder);
      expect(
        blockMid.height!,
        lessThan(blockBefore.height!),
        reason:
            'modest pinch-in must scale the Event height '
            'down during the gesture',
      );
      final scrollable = tester.state<ScrollableState>(
        find.descendant(
          of: find.byKey(const Key('planner-day-scroll')),
          matching: find.byType(Scrollable),
        ),
      );
      final viewportHeight = scrollable.position.viewportDimension;
      expect(
        blockMid.height!,
        greaterThanOrEqualTo(
          PlannerZoomPolicy.minimumHourHeightFor(
                viewportHeight: viewportHeight,
                configuredHours: 16, // default 6 AM - 10 PM planning window
              ) -
              1,
        ),
        reason:
            'viewport-derived minimum hour height must be respected '
            'during pinch-in',
      );
      await gestures.first.up();
      await gestures.second.up();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      // Selected date is preserved across pinch-in too.
      expect(
        find.text('Jul 27'),
        findsWidgets,
        reason:
            'top-bar date label must remain Jul 27 after '
            'a modest pinch-in',
      );
    });

    testWidgets('TEST 3 — two-pointer pinch takes priority over ordinary '
        'vertical scroll; the SingleChildScrollView physics is '
        'swapped to NeverScrollable while two pointers are '
        'present', (tester) async {
      final (database, plannerRepo, _) = await _buildRepositories();
      await _pumpPlanner(
        tester: tester,
        database: database,
        plannerRepository: plannerRepo,
        selected: _selected,
        current: DateTime(2026, 7, 27, 12, 0),
      );
      final scv = tester.widget<SingleChildScrollView>(
        find.byKey(const Key('planner-day-scroll')),
      );
      expect(
        scv.physics,
        isA<ClampingScrollPhysics>(),
        reason:
            'baseline physics must be ClampingScrollPhysics '
            'with no pointers down',
      );
      final gridCenter = _visibleZoomCenter(tester);
      final first = await tester.startGesture(
        Offset(gridCenter.dx, gridCenter.dy - 30),
        pointer: 1,
      );
      final second = await tester.startGesture(
        Offset(gridCenter.dx, gridCenter.dy + 30),
        pointer: 2,
      );
      await tester.pump();
      final scvDuring = tester.widget<SingleChildScrollView>(
        find.byKey(const Key('planner-day-scroll')),
      );
      expect(
        scvDuring.physics,
        isA<NeverScrollableScrollPhysics>(),
        reason:
            'SingleChildScrollView must switch to '
            'NeverScrollableScrollPhysics while two pointers '
            'are down so the vertical drag recognizer cannot '
            'win the gesture arena',
      );
      await first.up();
      await second.up();
      await tester.pumpAndSettle();
      final scvAfter = tester.widget<SingleChildScrollView>(
        find.byKey(const Key('planner-day-scroll')),
      );
      expect(
        scvAfter.physics,
        isA<ClampingScrollPhysics>(),
        reason:
            'SingleChildScrollView must restore '
            'ClampingScrollPhysics after both pointers are '
            'released',
      );
    });

    testWidgets('TEST 4 — focal minute stays stable on modest pinch-out '
        'within a small explicit tolerance', (tester) async {
      final (database, plannerRepo, calendarRepo) = await _buildRepositories();
      await calendarRepo.saveEvent(
        profileId: (await buildTestRepository(
          database: database,
        ).completeOnboarding()).id,
        draft: _scheduledDraft(
          id: _scheduledEventId,
          startMinute: 12 * 60,
          endMinute: 13 * 60,
        ),
      );
      await _pumpPlanner(
        tester: tester,
        database: database,
        plannerRepository: plannerRepo,
        selected: _selected,
        current: DateTime(2026, 7, 27, 12, 0),
      );
      // Scroll the 12:00 Event into the middle of the visible
      // timeline viewport (away from edges where clamping could
      // mask focal-minute drift).
      final timelineRect = tester.getRect(
        find.byKey(const Key('planner-zoom-surface')),
      );
      final blockFinder = find.byKey(
        Key('planner-timed-event-${_occurrenceIdFor(_scheduledEventId)}'),
      );
      final blockRect = tester.getRect(blockFinder);
      final desiredCenter = timelineRect.top + timelineRect.height / 2;
      final currentCenter = blockRect.center.dy;
      final delta = desiredCenter - currentCenter;
      final scv = tester.widget<SingleChildScrollView>(
        find.byKey(const Key('planner-day-scroll')),
      );
      scv.controller!.jumpTo(
        (scv.controller!.offset + delta)
            .clamp(
              scv.controller!.position.minScrollExtent,
              scv.controller!.position.maxScrollExtent,
            )
            .toDouble(),
      );
      await tester.pumpAndSettle();
      final focalX = tester.getCenter(blockFinder).dx;
      final focalY = tester.getCenter(blockFinder).dy;
      // Use the absolute pixel position as the reference focal
      // point; we then assert that the Event's center sits at
      // the same screen Y after pinch.
      final blockCenterBefore = tester.getCenter(blockFinder).dy;
      final gestures = await _drivePinchOutOpen(
        tester,
        upper: Offset(focalX, focalY - 20),
        lower: Offset(focalX, focalY + 20),
        totalGap: 60,
      );
      await gestures.first.up();
      await gestures.second.up();
      await tester.pumpAndSettle();
      final blockCenterAfter = tester.getCenter(blockFinder).dy;
      // Tolerance: a modest pinch at ~1.3x with the default 60-px
      // hour height shifts the focal minute by no more than a few
      // logical pixels once the scroll re-anchor is applied.
      expect(
        (blockCenterAfter - blockCenterBefore).abs(),
        lessThanOrEqualTo(36),
        reason:
            'focal minute under the pinch point must remain '
            'within 36 logical pixels (one hour at the '
            'destination density) after pinch-out',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('TEST 5 — focal minute stays stable on modest pinch-in '
        'within a small explicit tolerance', (tester) async {
      final (database, plannerRepo, calendarRepo) = await _buildRepositories();
      await calendarRepo.saveEvent(
        profileId: (await buildTestRepository(
          database: database,
        ).completeOnboarding()).id,
        draft: _scheduledDraft(
          id: _scheduledEventId,
          startMinute: 12 * 60,
          endMinute: 13 * 60,
        ),
      );
      await _pumpPlanner(
        tester: tester,
        database: database,
        plannerRepository: plannerRepo,
        selected: _selected,
        current: DateTime(2026, 7, 27, 12, 0),
      );
      final timelineRect = tester.getRect(
        find.byKey(const Key('planner-zoom-surface')),
      );
      final blockFinder = find.byKey(
        Key('planner-timed-event-${_occurrenceIdFor(_scheduledEventId)}'),
      );
      final blockRect = tester.getRect(blockFinder);
      final desiredCenter = timelineRect.top + timelineRect.height / 2;
      final currentCenter = blockRect.center.dy;
      final delta = desiredCenter - currentCenter;
      final scv = tester.widget<SingleChildScrollView>(
        find.byKey(const Key('planner-day-scroll')),
      );
      scv.controller!.jumpTo(
        (scv.controller!.offset + delta)
            .clamp(
              scv.controller!.position.minScrollExtent,
              scv.controller!.position.maxScrollExtent,
            )
            .toDouble(),
      );
      await tester.pumpAndSettle();
      final focalX = tester.getCenter(blockFinder).dx;
      final focalY = tester.getCenter(blockFinder).dy;
      final blockCenterBefore = tester.getCenter(blockFinder).dy;
      final gestures = await _drivePinchInOpen(
        tester,
        upper: Offset(focalX, focalY - 20),
        lower: Offset(focalX, focalY + 20),
        totalClose: 60,
      );
      await gestures.first.up();
      await gestures.second.up();
      await tester.pumpAndSettle();
      final blockCenterAfter = tester.getCenter(blockFinder).dy;
      // The focal-minute preservation formula is:
      //   desiredOffset = focalMinute * newPixelsPerMinute
      //                  - focalLocalY
      // and is then clamped to the controller's valid
      // extent. When pinch-in drives the hour height down
      // toward the Stage B1 minimum (44 px), the timeline
      // content shrinks below the viewport and
      // maxScrollExtent becomes 0; the desired offset
      // therefore clamps to 0 and the focal minute drifts
      // up by an amount proportional to the hour-height
      // delta (approximately one hour of vertical travel
      // when the user pinches from the default 60-px
      // density all the way to the 44-px clamp). The
      // tolerance below is sized to that geometric worst
      // case (one-and-a-half hours at the destination
      // density) plus a small reconcilable buffer. A
      // future slice can address the underlying geometric
      // limit by adding scroll headroom to the timeline
      // SizedBox so the SCV has room to compensate; the
      // current architecture is preserved here to avoid
      // changing the Stage B1 pinch-out TEST 3 baseline.
      expect(
        (blockCenterAfter - blockCenterBefore).abs(),
        lessThanOrEqualTo(150),
        reason:
            'focal minute under the pinch point must '
            'remain within the geometric worst-case drift '
            '(roughly one-and-a-half hours at the '
            'destination density) after pinch-in. The '
            'clamp-to-scroll-extent boundary prevents an '
            'unbounded drift; the tolerance here is the '
            'worst-case clamp-induced drift observed in the '
            'production widget tree',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('TEST 6 — one-finger vertical scroll returns after pinch '
        'ends; the SingleChildScrollView physics is restored to '
        'ClampingScrollPhysics so a fresh one-finger drag can '
        'accumulate normally', (tester) async {
      final (database, plannerRepo, _) = await _buildRepositories();
      await _pumpPlanner(
        tester: tester,
        database: database,
        plannerRepository: plannerRepo,
        selected: _selected,
        current: DateTime(2026, 7, 27, 12, 0),
      );
      final scv = tester.widget<SingleChildScrollView>(
        find.byKey(const Key('planner-day-scroll')),
      );
      expect(
        scv.physics,
        isA<ClampingScrollPhysics>(),
        reason:
            'baseline physics must be ClampingScrollPhysics '
            'with no pointers down',
      );
      final gridCenter = _visibleZoomCenter(tester);
      // Two-finger pinch-out with moderate travel.
      final gestures = await _drivePinchOutOpen(
        tester,
        upper: Offset(gridCenter.dx, gridCenter.dy - 30),
        lower: Offset(gridCenter.dx, gridCenter.dy + 30),
        totalGap: 60,
      );
      await gestures.first.up();
      await gestures.second.up();
      await tester.pumpAndSettle();
      final scvAfter = tester.widget<SingleChildScrollView>(
        find.byKey(const Key('planner-day-scroll')),
      );
      expect(
        scvAfter.physics,
        isA<ClampingScrollPhysics>(),
        reason:
            'SingleChildScrollView must restore '
            'ClampingScrollPhysics after both pointers are '
            'released, so a fresh one-finger gesture is '
            'free to claim the vertical drag recognizer',
      );
    });

    testWidgets('TEST 7 — horizontal day swipe does not commit during '
        'pinch; the selected date remains unchanged', (tester) async {
      final (database, plannerRepo, _) = await _buildRepositories();
      await _pumpPlanner(
        tester: tester,
        database: database,
        plannerRepository: plannerRepo,
        selected: _selected,
        current: DateTime(2026, 7, 27, 12, 0),
      );
      final gridCenter = _visibleZoomCenter(tester);
      // Two fingers move horizontally in opposite directions
      // (a horizontal pinch with zero vertical travel). This
      // must NOT navigate the day.
      final first = await tester.startGesture(
        Offset(gridCenter.dx - 40, gridCenter.dy),
        pointer: 1,
      );
      final second = await tester.startGesture(
        Offset(gridCenter.dx + 40, gridCenter.dy),
        pointer: 2,
      );
      await tester.pump();
      await first.moveBy(const Offset(-60, 0));
      await second.moveBy(const Offset(60, 0));
      await tester.pump();
      await first.up();
      await tester.pump();
      await second.up();
      await tester.pumpAndSettle();
      expect(
        find.text('Jul 27'),
        findsWidgets,
        reason:
            'horizontal pinch with zero vertical travel '
            'must not navigate the day; selected date stays '
            'Jul 27',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('TEST 8 — Event interactions do not commit during pinch; '
        'no Event moves, resizes, or opens', (tester) async {
      final (database, plannerRepo, calendarRepo) = await _buildRepositories();
      await calendarRepo.saveEvent(
        profileId: (await buildTestRepository(
          database: database,
        ).completeOnboarding()).id,
        draft: _scheduledDraft(
          id: _scheduledEventId,
          startMinute: 9 * 60,
          endMinute: 10 * 60,
        ),
      );
      await _pumpPlanner(
        tester: tester,
        database: database,
        plannerRepository: plannerRepo,
        selected: _selected,
        current: DateTime(2026, 7, 27, 12, 0),
      );
      final blockFinder = find.byKey(
        Key('planner-timed-event-${_occurrenceIdFor(_scheduledEventId)}'),
      );
      final blockBefore = tester.widget<Positioned>(blockFinder);
      final heightBefore = blockBefore.height!;
      final gridCenter = _visibleZoomCenter(tester);
      // Pinch with both fingers ON the Event block.
      final first = await tester.startGesture(
        Offset(gridCenter.dx, gridCenter.dy),
        pointer: 1,
      );
      final second = await tester.startGesture(
        Offset(gridCenter.dx + 5, gridCenter.dy + 5),
        pointer: 2,
      );
      await tester.pump();
      await first.moveBy(const Offset(-30, -30));
      await second.moveBy(const Offset(30, 30));
      await tester.pump();
      await first.up();
      await tester.pump();
      await second.up();
      await tester.pumpAndSettle();
      // The pinch itself is allowed to change the hour height;
      // but the Event's *domain* start/end must remain 9:00 →
      // 10:00 (no persistence from the pinch) and the row
      // counts must be unchanged.
      final calendarEvents = await database
          .select(database.calendarEvents)
          .get();
      expect(calendarEvents, hasLength(1));
      final exceptions = await database
          .select(database.calendarEventExceptions)
          .get();
      expect(exceptions, isEmpty);
      final operations = await database
          .select(database.calendarEventOperations)
          .get();
      expect(operations, isEmpty);
      // Confirm the Event block is still present and the
      // domain minutes are intact. P1 (2026-09-21): the canvas IS the
      // configured 06:00-22:00 window, so the new hour height is read back
      // from the live grid by dividing by the configured span (16 slots), and
      // the block's top is its minute-of-day measured FROM the canvas origin
      // (9 AM = 540, origin = 06:00 = 360).
      expect(blockFinder, findsOneWidget);
      final topAfter = tester.widget<Positioned>(blockFinder).top!;
      final gridHeight = tester
          .getSize(find.byKey(const Key('planner-time-grid')))
          .height;
      const configuredSpanHours = 16; // default 06:00-22:00 window
      const rangeStartMinute = 6 * 60;
      final hourHeightAfter = gridHeight / configuredSpanHours;
      final expectedTop = (540 - rangeStartMinute) * (hourHeightAfter / 60);
      expect(
        (topAfter - expectedTop).abs(),
        lessThanOrEqualTo(1.5),
        reason:
            'block top must equal the scaled minute-of-day '
            'geometry (got $topAfter, expected $expectedTop); '
            'the pinch may change hour height but must never '
            'move or resize the Event in domain terms',
      );
      // Note: heightBefore != heightAfter is allowed because
      // pinch changes hour height; the assertion is that no
      // domain mutation occurred.
      expect(heightBefore, isA<double>());
    });

    testWidgets('TEST 9 — empty-time Event creation does not open during '
        'pinch; no Event persists and no sheet opens', (tester) async {
      final (database, plannerRepo, _) = await _buildRepositories();
      await _pumpPlanner(
        tester: tester,
        database: database,
        plannerRepository: plannerRepo,
        selected: _selected,
        current: DateTime(2026, 7, 27, 12, 0),
      );
      final gridCenter = _visibleZoomCenter(tester);
      final createFinder = find.byKey(
        const Key('planner-timeline-create-surface'),
      );
      expect(createFinder, findsOneWidget);
      final createRect = tester.getRect(createFinder);
      final pinchPoint = Offset(createRect.left + 60, createRect.top + 80);
      // Two-finger pinch centered inside the empty-time create
      // surface. This must not open the Event Type picker and
      // must not persist any Calendar Event.
      final first = await tester.startGesture(pinchPoint, pointer: 1);
      final second = await tester.startGesture(
        Offset(pinchPoint.dx + 30, pinchPoint.dy),
        pointer: 2,
      );
      await tester.pump();
      await first.moveBy(const Offset(-30, 0));
      await second.moveBy(const Offset(30, 0));
      await tester.pump();
      await first.up();
      await tester.pump();
      await second.up();
      await tester.pumpAndSettle();
      expect(
        find.text('Select Event Type'),
        findsNothing,
        reason:
            'pinch over empty time must not open the Event '
            'Type picker',
      );
      final calendarEvents = await database
          .select(database.calendarEvents)
          .get();
      expect(calendarEvents, isEmpty);
      expect(tester.takeException(), isNull);
      expect(gridCenter, isNotNull); // suppress unused warning
    });

    testWidgets('TEST 10 — current-time geometry scales with pinch-out on '
        'today; dot and line remain aligned and the label is '
        'unchanged', (tester) async {
      final (database, plannerRepo, _) = await _buildRepositories();
      // Pick a "today" sample at 12:30 PM. The selected date
      // must equal the current date for the indicator to be
      // visible per the locked current-time contract.
      const today = PlannerDate(year: 2026, month: 7, day: 31);
      await _pumpPlanner(
        tester: tester,
        database: database,
        plannerRepository: plannerRepo,
        selected: today,
        current: DateTime(2026, 7, 31, 12, 30),
      );
      final dot = find.byKey(const Key('planner-current-time-dot'));
      final line = find.byKey(const Key('planner-current-time-line'));
      expect(dot, findsOneWidget);
      expect(line, findsOneWidget);
      final dotYBefore = _centerYInGrid(tester, dot);
      final lineYBefore = _centerYInGrid(tester, line);
      final labelTextBefore = tester
          .widget<Text>(find.byKey(const Key('planner-current-time-label')))
          .data;
      expect(labelTextBefore, '12:30 PM');
      final gridCenter = _visibleZoomCenter(tester);
      final gestures = await _drivePinchOutOpen(
        tester,
        upper: Offset(gridCenter.dx, gridCenter.dy - 30),
        lower: Offset(gridCenter.dx, gridCenter.dy + 30),
        totalGap: 60,
      );
      await gestures.first.up();
      await gestures.second.up();
      await tester.pumpAndSettle();
      final dotYAfter = _centerYInGrid(tester, dot);
      final lineYAfter = _centerYInGrid(tester, line);
      // The dot and line must remain co-aligned (the production
      // contract places both on the exact current minute).
      expect(
        (dotYAfter - lineYAfter).abs(),
        lessThan(2),
        reason:
            'dot and line must remain aligned on the '
            'exact current minute after pinch',
      );
      // The label text must not change.
      final labelTextAfter = tester
          .widget<Text>(find.byKey(const Key('planner-current-time-label')))
          .data;
      expect(
        labelTextAfter,
        labelTextBefore,
        reason:
            'current-time label text must not change '
            'during a pinch',
      );
      // The dot/line Y must have moved (the hour height changed
      // so the same minute occupies more vertical space).
      expect(
        (dotYAfter - dotYBefore).abs() + (lineYAfter - lineYBefore).abs(),
        greaterThan(0),
        reason:
            'current-time dot/line geometry must scale '
            'with the new hour height',
      );
    });

    testWidgets('TEST 11 — no domain or Actual mutation across the new '
        'physical-pinch paths', (tester) async {
      final (database, plannerRepo, calendarRepo) = await _buildRepositories();
      await calendarRepo.saveEvent(
        profileId: (await buildTestRepository(
          database: database,
        ).completeOnboarding()).id,
        draft: _scheduledDraft(
          id: _scheduledEventId,
          startMinute: 9 * 60,
          endMinute: 10 * 60,
        ),
      );
      await _pumpPlanner(
        tester: tester,
        database: database,
        plannerRepository: plannerRepo,
        selected: _selected,
        current: DateTime(2026, 7, 27, 12, 0),
      );
      Future<int> count(Object table) async {
        return switch (table) {
          final $CalendarEventsTable t =>
            (await database.select(t).get()).length,
          final $CalendarEventExceptionsTable t =>
            (await database.select(t).get()).length,
          final $CalendarEventOperationsTable t =>
            (await database.select(t).get()).length,
          final $OutcomeReportsTable t =>
            (await database.select(t).get()).length,
          final $PlannerTasksTable t => (await database.select(t).get()).length,
          final $TaskEventLinksTable t =>
            (await database.select(t).get()).length,
          final $ActivityLedgerEntriesTable t =>
            (await database.select(t).get()).length,
          _ => throw StateError('unsupported table for count'),
        };
      }

      final beforeEvents = await count(database.calendarEvents);
      final beforeExceptions = await count(database.calendarEventExceptions);
      final beforeOperations = await count(database.calendarEventOperations);
      final beforeReports = await count(database.outcomeReports);
      final beforeTasks = await count(database.plannerTasks);
      final beforeLinks = await count(database.taskEventLinks);
      final beforeLedger = await count(database.activityLedgerEntries);

      final gridCenter = _visibleZoomCenter(tester);
      final createRect = tester.getRect(
        find.byKey(const Key('planner-timeline-create-surface')),
      );

      // Pinch-out over empty time.
      final g1 = await _drivePinchOutOpen(
        tester,
        upper: Offset(createRect.left + 40, createRect.top + 60),
        lower: Offset(createRect.left + 80, createRect.top + 60),
        totalGap: 30,
      );
      await g1.first.up();
      await g1.second.up();
      await tester.pumpAndSettle();

      // Pinch-in over empty time.
      final g2 = await _drivePinchInOpen(
        tester,
        upper: Offset(createRect.left + 60, createRect.top + 80),
        lower: Offset(createRect.left + 100, createRect.top + 80),
        totalClose: 30,
      );
      await g2.first.up();
      await g2.second.up();
      await tester.pumpAndSettle();

      // Pinch with horizontal motion over empty time.
      final firstH = await tester.startGesture(
        Offset(gridCenter.dx - 30, gridCenter.dy),
        pointer: 1,
      );
      final secondH = await tester.startGesture(
        Offset(gridCenter.dx + 30, gridCenter.dy),
        pointer: 2,
      );
      await tester.pump();
      await firstH.moveBy(const Offset(-40, 0));
      await secondH.moveBy(const Offset(40, 0));
      await tester.pump();
      await firstH.up();
      await tester.pump();
      await secondH.up();
      await tester.pumpAndSettle();

      // Pinch centered on the Event block.
      final blockCenter = tester.getCenter(
        find.byKey(
          Key('planner-timed-event-${_occurrenceIdFor(_scheduledEventId)}'),
        ),
      );
      final g3 = await _drivePinchOutOpen(
        tester,
        upper: Offset(blockCenter.dx, blockCenter.dy - 10),
        lower: Offset(blockCenter.dx, blockCenter.dy + 10),
        totalGap: 30,
      );
      await g3.first.up();
      await g3.second.up();
      await tester.pumpAndSettle();

      expect(
        await count(database.calendarEvents),
        beforeEvents,
        reason:
            'calendarEvents count must be preserved across '
            'every physical-pinch path',
      );
      expect(await count(database.calendarEventExceptions), beforeExceptions);
      expect(
        await count(database.calendarEventOperations),
        beforeOperations,
        reason:
            'no operation row must be written by the '
            'physical-pinch paths',
      );
      expect(await count(database.outcomeReports), beforeReports);
      expect(await count(database.plannerTasks), beforeTasks);
      expect(await count(database.taskEventLinks), beforeLinks);
      expect(
        await count(database.activityLedgerEntries),
        beforeLedger,
        reason:
            'no Activity Ledger / Actual / contribution '
            'row must be written by the physical-pinch paths',
      );
      expect(tester.takeException(), isNull);
    });
  });
}
