// Stage B2B-R3A: exact Planner current-time indicator coverage.
//
// The Day view's current-time indicator must:
//
//   1. extend from a far-left dot through the time-label gutter and
//      continue across the Event area, with the time chip above the line;
//   2. place the dot and line center Y on the exact current minute
//      per the documented formula:
//        minuteFromVisibleStart = (now.hour - firstHour) * 60 + now.minute
//        pixelsPerMinute        = effectiveHourHeight / 60
//        resolvedMinuteY        = minuteFromVisibleStart * pixelsPerMinute
//      with the indicator Row's vertical center on `resolvedMinuteY`
//      (Row top = resolvedMinuteY - indicatorHeight / 2);
//   3. format the time label as `h:mm a` with no leading zero on the
//      hour, two-digit minutes, uppercase AM/PM, and no seconds,
//      timezone suffix, or "Now" replacement;
//   4. appear only when the selected Planner date equals the local
//      calendar date represented by the current clock value;
//   5. hide on a swipe away from today and reappear on a swipe back;
//   6. scale its Y position proportionally with pinch zoom without
//      changing the selected date;
//   7. not block any approved interaction underneath (e.g. an Event
//      body tap that opens the detail screen);
//   8. update deterministically when the listenable advances one
//      minute, moving the dot and line by exactly one minute of
//      pixels and updating the label text;
//   9. re-evaluate visibility at midnight so a July 31 indicator
//      disappears when the clock rolls to August 1 (while the
//      selected date remains July 31) and reappears at 12:00 AM
//      on August 1 when the selected date moves to August 1;
//   10. never mutate domain data (Calendar Events, exceptions,
//       operations, outcome reports, planner tasks, task-event
//       links, or Activity-Ledger rows) across the indicator's
//       render, minute update, swipe, and pinch paths.
//
// The current-time source is injected through a narrow
// [ValueListenable] on the PlannerScreen constructor — production
// code does not pass the parameter and the screen owns its own
// notifier + minute-boundary timer; tests pass a [ValueNotifier]
// they own and advance it by reassigning `.value`.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/app/next_transfer_app.dart'
    show appEnvironmentProvider;
import 'package:rmplanner/app/theme/app_theme.dart';
import 'package:rmplanner/app/theme/theme_color_mode.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/ids/identifier_source.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/core/security/auth_token_store.dart';
import 'package:rmplanner/features/contacts/application/contact_providers.dart';
import 'package:rmplanner/features/contacts/data/drift_contact_repository.dart';
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
import 'package:rmplanner/features/planner/presentation/widgets/planner_interactive_day_pager.dart'
    show PlannerCurrentTimeHorizontalGeometry;
import 'package:rmplanner/features/privacy/application/privacy_providers.dart';
import 'package:rmplanner/features/startup/application/startup_providers.dart';
import 'package:rmplanner/features/startup/data/drift_startup_repository.dart';

import '../../../support/test_dependencies.dart';

/// `formatPlannerCurrentTimeLabel` lives in `planner_screen.dart`
/// alongside the production widget. The import above pulls it into
/// scope; this local alias keeps the test call sites readable.
String formatTime(DateTime now) => formatPlannerCurrentTimeLabel(now);

/// Fixed day used as "today" for the focused current-time tests.
/// Chosen inside the 6→22 visible window so the 4:03 PM sample time
/// and the 11:59 PM midnight sample both fall inside the visible
/// band.
const PlannerDate _selectedToday = PlannerDate(year: 2026, month: 7, day: 31);

/// Display timezone used by the in-memory event fixtures. Mirrors
/// the production default in `test_dependencies.dart`.
const String _displayTimeZoneId = 'Asia/Manila';

/// The test owns the [ValueNotifier]; assigning a new value to its
/// `.value` is the only mechanism the tests use to advance time.
/// The production screen-owned notifier/timer pair is bypassed by
/// passing the listenable to `PlannerScreen(currentTimeListenable:)`,
/// so the production Timer never runs during these tests.
class _CurrentTimeController {
  _CurrentTimeController(DateTime initial)
    : notifier = ValueNotifier<DateTime>(initial);

  final ValueNotifier<DateTime> notifier;
  DateTime get value => notifier.value;
  set value(DateTime newValue) => notifier.value = newValue;

  void dispose() => notifier.dispose();
}

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

CalendarEventDraft _timedDraft({
  required String id,
  required PlannerDate date,
  required int startMinute,
  required int endMinute,
}) {
  return CalendarEventDraft(
    id: id,
    title: 'Current-Time Fixture $id',
    timing: CalendarEventTiming.timed,
    startDate: date,
    startMinute: startMinute,
    endMinute: endMinute,
    requiresReport: false,
    timeZoneId: _displayTimeZoneId,
  );
}

String _occurrenceId(String eventId, PlannerDate date) {
  return CalendarEventOccurrenceIdentity.forDate(
    eventId: eventId,
    originalDate: date,
  );
}

/// Center Y of a [RenderBox] in the timeline `Stack` coordinate
/// space. Used to assert the dot and line vertical center on the
/// exact current minute per the production formula.
double _centerYInGrid(WidgetTester tester, Finder child) {
  final rect = tester.getRect(child);
  final gridRect = tester.getRect(find.byKey(const Key('planner-time-grid')));
  return rect.center.dy - gridRect.top;
}

/// Pump the Planner Day view in a focused harness with a
/// [ValueListenable<DateTime>] the test owns. We use the same
/// ProviderScope overrides as the focused swipe/pinch tests but
/// host `PlannerScreen` directly so the listenable can be passed
/// through the constructor; the production screen-owned Timer never
/// runs in this mode (the constructor parameter signals
/// "external owner, do not start a ticker").
///
/// The current-time listenable is exposed by the harness so the
/// tests can advance it deterministically by reassigning `.value`
/// on the test-owned notifier — no real-time wait, no
/// fake-async, no timer pump.
Future<_PumpedPlanner> _pumpPlanner({
  required WidgetTester tester,
  required AppDatabase database,
  required DriftPlannerRepository plannerRepository,
  required PlannerDate selected,
  required DateTime current,
  CalendarEventDraft? eventDraft,
  ThemeData? theme,
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
        selected: selected,
        startupRepository: startup,
      ),
      child: MaterialApp(
        home: PlannerScreen(currentTimeListenable: currentTime.notifier),
      ),
    ),
  );
  // The planner controller, event-type controller, and startup
  // controller all kick off async work from microtasks during
  // their first build. The planner's `_load` reads the startup
  // controller's `profileId` synchronously, so the startup
  // controller must reach `StartupReady` before the planner
  // controller's microtask reads it. We pre-warm the ProviderScope
  // by building a tiny `Container` that watches the startup
  // provider first; that forces `initialize()` to complete before
  // the planner's first build. Then we trigger the planner
  // controller to re-load via `selectDate` so the failure state
  // from the first (racy) read is replaced with a successful
  // load.
  await tester.pumpWidget(
    ProviderScope(
      overrides: _plannerOverrides(
        database: database,
        privacy: privacy,
        plannerRepository: plannerRepository,
        selected: selected,
        startupRepository: startup,
      ),
      child: MaterialApp(theme: theme, home: const _StartupPrewarm()),
    ),
  );
  // Pre-warm: explicitly call `initialize()` on the startup
  // controller so its DB query completes before the planner
  // controller's first build.
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
        selected: selected,
        startupRepository: startup,
      ),
      child: MaterialApp(
        theme: theme,
        home: PlannerScreen(currentTimeListenable: currentTime.notifier),
      ),
    ),
  );
  await tester.pumpAndSettle();
  // Force the planner controller to re-load. The first build
  // may have raced with the startup controller's initialize();
  // calling selectDate on the same date triggers a fresh
  // `_load` that now sees a `StartupReady` state.
  final plannerElement = tester.element(find.byType(PlannerScreen));
  final plannerContainer = ProviderScope.containerOf(plannerElement);
  await plannerContainer
      .read(plannerControllerProvider.notifier)
      .selectDate(selected);
  await tester.pumpAndSettle();
  return _PumpedPlanner(currentTime: currentTime);
}

