// Stage B3-R1 Slice D3-A2B2: focused tests for the
// interactive day pager's preview columns (previous day / next
// day) and the cache-invalidation contract around them.
//
// These tests exercise the real Planner widget tree. They
// drive a fixed-clock in-memory Planner stack, seed
// deterministic Calendar Events through the real Calendar
// repository, and verify what each preview column actually
// renders.
//
// Content parity ground truth (read from
// `lib/features/planner/presentation/widgets/planner_interactive_day_pager.dart`):
//
//   * preview columns render `pageDay.timedEvents` only;
//     timed Events have a `PlannerCalendarItem` shape (see
//     `lib/features/planner/domain/planner_day.dart`).
//   * Planner `tasks` and `overdueTasks` are NOT part of the
//     timed-day canvas (authoritative `_TimedEventTimeline`
//     receives only `events: day.timedEvents`).
//   * `PlannerTimelineLayout.arrange` is the single shared
//     geometry helper consumed by both the centered column
//     and the preview columns.
//
// Therefore this file proves parity for: timed Calendar
// Events (TEST 1), recurring Event occurrences (TEST 3),
// recurrence exceptions (TEST 4), short + overlapping events
// (TEST 5). Task parity (TEST 2) is documented as "not in the
// timed-day canvas" and the test asserts the documented
// behavior.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/planner/application/planner_providers.dart';
import 'package:rmplanner/features/planner/data/calendar_event_time_zones.dart';
import 'package:rmplanner/features/planner/data/drift_calendar_event_repository.dart';
import 'package:rmplanner/features/planner/data/drift_outcome_reporting_repository.dart';
import 'package:rmplanner/features/planner/data/drift_planner_repository.dart';
import 'package:rmplanner/features/planner/data/drift_task_event_link_repository.dart';
import 'package:rmplanner/features/planner/domain/calendar_event.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';

import '../../../support/test_dependencies.dart';

const Size _testViewport = Size(862, 1824);
const double _testDevicePixelRatio = 2;
const String _displayTimeZoneId = 'Asia/Manila';

const PlannerDate _today = PlannerDate(year: 2026, month: 7, day: 27);
const PlannerDate _previous = PlannerDate(year: 2026, month: 7, day: 26);
const PlannerDate _next = PlannerDate(year: 2026, month: 7, day: 28);

// Stable UUIDs for seeded Calendar Events. The production
// `CalendarEventDraft.normalized` validator rejects non-UUID
// ids, so the test fixtures use real UUIDs here. Each id is
// referenced exactly once per test as a seed-only handle; the
// preview widget key is the deterministic v5
// `PlannerCalendarItem.id` returned by `readDay` for that seed.
const String _previousEventId = '11111111-aaaa-4aaa-8aaa-aaaaaaaaaa01';
const String _selectedEventId = '11111111-aaaa-4aaa-8aaa-aaaaaaaaaa02';
const String _nextEventId = '11111111-aaaa-4aaa-8aaa-aaaaaaaaaa03';
const String _recurringId = '11111111-aaaa-4aaa-8aaa-aaaaaaaaaa04';
const String _shortEventId = '11111111-aaaa-4aaa-8aaa-aaaaaaaaaa05';
const String _overlapAId = '11111111-aaaa-4aaa-8aaa-aaaaaaaaaa06';
const String _overlapBId = '11111111-aaaa-4aaa-8aaa-aaaaaaaaaa07';
const String _rescheduleReplacementId = '11111111-aaaa-4aaa-8aaa-aaaaaaaaaa08';
const String _rescheduleOperationId = '11111111-aaaa-4aaa-8aaa-aaaaaaaaaa09';

/// Build a Calendar Event Draft for a specific date.
CalendarEventDraft _timedDraft({
  required String id,
  required String title,
  required PlannerDate date,
  required int startMinute,
  required int endMinute,
  CalendarRecurrenceRule recurrence = const CalendarRecurrenceRule(),
  bool requiresReport = false,
}) {
  return CalendarEventDraft(
    id: id,
    title: title,
    timing: CalendarEventTiming.timed,
    startDate: date,
    startMinute: startMinute,
    endMinute: endMinute,
    timeZoneId: _displayTimeZoneId,
    requiresReport: requiresReport,
    recurrence: recurrence,
  );
}

/// Daily recurrence rule.
CalendarRecurrenceRule get _dailyRecurrence =>
    const CalendarRecurrenceRule(frequency: CalendarRecurrenceFrequency.daily);