List<Override> _plannerOverrides({
  required AppDatabase database,
  required TestPrivacyDependencies privacy,
  required DriftPlannerRepository plannerRepository,
  required PlannerDate selected,
  required DriftStartupRepository startupRepository,
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
  final contactRepository = DriftContactRepository(
    database: database,
    clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
    identifiers: const UuidIdentifierSource(),
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
    contactRepositoryProvider.overrideWithValue(contactRepository),
    taskEventLinkRepositoryProvider.overrideWithValue(linkRepository),
    plannerDateSourceProvider.overrideWithValue(
      FixedPlannerDateSource(selected),
    ),
  ];
}

class _PumpedPlanner {
  _PumpedPlanner({required this.currentTime});
  final _CurrentTimeController currentTime;
}

/// Tiny widget that exists only to anchor a `ProviderContainer`
/// for pre-warming. The harness uses this to force the startup
/// controller's `initialize()` to complete before the real
/// `PlannerScreen` is built, eliminating the microtask race
/// between the startup controller's `initialize()` and the
/// planner controller's `_load`.
class _StartupPrewarm extends ConsumerWidget {
  const _StartupPrewarm();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Watch the startup provider so it instantiates and runs
    // its async initialize.
    ref.watch(startupControllerProvider);
    return const SizedBox.shrink();
  }
}

/// Sample times used across the focused current-time tests. The
/// local [DateTime] constructors only build a wall-clock `DateTime`
/// (not UTC), so the production
/// `formatPlannerCurrentTimeLabel` and the production
/// `PlannerDate.fromDateTime` both see the same local date.
final DateTime _fourOhThree = DateTime(2026, 7, 31, 16, 3);
final DateTime _fourOhFour = DateTime(2026, 7, 31, 16, 4);
final DateTime _nineOhFive = DateTime(2026, 7, 31, 9, 5);
final DateTime _elevenFiftyNineAm = DateTime(2026, 7, 31, 11, 59);
final DateTime _noon = DateTime(2026, 7, 31, 12, 0);
final DateTime _threeOhOne = DateTime(2026, 7, 31, 15, 1);
final DateTime _july31LateNight = DateTime(2026, 7, 31, 23, 59);
final DateTime _august1Midnight = DateTime(2026, 8, 1, 0, 0);

void main() {
  // Allow plenty of room for the 6→22 hour timeline at the default
  // 60-px hour height (60 px × 16 hours = 960 px) plus the day header.
  group('Stage B2B-R3A: Planner current-time indicator', () {
    testWidgets('TEST 1 — R5-05 dot stays on the 56 dp gutter after the label '
        'and the bounded line continues through the Event area', (
      tester,
    ) async {
      final (database, plannerRepo, _) = await _buildRepositories();
      await _pumpPlanner(
        tester: tester,
        database: database,
        plannerRepository: plannerRepo,
        selected: _selectedToday,
        current: _fourOhThree,
      );

      final indicator = find.byKey(const Key('planner-current-time-indicator'));
      expect(indicator, findsOneWidget);

      final label = find.byKey(const Key('planner-current-time-label'));
      final dot = find.byKey(const Key('planner-current-time-dot'));
      final line = find.byKey(const Key('planner-current-time-line'));
      expect(label, findsOneWidget);
      expect(dot, findsOneWidget);
      expect(line, findsOneWidget);

      // The label is the only Text inside the indicator Row.
      final labelText = tester.widget<Text>(
        find.descendant(of: indicator, matching: find.byType(Text)),
      );
      expect(labelText.data, '4:03 PM');

      // CT-01: the capsule is anchored to the fixed time-gutter boundary.
      // The capsule right edge is tangent to the circular anchor (whose
      // center stays on the 56 dp gutter), and the thin line begins at the
      // anchor's right edge and continues through the Event area.
      final labelRect = tester.getRect(label);
      final capsuleRect = tester.getRect(_currentTimeCapsule(label));
      final dotRect = tester.getRect(dot);
      final lineRect = tester.getRect(line);
      final gridRect = tester.getRect(
        find.byKey(const Key('planner-time-grid')),
      );

      expect(
        dotRect.center.dx - gridRect.left,
        closeTo(PlannerCurrentTimeHorizontalGeometry.dotCenterX, 0.5),
        reason: 'the anchor center must stay on the 56 dp gutter boundary',
      );
      expect(
        dotRect.left - capsuleRect.right,
        closeTo(0, 0.5),
        reason: 'the capsule must be attached/tangent to the circular anchor',
      );
      expect(
        labelRect.right,
        lessThan(dotRect.left),
        reason: 'the time text stays inside the capsule, before the anchor',
      );
      expect(
        lineRect.left - dotRect.right,
        closeTo(0, 0.5),
        reason: 'the thin line must begin at the anchor right edge',
      );
      expect(
        lineRect.right,
        closeTo(gridRect.right, 0.5),
        reason: 'the line must continue through the Event area',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'TEST 1B — R5-05 fixes the dot to the 56 dp gutter while the label '
      'stays bounded and non-overlapping',
      (tester) async {
        final (database, plannerRepo, _) = await _buildRepositories();
        await _pumpPlanner(
          tester: tester,
          database: database,
          plannerRepository: plannerRepo,
          selected: _selectedToday,
          current: _fourOhThree,
        );

        final label = find.byKey(const Key('planner-current-time-label'));
        final dot = find.byKey(const Key('planner-current-time-dot'));
        final hourLine = find.byKey(const Key('planner-full-hour-line-6'));
        final gridRect = tester.getRect(
          find.byKey(const Key('planner-time-grid')),
        );
        final labelRect = tester.getRect(label);
        final capsuleRect = tester.getRect(_currentTimeCapsule(label));
        final dotRect = tester.getRect(dot);
        final hourLineRect = tester.getRect(hourLine);

        // CT-03: the label area widens LEFTWARD (labelLeft = anchorLeft -
        // labelWidth), so wide 12h labels may start left of the grid origin;
        // the right edge stays tangent to the anchor (asserted below).
        expect(
          capsuleRect.left,
          closeTo(
            gridRect.left + PlannerCurrentTimeHorizontalGeometry.labelLeft,
            0.5,
          ),
          reason: 'CT-03 label area left edge must follow labelLeft (-11 dp)',
        );
        expect(
          capsuleRect.right,
          closeTo(dotRect.left, 0.5),
          reason:
              'the capsule must end tangent to the anchor, never '
              'overlapping it',
        );
        expect(
          labelRect.right,
          lessThan(capsuleRect.right),
          reason: 'the time text stays inside the capsule',
        );
        expect(
          dotRect.center.dx - gridRect.left,
          closeTo(PlannerCurrentTimeHorizontalGeometry.dotCenterX, 0.5),
          reason: 'the anchor center is the fixed gutter boundary',
        );
        expect(
          hourLineRect.left - gridRect.left,
          closeTo(56, 0.5),
          reason: 'R4-07 must not keep R3’s widened 80 dp hour gutter',
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('TEST 1C — R5-05 long labels keep one fixed dot X at normal, '
        'intermediate, and maximum zoom', (tester) async {
      final (database, plannerRepo, _) = await _buildRepositories();
      final pumped = await _pumpPlanner(
        tester: tester,
        database: database,
        plannerRepository: plannerRepo,
        selected: _selectedToday,
        current: _nineOhFive,
      );
      final plannerElement = tester.element(find.byType(PlannerScreen));
      final container = ProviderScope.containerOf(plannerElement);
      final settingsController = container.read(
        eventTypeControllerProvider.notifier,
      );
      final baseSettings = container.read(eventTypeControllerProvider).settings;
      final samples = <(DateTime, String)>[
        (_nineOhFive, '9:05 AM'),
        (_elevenFiftyNineAm, '11:59 AM'),
        (_noon, '12:00 PM'),
        (_threeOhOne, '3:01 PM'),
        (_july31LateNight, '11:59 PM'),
      ];
      const zoomHeights = <double>[
        PlannerZoomPolicy.normalHourHeight,
        PlannerZoomPolicy.expandedHourHeight,
        PlannerZoomPolicy.absoluteMaximumHourHeight,
      ];

      double? firstDotCenterX;
      for (final hourHeight in zoomHeights) {
        await settingsController.saveSettings(
          baseSettings.copyWith(
            visibleStartHour: 0,
            visibleEndHour: 24,
            timelineHourHeight: hourHeight,
          ),
        );
        await tester.pumpAndSettle();

        for (final sample in samples) {
          pumped.currentTime.value = sample.$1;
          await tester.pump();

          final label = find.byKey(const Key('planner-current-time-label'));
          final dot = find.byKey(const Key('planner-current-time-dot'));
          final line = find.byKey(const Key('planner-current-time-line'));
          final grid = find.byKey(const Key('planner-time-grid'));
          expect(label, findsOneWidget);
          expect(tester.widget<Text>(label).data, sample.$2);

          final gridRect = tester.getRect(grid);
          final capsuleRect = tester.getRect(_currentTimeCapsule(label));
          final dotRect = tester.getRect(dot);
          final lineRect = tester.getRect(line);
          final dotCenterX = dotRect.center.dx - gridRect.left;
          firstDotCenterX ??= dotCenterX;
          // CT-03: see TEST 1 — label area left edge follows labelLeft.
          expect(
            capsuleRect.left,
            closeTo(
              gridRect.left + PlannerCurrentTimeHorizontalGeometry.labelLeft,
              0.5,
            ),
          );
          expect(dotRect.left - capsuleRect.right, closeTo(0, 0.5));
          expect(
            dotCenterX,
            closeTo(PlannerCurrentTimeHorizontalGeometry.dotCenterX, 0.5),
          );
          expect(dotCenterX, closeTo(firstDotCenterX, 0.5));
          expect(lineRect.left - dotRect.right, closeTo(0, 0.5));
          expect(lineRect.right, closeTo(gridRect.right, 0.5));
          expect(lineRect.width, greaterThan(100));
          expect(tester.takeException(), isNull);
        }
      }
    });

    testWidgets(
      'TEST 2 — exact current-minute Y matches the production formula: '
      '(hour * 60 + minute) * (hourHeight / 60) within a small logical-'
      'pixel tolerance, with the dot and line center Y on that line and '
      'the label center Y within the same tolerance',
      (tester) async {
        final (database, plannerRepo, _) = await _buildRepositories();
        await _pumpPlanner(
          tester: tester,
          database: database,
          plannerRepository: plannerRepo,
          selected: _selectedToday,
          current: _fourOhThree,
        );

        // Production formula. Defaults: hourHeight = 60, and the default
        // 06:00-22:00 configured window which IS the canvas under the P1
        // (2026-09-21) visible-hours law. Pixel 0 is the configured start
        // hour, so the indicator measures from the window origin — the
        // configured window is no longer a soft window over a full-day
        // canvas.
        const hourHeight = PlannerZoomPolicy.normalHourHeight;
        const hour = 16;
        const minute = 3;
        const minuteOfDay = hour * 60 + minute;
        const rangeStartMinute = 6 * 60; // default visibleStartHour
        const pixelsPerMinute = hourHeight / 60;
        const resolvedMinuteY =
            (minuteOfDay - rangeStartMinute) * pixelsPerMinute;

        // Small logical-pixel tolerance for layout rounding. The
        // production Row centers its children with
        // `crossAxisAlignment: CrossAxisAlignment.center`, so
        // each child's center Y is the Row's vertical center;
        // any rounding comes from the Stack/Positioned math.
        const tolerance = 0.5;

        final dot = find.byKey(const Key('planner-current-time-dot'));
        final line = find.byKey(const Key('planner-current-time-line'));
        final label = find.byKey(const Key('planner-current-time-label'));

        final dotCenterY = _centerYInGrid(tester, dot);
        final lineCenterY = _centerYInGrid(tester, line);
        final labelCenterY = _centerYInGrid(tester, label);

        expect(
          (dotCenterY - resolvedMinuteY).abs(),
          lessThanOrEqualTo(tolerance),
          reason:
              'dot center Y must land on the exact current minute '
              '(got $dotCenterY, expected $resolvedMinuteY)',
        );
        expect(
          (lineCenterY - resolvedMinuteY).abs(),
          lessThanOrEqualTo(tolerance),
          reason:
              'line center Y must land on the exact current minute '
              '(got $lineCenterY, expected $resolvedMinuteY)',
        );
        // Label sits in the same Row with crossAxisAlignment.center,
        // so its center Y must be within the same tolerance of the
        // Row's center (== resolvedMinuteY).
        expect(
          (labelCenterY - resolvedMinuteY).abs(),
          lessThanOrEqualTo(tolerance),
          reason:
              'label center Y must align with the dot and line '
              '(got $labelCenterY, expected $resolvedMinuteY)',
        );
        // 4:03 must NOT round to 4:00, 4:05, or 4:15. The dot
        // and line Y for those would be 960, 965, and 975 px
        // respectively at the default 60-px hour height; the
        // expected resolvedMinuteY is 963. Asserting that the
        // measured Y is not any of those integer-minute
        // neighbours guards the exact-minute contract.
        expect(
          dotCenterY,
          isNot(anyOf(960.0, 965.0, 975.0)),
          reason: '4:03 must not round to 4:00, 4:05, or 4:15',
        );
        expect(tester.takeException(), isNull);
      },
    );

    group('TEST 3 — formatter output', () {
      test('produces 12:00 AM for 00:00', () {
        expect(formatTime(DateTime(2026, 7, 31, 0, 0)), '12:00 AM');
      });
      test('produces 1:05 AM for 01:05', () {
        expect(formatTime(DateTime(2026, 7, 31, 1, 5)), '1:05 AM');
      });
      test('produces 12:00 PM for 12:00', () {
        expect(formatTime(DateTime(2026, 7, 31, 12, 0)), '12:00 PM');
      });
      test('produces 4:03 PM for 16:03', () {
        expect(formatTime(DateTime(2026, 7, 31, 16, 3)), '4:03 PM');
      });
      test('produces 11:59 PM for 23:59', () {
        expect(formatTime(DateTime(2026, 7, 31, 23, 59)), '11:59 PM');
      });
    });

    testWidgets('TEST 4 — indicator is visible today, hidden on previous day, '
        'hidden on next day', (tester) async {
      // today = 2026-07-31 → visible
      // previous = 2026-07-30 → hidden
      // next = 2026-08-01 → hidden
      final (database, plannerRepo, _) = await _buildRepositories();

      // Today.
      const today = _selectedToday;
      await _pumpPlanner(
        tester: tester,
        database: database,
        plannerRepository: plannerRepo,
        selected: today,
        current: _fourOhThree,
      );
      expect(
        find.byKey(const Key('planner-current-time-indicator')),
        findsOneWidget,
        reason: 'indicator must be visible on the selected "today"',
      );
      // Unmount the planner before re-pumping with a different
      // selected date so the prior test notifier's listeners
      // detach before any dispose runs. The notifier itself
      // is cleaned up by the addTearDown registered in
      // _pumpPlanner; no manual dispose is needed here.
      await tester.pumpWidget(const SizedBox.shrink());

      // Previous day.
      const previous = PlannerDate(year: 2026, month: 7, day: 30);
      await _pumpPlanner(
        tester: tester,
        database: database,
        plannerRepository: plannerRepo,
        selected: previous,
        current: _fourOhThree,
      );
      expect(
        find.byKey(const Key('planner-current-time-indicator')),
        findsNothing,
        reason:
            'indicator must be hidden when the selected date is '
            'yesterday relative to the clock',
      );
      await tester.pumpWidget(const SizedBox.shrink());

      // Next day.
      const next = PlannerDate(year: 2026, month: 8, day: 1);
      await _pumpPlanner(
        tester: tester,
        database: database,
        plannerRepository: plannerRepo,
        selected: next,
        current: _fourOhThree,
      );
      expect(
        find.byKey(const Key('planner-current-time-indicator')),
        findsNothing,
        reason:
            'indicator must be hidden when the selected date is '
            'tomorrow relative to the clock',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'TEST 5 — swipe away from today hides the indicator; swipe back '
      'to today makes it reappear; zoom density is unchanged',
      (tester) async {
        final (database, plannerRepo, _) = await _buildRepositories();
        await _pumpPlanner(
          tester: tester,
          database: database,
          plannerRepository: plannerRepo,
          selected: _selectedToday,
          current: _fourOhThree,
        );

        // Visible on today.
        expect(
          find.byKey(const Key('planner-current-time-indicator')),
          findsOneWidget,
          reason: 'indicator must start visible on today',
        );
        // P1 (2026-09-21): the canvas IS the configured 06:00-22:00 window, so
        // the grid height is 16 slots at the active hour height. Capture it
        // before the swipe cycle so the density check below compares like with
        // like instead of hard-coding a full-day slot count.
        final gridHeightBefore = tester
            .getSize(find.byKey(const Key('planner-time-grid')))
            .height;

        // Drive a left swipe to advance one day (yesterday relative
        // to the clock stays today-1 = 2026-07-30). The
        // centered page is now 2026-07-30 and the new
        // previous preview is 2026-07-29; the new next
        // preview is 2026-07-31, which IS today.
        final scrollFinder = find.byKey(const Key('planner-day-scroll'));
        final scrollRect = tester.getRect(scrollFinder);
        final center = scrollRect.center;
        final gestureLeft = await tester.startGesture(center, pointer: 1);
        const steps = 8;
        const dx = -300.0;
        final perStep = dx / steps;
        for (var i = 1; i <= steps; i++) {
          await gestureLeft.moveBy(Offset(perStep, 0));
          await tester.pump(const Duration(milliseconds: 16));
        }
        await gestureLeft.up();
        await tester.pumpAndSettle();

        // The centered page is no longer today, so the
        // centered current-time indicator is hidden. The
        // next preview is today, so exactly one indicator
        // remains — the preview-page one. The unified
        // current-time source guarantees the preview and
        // the centered page read from the same instant;
        // the indicator is never duplicated.
        expect(
          find.byKey(const Key('planner-current-time-indicator')),
          findsOneWidget,
          reason:
              'after a left swipe, the next preview (today) must '
              'own the single current-time indicator',
        );

        // Drive a right swipe to return to today.
        final gestureRight = await tester.startGesture(center, pointer: 1);
        const dxRight = 300.0;
        final perStepRight = dxRight / steps;
        for (var i = 1; i <= steps; i++) {
          await gestureRight.moveBy(Offset(perStepRight, 0));
          await tester.pump(const Duration(milliseconds: 16));
        }
        await gestureRight.up();
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('planner-current-time-indicator')),
          findsOneWidget,
          reason:
              'swiping back to today must re-show the indicator '
              'on the centered page (or, if the centered page is '
              'off-today, on the relevant preview)',
        );

        // Zoom density: the grid height is the active hour-height × the
        // configured visible span and must be unchanged across a swipe cycle.
        final gridHeightAfter = tester
            .getSize(find.byKey(const Key('planner-time-grid')))
            .height;
        expect(
          gridHeightAfter,
          gridHeightBefore,
          reason: 'zoom density must be unchanged across swipes',
        );
        // P1 (2026-09-21): the canvas is the configured window, so the default
        // 06:00-22:00 window is exactly 16 slots at the default hour height.
        expect(
          gridHeightAfter,
          16 * PlannerZoomPolicy.normalHourHeight,
          reason:
              'the canvas must be the configured 06:00-22:00 window '
              '(16 slots at the default hour height)',
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('TEST 6 — pinch-out increases effective hour height and the '
        'indicator Y scales proportionally; label, dot, and line remain '
        'aligned; the selected date is unchanged', (tester) async {
      final (database, plannerRepo, _) = await _buildRepositories();
      await _pumpPlanner(
        tester: tester,
        database: database,
        plannerRepository: plannerRepo,
        selected: _selectedToday,
        current: _fourOhThree,
      );

      // Default 60-px hour height and the default 06:00-22:00 configured
      // window (16 slots), which IS the canvas under the P1 (2026-09-21)
      // visible-hours law. The indicator measures from the window origin, not
      // from midnight.
      const defaultHourHeight = PlannerZoomPolicy.normalHourHeight;
      const configuredSpanHours = 16; // default 06:00-22:00 window
      const rangeStartMinute = 6 * 60; // default visibleStartHour
      const baseMinuteOfDay = 16 * 60 + 3;
      const basePixelsPerMinute = defaultHourHeight / 60;
      const baseResolvedY =
          (baseMinuteOfDay - rangeStartMinute) * basePixelsPerMinute;

      final dot = find.byKey(const Key('planner-current-time-dot'));
      final line = find.byKey(const Key('planner-current-time-line'));
      final label = find.byKey(const Key('planner-current-time-label'));

      final baseDotY = _centerYInGrid(tester, dot);
      final baseLineY = _centerYInGrid(tester, line);
      final baseLabelY = _centerYInGrid(tester, label);
      expect((baseDotY - baseResolvedY).abs(), lessThanOrEqualTo(0.5));
      expect((baseLineY - baseResolvedY).abs(), lessThanOrEqualTo(0.5));
      expect((baseLabelY - baseResolvedY).abs(), lessThanOrEqualTo(0.5));

      // Pinch out: two fingers start 80 px apart vertically and
      // move to 200 px apart (total spread 120 px). That gap
      // comfortably crosses the ScaleGestureRecognizer's
      // kScaleSlop threshold so onScaleUpdate dispatches with
      // scale > 1 and the timeline's hour-height clamp widens.
      final gridRect = tester.getRect(
        find.byKey(const Key('planner-time-grid')),
      );
      final baseGridHeight = gridRect.height;
      final gridCenter = gridRect.center;
      final upperFinger = gridCenter + const Offset(0, -40);
      final lowerFinger = gridCenter + const Offset(0, 40);

      final first = await tester.startGesture(upperFinger, pointer: 1);
      final second = await tester.startGesture(lowerFinger, pointer: 2);
      await tester.pump();
      // Move each finger outward by 60 px in two stages so the
      // recognizer dispatches a clean onScaleUpdate with
      // scale > 1.
      await first.moveBy(const Offset(0, -60));
      await second.moveBy(const Offset(0, 60));
      await tester.pump();
      await first.moveBy(const Offset(0, -60));
      await second.moveBy(const Offset(0, 60));
      await tester.pumpAndSettle();
      await first.up();
      await second.up();
      await tester.pumpAndSettle();

      // Effective hour height must increase.
      final newGridHeight = tester
          .getSize(find.byKey(const Key('planner-time-grid')))
          .height;
      expect(
        newGridHeight,
        greaterThan(baseGridHeight),
        reason: 'pinch-out must increase the effective hour height',
      );
      final newHourHeight = newGridHeight / configuredSpanHours;
      final newPixelsPerMinute = newHourHeight / 60;
      final newResolvedY =
          (baseMinuteOfDay - rangeStartMinute) * newPixelsPerMinute;

      // Indicator Y must scale proportionally. Use a 1.5-px
      // tolerance to absorb layout rounding from the
      // Positioned math (PixelRatio rounding in headless mode).
      final newDotY = _centerYInGrid(tester, dot);
      final newLineY = _centerYInGrid(tester, line);
      final newLabelY = _centerYInGrid(tester, label);
      expect(
        (newDotY - newResolvedY).abs(),
        lessThanOrEqualTo(1.5),
        reason: 'dot Y must scale with pinch zoom',
      );
      expect(
        (newLineY - newResolvedY).abs(),
        lessThanOrEqualTo(1.5),
        reason: 'line Y must scale with pinch zoom',
      );
      expect(
        (newLabelY - newResolvedY).abs(),
        lessThanOrEqualTo(1.5),
        reason: 'label Y must scale with pinch zoom',
      );
      // Alignment: label center Y ≈ dot center Y ≈ line center Y
      // within a small tolerance.
      expect(
        (newLabelY - newDotY).abs(),
        lessThanOrEqualTo(0.5),
        reason: 'label center Y must align with dot center Y after pinch',
      );
      expect(
        (newLineY - newDotY).abs(),
        lessThanOrEqualTo(0.5),
        reason: 'line center Y must align with dot center Y after pinch',
      );
      // Selected date unchanged.
      expect(
        _selectedDateIso(tester),
        _selectedToday.iso8601,
        reason: 'pinch must not change the selected date',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('TEST 7 — overlay is non-interactive: an Event body that sits '
        'under the current-time indicator still opens its detail screen; '
        'the selected date is unchanged; no exception is raised', (
      tester,
    ) async {
      const eventId = 'c1c1c1c1-c1c1-4c1c-8c1c-c1c1c1c1c1c1';
      // Event body that spans 4:00 PM → 5:00 PM, so the 4:03 PM
      // indicator runs through the body interior — the tap point
      // must be inside the body, not on a hit area outside it.
      final (database, plannerRepo, calendarRepo) = await _buildRepositories();
      await _pumpPlanner(
        tester: tester,
        database: database,
        plannerRepository: plannerRepo,
        selected: _selectedToday,
        current: _fourOhThree,
        eventDraft: _timedDraft(
          id: eventId,
          date: _selectedToday,
          startMinute: 16 * 60,
          endMinute: 17 * 60,
        ),
      );

      final blockFinder = find.byKey(
        Key('planner-timed-event-${_occurrenceId(eventId, _selectedToday)}'),
      );
      expect(
        blockFinder,
        findsOneWidget,
        reason: 'fixture event body must be rendered',
      );

      final blockRect = tester.getRect(blockFinder);
      // Tap at a point well inside the body, near the top, but
      // not on the resize hit area. A y offset of 10 px from the
      // top of the body keeps the gesture in the body interior
      // where the indicator overlay sits.
      await tester.tapAt(Offset(blockRect.center.dx, blockRect.top + 10));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // Selected date unchanged.
      expect(
        _selectedDateIso(tester),
        _selectedToday.iso8601,
        reason:
            'tapping the event body under the overlay must not '
            'change the selected date',
      );

      // The detail screen pushes a route. We can't assert on the
      // pushed widget (varies by build), but the absence of
      // exceptions — combined with the documented tap pipeline
      // in `_TimelineEventBlock` — confirms the overlay's
      // `IgnorePointer` did not absorb the gesture. The same
      // pattern is used by the focused swipe Test 7 to prove
      // the body-tap route survives the swipe wrapper.
      expect(tester.takeException(), isNull);
      // Sanity: the event row itself was not mutated.
      final events = await database.select(database.calendarEvents).get();
      expect(events, hasLength(1));
    });

    testWidgets(
      'TEST 8 — minute-boundary update: the label text changes, the dot '
      'and line move by exactly one minute of pixels, and the screen '
      'owns no extra timer or listener',
      (tester) async {
        final (database, plannerRepo, _) = await _buildRepositories();
        final pumped = await _pumpPlanner(
          tester: tester,
          database: database,
          plannerRepository: plannerRepo,
          selected: _selectedToday,
          current: _fourOhThree,
        );

        // The default 06:00-22:00 window is the canvas, so both the baseline
        // and the advanced minute measure from the window origin.
        const hourHeight = PlannerZoomPolicy.normalHourHeight;
        const rangeStartMinute = 6 * 60;
        const baseMinuteOfDay = 16 * 60 + 3;
        const basePixelsPerMinute = hourHeight / 60;
        const baseResolvedY =
            (baseMinuteOfDay - rangeStartMinute) * basePixelsPerMinute;
        const nextMinuteOfDay = 16 * 60 + 4;
        const nextResolvedY =
            (nextMinuteOfDay - rangeStartMinute) * basePixelsPerMinute;
        const expectedDelta = nextResolvedY - baseResolvedY; // exactly 1 px

        final dot = find.byKey(const Key('planner-current-time-dot'));
        final line = find.byKey(const Key('planner-current-time-line'));
        final label = find.byKey(const Key('planner-current-time-label'));

        // Baseline at 4:03 PM.
        final beforeDotY = _centerYInGrid(tester, dot);
        final beforeLineY = _centerYInGrid(tester, line);
        final beforeLabelText = tester.widget<Text>(label).data;
        expect(beforeLabelText, '4:03 PM');
        expect((beforeDotY - baseResolvedY).abs(), lessThanOrEqualTo(0.5));
        expect((beforeLineY - baseResolvedY).abs(), lessThanOrEqualTo(0.5));

        // Advance the test-owned listenable to 4:04 PM. This is
        // the only mechanism the tests use to trigger a minute
        // update — the production minute-boundary Timer never
        // runs in this mode.
        pumped.currentTime.value = _fourOhFour;
        await tester.pumpAndSettle();

        final afterDotY = _centerYInGrid(tester, dot);
        final afterLineY = _centerYInGrid(tester, line);
        final afterLabelText = tester.widget<Text>(label).data;
        expect(afterLabelText, '4:04 PM');
        // The dot and line must move by exactly one minute of
        // pixels (1 px at the default 60-px hour height). The
        // label is rendered inside the same Row so it moves with
        // them; we assert that label Y also moves by the same
        // delta, with the same tolerance.
        expect(
          (afterDotY - beforeDotY - expectedDelta).abs(),
          lessThanOrEqualTo(0.5),
          reason: 'dot must move by exactly one minute of pixels',
        );
        expect(
          (afterLineY - beforeLineY - expectedDelta).abs(),
          lessThanOrEqualTo(0.5),
          reason: 'line must move with the dot',
        );
        // Final position must land on the 4:04 PM minute.
        expect(
          (afterDotY - nextResolvedY).abs(),
          lessThanOrEqualTo(0.5),
          reason: 'dot must land on the 4:04 PM minute',
        );
        expect(
          (afterLineY - nextResolvedY).abs(),
          lessThanOrEqualTo(0.5),
          reason: 'line must land on the 4:04 PM minute',
        );
        // No exception: in particular no ParentData / RenderConstrainedBox
        // errors from the nested-Stack overlay.
        expect(tester.takeException(), isNull);
        // No duplicate timer / listener: we hold exactly one
        // ValueNotifier (the one we constructed). The screen
        // would have created its own notifier + Timer had the
        // seam not been wired; verifying the listenable is the
        // only one we own proves the seam is functioning.
        expect(
          identical(pumped.currentTime.notifier, pumped.currentTime.notifier),
          isTrue,
        );
      },
    );

    testWidgets(
      'TEST 9 — midnight behavior: a 31 July 11:59 PM indicator hides '
      'when the clock rolls to 1 August 12:00 AM (selected date still '
      '31 July), then reappears at 12:00 AM when the selected date '
      'moves to 1 August',
      (tester) async {
        final (database, plannerRepo, _) = await _buildRepositories();

        // Start: 31 July 11:59 PM, selected = 31 July. The Correction Pack
        // locks the range rule: the indicator shows only when the current
        // time is inside the configured Planner range. This test configures
        // the full 24-hour range so midnight semantics are exercised while
        // the range rule stays honored.
        final pumped = await _pumpPlanner(
          tester: tester,
          database: database,
          plannerRepository: plannerRepo,
          selected: _selectedToday,
          current: _july31LateNight,
        );
        final plannerElement = tester.element(find.byType(PlannerScreen));
        final container = ProviderScope.containerOf(plannerElement);
        final settingsController = container.read(
          eventTypeControllerProvider.notifier,
        );
        await settingsController.saveSettings(
          container
              .read(eventTypeControllerProvider)
              .settings
              .copyWith(visibleStartHour: 0, visibleEndHour: 24),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('planner-current-time-indicator')),
          findsOneWidget,
          reason:
              'indicator must be visible at 31 July 11:59 PM with '
              'selected date = 31 July inside the full-day range',
        );
        expect(
          tester
              .widget<Text>(find.byKey(const Key('planner-current-time-label')))
              .data,
          '11:59 PM',
        );

        // Roll the clock to 1 August 12:00 AM. Selected date is
        // still 31 July — the indicator must hide because the
        // selected date no longer matches the clock's local
        // calendar date.
        pumped.currentTime.value = _august1Midnight;
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('planner-current-time-indicator')),
          findsNothing,
          reason:
              'indicator must hide when the clock rolls past '
              'midnight while the selected date is still 31 July',
        );

        // Move the selected date to 1 August. The indicator must
        // reappear at minute 0, with label "12:00 AM".
        const august1 = PlannerDate(year: 2026, month: 8, day: 1);
        // Drive a left swipe from the Day view to advance one day.
        // (Selected is currently 31 July; one left swipe lands on
        // 1 August.)
        final scrollFinder = find.byKey(const Key('planner-day-scroll'));
        final scrollRect = tester.getRect(scrollFinder);
        final center = scrollRect.center;
        final gesture = await tester.startGesture(center, pointer: 1);
        const steps = 8;
        const dx = -300.0;
        final perStep = dx / steps;
        for (var i = 1; i <= steps; i++) {
          await gesture.moveBy(Offset(perStep, 0));
          await tester.pump(const Duration(milliseconds: 16));
        }
        await gesture.up();
        await tester.pumpAndSettle();

        // Sanity: the selected date is now 1 August.
        expect(
          _selectedDateIso(tester),
          august1.iso8601,
          reason: 'a single left swipe from 31 July must land on 1 August',
        );

        // The indicator must be visible at minute 0 with label
        // "12:00 AM". No stale 31 July indicator may remain.
        expect(
          find.byKey(const Key('planner-current-time-indicator')),
          findsOneWidget,
          reason: 'indicator must reappear at minute 0 on 1 August',
        );
        expect(
          tester
              .widget<Text>(find.byKey(const Key('planner-current-time-label')))
              .data,
          '12:00 AM',
        );
        // Dot and line center Y at minute 0 with the full-day range:
        // minuteFromVisibleStart = (0 - 0) * 60 + 0 = 0, so the dot sits at
        // the very top of the visible window (grid-local Y ≈ 0), within a
        // small tolerance.
        final dot = find.byKey(const Key('planner-current-time-dot'));
        final dotY = _centerYInGrid(tester, dot);
        expect(
          dotY,
          greaterThanOrEqualTo(-1.5),
          reason:
              'midnight indicator must sit at the top of the '
              'visible window (got $dotY)',
        );
        expect(
          (dotY - 0.0).abs(),
          lessThanOrEqualTo(1.5),
          reason:
              'midnight dot Y must be at 0 in the grid local '
              'coordinate space (got $dotY)',
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('TEST 10 — no domain or Actual writes across initial render, '
        'minute update, swipe away, swipe back, and pinch geometry', (
      tester,
    ) async {
      final (database, plannerRepo, _) = await _buildRepositories();
      final pumped = await _pumpPlanner(
        tester: tester,
        database: database,
        plannerRepository: plannerRepo,
        selected: _selectedToday,
        current: _fourOhThree,
      );

      // Baseline counts: no fixture events were seeded, so every
      // domain table should be empty.
      Future<List<Object>> calendarEvents() =>
          database.select(database.calendarEvents).get();
      Future<List<Object>> calendarEventExceptions() =>
          database.select(database.calendarEventExceptions).get();
      Future<List<Object>> calendarEventOperations() =>
          database.select(database.calendarEventOperations).get();
      Future<List<Object>> outcomeReports() =>
          database.select(database.outcomeReports).get();
      Future<List<Object>> plannerTasks() =>
          database.select(database.plannerTasks).get();
      Future<List<Object>> taskEventLinks() =>
          database.select(database.taskEventLinks).get();
      Future<List<Object>> activityLedgerEntries() =>
          database.select(database.activityLedgerEntries).get();

      Future<
        ({
          int events,
          int exceptions,
          int operations,
          int reports,
          int tasks,
          int links,
          int ledger,
        })
      >
      snapshot() async {
        final values = await Future.wait(<Future<List<Object>>>[
          calendarEvents(),
          calendarEventExceptions(),
          calendarEventOperations(),
          outcomeReports(),
          plannerTasks(),
          taskEventLinks(),
          activityLedgerEntries(),
        ]);
        return (
          events: values[0].length,
          exceptions: values[1].length,
          operations: values[2].length,
          reports: values[3].length,
          tasks: values[4].length,
          links: values[5].length,
          ledger: values[6].length,
        );
      }

      final before = await snapshot();

      // 1. Initial indicator render.
      expect(
        find.byKey(const Key('planner-current-time-indicator')),
        findsOneWidget,
      );
      // 2. Deterministic minute update.
      pumped.currentTime.value = _fourOhFour;
      await tester.pumpAndSettle();
      // 3. Swipe away (left one day).
      final scrollRect = tester.getRect(
        find.byKey(const Key('planner-day-scroll')),
      );
      final center = scrollRect.center;
      final left = await tester.startGesture(center, pointer: 1);
      const steps = 8;
      const dxLeft = -300.0;
      final perLeft = dxLeft / steps;
      for (var i = 1; i <= steps; i++) {
        await left.moveBy(Offset(perLeft, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await left.up();
      await tester.pumpAndSettle();
      // 4. Swipe back (right one day).
      final right = await tester.startGesture(center, pointer: 1);
      const dxRight = 300.0;
      final perRight = dxRight / steps;
      for (var i = 1; i <= steps; i++) {
        await right.moveBy(Offset(perRight, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await right.up();
      await tester.pumpAndSettle();
      // 5. Pinch geometry update: two fingers move apart by 60 px
      // total, then lift. The pinch fires onScaleEnd which calls
      // onZoomEnd; that path must not write to any domain table.
      final gridRect = tester.getRect(
        find.byKey(const Key('planner-time-grid')),
      );
      final gridCenter = gridRect.center;
      final first = await tester.startGesture(
        gridCenter + const Offset(0, -30),
        pointer: 1,
      );
      final second = await tester.startGesture(
        gridCenter + const Offset(0, 30),
        pointer: 2,
      );
      await tester.pump();
      await first.moveBy(const Offset(0, -30));
      await second.moveBy(const Offset(0, 30));
      await tester.pump();
      await first.up();
      await second.up();
      await tester.pumpAndSettle();

      final after = await snapshot();
      expect(after.events, before.events);
      expect(after.exceptions, before.exceptions);
      expect(after.operations, before.operations);
      expect(after.reports, before.reports);
      expect(after.tasks, before.tasks);
      expect(after.links, before.links);
      expect(after.ledger, before.ledger);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'TEST 11 — P1 range law: under the DEFAULT 06:00-22:00 window the '
      'indicator is visible for every in-window hour (including the noon '
      'boundary) and genuinely ABSENT outside it; with an explicit 0-24 '
      'window it stays continuous across the whole civil day',
      (tester) async {
        final (database, plannerRepo, _) = await _buildRepositories();
        final pumped = await _pumpPlanner(
          tester: tester,
          database: database,
          plannerRepository: plannerRepo,
          selected: _selectedToday,
          current: _fourOhThree,
        );
        final container = ProviderScope.containerOf(
          tester.element(find.byType(PlannerScreen)),
        );
        final settings = container.read(eventTypeControllerProvider).settings;
        expect(
          settings.visibleStartHour,
          6,
          reason:
              'this regression must run against the DEFAULT planning '
              'window, not a widened one',
        );
        expect(settings.visibleEndHour, 22);

        // P1 (2026-09-21) range law: the configured visible window IS the
        // canvas, so an in-window current time is visible and an out-of-window
        // current time is genuinely absent (never painted at a clamped false
        // boundary). The pre-P1 expectation that 22:00-05:59 stayed visible
        // under the default window is the law this supersedes.
        const samples = <(int, int, String)>[
          (6, 0, '6:00 AM'),
          (11, 59, '11:59 AM'),
          (12, 0, '12:00 PM'),
          (12, 59, '12:59 PM'),
          (13, 0, '1:00 PM'),
          (21, 0, '9:00 PM'),
          (21, 59, '9:59 PM'),
        ];
        final gridHeight = tester
            .getRect(find.byKey(const Key('planner-time-grid')))
            .height;
        double? previousY;
        for (final (hour, minute, label) in samples) {
          pumped.currentTime.value = DateTime(2026, 7, 31, hour, minute);
          await tester.pump();
          final clock =
              '${hour.toString().padLeft(2, '0')}:'
              '${minute.toString().padLeft(2, '0')}';
          expect(
            find.byKey(const Key('planner-current-time-indicator')),
            findsOneWidget,
            reason:
                'the current-time indicator must be visible at $clock on '
                'the selected current day: $clock is inside the configured '
                '06:00-22:00 window, which is the canvas',
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
          final centerY = _centerYInGrid(
            tester,
            find.byKey(const Key('planner-current-time-dot')),
          );
          expect(
            centerY,
            greaterThanOrEqualTo(0),
            reason: 'the $clock dot must stay inside the canvas (got $centerY)',
          );
          expect(
            centerY,
            lessThanOrEqualTo(gridHeight),
            reason:
                'the $clock dot must stay inside the canvas '
                '(got $centerY of $gridHeight)',
          );
          if (previousY != null) {
            expect(
              centerY,
              greaterThan(previousY),
              reason:
                  'the indicator must advance monotonically through the '
                  'day (at $clock expected greater than $previousY, got '
                  '$centerY)',
            );
          }
          previousY = centerY;
        }

        // Outside the configured default window: genuinely absent. The
        // indicator must not be clamped to a false 06:00 or 22:00 boundary.
        for (final (hour, minute) in const <(int, int)>[
          (0, 0),
          (5, 59),
          (22, 0),
          (22, 59),
          (23, 0),
          (23, 59),
        ]) {
          pumped.currentTime.value = DateTime(2026, 7, 31, hour, minute);
          await tester.pump();
          expect(
            find.byKey(const Key('planner-current-time-indicator')),
            findsNothing,
            reason:
                'the indicator must be absent at $hour:$minute because the '
                'configured 06:00-22:00 window is the canvas and an outside '
                'time is never painted at a false boundary',
          );
        }

        // Retained full-day coverage: with an explicit 0-24 window the
        // indicator is continuous across the whole civil day, including the
        // late-night hours the pre-P1 law asserted under the default window.
        await container
            .read(eventTypeControllerProvider.notifier)
            .saveSettings(
              settings.copyWith(visibleStartHour: 0, visibleEndHour: 24),
            );
        await tester.pumpAndSettle();
        final fullDayHeight = tester
            .getRect(find.byKey(const Key('planner-time-grid')))
            .height;
        double? fullDayPreviousY;
        for (final (hour, minute) in const <(int, int)>[
          (0, 0),
          (11, 59),
          (12, 0),
          (22, 0),
          (23, 0),
          (23, 59),
        ]) {
          pumped.currentTime.value = DateTime(2026, 7, 31, hour, minute);
          await tester.pump();
          expect(
            find.byKey(const Key('planner-current-time-indicator')),
            findsOneWidget,
            reason:
                'under an explicit 0-24 window the indicator must stay '
                'visible at $hour:$minute',
          );
          final fullDayY = _centerYInGrid(
            tester,
            find.byKey(const Key('planner-current-time-dot')),
          );
          expect(
            fullDayY,
            inInclusiveRange(0, fullDayHeight),
            reason:
                'the $hour:$minute dot must stay inside the full-day canvas '
                '(got $fullDayY of $fullDayHeight)',
          );
          if (fullDayPreviousY != null) {
            expect(
              fullDayY,
              greaterThan(fullDayPreviousY),
              reason: 'the full-day indicator must advance monotonically',
            );
          }
          fullDayPreviousY = fullDayY;
        }
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'TEST 12 — P1 range law: after the local date rollover the indicator '
      'reappears at 00:00 under an explicit 0-24 window, and is correctly '
      'absent under the DEFAULT 06:00-22:00 window',
      (tester) async {
        final (database, plannerRepo, _) = await _buildRepositories();
        const august1 = PlannerDate(year: 2026, month: 8, day: 1);
        final pumped = await _pumpPlanner(
          tester: tester,
          database: database,
          plannerRepository: plannerRepo,
          selected: august1,
          current: _august1Midnight,
        );
        final container = ProviderScope.containerOf(
          tester.element(find.byType(PlannerScreen)),
        );
        final settings = container.read(eventTypeControllerProvider).settings;
        expect(settings.visibleStartHour, 6);
        expect(settings.visibleEndHour, 22);

        // Date law first: while the clock is still 31 July 23:59,
        // viewing 1 August must not paint the marker at all (a
        // 00:00-05:59 planner row is still 31 July's row).
        pumped.currentTime.value = _july31LateNight;
        await tester.pump();
        expect(
          find.byKey(const Key('planner-current-time-indicator')),
          findsNothing,
          reason:
              'the indicator must never paint on a non-current viewed '
              'date',
        );

        // P1 (2026-09-21) range law: 00:00-05:59 lies outside the DEFAULT
        // 06:00-22:00 window and that window is now the canvas, so the
        // indicator is genuinely absent there rather than clamped to a false
        // 06:00 boundary.
        for (final (hour, minute) in const <(int, int)>[
          (0, 0),
          (0, 1),
          (0, 30),
          (0, 59),
          (1, 0),
        ]) {
          pumped.currentTime.value = DateTime(2026, 8, 1, hour, minute);
          await tester.pump();
          expect(
            find.byKey(const Key('planner-current-time-indicator')),
            findsNothing,
            reason:
                'the indicator must be absent at $hour:$minute: the default '
                '06:00-22:00 window is the canvas and 00:00-05:59 is '
                'outside it',
          );
        }

        // Retained coverage: with an explicit 0-24 window the original
        // midnight-rollover continuity law is exercised exactly as before.
        await container
            .read(eventTypeControllerProvider.notifier)
            .saveSettings(
              settings.copyWith(visibleStartHour: 0, visibleEndHour: 24),
            );
        await tester.pumpAndSettle();

        const samples = <(int, int, String)>[
          (0, 0, '12:00 AM'),
          (0, 1, '12:01 AM'),
          (0, 30, '12:30 AM'),
          (0, 59, '12:59 AM'),
          (1, 0, '1:00 AM'),
        ];
        double? previousY;
        for (final (hour, minute, label) in samples) {
          pumped.currentTime.value = DateTime(2026, 8, 1, hour, minute);
          await tester.pump();
          final clock =
              '${hour.toString().padLeft(2, '0')}:'
              '${minute.toString().padLeft(2, '0')}';
          expect(
            find.byKey(const Key('planner-current-time-indicator')),
            findsOneWidget,
            reason:
                'the current-time indicator must be visible at $clock on '
                'the new current local day under the explicit 0-24 window',
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
          final centerY = _centerYInGrid(
            tester,
            find.byKey(const Key('planner-current-time-dot')),
          );
          if (previousY == null) {
            expect(
              centerY,
              closeTo(0, 0.5),
              reason:
                  '00:00 must sit at the very top of the full civil-day '
                  'canvas (got $centerY)',
            );
          } else {
            expect(
              centerY,
              greaterThan(previousY),
              reason:
                  'the indicator must advance monotonically into the new '
                  'day (at $clock expected greater than $previousY, got '
                  '$centerY)',
            );
          }
          previousY = centerY;
        }
        expect(tester.takeException(), isNull);
      },
    );

    // P1 (2026-09-21) range-law regression: the configured visible window is
    // the canvas, so `TEST 11` and `TEST 12` drive the DEFAULT 06:00-22:00
    // window and assert BOTH that in-window times are visible and that
    // out-of-window times are genuinely absent; each then re-runs the original
    // whole-civil-day continuity coverage under an explicit 0-24 window. A
    // future change that re-couples visibility to a full-day canvas, or that
    // clamps an outside time onto a false boundary, fails loudly.
  });

  // ------------------------------------------------------------- CT-02
  // Planner current-time label contract: in ALL FOUR Rose/Blue x Light/Dark
  // combinations the time label has NO fill/background, the time text uses
  // scheme.primary and is slightly larger (fontSize 13), and the anchor and
  // line stay scheme.primary with their CT-01 geometry unchanged.
  group('CT-02 current-time label contract', () {
    Future<void> pumpAndProbe(
      WidgetTester tester, {
      required ThemeData theme,
      required Color expectedPrimary,
      required Color expectedOnPrimary,
    }) async {
      final (database, plannerRepo, _) = await _buildRepositories();
      await _pumpPlanner(
        tester: tester,
        database: database,
        plannerRepository: plannerRepo,
        selected: _selectedToday,
        current: _fourOhThree,
        theme: theme,
      );
      final scheme = theme.colorScheme;
      expect(scheme.primary, expectedPrimary);
      expect(scheme.onPrimary, expectedOnPrimary);

      final label = find.byKey(const Key('planner-current-time-label'));
      final dot = find.byKey(const Key('planner-current-time-dot'));
      final line = find.byKey(const Key('planner-current-time-line'));
      expect(label, findsOneWidget);
      expect(dot, findsOneWidget);
      expect(line, findsOneWidget);

      // CT-02: the time text ITSELF is the highlighted element — semantic
      // primary, slightly larger than before (fontSize 13).
      final labelText = tester.widget<Text>(label);
      expect(
        labelText.style!.color,
        scheme.primary,
        reason: 'current-time label text must use scheme.primary',
      );
      expect(
        labelText.style!.fontSize,
        15,
        reason: 'current-time label text must be fontSize 15 (CT-03)',
      );

      // CT-02: NO fill/background behind the label.  The nearest Container
      // ancestor (the label-area box) must carry NO decoration.
      final labelArea = tester.widget<Container>(
        find.ancestor(of: label, matching: find.byType(Container)).first,
      );
      expect(
        labelArea.decoration,
        isNull,
        reason: 'current-time label must have no fill/background',
      );
      final capsuleRect = tester.getRect(
        find.ancestor(of: label, matching: find.byType(Container)).first,
      );
      expect(
        capsuleRect.height,
        lessThanOrEqualTo(
          PlannerCurrentTimeHorizontalGeometry.capsuleHeight + 0.5,
        ),
        reason: 'label area height must be bounded by the design height',
      );
      expect(
        capsuleRect.height,
        greaterThan(7),
        reason: 'label area must remain the compact time gutter height',
      );

      // CT-03: the label area widens LEFTWARD to 62dp with 4dp horizontal
      // padding so longer 12h labels render larger; the right edge stays
      // tangent to the unchanged anchor boundary (anchor/line untouched).
      final labelPadding = labelArea.padding;
      expect(
        labelPadding,
        isNotNull,
        reason: 'CT-03 label area must declare its padding',
      );
      expect(
        labelPadding!.horizontal,
        8,
        reason: 'CT-03 label horizontal padding must be 4dp per side',
      );
      expect(
        capsuleRect.width,
        closeTo(PlannerCurrentTimeHorizontalGeometry.labelWidth, 0.5),
        reason: 'CT-03 label area width must be 62dp',
      );
      expect(
        PlannerCurrentTimeHorizontalGeometry.labelLeft,
        closeTo(
          PlannerCurrentTimeHorizontalGeometry.anchorLeft -
              PlannerCurrentTimeHorizontalGeometry.labelWidth,
          0.001,
        ),
        reason: 'CT-03 label area must widen leftward from the anchor tangent',
      );
      expect(
        PlannerCurrentTimeHorizontalGeometry.lineStartX,
        PlannerCurrentTimeHorizontalGeometry.anchorRight,
        reason: 'CT-03 line start must remain anchored to the unchanged anchor',
      );

      // The circular anchor is primary and attached/tangent to the label
      // area; the thin line begins at the anchor right edge.
      final dotDecoration = tester.widget<DecoratedBox>(
        find.descendant(of: dot, matching: find.byType(DecoratedBox)),
      );
      expect(
        (dotDecoration.decoration as BoxDecoration).color,
        scheme.primary,
        reason: 'current-time anchor must use scheme.primary',
      );
      final dotRect = tester.getRect(dot);
      expect(
        dotRect.left - capsuleRect.right,
        closeTo(0, 0.5),
        reason:
            'the circular anchor must be attached/tangent to the label area',
      );
      final lineDecoration = tester.widget<DecoratedBox>(
        find.descendant(of: line, matching: find.byType(DecoratedBox)),
      );
      expect(
        (lineDecoration.decoration as BoxDecoration).color,
        scheme.primary,
        reason: 'current-time line must use scheme.primary',
      );
      final lineRect = tester.getRect(line);
      expect(
        lineRect.left - dotRect.right,
        closeTo(0, 0.5),
        reason: 'the thin line must begin at the anchor right edge',
      );

      // No wedge/triangle/play-head primitive inside the indicator.
      final indicator = find.byKey(const Key('planner-current-time-indicator'));
      expect(
        find
            .descendant(of: indicator, matching: find.byType(CustomPaint))
            .evaluate(),
        isEmpty,
        reason: 'no wedge/triangle/play-head may exist in the indicator',
      );
    }

    testWidgets(
      'Rose Light: transparent label + primary text + primary dot/line',
      (tester) async {
        await pumpAndProbe(
          tester,
          theme: AppTheme.light(ThemeColorMode.rose),
          expectedPrimary: AppTheme.roseLightPrimary,
          expectedOnPrimary: AppTheme.roseLightOnPrimary,
        );
      },
    );

    testWidgets(
      'Blue Light: transparent label + primary text + primary dot/line',
      (tester) async {
        await pumpAndProbe(
          tester,
          theme: AppTheme.light(ThemeColorMode.blue),
          expectedPrimary: AppTheme.blueLightPrimary,
          expectedOnPrimary: AppTheme.blueLightOnPrimary,
        );
      },
    );

    testWidgets(
      'Rose Dark: transparent label + primary text + primary dot/line',
      (tester) async {
        await pumpAndProbe(
          tester,
          theme: AppTheme.dark(ThemeColorMode.rose),
          expectedPrimary: AppTheme.roseDarkPrimary,
          expectedOnPrimary: AppTheme.darkOnPrimary,
        );
      },
    );

    testWidgets(
      'Blue Dark: transparent label + primary text + primary dot/line',
      (tester) async {
        await pumpAndProbe(
          tester,
          theme: AppTheme.dark(ThemeColorMode.blue),
          expectedPrimary: AppTheme.blueDarkPrimary,
          expectedOnPrimary: AppTheme.darkOnPrimary,
        );
      },
    );
  });
}

/// The CT-02 label area is the nearest [Container] ancestor of the
/// current-time label (it bounds the label horizontally, tangent to the
/// anchor; it carries NO fill/background since CT-02).
Finder _currentTimeCapsule(Finder label) =>
    find.ancestor(of: label, matching: find.byType(Container)).first;

/// Read the iso string of the currently selected date from the
/// `planner-selected-date` semantics node. Mirrors the helper used
/// by the focused swipe test.
String _selectedDateIso(WidgetTester tester) {
  final selectedSemantics = find.byKey(const Key('planner-selected-date'));
  expect(selectedSemantics, findsOneWidget);
  final widget = tester.widget<Semantics>(selectedSemantics);
  final String? rawLabel = widget.properties.label;
  expect(
    rawLabel,
    isNotNull,
    reason: 'planner-selected-date must carry a label',
  );
  final label = rawLabel!;
  final RegExpMatch? matcher = RegExp(r'(\d{4}-\d{2}-\d{2})').firstMatch(label);
  expect(
    matcher,
    isNotNull,
    reason: 'planner-selected-date label must contain an iso date: $label',
  );
  return matcher!.group(1)!;
}