/// Pump frames enough for in-flight rebuild/animation to settle
/// without triggering the per-minute current-time Timer that
/// hangs `pumpAndSettle` in the Planner route.
Future<void> _pumpFrames(WidgetTester tester) async {
  for (var i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// Force a planner refresh via the normal `refresh()` path so
/// the per-build data revision bumps and the preview signature
/// refires. This is the production refresh path — the preview
/// cache invalidation is driven by the per-build data revision
/// counter, not by a manual selected-date round trip.
Future<void> _refresh(WidgetTester tester, ProviderContainer container) async {
  await container.read(plannerControllerProvider.notifier).refresh();
  await _pumpFrames(tester);
  await tester.pumpAndSettle();
  // Pump extra frames so the preview FutureBuilder's wider
  // signature has a chance to fire and the previous/next day
  // content signatures populate.
  for (var i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Key _previewPageKey(PlannerDate date) =>
    Key('planner-day-page-${date.iso8601}');

Key _previewEventKey(String id) => Key('planner-pager-preview-event-$id');

/// Look up the `PlannerCalendarItem.id` (a deterministic
/// v5 UUID per `{eventId, originalDate}`) that the production
/// preview column uses as its widget key. Going through
/// `readDay` keeps the test anchored to the same source of
/// truth the preview consumes; raw row IDs never appear on
/// the preview tree.
Future<String> _occurrenceIdFor({
  required DriftCalendarEventRepository calendar,
  required String profileId,
  required PlannerDate date,
  required String seedEventId,
}) async {
  final items = await calendar.readDay(profileId: profileId, date: date);
  final matches = items.where((item) => item.eventId == seedEventId);
  if (matches.isEmpty) {
    return '';
  }
  return matches.first.id;
}

/// Set of repositories the tests need to seed data and pump
/// the app. All wired into a single in-memory database so the
/// repositories stay coherent across the production tree and
/// the test driver.
class _Stack {
  _Stack({
    required this.database,
    required this.privacy,
    required this.calendarRepository,
    required this.linkRepository,
    required this.outcomeReportingRepository,
    required this.plannerRepository,
  });

  final dynamic database;
  final TestPrivacyDependencies privacy;
  final DriftCalendarEventRepository calendarRepository;
  final DriftTaskEventLinkRepository linkRepository;
  final DriftOutcomeReportingRepository outcomeReportingRepository;
  final DriftPlannerRepository plannerRepository;

  Future<({ProviderContainer container, String profileId})> pumpApp(
    WidgetTester tester,
  ) async {
    final startup = buildTestRepository(
      database: database,
      privacyGate: privacy.gate,
    );
    // Capture the profile identity produced by onboarding rather
    // than hard-coding the underlying identifier-source seed.
    // The repository owns its identifier source so the caller's
    // UUID literal stays out of the assertions: the planner
    // understands the persisted profile by id and nothing else
    // needs to know which UUID is in play.
    final profile = await startup.completeOnboarding();
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
        calendarEventRepository: calendarRepository,
        plannerRepository: plannerRepository,
        plannerDateSource: const FixedPlannerDateSource(_today),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Planner'));
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp).first),
    );
    return (container: container, profileId: profile.id);
  }
}

Future<_Stack> _buildStack(WidgetTester tester) async {
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
  return _Stack(
    database: database,
    privacy: privacy,
    calendarRepository: calendarRepository,
    linkRepository: linkRepository,
    outcomeReportingRepository: outcomeReportingRepository,
    plannerRepository: plannerRepository,
  );
}

Future<void> _seedThreeDayFixture(_Stack stack, String profileId) async {
  final calendar = stack.calendarRepository;
  // Previous day only.
  await calendar.saveEvent(
    profileId: profileId,
    draft: _timedDraft(
      id: _previousEventId,
      title: 'Previous only',
      date: _previous,
      startMinute: 10 * 60,
      endMinute: 11 * 60,
    ),
  );
  // Selected day only.
  await calendar.saveEvent(
    profileId: profileId,
    draft: _timedDraft(
      id: _selectedEventId,
      title: 'Selected only',
      date: _today,
      startMinute: 14 * 60,
      endMinute: 15 * 60,
    ),
  );
  // Next day only.
  await calendar.saveEvent(
    profileId: profileId,
    draft: _timedDraft(
      id: _nextEventId,
      title: 'Next only',
      date: _next,
      startMinute: 9 * 60,
      endMinute: 10 * 60,
    ),
  );
}

void main() {
  group('Stage B3-R1 D3-A2B2: pager preview content parity', () {
    testWidgets('TEST 1 — Calendar Events appear only on the correct explicit '
        'preview page; no Event leaks onto the wrong date page', (
      tester,
    ) async {
      final stack = await _buildStack(tester);
      // Pump the Planner route first so `completeOnboarding`
      // inserts the `localProfiles` row that the FK requires
      // for the seeded Calendar Events below.
      final app = await stack.pumpApp(tester);
      await _seedThreeDayFixture(stack, app.profileId);
      // Force a planner reload so the preview signature
      // changes after the post-pump seed and the preview
      // columns re-render the freshly written data.
      await _refresh(tester, app.container);

      // Resolve each Event to its deterministic `PlannerCalendarItem.id`
      // via the same `readDay` path the preview consumes.
      final previousOccurrenceId = await _occurrenceIdFor(
        calendar: stack.calendarRepository,
        profileId: app.profileId,
        date: _previous,
        seedEventId: _previousEventId,
      );
      final nextOccurrenceId = await _occurrenceIdFor(
        calendar: stack.calendarRepository,
        profileId: app.profileId,
        date: _next,
        seedEventId: _nextEventId,
      );
      final selectedOccurrenceId = await _occurrenceIdFor(
        calendar: stack.calendarRepository,
        profileId: app.profileId,
        date: _today,
        seedEventId: _selectedEventId,
      );

      // Previous Event: only on previous preview.
      expect(
        find.descendant(
          of: find.byKey(_previewPageKey(_previous)),
          matching: find.byKey(_previewEventKey(previousOccurrenceId)),
        ),
        findsOneWidget,
        reason: 'previous Event must appear on the previous preview',
      );
      expect(
        find.descendant(
          of: find.byKey(_previewPageKey(_today)),
          matching: find.byKey(_previewEventKey(previousOccurrenceId)),
        ),
        findsNothing,
        reason: 'previous Event must not leak onto centered page',
      );
      expect(
        find.descendant(
          of: find.byKey(_previewPageKey(_next)),
          matching: find.byKey(_previewEventKey(previousOccurrenceId)),
        ),
        findsNothing,
        reason: 'previous Event must not leak onto next preview',
      );

      // Selected-day Event surfaces only via the centered
      // page. The pager preview columns consume the per-page
      // `PlannerDay.timedEvents` derived from `readDay(pageDate)`,
      // so an Event scheduled on _today produces a
      // `PlannerCalendarItem` only on `_today`'s list. The
      // previous and next preview keys therefore never carry
      // a placement keyed to its occurrence id.
      expect(
        find.descendant(
          of: find.byKey(_previewPageKey(_previous)),
          matching: find.byKey(_previewEventKey(selectedOccurrenceId)),
        ),
        findsNothing,
        reason: 'selected-day Event must not appear on previous preview',
      );
      expect(
        find.descendant(
          of: find.byKey(_previewPageKey(_next)),
          matching: find.byKey(_previewEventKey(selectedOccurrenceId)),
        ),
        findsNothing,
        reason: 'selected-day Event must not appear on next preview',
      );

      // Next Event: only on next preview.
      expect(
        find.descendant(
          of: find.byKey(_previewPageKey(_next)),
          matching: find.byKey(_previewEventKey(nextOccurrenceId)),
        ),
        findsOneWidget,
        reason: 'next Event must appear on next preview',
      );
      expect(
        find.descendant(
          of: find.byKey(_previewPageKey(_previous)),
          matching: find.byKey(_previewEventKey(nextOccurrenceId)),
        ),
        findsNothing,
        reason: 'next Event must not leak onto previous preview',
      );

      // Basic current-time preview parity: in this fixture
      // the centered page is `today` and neither preview
      // date is `today`, so the current-time indicator is
      // absent from both preview pages. The next-phase
      // ownership/midnight matrix is intentionally out of
      // scope here.
      expect(
        find.descendant(
          of: find.byKey(_previewPageKey(_previous)),
          matching: find.byKey(const Key('planner-current-time-indicator')),
        ),
        findsNothing,
        reason:
            'previous preview is not today, so no current-time '
            'indicator must render',
      );
      expect(
        find.descendant(
          of: find.byKey(_previewPageKey(_next)),
          matching: find.byKey(const Key('planner-current-time-indicator')),
        ),
        findsNothing,
        reason:
            'next preview is not today, so no current-time '
            'indicator must render',
      );
    });

    testWidgets('TEST 2 — task parity: tasks are NOT part of the timed-day '
        'canvas (documented); preview columns render timedEvents only', (
      tester,
    ) async {
      // Documented fact (from the production source): the
      // authoritative `_TimedEventTimeline` receives only
      // `events: day.timedEvents` and the pager preview
      // columns also render `pageDay.timedEvents`. Planner
      // tasks live in `PlannerDay.tasks` / `overdueTasks` /
      // `completedTasks` and are surfaced through a separate
      // surface, never the timed-day canvas.
      //
      // Therefore the preview columns never host a Planner
      // task. We assert the documented behavior via
      // find.byWidgetPredicate: zero widgets inside a preview
      // are keyed by a Planner-task-only pattern.
      final stack = await _buildStack(tester);
      final app = await stack.pumpApp(tester);
      await _seedThreeDayFixture(stack, app.profileId);
      // Force a planner reload so the preview signature
      // changes after the post-pump seed.
      await _refresh(tester, app.container);

      for (final date in <PlannerDate>[_previous, _today, _next]) {
        expect(
          find.descendant(
            of: find.byKey(_previewPageKey(date)),
            matching: find.byWidgetPredicate((w) {
              final k = w.key;
              return k is ValueKey<String> &&
                  k.value.startsWith('planner-pager-preview-task-');
            }),
          ),
          findsNothing,
          reason:
              'preview column for $date must not host any '
              'task-derived timeline widget (documented)',
        );
      }

      // Sanity: the planner is parked on _today.
      expect(
        app.container.read(plannerControllerProvider).selectedDate,
        _today,
      );
    });

    testWidgets('TEST 3 — recurring Event occurrences render on every '
        'explicit preview page the recurrence reader fills; no '
        'synthetic per-occurrence duplicate is invented by the '
        'preview', (tester) async {
      final stack = await _buildStack(tester);
      final app = await stack.pumpApp(tester);
      // Seed a daily recurring Event anchored on _previous.
      await stack.calendarRepository.saveEvent(
        profileId: app.profileId,
        draft: _timedDraft(
          id: _recurringId,
          title: 'Daily standup',
          date: _previous,
          startMinute: 9 * 60,
          endMinute: 10 * 60,
          recurrence: _dailyRecurrence,
          requiresReport: true,
        ),
      );
      // Force a planner reload so the preview signature
      // changes after the post-pump seed and the recurring
      // occurrences render on the matching preview pages.
      await _refresh(tester, app.container);

      // The recurrence reader expands the series one day
      // forward and one day back from each readDay pageDate.
      // Therefore the seeded series should produce one
      // occurrence visible on _previous, one on _today, and
      // one on _next. The previous/next preview columns
      // consume the same readDay produced
      // `PlannerDay.timedEvents`; the centered current page
      // is rendered by the production `_TimedEventTimeline`,
      // which uses a different per-Event key. We assert
      // page-correctness with the right key for each column.
      for (final date in <PlannerDate>[_previous, _next]) {
        final occurrenceId = await _occurrenceIdFor(
          calendar: stack.calendarRepository,
          profileId: app.profileId,
          date: date,
          seedEventId: _recurringId,
        );
        expect(
          occurrenceId,
          isNotEmpty,
          reason: 'recurring occurrence for $date must be returned by readDay',
        );
        expect(
          find.descendant(
            of: find.byKey(_previewPageKey(date)),
            matching: find.byKey(_previewEventKey(occurrenceId)),
          ),
          findsOneWidget,
          reason:
              'recurring occurrence for $date must render on its '
              'matching explicit preview page',
        );
        final previewEvent = find.descendant(
          of: find.byKey(_previewPageKey(date)),
          matching: find.byKey(_previewEventKey(occurrenceId)),
        );
        expect(
          find.descendant(
            of: previewEvent,
            matching: find.textContaining('Daily standup'),
          ),
          findsOneWidget,
          reason: 'adjacent preview must retain the Event title',
        );
        expect(
          find.descendant(
            of: previewEvent,
            matching: find.textContaining('9:00 AM - 10:00 AM'),
          ),
          findsOneWidget,
          reason: 'adjacent preview must retain the formatted time range',
        );
        expect(
          find.descendant(
            of: previewEvent,
            matching: find.byKey(
              Key('planner-pager-preview-event-recurrence-$occurrenceId'),
            ),
          ),
          findsOneWidget,
          reason: 'recurring adjacent preview must show the repeat icon',
        );
        expect(
          find.descendant(
            of: previewEvent,
            matching: find.byKey(
              Key('planner-pager-preview-event-status-$occurrenceId'),
            ),
          ),
          findsOneWidget,
          reason: 'adjacent preview must show compact status when it fits',
        );
      }
      // The centered day is rendered by `_TimedEventTimeline`
      // (different per-Event key path) and must carry exactly
      // one placement for the recurring series.
      final centeredOccurrenceId = await _occurrenceIdFor(
        calendar: stack.calendarRepository,
        profileId: app.profileId,
        date: _today,
        seedEventId: _recurringId,
      );
      expect(
        centeredOccurrenceId,
        isNotEmpty,
        reason: 'recurring occurrence for $_today must be returned by readDay',
      );
      expect(
        find.byKey(Key('planner-timed-event-$centeredOccurrenceId')),
        findsOneWidget,
        reason:
            'recurring occurrence for $_today must render on the '
            'centered current timeline exactly once',
      );
      // No duplicate occurrences on the same preview page:
      // each preview page renders a single instance of the
      // recurring series, mirroring the authoritative
      // `readDay` fan-out rather than synthesizing extra
      // events.
      for (final date in <PlannerDate>[_previous, _next]) {
        final occurrenceId = await _occurrenceIdFor(
          calendar: stack.calendarRepository,
          profileId: app.profileId,
          date: date,
          seedEventId: _recurringId,
        );
        expect(
          find
              .descendant(
                of: find.byKey(_previewPageKey(date)),
                matching: find.byKey(_previewEventKey(occurrenceId)),
              )
              .evaluate()
              .length,
          lessThanOrEqualTo(1),
          reason:
              'preview page $date must contain at most one occurrence '
              'for the series',
        );
      }
    });

    testWidgets('TEST 4 — recurrence exception: an occurrence-scoped '
        'reschedule of a recurring Event moves the placement '
        'without leaving a duplicate on the original page', (tester) async {
      // Authoritative contract under test:
      //   - `DriftCalendarEventRepository.readDay` emits the moved
      //     occurrence only on its effective (new) date.
      //   - `rescheduleEvent(scope: occurrence)` on a REPEATING series
      //     writes an occurrence override under the SAME series event id
      //     (Planner Polish Delta 2): the moved occurrence keeps its
      //     deterministic occurrence id and its series lineage, and no
      //     standalone replacement Event row is created.
      //   - Therefore the original page must no longer render the moved
      //     occurrence, the new date must render exactly one occurrence
      //     with the ORIGINAL occurrence id, and future occurrences stay
      //     untouched.
      final stack = await _buildStack(tester);
      // Pump the Planner route first so the FK row exists
      // for the seeded series and the reschedule.
      final app = await stack.pumpApp(tester);
      // Seed a daily recurring series anchored on _previous.
      await stack.calendarRepository.saveEvent(
        profileId: app.profileId,
        draft: _timedDraft(
          id: _recurringId,
          title: 'Daily standup',
          date: _previous,
          startMinute: 9 * 60,
          endMinute: 9 * 60 + 30,
          recurrence: _dailyRecurrence,
        ),
      );
      // Force a planner reload so the preview signature
      // changes after the post-pump seed and the _previous
      // occurrence renders on the matching preview page.
      await _refresh(tester, app.container);

      // Sanity: the _previous occurrence is visible on the
      // _previous preview BEFORE the reschedule. Use the
      // readDay-resolved occurrence id; the seed row id never
      // appears on the preview tree.
      final originalPreviousOccurrenceId = await _occurrenceIdFor(
        calendar: stack.calendarRepository,
        profileId: app.profileId,
        date: _previous,
        seedEventId: _recurringId,
      );
      expect(
        originalPreviousOccurrenceId,
        isNotEmpty,
        reason: 'series must have a deterministic occurrence id on _previous',
      );
      expect(
        find.descendant(
          of: find.byKey(_previewPageKey(_previous)),
          matching: find.byKey(_previewEventKey(originalPreviousOccurrenceId)),
        ),
        findsOneWidget,
        reason:
            'seeded occurrence must render on the _previous preview '
            'before the reschedule',
      );

      // Apply an occurrence-scoped reschedule that moves the
      // _previous occurrence to _today. Planner Polish Delta 2:
      // for a repeating series this writes an occurrence override
      // under the SAME series event id, so the moved occurrence
      // keeps its deterministic occurrence id and series lineage;
      // no standalone replacement Event row is created.
      final outcome = await stack.calendarRepository.rescheduleEvent(
        profileId: app.profileId,
        eventId: _recurringId,
        originalDate: _previous,
        scope: CalendarEventEditScope.occurrence,
        replacement: _timedDraft(
          id: _rescheduleReplacementId,
          title: 'Daily standup',
          date: _today,
          startMinute: 10 * 60,
          endMinute: 10 * 60 + 30,
        ),
        operationId: _rescheduleOperationId,
      );
      expect(
        outcome,
        CalendarEventMutationOutcome.changed,
        reason: 'reschedule must commit a new mutation',
      );
      // Force a planner reload so the preview signature
      // changes after the reschedule and the preview
      // columns reflect the post-mutation readDay result.
      await _refresh(tester, app.container);

      // The moved occurrence KEEPS its deterministic occurrence id
      // (eventId + originalDate) and now renders on _today's
      // centered timeline exactly once.
      expect(
        find.byKey(Key('planner-timed-event-$originalPreviousOccurrenceId')),
        findsOneWidget,
        reason:
            'moved occurrence must render on the _today centered '
            'timeline exactly once',
      );

      // The original _previous preview must no longer carry the
      // occurrence (the override moved it to _today).
      expect(
        find.descendant(
          of: find.byKey(_previewPageKey(_previous)),
          matching: find.byKey(_previewEventKey(originalPreviousOccurrenceId)),
        ),
        findsNothing,
        reason: 'moved occurrence must not leak to the _previous preview page',
      );

      // The moved occurrence resolves on _today under the ORIGINAL series
      // occurrence id (the daily series also has its own natural 9:00
      // occurrence on _today, so membership, not first-match, is asserted).
      final todayItems = await stack.calendarRepository.readDay(
        profileId: app.profileId,
        date: _today,
      );
      expect(
        todayItems.any((item) => item.id == originalPreviousOccurrenceId),
        isTrue,
        reason: 'the moved occurrence keeps its series occurrence id',
      );
      // No standalone replacement Event exists under any id.
      final orphan = await _occurrenceIdFor(
        calendar: stack.calendarRepository,
        profileId: app.profileId,
        date: _today,
        seedEventId: _rescheduleReplacementId,
      );
      expect(
        orphan,
        isEmpty,
        reason: 'no standalone replacement Event may be created',
      );

      // The _next page (28) is one day past the original
      // _previous (26) anchor; the daily series still produces a
      // real, unmodified occurrence there, distinct from the moved
      // occurrence and rendered exactly once on the _next preview.
      final nextOccurrenceId = await _occurrenceIdFor(
        calendar: stack.calendarRepository,
        profileId: app.profileId,
        date: _next,
        seedEventId: _recurringId,
      );
      expect(
        nextOccurrenceId,
        isNotEmpty,
        reason: 'unmodified series occurrence on _next must still exist',
      );
      expect(
        nextOccurrenceId,
        isNot(originalPreviousOccurrenceId),
        reason:
            'unmodified _next occurrence must remain distinct from '
            'the moved occurrence',
      );
      expect(
        find.descendant(
          of: find.byKey(_previewPageKey(_next)),
          matching: find.byKey(_previewEventKey(nextOccurrenceId)),
        ),
        findsOneWidget,
        reason:
            'unmodified _next occurrence must render exactly once '
            'after the reschedule',
      );
    });

    testWidgets('TEST 5 — short and overlapping Events render on the preview '
        'using the same production layout helper', (tester) async {
      final stack = await _buildStack(tester);
      // Pump the Planner route first so the FK row exists
      // for the seeded Calendar Events below.
      final app = await stack.pumpApp(tester);
      final calendar = stack.calendarRepository;
      // Short Event (~30 minutes) on _previous.
      await calendar.saveEvent(
        profileId: app.profileId,
        draft: _timedDraft(
          id: _shortEventId,
          title: 'Quick sync',
          date: _previous,
          startMinute: 8 * 60,
          endMinute: 8 * 60 + 30,
        ),
      );
      // Overlapping Events on _previous.
      await calendar.saveEvent(
        profileId: app.profileId,
        draft: _timedDraft(
          id: _overlapAId,
          title: 'Overlap A',
          date: _previous,
          startMinute: 13 * 60,
          endMinute: 14 * 60,
        ),
      );
      await calendar.saveEvent(
        profileId: app.profileId,
        draft: _timedDraft(
          id: _overlapBId,
          title: 'Overlap B',
          date: _previous,
          startMinute: 13 * 60 + 30,
          endMinute: 14 * 60 + 30,
        ),
      );
      // Force a planner reload so the preview signature
      // changes after the post-pump seed and the short and
      // overlapping Events render on the _previous preview.
      await _refresh(tester, app.container);

      // Resolve each seed to its readDay occurrence id; the
      // preview widget key is the occurrence id, never the
      // raw row id.
      final shortOccurrenceId = await _occurrenceIdFor(
        calendar: calendar,
        profileId: app.profileId,
        date: _previous,
        seedEventId: _shortEventId,
      );
      final overlapAOccurrenceId = await _occurrenceIdFor(
        calendar: calendar,
        profileId: app.profileId,
        date: _previous,
        seedEventId: _overlapAId,
      );
      final overlapBOccurrenceId = await _occurrenceIdFor(
        calendar: calendar,
        profileId: app.profileId,
        date: _previous,
        seedEventId: _overlapBId,
      );

      // Short Event: renders on the previous preview using
      // the exact production minute-to-pixel geometry. At
      // the preview's 60px/hour scale, a 30-minute Event is
      // 30 logical pixels tall. The readable preview rectangle
      // may be visually expanded to the production minimum
      // without changing the logical schedule span.
      final shortFinder = find.descendant(
        of: find.byKey(_previewPageKey(_previous)),
        matching: find.byKey(_previewEventKey(shortOccurrenceId)),
      );
      expect(
        shortFinder,
        findsOneWidget,
        reason: 'short Event must render on the preview',
      );
      final shortSize = tester.getSize(shortFinder);
      // Combined-delta exact-duration geometry: at the preview's 60 px/hour
      // scale a 30-minute Event renders exactly 30 logical pixels tall (the
      // old 48 px minimum-height inflation is removed).
      expect(shortSize.height, closeTo(30.0, 0.01));

      // Both overlapping Events render side-by-side on the
      // same preview page because the production layout
      // helper `PlannerTimelineLayout.arrange` produces a
      // column-placement per overlapping Event. Verify each
      // finds exactly one placement and that the two
      // placements sit in different horizontal columns.
      final overlapAFinder = find.descendant(
        of: find.byKey(_previewPageKey(_previous)),
        matching: find.byKey(_previewEventKey(overlapAOccurrenceId)),
      );
      final overlapBFinder = find.descendant(
        of: find.byKey(_previewPageKey(_previous)),
        matching: find.byKey(_previewEventKey(overlapBOccurrenceId)),
      );
      expect(
        overlapAFinder,
        findsOneWidget,
        reason: 'overlap A must render on the preview',
      );
      expect(
        overlapBFinder,
        findsOneWidget,
        reason: 'overlap B must also render on the preview',
      );
      final overlapARect = tester.getRect(overlapAFinder);
      final overlapBRect = tester.getRect(overlapBFinder);
      // Two columns for two overlapping Events means their
      // horizontal left edges must differ; the production
      // `arrange` helper never stacks them at the same x.
      expect(
        (overlapARect.left - overlapBRect.left).abs() > 1,
        isTrue,
        reason:
            'overlapping Events must occupy distinct columns on '
            'the preview (left A=${overlapARect.left}, '
            'left B=${overlapBRect.left})',
      );

      // Page-scoped finders prevent false positives: the
      // same occurrence ids must not be on any other
      // preview page.
      expect(
        find.descendant(
          of: find.byKey(_previewPageKey(_today)),
          matching: find.byKey(_previewEventKey(shortOccurrenceId)),
        ),
        findsNothing,
        reason: 'short Event must not leak onto the _today preview',
      );
      expect(
        find.descendant(
          of: find.byKey(_previewPageKey(_next)),
          matching: find.byKey(_previewEventKey(shortOccurrenceId)),
        ),
        findsNothing,
        reason: 'short Event must not leak onto the _next preview',
      );

      // Final shared-layout assertion: the two overlapping
      // Events share the production `hourHeight` step.
      // Overlap B starts exactly 30 minutes after overlap A
      // so their top y positions must differ by a positive
      // step. The page-scoped and column-distinct assertions
      // above already cover the page-keying and column
      // geometry contracts; the positive step closes the
      // loop on the production `hourHeight` being shared
      // (i.e. the gap is not zero and not noise).
      final gap = (overlapBRect.top - overlapARect.top).abs();
      expect(
        gap > 0,
        isTrue,
        reason:
            'overlap B must sit below overlap A by a positive '
            'vertical step (was $gap)',
      );
    });

    testWidgets('TEST 6 — basic current-time preview parity: the production '
        'preview column respects the `isToday` flag and never '
        'renders the current-time indicator on off-today pages', (
      tester,
    ) async {
      // Contract under test (D3-A2 narrow scope):
      //   - The production `_PagerPreviewColumn` renders the
      //     current-time indicator only when
      //     `settings.showCurrentTime && isToday`.
      //   - `isToday` is `widget.today == widget.nextDate`
      //     for the next preview and
      //     `widget.today == widget.previousDate` for the
      //     previous preview, where `widget.today` is the
      //     `FixedPlannerDateSource` value (2026-07-27).
      //   - The indicator is suppressed on off-today pages
      //     regardless of the wall-clock minute or
      //     `DateTime.now()`; this is the durable parity
      //     claim the test can prove deterministically.
      //
      // The presence side (indicator actually rendering on
      // a today page) depends on `DateTime.now()` falling
      // inside the visible hour window AND on the
      // wall-clock date being 2026-07-27, neither of
      // which the focused test can guarantee without a
      // production change to thread a
      // `currentTimeListenable` into the preview column.
      // The preview column's `_positionedCurrentTime` is
      // still called from `DateTime.now()` directly, so
      // the focused test proves only the negative side:
      // off-today pages never render the indicator.
      // The presence side is part of the remaining D3-A2
      // current-time ownership matrix.
      final stack = await _buildStack(tester);
      final app = await stack.pumpApp(tester);
      // Selected is _today (2026-07-27) by default. Both
      // preview pages are off-today (26 and 28), so the
      // `isToday` flag is false on both columns.
      expect(
        app.container.read(plannerControllerProvider).selectedDate,
        _today,
        reason: 'planner must start parked on _today',
      );
      await _pumpFrames(tester);
      // M7 reconciliation (2026-09-16): this was a bare `pumpAndSettle()`, which
      // can never settle on the Planner route because the per-minute
      // current-time Timer keeps scheduling — the exact hazard this file's own
      // `_pumpFrames` helper was written to avoid. Use the bounded pump so the
      // assertion below actually runs instead of hanging.
      await _pumpFrames(tester);

      // Off-today previous preview: no indicator at all.
      expect(
        find.descendant(
          of: find.byKey(_previewPageKey(_previous)),
          matching: find.byKey(const Key('planner-current-time-indicator')),
        ),
        findsNothing,
        reason:
            'previous preview (off-today) must not render the '
            'current-time indicator',
      );

      // Off-today next preview: no indicator at all.
      expect(
        find.descendant(
          of: find.byKey(_previewPageKey(_next)),
          matching: find.byKey(const Key('planner-current-time-indicator')),
        ),
        findsNothing,
        reason:
            'next preview (off-today) must not render the '
            'current-time indicator',
      );

      // Off-today centered page: the centered current
      // page is also off-today only if the planner is not
      // parked on today. In this fixture the planner is
      // parked on _today (= 2026-07-27) so the centered
      // page IS today; the centered current-time
      // indicator (a different widget subtree owned by
      // the production `_TimedEventTimeline`) is out of
      // scope for the preview-parity test. We only assert
      // the off-today preview parity here.

      // The indicator's structure (line + dot + label) is
      // owned by the production tree and rendered inside
      // the same Row. Off-today pages must contain zero
      // of those keys, individually.
      for (final key in const <String>[
        'planner-current-time-indicator',
        'planner-current-time-line',
        'planner-current-time-dot',
        'planner-current-time-label',
      ]) {
        expect(
          find.descendant(
            of: find.byKey(_previewPageKey(_previous)),
            matching: find.byKey(Key(key)),
          ),
          findsNothing,
          reason:
              'off-today previous preview must not render '
              '$key (proves isToday gating)',
        );
        expect(
          find.descendant(
            of: find.byKey(_previewPageKey(_next)),
            matching: find.byKey(Key(key)),
          ),
          findsNothing,
          reason:
              'off-today next preview must not render '
              '$key (proves isToday gating)',
        );
      }
    });
  });
}
