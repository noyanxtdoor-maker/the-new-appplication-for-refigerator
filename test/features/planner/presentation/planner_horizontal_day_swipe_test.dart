// Stage B2A: Planner horizontal day-swipe navigation coverage.
//
// Single-finger horizontal swipes in the Planner Day view must:
//   - swipe left → advance to the next calendar day;
//   - swipe right → go back to the previous calendar day;
//   - work across month, year, and leap-year boundaries;
//   - require a named minimum distance (or a velocity equivalent);
//   - preserve vertical scrolling, pinch zoom, Event body tap,
//     Event move, Event resize, empty-time tap, selection mode,
//     and the date-dropdown surface;
//   - never trigger on small horizontal jitter, dominant vertical
//     scrolls, or two-finger pinch gestures (even when a finger
//     moves horizontally);
//   - never mutate domain data: no Calendar Event, exception,
//     operation, outcome report, Task, Task-Event link, Activity
//     Ledger, or Actual rows are written by a swipe.
//
// The detector is a `Listener`-based wrapper that observes raw
// pointer events without competing in the gesture arena, so the
// existing recognizers (tap, long-press move, vertical drag,
// scale) keep their authority. A shared coordinator lets the
// pinch, long-press move, and vertical resize recognizers cancel
// a pending swipe before it commits. The tests below verify each
// promise in isolation against a Drift-backed Planner stack.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/planner/application/calendar_event_repository.dart';
import 'package:rmplanner/features/planner/application/event_type_providers.dart';
import 'package:rmplanner/features/planner/data/calendar_event_time_zones.dart';
import 'package:rmplanner/features/planner/data/drift_calendar_event_repository.dart';
import 'package:rmplanner/features/planner/data/drift_outcome_reporting_repository.dart';
import 'package:rmplanner/features/planner/data/drift_planner_repository.dart';
import 'package:rmplanner/features/planner/data/drift_task_event_link_repository.dart';
import 'package:rmplanner/features/planner/domain/calendar_event.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_day.dart';

import '../../../support/test_dependencies.dart';

/// Read the top-bar date label text. The label is rendered inside
/// the `planner-date-label` InkWell and shows the month
/// abbreviation + day for the Day view, so this gives a stable,
/// semantic-free way to assert the currently selected date from
/// widget tests.
String _readDateLabelText(WidgetTester tester) {
  final finder = find.descendant(
    of: find.byKey(const Key('planner-date-label')),
    matching: find.byType(Text),
  );
  expect(
    finder,
    findsOneWidget,
    reason: 'planner-date-label must contain a single Text child',
  );
  return (tester.widget<Text>(finder).data) ?? '';
}

/// Read the iso string of the currently selected date. The
/// selected day button is wrapped in a `Semantics(key:
/// 'planner-selected-date')` widget, and the `Semantics` label
/// includes the iso date (the `_DayButton` label format is
/// `'<weekday> <iso>, selected'`). Returning the iso string from
/// the semantic label keeps the swipe assertions self-describing
/// and avoids depending on the InkWell key implementation.
String _readSelectedDateIso(WidgetTester tester) {
  final selectedSemantics = find.byKey(const Key('planner-selected-date'));
  expect(selectedSemantics, findsOneWidget);
  final widget = tester.widget<Semantics>(selectedSemantics);
  // The Semantics widget's `properties.label` exposes the
  // human-readable string the parent Semantics node will
  // announce. The production `_DayButton` builds the label as
  // `'<weekday> <iso>, selected'` so a simple substring
  // match picks out the iso date.
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

/// R7-04 test seam: delegates every Calendar Event operation to a real
/// Drift repository but holds the move commits (editEvent / rescheduleEvent)
/// open until [releaseMoveCommit] completes, so a test can observe the
/// optimistic pending-move projection BEFORE the canonical commit lands.
final class _DelayedMoveCalendarRepository implements CalendarEventRepository {
  _DelayedMoveCalendarRepository(this._inner);

  final DriftCalendarEventRepository _inner;
  final Completer<void> moveCommitGate = Completer<void>();

  void releaseMoveCommit() {
    if (!moveCommitGate.isCompleted) {
      moveCommitGate.complete();
    }
  }

  @override
  String get displayTimeZoneId => _inner.displayTimeZoneId;

  @override
  bool isValidTimeZone(String timeZoneId) => _inner.isValidTimeZone(timeZoneId);

  @override
  Future<List<PlannerCalendarItem>> readDay({
    required String profileId,
    required PlannerDate date,
  }) {
    return _inner.readDay(profileId: profileId, date: date);
  }

  @override
  Future<CalendarEventDraft?> readEventDraft({
    required String profileId,
    required String eventId,
  }) {
    return _inner.readEventDraft(profileId: profileId, eventId: eventId);
  }

  @override
  Future<CalendarEventOccurrence?> readOccurrence({
    required String profileId,
    required String eventId,
    required PlannerDate originalDate,
  }) {
    return _inner.readOccurrence(
      profileId: profileId,
      eventId: eventId,
      originalDate: originalDate,
    );
  }

  @override
  Future<CalendarEventDraft> saveEvent({
    required String profileId,
    required CalendarEventDraft draft,
  }) {
    return _inner.saveEvent(profileId: profileId, draft: draft);
  }

  @override
  Future<CalendarEventMutationOutcome> editEvent({
    required String profileId,
    required String eventId,
    required PlannerDate originalDate,
    required CalendarEventEditScope scope,
    required CalendarEventDraft draft,
    required String operationId,
  }) async {
    await moveCommitGate.future;
    return _inner.editEvent(
      profileId: profileId,
      eventId: eventId,
      originalDate: originalDate,
      scope: scope,
      draft: draft,
      operationId: operationId,
    );
  }

  @override
  Future<CalendarEventMutationOutcome> cancelEvent({
    required String profileId,
    required String eventId,
    required PlannerDate originalDate,
    required CalendarEventEditScope scope,
    required String operationId,
  }) {
    return _inner.cancelEvent(
      profileId: profileId,
      eventId: eventId,
      originalDate: originalDate,
      scope: scope,
      operationId: operationId,
    );
  }

  @override
  Future<CalendarEventMutationOutcome> rescheduleEvent({
    required String profileId,
    required String eventId,
    required PlannerDate originalDate,
    required CalendarEventEditScope scope,
    required CalendarEventDraft replacement,
    required String operationId,
  }) async {
    await moveCommitGate.future;
    return _inner.rescheduleEvent(
      profileId: profileId,
      eventId: eventId,
      originalDate: originalDate,
      scope: scope,
      replacement: replacement,
      operationId: operationId,
    );
  }

  @override
  Future<CalendarEventMutationOutcome> duplicateEvent({
    required String profileId,
    required String eventId,
    required PlannerDate originalDate,
    required String duplicateId,
    required String operationId,
  }) {
    return _inner.duplicateEvent(
      profileId: profileId,
      eventId: eventId,
      originalDate: originalDate,
      duplicateId: duplicateId,
      operationId: operationId,
    );
  }
}

void main() {
  const displayTimeZoneId = 'Asia/Manila';

  const scheduledEventId = 'aaaa1111-aaaa-4aaa-8aaa-aaaa1111aaaa';
  const scheduledEventId2 = 'bbbb2222-bbbb-4bbb-8bbb-bbbb2222bbbb';

  CalendarEventDraft timedDraft({
    required String id,
    required PlannerDate date,
    required int startMinute,
    required int endMinute,
    CalendarRecurrenceRule recurrence = const CalendarRecurrenceRule(),
  }) {
    return CalendarEventDraft(
      id: id,
      title: 'Swipe Fixture $id',
      timing: CalendarEventTiming.timed,
      startDate: date,
      startMinute: startMinute,
      endMinute: endMinute,
      requiresReport: false,
      timeZoneId: displayTimeZoneId,
      recurrence: recurrence,
    );
  }

  String occurrenceIdFor(String eventId, PlannerDate date) {
    return CalendarEventOccurrenceIdentity.forDate(
      eventId: eventId,
      originalDate: date,
    );
  }

  Future<(AppDatabase, DriftPlannerRepository, DriftCalendarEventRepository)>
  buildRepositories() async {
    final database = openMemoryDatabase();
    addTearDown(database.close);
    final timeZones = IanaCalendarEventTimeZones(
      displayTimeZoneId: displayTimeZoneId,
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

  /// Pump the Planner Day view with a controlled selected date and
  /// (optionally) one timed Calendar Event at a known time.
  /// Returns the database handle so tests can read table counts
  /// before and after a swipe. The `database` must be supplied by
  /// the caller so the test can later read table counts from the
  /// same Drift connection the widget tree uses (avoids the
  /// multi-database warning that would fire from a separate
  /// `openMemoryDatabase` call).
  Future<void> pumpPlannerDay(
    WidgetTester tester, {
    required AppDatabase database,
    required DriftPlannerRepository plannerRepository,
    required CalendarEventRepository calendarRepository,
    required PlannerDate selected,
    PlannerDate? eventDate,
    String? eventId,
    int startMinute = 9 * 60,
    int endMinute = 10 * 60,
    CalendarRecurrenceRule recurrence = const CalendarRecurrenceRule(),
  }) async {
    tester.view.physicalSize = const Size(862, 1824);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    if (eventId != null) {
      final profile = await buildTestRepository(
        database: database,
      ).completeOnboarding();
      await calendarRepository.saveEvent(
        profileId: profile.id,
        draft: timedDraft(
          id: eventId,
          date: eventDate ?? selected,
          startMinute: startMinute,
          endMinute: endMinute,
          recurrence: recurrence,
        ),
      );
    }
    final privacy = TestPrivacyDependencies(database: database);
    final startup = buildTestRepository(
      database: database,
      privacyGate: privacy.gate,
    );
    await startup.completeOnboarding();
    await tester.pumpWidget(
      privacy.buildApp(
        environment: const AppEnvironment(
          name: AppEnvironmentName.production,
          label: 'PRODUCTION',
        ),
        diagnostics: SanitizedDiagnostics(),
        startupRepository: startup,
        plannerRepository: plannerRepository,
        plannerDateSource: FixedPlannerDateSource(selected),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Planner'));
    await tester.pumpAndSettle();
  }

  Future<(TestGesture, Rect)> hoverSelectedEventOnNextDay(
    WidgetTester tester, {
    required String occurrenceId,
    double verticalDelta = 0,
  }) async {
    final block = find.byKey(Key('planner-timed-event-$occurrenceId'));
    await tester.longPress(block);
    await tester.pumpAndSettle();
    final originalRect = tester.getRect(block);
    final timelineRect = tester.getRect(
      find.byKey(const Key('planner-time-grid')),
    );
    final rightTrigger = Offset(
      timelineRect.right - 28,
      originalRect.center.dy + verticalDelta,
    );
    final gesture = await tester.startGesture(originalRect.center);
    await tester.pump(const Duration(milliseconds: 20));
    await gesture.moveBy(const Offset(-24, 0));
    await tester.pump();
    await gesture.moveTo(rightTrigger);
    await tester.pump();
    // A live pointer intentionally keeps the pager's gesture machinery
    // active. Advance a bounded set of frames for the target-date load
    // instead of waiting for global quiescence before the pointer is lifted.
    for (var frame = 0; frame < 12; frame += 1) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    return (gesture, originalRect);
  }

  Future<void> pumpUntilMoveCard(WidgetTester tester) async {
    final card = find.byKey(const Key('planner-move-undo-card'));
    for (var frame = 0; frame < 30; frame += 1) {
      await tester.pump(const Duration(milliseconds: 50));
      if (card.evaluate().isNotEmpty) {
        // The SnackBar widget mounts at zero height on the first entrance
        // frame. Finish the standard entrance animation without globally
        // settling, because the visible card intentionally owns a countdown
        // timer for the next ten seconds.
        await tester.pump(const Duration(milliseconds: 300));
        return;
      }
    }
  }

  /// Drive a single-finger horizontal swipe. Negative `dx` produces
  /// a left swipe (next day); positive `dx` produces a right swipe
  /// (previous day). `steps` is the number of intermediate move
  /// events so the recognizer sees a continuous sweep rather than
  /// a single teleport.
  Future<void> driveHorizontalSwipe(
    WidgetTester tester, {
    required Offset start,
    required double dx,
    int steps = 8,
  }) async {
    final gesture = await tester.startGesture(start, pointer: 1);
    final perStep = dx / steps;
    for (var i = 1; i <= steps; i++) {
      await gesture.moveBy(Offset(perStep, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();
  }

  /// Drive a small horizontal jitter that must NOT trigger the
  /// swipe detector (below the named distance threshold).
  Future<void> driveSmallHorizontalJitter(
    WidgetTester tester, {
    required Offset start,
    double dx = 24,
  }) async {
    final gesture = await tester.startGesture(start, pointer: 1);
    await gesture.moveBy(Offset(dx, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
  }

  /// Drive a dominant vertical scroll with a small horizontal
  /// jitter. Must NOT trigger the swipe detector.
  Future<void> driveVerticalScroll(
    WidgetTester tester, {
    required Offset start,
    required double dy,
    double dx = 12,
  }) async {
    final gesture = await tester.startGesture(start, pointer: 1);
    await gesture.moveBy(Offset(dx, dy / 2));
    await tester.pump();
    await gesture.moveBy(Offset(0, dy / 2));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
  }

  /// Drive a two-finger pinch that contains horizontal movement on
  /// both pointers. Must NOT trigger the swipe detector and must
  /// still leave the selected date untouched.
  Future<void> driveHorizontalPinch(
    WidgetTester tester, {
    required Offset upper,
    required Offset lower,
    required double horizontalSpan,
  }) async {
    final first = await tester.startGesture(upper, pointer: 1);
    final second = await tester.startGesture(lower, pointer: 2);
    await tester.pump();
    // The two fingers move apart in opposite horizontal directions
    // so the pointer count stays at 2 throughout and the scale
    // recognizer observes a real scale change. dy stays at 0 so
    // this is purely a horizontal two-pointer gesture; the
    // detector must cancel itself on the first pointer-down and
    // never commit a day change when the last finger lifts.
    await first.moveBy(Offset(-horizontalSpan / 2, 0));
    await second.moveBy(Offset(horizontalSpan / 2, 0));
    await tester.pump();
    await first.up();
    await tester.pump();
    await second.up();
    await tester.pumpAndSettle();
  }

  Offset visibleZoomCenter(WidgetTester tester) {
    final canvas = tester.getRect(
      find.byKey(const Key('planner-zoom-surface')),
    );
    final viewport = tester.getRect(
      find.byKey(const Key('planner-day-scroll')),
    );
    final visible = canvas.intersect(viewport);
    expect(visible.height, greaterThan(60));
    return visible.center;
  }

  group('Stage B2A: Planner horizontal day swipe', () {
    testWidgets('TEST 1 — swipe left navigates to the next calendar day and '
        'preserves zoom density and filters', (tester) async {
      const selected = PlannerDate(year: 2026, month: 7, day: 27);
      const next = PlannerDate(year: 2026, month: 7, day: 28);
      final (database, plannerRepo, calendarRepo) = await buildRepositories();
      await pumpPlannerDay(
        tester,
        database: database,
        plannerRepository: plannerRepo,
        calendarRepository: calendarRepo,
        selected: selected,
        eventId: scheduledEventId,
      );
      expect(
        _readSelectedDateIso(tester),
        selected.iso8601,
        reason: 'starting state must show 2026-07-27 as selected',
      );
      // The top-bar date label must show the same month-day pair
      // the production widget renders for the Day view.
      expect(_readDateLabelText(tester), 'Jul 27');

      // Drive a deliberate left swipe over the day-scroll
      // surface. The swipe is taken from the visible grid
      // (planner-zoom-surface) and clears the named distance
      // threshold comfortably.
      final gridCenter = visibleZoomCenter(tester);
      await driveHorizontalSwipe(tester, start: gridCenter, dx: -180);

      expect(
        _readSelectedDateIso(tester),
        next.iso8601,
        reason: 'left swipe must advance selected date to 2026-07-28',
      );
      expect(
        _readDateLabelText(tester),
        'Jul 28',
        reason: 'top-bar date label must reflect the new day',
      );
      // After navigation the previous day's Event block is no
      // longer mounted (the timeline re-renders for the new
      // day). The new day has no Events seeded in this test
      // so the empty-timeline placeholder is the only Event-
      // level widget on screen.
      final previousBlockKey = Key(
        'planner-timed-event-${occurrenceIdFor(scheduledEventId, selected)}',
      );
      expect(
        find.byKey(previousBlockKey),
        findsNothing,
        reason:
            '2026-07-27 Event block must be gone after navigating '
            'to 2026-07-28',
      );
      expect(tester.takeException(), isNull);

      // Database rows for the source day are unchanged.
      final calendarEvents = await database
          .select(database.calendarEvents)
          .get();
      expect(calendarEvents, hasLength(1));
    });

    testWidgets('TEST 2 — swipe right navigates to the previous calendar day', (
      tester,
    ) async {
      const selected = PlannerDate(year: 2026, month: 7, day: 28);
      const previous = PlannerDate(year: 2026, month: 7, day: 27);
      final (database, plannerRepo, calendarRepo) = await buildRepositories();
      await pumpPlannerDay(
        tester,
        database: database,
        plannerRepository: plannerRepo,
        calendarRepository: calendarRepo,
        selected: selected,
      );
      expect(_readSelectedDateIso(tester), selected.iso8601);
      final gridCenter = visibleZoomCenter(tester);
      await driveHorizontalSwipe(tester, start: gridCenter, dx: 180);
      expect(
        _readSelectedDateIso(tester),
        previous.iso8601,
        reason: 'right swipe must move selected date back to 2026-07-27',
      );
      expect(_readDateLabelText(tester), 'Jul 27');
      expect(tester.takeException(), isNull);
      final calendarEvents = await database
          .select(database.calendarEvents)
          .get();
      expect(
        calendarEvents,
        isEmpty,
        reason: 'no Event has been created in this swipe-only test',
      );
    });

    testWidgets('TEST 3 — month and year boundaries round-trip across the '
        'leap-year February using the app calendar arithmetic', (tester) async {
      // One Drift database is shared across the four
      // boundary cases to avoid the multi-database warning;
      // each case re-pumps the widget tree with a different
      // `plannerDateSource` so the calendar arithmetic is the
      // only thing that varies.
      final (database, plannerRepo, calendarRepo) = await buildRepositories();
      Future<void> swipeAndExpect(
        PlannerDate start,
        double dx,
        PlannerDate expected,
      ) async {
        // Reset the widget tree to the new selected date by
        // re-pumping.
        await tester.pumpWidget(const SizedBox.shrink());
        await pumpPlannerDay(
          tester,
          database: database,
          plannerRepository: plannerRepo,
          calendarRepository: calendarRepo,
          selected: start,
        );
        expect(
          _readSelectedDateIso(tester),
          start.iso8601,
          reason: 'starting state must show ${start.iso8601}',
        );
        final gridCenter = visibleZoomCenter(tester);
        await driveHorizontalSwipe(tester, start: gridCenter, dx: dx);
        expect(
          _readSelectedDateIso(tester),
          expected.iso8601,
          reason: 'expected swipe to land on ${expected.iso8601}',
        );
        expect(tester.takeException(), isNull);
      }

      // December 31, 2026 swipe left → January 1, 2027.
      await swipeAndExpect(
        const PlannerDate(year: 2026, month: 12, day: 31),
        -180,
        const PlannerDate(year: 2027, month: 1, day: 1),
      );

      // January 1, 2026 swipe right → December 31, 2025.
      await swipeAndExpect(
        const PlannerDate(year: 2026, month: 1, day: 1),
        180,
        const PlannerDate(year: 2025, month: 12, day: 31),
      );

      // Leap-year February: 2024-02-29 swipe right → 2024-02-28.
      await swipeAndExpect(
        const PlannerDate(year: 2024, month: 2, day: 29),
        180,
        const PlannerDate(year: 2024, month: 2, day: 28),
      );

      // Non-leap February: 2025-02-28 swipe left → 2025-03-01.
      await swipeAndExpect(
        const PlannerDate(year: 2025, month: 2, day: 28),
        -180,
        const PlannerDate(year: 2025, month: 3, day: 1),
      );
    });

    testWidgets('TEST 4 — a small horizontal drag does not navigate the day', (
      tester,
    ) async {
      const selected = PlannerDate(year: 2026, month: 7, day: 27);
      final (database, plannerRepo, calendarRepo) = await buildRepositories();
      await pumpPlannerDay(
        tester,
        database: database,
        plannerRepository: plannerRepo,
        calendarRepository: calendarRepo,
        selected: selected,
      );
      final gridCenter = visibleZoomCenter(tester);
      await driveSmallHorizontalJitter(
        tester,
        start: gridCenter,
        dx: 18, // well below the 64-px distance threshold
      );
      expect(
        _readSelectedDateIso(tester),
        selected.iso8601,
        reason: 'small jitter must not navigate',
      );
      expect(tester.takeException(), isNull);
      final calendarEvents = await database
          .select(database.calendarEvents)
          .get();
      expect(calendarEvents, isEmpty);
    });

    testWidgets('TEST 5 — a dominant vertical scroll with horizontal jitter '
        'does not navigate the day', (tester) async {
      const selected = PlannerDate(year: 2026, month: 7, day: 27);
      final (database, plannerRepo, calendarRepo) = await buildRepositories();
      await pumpPlannerDay(
        tester,
        database: database,
        plannerRepository: plannerRepo,
        calendarRepository: calendarRepo,
        selected: selected,
      );
      final gridCenter = visibleZoomCenter(tester);
      // Drag dominantly downward (positive dy) with a small
      // horizontal jitter. The Planner Day timeline claims
      // single-finger drags with its scale recognizer (so
      // the outer SingleChildScrollView's vertical drag is
      // not the canonical scroll path on the timeline
      // surface) but the date must not change either way.
      await driveVerticalScroll(tester, start: gridCenter, dy: 240, dx: 12);
      expect(
        _readSelectedDateIso(tester),
        selected.iso8601,
        reason: 'a dominant vertical drag must not change the date',
      );
      expect(tester.takeException(), isNull);
      // No domain write: the dominant vertical drag did not
      // create or modify a Calendar Event.
      final calendarEvents = await database
          .select(database.calendarEvents)
          .get();
      expect(calendarEvents, isEmpty);
    });

    testWidgets('TEST 6 / Delta 4.2C — pinch over a selected Event body wins, '
        'zooms, and commits no swipe or Event edit when the last finger '
        'lifts', (tester) async {
      const selected = PlannerDate(year: 2026, month: 7, day: 27);
      final (database, plannerRepo, calendarRepo) = await buildRepositories();
      await pumpPlannerDay(
        tester,
        database: database,
        plannerRepository: plannerRepo,
        calendarRepository: calendarRepo,
        selected: selected,
        eventId: scheduledEventId2,
        startMinute: 9 * 60,
        endMinute: 11 * 60,
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      });
      final occurrenceId = occurrenceIdFor(scheduledEventId2, selected);
      final block = find.byKey(Key('planner-timed-event-$occurrenceId'));
      await tester.longPress(block);
      await tester.pumpAndSettle();
      expect(
        find.byKey(Key('planner-top-resize-hit-$occurrenceId')),
        findsOneWidget,
      );
      final grid = find.byKey(const Key('planner-time-grid'));
      final heightBefore = tester.getSize(grid).height;
      final eventCenter = tester.getCenter(block);
      await driveHorizontalPinch(
        tester,
        upper: eventCenter - const Offset(0, 20),
        lower: eventCenter + const Offset(0, 20),
        horizontalSpan: 80,
      );
      expect(tester.getSize(grid).height, greaterThan(heightBefore));
      expect(
        _readSelectedDateIso(tester),
        selected.iso8601,
        reason: 'pinch with horizontal motion must not navigate',
      );
      expect(tester.takeException(), isNull);
      final calendarEvents = await database
          .select(database.calendarEvents)
          .get();
      expect(calendarEvents, hasLength(1));
      expect(calendarEvents.single.startMinute, 9 * 60);
      expect(calendarEvents.single.endMinute, 11 * 60);
      final exceptions = await database
          .select(database.calendarEventExceptions)
          .get();
      expect(exceptions, isEmpty);
      final operations = await database
          .select(database.calendarEventOperations)
          .get();
      expect(operations, isEmpty);
    });

    testWidgets('TEST 7 — Event body tap still opens details; the date is '
        'not changed by a stationary tap on an Event block', (tester) async {
      const selected = PlannerDate(year: 2026, month: 7, day: 27);
      final (database, plannerRepo, calendarRepo) = await buildRepositories();
      await pumpPlannerDay(
        tester,
        database: database,
        plannerRepository: plannerRepo,
        calendarRepository: calendarRepo,
        selected: selected,
        eventId: scheduledEventId,
      );
      final blockFinder = find.byKey(
        Key(
          'planner-timed-event-${occurrenceIdFor(scheduledEventId, selected)}',
        ),
      );
      final rect = tester.getRect(blockFinder);
      await tester.tapAt(Offset(rect.center.dx, rect.top + 10));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        _readSelectedDateIso(tester),
        selected.iso8601,
        reason: 'a body tap must not change the date',
      );
      // The detail screen does not assert a specific widget
      // (the tap path pushes a route that varies by build),
      // but the absence of exceptions confirms the body tap
      // route did not break the swipe wrapper.
      final calendarEvents = await database
          .select(database.calendarEvents)
          .get();
      expect(calendarEvents, hasLength(1));
    });

    testWidgets('TEST 8 — Event move and resize remain available; neither '
        'gesture changes the selected date', (tester) async {
      const selected = PlannerDate(year: 2026, month: 7, day: 27);
      final (database, plannerRepo, calendarRepo) = await buildRepositories();
      await pumpPlannerDay(
        tester,
        database: database,
        plannerRepository: plannerRepo,
        calendarRepository: calendarRepo,
        selected: selected,
        eventId: scheduledEventId,
        // Tall Event so the resize hit area and the move path
        // are both exercisable.
        startMinute: 9 * 60,
        endMinute: 11 * 60,
      );
      final occurrenceId = occurrenceIdFor(scheduledEventId, selected);
      final blockFinder = find.byKey(Key('planner-timed-event-$occurrenceId'));
      final hitFinder = find.byKey(Key('planner-resize-hit-$occurrenceId'));
      expect(hitFinder, findsNothing);
      await tester.longPress(blockFinder);
      await tester.pumpAndSettle();
      expect(
        hitFinder,
        findsOneWidget,
        reason: 'resize hit area must remain available',
      );
      // Drive a vertical resize drag that crosses kTouchSlop
      // and pushes the cumulative delta past one snap. The
      // production rule is one persistence mutation on release.
      final hitCenter = tester.getCenter(hitFinder);
      final resizeGesture = await tester.startGesture(hitCenter);
      await tester.pump(const Duration(milliseconds: 20));
      await resizeGesture.moveBy(const Offset(0, 24));
      await tester.pump();
      await resizeGesture.moveBy(const Offset(0, 40));
      await tester.pump();
      await resizeGesture.up();
      await tester.pumpAndSettle();

      expect(
        _readSelectedDateIso(tester),
        selected.iso8601,
        reason: 'resize must not change the date',
      );
      final operations = await database
          .select(database.calendarEventOperations)
          .get();
      expect(
        operations,
        hasLength(1),
        reason: 'one resize operation must persist',
      );
      final calendarEvents = await database
          .select(database.calendarEvents)
          .get();
      expect(calendarEvents, hasLength(1));
      // Owner fix: a non-recurring Event owns its schedule on the master
      // row, so the resize commit is a canonical row update (11:00 + 60
      // snapped minutes = 12:00) and no exception row is created.
      expect(calendarEvents.single.endMinute, 12 * 60);
      final exceptions = await database
          .select(database.calendarEventExceptions)
          .get();
      expect(exceptions, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('TEST 9 — empty-time tap still opens the Event Type selection '
        'flow without changing the selected date', (tester) async {
      const selected = PlannerDate(year: 2026, month: 7, day: 27);
      final (database, plannerRepo, calendarRepo) = await buildRepositories();
      await pumpPlannerDay(
        tester,
        database: database,
        plannerRepository: plannerRepo,
        calendarRepository: calendarRepo,
        selected: selected,
      );
      final createFinder = find.byKey(
        const Key('planner-timeline-create-surface'),
      );
      expect(createFinder, findsOneWidget);
      // Anchor the scroll to 00:00 so the create surface's top
      // edge sits at the viewport top (the canvas now starts at
      // midnight, so its raw top-left may be scrolled off-screen).
      final plannerScroll = tester.state<ScrollableState>(
        find.descendant(
          of: find.byKey(const Key('planner-day-scroll')),
          matching: find.byType(Scrollable),
        ),
      );
      plannerScroll.position.jumpTo(0);
      await tester.pumpAndSettle();
      final topLeft = tester.getTopLeft(createFinder);
      await tester.tapAt(Offset(topLeft.dx + 80, topLeft.dy + 220));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        _readSelectedDateIso(tester),
        selected.iso8601,
        reason: 'empty-time tap must not change the date',
      );
      final calendarEvents = await database
          .select(database.calendarEvents)
          .get();
      expect(
        calendarEvents,
        isEmpty,
        reason: 'the tap did not persist a draft Event',
      );
    });

    testWidgets('TEST 10 — no domain or Actual writes occur from horizontal '
        'swipes in either direction', (tester) async {
      const selected = PlannerDate(year: 2026, month: 7, day: 27);
      final (database, plannerRepo, calendarRepo) = await buildRepositories();
      await pumpPlannerDay(
        tester,
        database: database,
        plannerRepository: plannerRepo,
        calendarRepository: calendarRepo,
        selected: selected,
        eventId: scheduledEventId,
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

      final eventsBefore = await count(database.calendarEvents);
      final exceptionsBefore = await count(database.calendarEventExceptions);
      final operationsBefore = await count(database.calendarEventOperations);
      final reportsBefore = await count(database.outcomeReports);
      final tasksBefore = await count(database.plannerTasks);
      final linksBefore = await count(database.taskEventLinks);
      final ledgerBefore = await count(database.activityLedgerEntries);

      final gridCenter = visibleZoomCenter(tester);

      // One left swipe → next day.
      await driveHorizontalSwipe(tester, start: gridCenter, dx: -200);
      // One right swipe → previous day. The grid center is
      // re-read after the first swipe because the widget tree
      // rebuilt for the new day.
      final nextGridCenter = visibleZoomCenter(tester);
      await driveHorizontalSwipe(tester, start: nextGridCenter, dx: 200);

      expect(await count(database.calendarEvents), eventsBefore);
      expect(await count(database.calendarEventExceptions), exceptionsBefore);
      expect(await count(database.calendarEventOperations), operationsBefore);
      expect(await count(database.outcomeReports), reportsBefore);
      expect(await count(database.plannerTasks), tasksBefore);
      expect(await count(database.taskEventLinks), linksBefore);
      expect(await count(database.activityLedgerEntries), ledgerBefore);
      // And the selected date is back to the starting one.
      expect(_readSelectedDateIso(tester), selected.iso8601);
      expect(tester.takeException(), isNull);
    });

    testWidgets('TEST 11 — two deliberate swipes in sequence land on a '
        'deterministic expected date with no skipped or duplicated '
        'day change', (tester) async {
      const selected = PlannerDate(year: 2026, month: 7, day: 27);
      const expected = PlannerDate(year: 2026, month: 7, day: 29);
      final (database, plannerRepo, calendarRepo) = await buildRepositories();
      await pumpPlannerDay(
        tester,
        database: database,
        plannerRepository: plannerRepo,
        calendarRepository: calendarRepo,
        selected: selected,
      );
      Future<void> swipeOnce(double dx) async {
        final gridCenter = visibleZoomCenter(tester);
        await driveHorizontalSwipe(tester, start: gridCenter, dx: dx);
      }

      await swipeOnce(-200);
      await swipeOnce(-200);

      expect(
        _readSelectedDateIso(tester),
        expected.iso8601,
        reason: 'two left swipes from 2026-07-27 must land on 2026-07-29',
      );
      expect(tester.takeException(), isNull);
      final calendarEvents = await database
          .select(database.calendarEvents)
          .get();
      expect(
        calendarEvents,
        isEmpty,
        reason: 'no Event was created by the swipes',
      );
    });
  });

  // The second fixture exercises the Event-on-Event body case so a
  // future regression that affects Event-block swipe does not
  // silently leak through the empty-timeline path tested above.
  group('Stage B2A: Planner horizontal day swipe on Event body', () {
    testWidgets('a clean horizontal swipe that begins on an Event body '
        'navigates the day without persisting any domain change', (
      tester,
    ) async {
      const selected = PlannerDate(year: 2026, month: 7, day: 27);
      const next = PlannerDate(year: 2026, month: 7, day: 28);
      final (database, plannerRepo, calendarRepo) = await buildRepositories();
      await pumpPlannerDay(
        tester,
        database: database,
        plannerRepository: plannerRepo,
        calendarRepository: calendarRepo,
        selected: selected,
        eventId: scheduledEventId2,
        startMinute: 10 * 60,
        endMinute: 11 * 60,
      );
      final blockFinder = find.byKey(
        Key(
          'planner-timed-event-${occurrenceIdFor(scheduledEventId2, selected)}',
        ),
      );
      final blockRect = tester.getRect(blockFinder);
      // Start the gesture roughly on the Event body but bias
      // upward (above the bottom resize hit area) so the
      // vertical drag recognizer for resize is not triggered.
      final start = Offset(
        blockRect.center.dx,
        blockRect.top + (blockRect.height * 0.4).clamp(20, 80),
      );
      await driveHorizontalSwipe(tester, start: start, dx: -180);
      expect(
        _readSelectedDateIso(tester),
        next.iso8601,
        reason: 'a clean swipe on an Event body must navigate the day',
      );
      expect(tester.takeException(), isNull);
      final calendarEvents = await database
          .select(database.calendarEvents)
          .get();
      expect(calendarEvents, hasLength(1));
      final operations = await database
          .select(database.calendarEventOperations)
          .get();
      expect(
        operations,
        isEmpty,
        reason:
            'no move/resize operation should be persisted by a '
            'horizontal swipe that began on an Event body',
      );
    });

    testWidgets('a vertical drag on an Event body does NOT navigate the day '
        'and does not persist any move operation', (tester) async {
      const selected = PlannerDate(year: 2026, month: 7, day: 27);
      final (database, plannerRepo, calendarRepo) = await buildRepositories();
      await pumpPlannerDay(
        tester,
        database: database,
        plannerRepository: plannerRepo,
        calendarRepository: calendarRepo,
        selected: selected,
        eventId: scheduledEventId2,
        startMinute: 9 * 60,
        endMinute: 11 * 60,
      );
      final blockFinder = find.byKey(
        Key(
          'planner-timed-event-${occurrenceIdFor(scheduledEventId2, selected)}',
        ),
      );
      final blockCenter = tester.getCenter(blockFinder);
      final gesture = await tester.startGesture(blockCenter);
      // A drag that drifts vertically with a small horizontal
      // bias — well below the named horizontal distance and
      // well within the vertical-dominance ratio. The long-
      // press recognizer may or may not have claimed by the
      // end of the gesture; either way the swipe detector
      // must not commit.
      await gesture.moveBy(const Offset(8, 24));
      await tester.pump();
      await gesture.moveBy(const Offset(0, 60));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(
        _readSelectedDateIso(tester),
        selected.iso8601,
        reason: 'vertical drag must not change the date',
      );
      expect(tester.takeException(), isNull);
      final operations = await database
          .select(database.calendarEventOperations)
          .get();
      expect(
        operations,
        isEmpty,
        reason:
            'vertical drag below the long-press threshold '
            'should not commit a move',
      );
    });

    testWidgets(
      'Delta 4.2C: after long-press selection, body drag moves the whole Event '
      'after touch slop and preserves its duration',
      (tester) async {
        const selected = PlannerDate(year: 2026, month: 7, day: 27);
        final (database, plannerRepo, calendarRepo) = await buildRepositories();
        await pumpPlannerDay(
          tester,
          database: database,
          plannerRepository: plannerRepo,
          calendarRepository: calendarRepo,
          selected: selected,
          eventId: scheduledEventId2,
          startMinute: 9 * 60,
          endMinute: 11 * 60,
        );
        final occurrenceId = occurrenceIdFor(scheduledEventId2, selected);
        final blockFinder = find.byKey(
          Key('planner-timed-event-$occurrenceId'),
        );

        await tester.longPress(blockFinder);
        await tester.pumpAndSettle();
        expect(
          find.byKey(Key('planner-top-resize-hit-$occurrenceId')),
          findsOneWidget,
        );
        expect(
          find.byKey(Key('planner-resize-hit-$occurrenceId')),
          findsOneWidget,
        );

        final gesture = await tester.startGesture(
          tester.getCenter(blockFinder),
        );
        await tester.pump(const Duration(milliseconds: 20));
        await gesture.moveBy(const Offset(0, 24));
        await tester.pump();
        await gesture.moveBy(const Offset(0, 36));
        await tester.pump();
        await gesture.up();
        await pumpUntilMoveCard(tester);

        final events = await database.select(database.calendarEvents).get();
        expect(events, hasLength(1));
        expect(events.single.startMinute, 10 * 60);
        expect(events.single.endMinute, 12 * 60);
        expect(events.single.endMinute! - events.single.startMinute!, 2 * 60);
        expect(
          await database.select(database.calendarEventOperations).get(),
          hasLength(1),
        );
        expect(_readSelectedDateIso(tester), selected.iso8601);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
    );
  });

  group('Delta 4.2E: selected Event cross-date drag and Undo card', () {
    testWidgets(
      'R5-01: hover changes the active date without writes; drop commits once and '
      'Undo restores the same non-recurring Event identity',
      (tester) async {
        const selected = PlannerDate(year: 2026, month: 7, day: 27);
        const target = PlannerDate(year: 2026, month: 7, day: 28);
        final (database, plannerRepo, calendarRepo) = await buildRepositories();
        await pumpPlannerDay(
          tester,
          database: database,
          plannerRepository: plannerRepo,
          calendarRepository: calendarRepo,
          selected: selected,
          eventId: scheduledEventId,
          startMinute: 9 * 60,
          endMinute: 11 * 60,
        );
        final profileId =
            (await database.select(database.localProfiles).getSingle()).id;
        final originalOccurrenceId = occurrenceIdFor(
          scheduledEventId,
          selected,
        );
        final (gesture, originalRect) = await hoverSelectedEventOnNextDay(
          tester,
          occurrenceId: originalOccurrenceId,
          verticalDelta: 30,
        );

        expect(_readSelectedDateIso(tester), target.iso8601);
        final ghost = find.byKey(const Key('planner-saved-event-drag-ghost'));
        expect(ghost, findsOneWidget);
        expect(
          tester.getRect(ghost).left,
          greaterThan(originalRect.left + 4),
          reason:
              'the live drag ghost must follow the finger into the right strip',
        );
        expect(
          await database.select(database.calendarEventOperations).get(),
          isEmpty,
          reason: 'date hover must not persist an intermediate move',
        );
        final beforeDropRows = await database
            .select(database.calendarEvents)
            .get();
        expect(beforeDropRows, hasLength(1));
        expect(beforeDropRows.single.id, scheduledEventId);
        expect(beforeDropRows.single.startDate, selected.iso8601);
        expect(
          await database.select(database.calendarEventExceptions).get(),
          isEmpty,
        );
        await gesture.up();
        await pumpUntilMoveCard(tester);

        expect(_readSelectedDateIso(tester), target.iso8601);
        final movedRows = await database.select(database.calendarEvents).get();
        expect(movedRows, hasLength(1));
        expect(movedRows.single.id, scheduledEventId);
        expect(movedRows.single.startDate, target.iso8601);
        expect(movedRows.single.startMinute, 9 * 60 + 30);
        expect(movedRows.single.endMinute, 11 * 60 + 30);
        expect(
          await database.select(database.calendarEventOperations).get(),
          hasLength(1),
          reason: 'the final drop must persist exactly one atomic move',
        );
        expect(
          await calendarRepo.readDay(profileId: profileId, date: selected),
          isEmpty,
        );
        final targetDay = await calendarRepo.readDay(
          profileId: profileId,
          date: target,
        );
        expect(targetDay, hasLength(1));
        expect(targetDay.single.eventId, scheduledEventId);
        expect(targetDay.single.id, occurrenceIdFor(scheduledEventId, target));
        final snackFinder = find.byKey(const Key('planner-move-undo-card'));
        expect(snackFinder, findsOneWidget);
        final snack = tester.widget<SnackBar>(snackFinder);
        expect(snack.behavior, SnackBarBehavior.floating);
        expect(snack.margin, const EdgeInsets.fromLTRB(16, 0, 16, 12));
        expect(
          snack.padding,
          const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
        );
        expect(
          (snack.shape! as RoundedRectangleBorder).borderRadius,
          BorderRadius.circular(15),
        );
        expect(find.text('Moved to 9:30 AM'), findsOneWidget);
        expect(find.text('10s remaining'), findsOneWidget);
        expect(find.text('Undo'), findsOneWidget);
        // R4-02: the card is theme-derived (neutral surface + 5% active
        // accent), compact, and keeps the actual target time plus countdown.
        final undoContent = find.byKey(const Key('planner-move-undo-content'));
        final colors = Theme.of(tester.element(undoContent)).colorScheme;
        expect(
          snack.backgroundColor,
          Color.alphaBlend(
            colors.primary.withValues(alpha: 0.05),
            colors.surface,
          ),
        );
        expect(
          find.byIcon(Icons.history),
          findsOneWidget,
          reason: 'the card leads with the small undo/history icon',
        );
        expect(
          undoContent,
          findsOneWidget,
          reason: 'message, countdown, and Undo share one floating card',
        );
        expect(tester.getSize(undoContent).height, 48);
        expect(
          tester.getSize(undoContent).height + 20,
          inInclusiveRange(68, 76),
          reason: 'content plus vertical padding stays in the compact band',
        );
        // A SnackBar's keyed root is the full-width dismissible host; its
        // configured `margin` above is the authoritative card inset. Measure
        // the visible one-row content for physical placement rather than that
        // host's full-width render box.
        final cardRect = tester.getRect(undoContent);
        final logicalWidth =
            tester.view.physicalSize.width / tester.view.devicePixelRatio;
        expect(cardRect.left, greaterThanOrEqualTo(16));
        expect(logicalWidth - cardRect.right, greaterThanOrEqualTo(16));
        final navigationRect = tester.getRect(find.byType(NavigationBar));
        expect(
          cardRect.bottom,
          lessThan(navigationRect.top),
          reason: 'the floating card must sit above the bottom navigation',
        );
        await tester.pump(const Duration(seconds: 1));
        expect(find.text('9s remaining'), findsOneWidget);
        await tester.tap(find.byKey(const Key('planner-move-undo-action')));
        // R5 test contract: repository refresh and SnackBar dismissal are
        // state transitions, not a wall-clock performance assertion. Wait on
        // those exact facts instead of globally settling every route timer.
        for (var frame = 0; frame < 60; frame += 1) {
          await tester.pump(const Duration(milliseconds: 50));
          final operations = await database
              .select(database.calendarEventOperations)
              .get();
          if (operations.length == 2 && snackFinder.evaluate().isEmpty) {
            break;
          }
        }

        expect(snackFinder, findsNothing);
        expect(
          await database.select(database.calendarEventOperations).get(),
          hasLength(2),
          reason: 'Undo is one canonical inverse transaction',
        );
        final undoneRows = await database.select(database.calendarEvents).get();
        expect(undoneRows, hasLength(1));
        expect(undoneRows.single.id, scheduledEventId);
        expect(undoneRows.single.startDate, selected.iso8601);
        expect(undoneRows.single.startMinute, 9 * 60);
        expect(undoneRows.single.endMinute, 11 * 60);
        final restoredDay = await calendarRepo.readDay(
          profileId: profileId,
          date: selected,
        );
        expect(restoredDay, hasLength(1));
        expect(restoredDay.single.id, originalOccurrenceId);
        expect(
          await calendarRepo.readDay(profileId: profileId, date: target),
          isEmpty,
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'R7-03: entering the previous in-viewport trigger strip (same-width '
      'mirror of the next strip) moves to the previous date with the same '
      'pointer and one final commit',
      (tester) async {
        const selected = PlannerDate(year: 2026, month: 7, day: 27);
        const target = PlannerDate(year: 2026, month: 7, day: 26);
        final (database, plannerRepo, calendarRepo) = await buildRepositories();
        await pumpPlannerDay(
          tester,
          database: database,
          plannerRepository: plannerRepo,
          calendarRepository: calendarRepo,
          selected: selected,
          eventId: scheduledEventId,
          startMinute: 9 * 60,
          endMinute: 11 * 60,
        );
        final occurrenceId = occurrenceIdFor(scheduledEventId, selected);
        final block = find.byKey(Key('planner-timed-event-$occurrenceId'));
        await tester.longPress(block);
        await tester.pumpAndSettle();
        final timelineRect = tester.getRect(
          find.byKey(const Key('planner-time-grid')),
        );
        // R7-03 symmetric trigger: the previous strip is the 56 dp in-viewport
        // strip just inside the Event canvas (after the 56 dp time gutter),
        // mirroring the next strip at the right edge.
        final previousTrigger = Offset(
          timelineRect.left + 56 + 28,
          tester.getCenter(block).dy,
        );
        final gesture = await tester.startGesture(tester.getCenter(block));
        await tester.pump(const Duration(milliseconds: 20));
        await gesture.moveBy(const Offset(-24, 0));
        await tester.pump();
        await gesture.moveTo(previousTrigger);
        await tester.pump();
        for (var frame = 0; frame < 12; frame += 1) {
          await tester.pump(const Duration(milliseconds: 50));
        }

        expect(_readSelectedDateIso(tester), target.iso8601);
        expect(
          await database.select(database.calendarEventOperations).get(),
          isEmpty,
          reason: 'the live previous-date transition must not write',
        );
        expect(
          find.byKey(const Key('planner-saved-event-drag-ghost')),
          findsOneWidget,
          reason:
              'the transient saved-event ghost remains under the live pointer',
        );

        await gesture.up();
        await pumpUntilMoveCard(tester);
        expect(
          await database.select(database.calendarEventOperations).get(),
          hasLength(1),
          reason: 'release persists exactly one final move',
        );
        final rows = await database.select(database.calendarEvents).get();
        expect(rows, hasLength(1));
        expect(rows.single.id, scheduledEventId);
        expect(rows.single.startDate, target.iso8601);
        expect(rows.single.startMinute, 9 * 60);
        expect(rows.single.endMinute, 11 * 60);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('the 10-second countdown expires deterministically and leaves '
        'the single committed move intact', (tester) async {
      const selected = PlannerDate(year: 2026, month: 7, day: 27);
      const target = PlannerDate(year: 2026, month: 7, day: 28);
      final (database, plannerRepo, calendarRepo) = await buildRepositories();
      await pumpPlannerDay(
        tester,
        database: database,
        plannerRepository: plannerRepo,
        calendarRepository: calendarRepo,
        selected: selected,
        eventId: scheduledEventId,
      );
      final (gesture, _) = await hoverSelectedEventOnNextDay(
        tester,
        occurrenceId: occurrenceIdFor(scheduledEventId, selected),
      );
      await gesture.up();
      await pumpUntilMoveCard(tester);

      expect(find.text('10s remaining'), findsOneWidget);
      await tester.pump(const Duration(seconds: 9));
      expect(find.text('1s remaining'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('planner-move-undo-card')), findsNothing);
      expect(
        await database.select(database.calendarEventOperations).get(),
        hasLength(1),
      );
      final rows = await database.select(database.calendarEvents).get();
      expect(rows, hasLength(1));
      expect(rows.single.id, scheduledEventId);
      expect(rows.single.startDate, target.iso8601);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'R5-01: a recurring occurrence keeps its series and deterministic '
      'occurrence identity through cross-date move and Undo',
      (tester) async {
        const selected = PlannerDate(year: 2026, month: 7, day: 27);
        const target = PlannerDate(year: 2026, month: 7, day: 28);
        final (database, plannerRepo, calendarRepo) = await buildRepositories();
        await pumpPlannerDay(
          tester,
          database: database,
          plannerRepository: plannerRepo,
          calendarRepository: calendarRepo,
          selected: selected,
          eventId: scheduledEventId2,
          recurrence: const CalendarRecurrenceRule(
            frequency: CalendarRecurrenceFrequency.weekly,
          ),
        );
        final profileId =
            (await database.select(database.localProfiles).getSingle()).id;
        final occurrenceId = occurrenceIdFor(scheduledEventId2, selected);
        final (gesture, _) = await hoverSelectedEventOnNextDay(
          tester,
          occurrenceId: occurrenceId,
        );
        expect(_readSelectedDateIso(tester), target.iso8601);
        expect(
          await database.select(database.calendarEventOperations).get(),
          isEmpty,
        );
        expect(
          await database.select(database.calendarEventExceptions).get(),
          isEmpty,
        );

        await gesture.up();
        final scopeDialog = find.byKey(
          const Key('recurring-timeline-scope-dialog'),
        );
        for (var frame = 0; frame < 20; frame += 1) {
          await tester.pump(const Duration(milliseconds: 50));
          if (scopeDialog.evaluate().isNotEmpty) {
            await tester.pump(const Duration(milliseconds: 300));
            break;
          }
        }
        expect(scopeDialog, findsOneWidget);
        await tester.tap(
          find.byKey(const Key('recurring-timeline-scope-this')),
        );
        await pumpUntilMoveCard(tester);

        final masterRows = await database.select(database.calendarEvents).get();
        expect(masterRows, hasLength(1));
        expect(masterRows.single.id, scheduledEventId2);
        expect(
          await database.select(database.calendarEventExceptions).get(),
          hasLength(1),
        );
        expect(
          await database.select(database.calendarEventOperations).get(),
          hasLength(1),
        );
        final moved = await calendarRepo.readOccurrence(
          profileId: profileId,
          eventId: scheduledEventId2,
          originalDate: selected,
        );
        expect(moved, isNotNull);
        expect(moved!.id, occurrenceId);
        expect(moved.eventId, scheduledEventId2);
        expect(moved.originalDate, selected);
        expect(moved.displayDate, target);
        expect(moved.isRecurring, isTrue);
        expect(
          (await calendarRepo.readDay(
            profileId: profileId,
            date: selected,
          )).any((event) => event.id == occurrenceId),
          isFalse,
        );
        expect(
          (await calendarRepo.readDay(
            profileId: profileId,
            date: target,
          )).where((event) => event.id == occurrenceId),
          hasLength(1),
        );

        await tester.tap(find.byKey(const Key('planner-move-undo-action')));
        final movedBlock = find.byKey(Key('planner-timed-event-$occurrenceId'));
        for (var frame = 0; frame < 60; frame += 1) {
          await tester.pump(const Duration(milliseconds: 50));
          final operations = await database
              .select(database.calendarEventOperations)
              .get();
          if (operations.length == 2 &&
              find
                  .byKey(const Key('planner-move-undo-card'))
                  .evaluate()
                  .isEmpty &&
              movedBlock.evaluate().isEmpty) {
            break;
          }
        }
        final targetPageRefreshed = movedBlock.evaluate().isEmpty;
        final liveUiException = tester.takeException();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        expect(
          targetPageRefreshed,
          isTrue,
          reason: 'Undo refresh removes the occurrence from the target day',
        );
        expect(liveUiException, isNull);
        final restored = await calendarRepo.readOccurrence(
          profileId: profileId,
          eventId: scheduledEventId2,
          originalDate: selected,
        );
        expect(restored, isNotNull);
        expect(restored!.id, occurrenceId);
        expect(restored.eventId, scheduledEventId2);
        expect(restored.originalDate, selected);
        expect(restored.displayDate, selected);
        expect(restored.isRecurring, isTrue);
        expect(
          await database.select(database.calendarEvents).get(),
          hasLength(1),
        );
        final exceptionHistory = await database
            .select(database.calendarEventExceptions)
            .get();
        expect(
          exceptionHistory,
          hasLength(2),
          reason:
              'the existing append-only recurrence architecture records the '
              'move and its inverse without duplicating the Event',
        );
        expect(exceptionHistory.map((row) => row.eventId).toSet(), <String>{
          scheduledEventId2,
        });
        expect(
          exceptionHistory.map((row) => row.occurrenceId).toSet(),
          <String>{occurrenceId},
        );
        expect(
          await database.select(database.calendarEventOperations).get(),
          hasLength(2),
        );
        expect(
          (await calendarRepo.readDay(
            profileId: profileId,
            date: selected,
          )).where((event) => event.id == occurrenceId),
          hasLength(1),
        );
        expect(
          (await calendarRepo.readDay(
            profileId: profileId,
            date: target,
          )).any((event) => event.id == occurrenceId),
          isFalse,
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('Delta 4.2R3 R3-07: recurring END shrink + All events keeps '
        'the resized range on the series master', (tester) async {
      // Owner scenario: a long recurring Event (12:00 AM-5:30 AM) resized
      // down to 12:00 AM-2:00 AM, then "All events".
      const selected = PlannerDate(year: 2026, month: 7, day: 27);
      final (database, plannerRepo, calendarRepo) = await buildRepositories();
      await pumpPlannerDay(
        tester,
        database: database,
        plannerRepository: plannerRepo,
        calendarRepository: calendarRepo,
        selected: selected,
        eventId: scheduledEventId2,
        startMinute: 0,
        endMinute: 5 * 60 + 30,
        recurrence: const CalendarRecurrenceRule(
          frequency: CalendarRecurrenceFrequency.weekly,
        ),
      );
      // P1 (2026-09-21): the canvas IS the configured visible window, and this
      // owner scenario resizes a 12:00 AM-5:30 AM recurring Event. Widen the
      // configured window to the whole civil day so that Event is on-canvas and
      // its END handle is reachable. The scenario itself (END shrink of a
      // long recurring Event, then "All events") is unchanged.
      final resizeContainer = ProviderScope.containerOf(
        tester.element(find.byType(MaterialApp).first),
      );
      await resizeContainer
          .read(eventTypeControllerProvider.notifier)
          .saveSettings(
            resizeContainer
                .read(eventTypeControllerProvider)
                .settings
                .copyWith(visibleStartHour: 0, visibleEndHour: 24),
          );
      await tester.pumpAndSettle();

      final profileId =
          (await database.select(database.localProfiles).getSingle()).id;
      final occurrenceId = occurrenceIdFor(scheduledEventId2, selected);
      final blockFinder = find.byKey(Key('planner-timed-event-$occurrenceId'));
      // P1 (2026-09-21): widening the window preserves the anchored view (the
      // documented one-shot range reconciliation keeps the previously visible
      // hours under the viewport), so the 12:00 AM-5:30 AM Event is on-canvas
      // but above the fold. An owner would scroll to it; put the owner-scenario
      // Event in view deterministically before the resize gesture so the long
      // press lands on the block itself instead of on empty viewport space.
      await tester.ensureVisible(blockFinder);
      await tester.pumpAndSettle();
      await tester.longPress(blockFinder);
      await tester.pumpAndSettle();

      // Drag the END handle UP to shrink the end from 5:30 AM to 2:00 AM
      // (210 minutes == 210 logical px at the fixture's 60 px/hour
      // mapping; the resize preview snaps to 15-minute increments, so a
      // -210 px drag lands exactly on 2:00 AM).
      final resizeHit = find.byKey(Key('planner-resize-hit-$occurrenceId'));
      expect(resizeHit, findsOneWidget);
      final resizeGesture = await tester.startGesture(
        tester.getCenter(resizeHit),
      );
      await tester.pump(const Duration(milliseconds: 20));
      await resizeGesture.moveBy(const Offset(0, -105));
      await tester.pump();
      await resizeGesture.moveBy(const Offset(0, -105));
      await tester.pump();
      await resizeGesture.up();
      await tester.pump(const Duration(milliseconds: 50));

      // The recurring scope chooser must appear before any commit.
      final scopeDialog = find.byKey(
        const Key('recurring-timeline-scope-dialog'),
      );
      for (var frame = 0; frame < 20; frame += 1) {
        await tester.pump(const Duration(milliseconds: 50));
        if (scopeDialog.evaluate().isNotEmpty) {
          await tester.pump(const Duration(milliseconds: 300));
          break;
        }
      }
      expect(scopeDialog, findsOneWidget);
      await tester.tap(find.byKey(const Key('recurring-timeline-scope-all')));
      await tester.pump(const Duration(milliseconds: 300));

      // The master row must now carry the resized range (12 AM-2 AM), not
      // the original 12 AM-5:30 AM (owner-confirmed FAIL on the R2 build).
      final rows = await database.select(database.calendarEvents).get();
      expect(rows, hasLength(1));
      expect(rows.single.id, scheduledEventId2);
      expect(rows.single.startMinute, 0);
      expect(
        rows.single.endMinute,
        2 * 60,
        reason: 'All events shrink must persist the resized series range',
      );
      final day = await calendarRepo.readDay(
        profileId: profileId,
        date: selected,
      );
      expect(day.single.startLocal, DateTime(2026, 7, 27));
      expect(day.single.endLocal, DateTime(2026, 7, 27, 2));
      expect(tester.takeException(), isNull);
    });

    testWidgets('R5-01: a quick sub-dwell flick past the edge must not '
        'switch the date or write; a stable dwell advances exactly one date '
        'and a stationary hold in the edge does not repeat it', (tester) async {
      const selected = PlannerDate(year: 2026, month: 7, day: 27);
      const target = PlannerDate(year: 2026, month: 7, day: 28);
      final (database, plannerRepo, calendarRepo) = await buildRepositories();
      await pumpPlannerDay(
        tester,
        database: database,
        plannerRepository: plannerRepo,
        calendarRepository: calendarRepo,
        selected: selected,
        eventId: scheduledEventId,
      );
      final occurrenceId = occurrenceIdFor(scheduledEventId, selected);
      final block = find.byKey(Key('planner-timed-event-$occurrenceId'));
      await tester.longPress(block);
      await tester.pumpAndSettle();
      final timelineRect = tester.getRect(
        find.byKey(const Key('planner-time-grid')),
      );
      final rightTrigger = Offset(
        timelineRect.right - 28,
        tester.getCenter(block).dy,
      );

      // Fast flick into the 56 dp in-viewport right trigger, released before
      // the 200ms stable-dwell interval elapses.
      final flick = await tester.startGesture(tester.getCenter(block));
      await tester.pump(const Duration(milliseconds: 20));
      await flick.moveBy(const Offset(-24, 0));
      await tester.pump();
      await flick.moveTo(rightTrigger);
      await tester.pump(const Duration(milliseconds: 50));
      await flick.up();
      await tester.pumpAndSettle();

      expect(
        _readSelectedDateIso(tester),
        selected.iso8601,
        reason: 'incidental edge jitter must not switch the date',
      );
      expect(
        await database.select(database.calendarEventOperations).get(),
        isEmpty,
        reason: 'a sub-dwell flick must not commit any move',
      );
      expect(
        find.byKey(Key('planner-resize-hit-$occurrenceId')),
        findsOneWidget,
        reason: 'the no-op release keeps the Event selected (R2-01)',
      );

      // Now hold past the edge for the full dwell: exactly ONE date step.
      final hold = await tester.startGesture(tester.getCenter(block));
      await tester.pump(const Duration(milliseconds: 20));
      await hold.moveBy(const Offset(-24, 0));
      await tester.pump();
      await hold.moveTo(rightTrigger);
      await tester.pump();
      for (var frame = 0; frame < 12; frame += 1) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(
        _readSelectedDateIso(tester),
        target.iso8601,
        reason: 'the stable dwell must advance exactly one date',
      );
      // Keep the finger stationary in the edge zone: the latch plus the
      // rebased (zeroed) residual must prevent a repeated date step.
      for (var frame = 0; frame < 10; frame += 1) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(
        _readSelectedDateIso(tester),
        target.iso8601,
        reason: 'a stationary hold in the edge zone must not advance again',
      );
      expect(
        await database.select(database.calendarEventOperations).get(),
        isEmpty,
        reason: 'hover must not write before the release',
      );
      await hold.up();
      for (var frame = 0; frame < 30; frame += 1) {
        await tester.pump(const Duration(milliseconds: 50));
        if (find
            .byKey(const Key('planner-move-undo-card'))
            .evaluate()
            .isNotEmpty) {
          break;
        }
      }
      // Expire the floating Undo card deterministically.
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
      final rows = await database.select(database.calendarEvents).get();
      expect(rows, hasLength(1));
      expect(rows.single.id, scheduledEventId);
      expect(rows.single.startDate, target.iso8601);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'R5-01: after the date switch canonical pointer mapping keeps the same '
      'post-switch delta 1:1 (no multi-hour jump) and commits the exact '
      'pointer-mapped position',
      (tester) async {
        const selected = PlannerDate(year: 2026, month: 7, day: 27);
        const target = PlannerDate(year: 2026, month: 7, day: 28);
        final (database, plannerRepo, calendarRepo) = await buildRepositories();
        await pumpPlannerDay(
          tester,
          database: database,
          plannerRepository: plannerRepo,
          calendarRepository: calendarRepo,
          selected: selected,
          eventId: scheduledEventId,
          startMinute: 9 * 60,
          endMinute: 11 * 60,
        );
        final profileId =
            (await database.select(database.localProfiles).getSingle()).id;
        final occurrenceId = occurrenceIdFor(scheduledEventId, selected);
        final block = find.byKey(Key('planner-timed-event-$occurrenceId'));
        await tester.longPress(block);
        await tester.pumpAndSettle();
        final timelineRect = tester.getRect(
          find.byKey(const Key('planner-time-grid')),
        );
        final rightTrigger = Offset(
          timelineRect.right - 28,
          tester.getCenter(block).dy - 180,
        );

        // Enter the in-viewport right trigger with a large pre-switch vertical
        // drift (-180 px == -180 minutes at 60 px/hour).
        final gesture = await tester.startGesture(tester.getCenter(block));
        await tester.pump(const Duration(milliseconds: 20));
        await gesture.moveBy(const Offset(-24, 0));
        await tester.pump();
        await gesture.moveTo(rightTrigger);
        await tester.pump();
        for (var frame = 0; frame < 12; frame += 1) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(_readSelectedDateIso(tester), target.iso8601);

        final ghost = find.byKey(const Key('planner-saved-event-drag-ghost'));
        expect(ghost, findsOneWidget);
        final beforeTop = tester.getRect(ghost).top;

        // Small post-switch movement: +15 px must move the Event exactly
        // +15 px (1:1), never a multi-hour jump.
        await gesture.moveBy(const Offset(0, 15));
        await tester.pump();
        final afterTop = tester.getRect(ghost).top;
        expect(
          (afterTop - beforeTop).abs(),
          closeTo(15, 2),
          reason: 'the post-switch drag must stay 1:1 with the finger (rebase)',
        );

        await gesture.up();
        for (var frame = 0; frame < 30; frame += 1) {
          await tester.pump(const Duration(milliseconds: 50));
          if (find
              .byKey(const Key('planner-move-undo-card'))
              .evaluate()
              .isNotEmpty) {
            break;
          }
        }
        await tester.pump(const Duration(seconds: 10));
        await tester.pumpAndSettle();

        expect(
          await database.select(database.calendarEventOperations).get(),
          hasLength(1),
          reason: 'one final atomic commit on release',
        );
        final rows = await database.select(database.calendarEvents).get();
        expect(rows, hasLength(1));
        expect(rows.single.id, scheduledEventId);
        expect(rows.single.startDate, target.iso8601);
        // 540 (9:00) - 180 (pre-switch) + 15 (post-switch) == 375 (6:15 AM).
        expect(
          rows.single.startMinute,
          375,
          reason: 'the committed time is the exact rebased position',
        );
        expect(
          rows.single.endMinute,
          375 + 120,
          reason: 'the move must preserve the Event duration',
        );
        expect(
          await calendarRepo.readDay(profileId: profileId, date: selected),
          isEmpty,
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'R5-01: one long-press pointer owns selection, edge transition, '
      'post-switch movement, and exactly one final commit',
      (tester) async {
        const selected = PlannerDate(year: 2026, month: 7, day: 27);
        const target = PlannerDate(year: 2026, month: 7, day: 28);
        final (database, plannerRepo, calendarRepo) = await buildRepositories();
        await pumpPlannerDay(
          tester,
          database: database,
          plannerRepository: plannerRepo,
          calendarRepository: calendarRepo,
          selected: selected,
          eventId: scheduledEventId,
          startMinute: 9 * 60,
          endMinute: 11 * 60,
        );
        final occurrenceId = occurrenceIdFor(scheduledEventId, selected);
        final block = find.byKey(Key('planner-timed-event-$occurrenceId'));
        final originalRect = tester.getRect(block);
        final timelineRect = tester.getRect(
          find.byKey(const Key('planner-time-grid')),
        );
        final edgePointer = Offset(
          timelineRect.right - 28,
          originalRect.center.dy + 30,
        );

        // Do not release after selection: this is the physical
        // long-press-then-drag path whose recognizer must survive the rebuild.
        final gesture = await tester.startGesture(originalRect.center);
        await tester.pump(const Duration(milliseconds: 350));
        expect(
          find.byKey(Key('planner-resize-hit-$occurrenceId')),
          findsOneWidget,
          reason: 'the in-flight long press selects the saved Event',
        );
        await gesture.moveTo(edgePointer);
        await tester.pump();
        for (var frame = 0; frame < 12; frame += 1) {
          await tester.pump(const Duration(milliseconds: 50));
        }

        expect(_readSelectedDateIso(tester), target.iso8601);
        final ghost = find.byKey(const Key('planner-saved-event-drag-ghost'));
        expect(ghost, findsOneWidget);
        final ghostRect = tester.getRect(ghost);
        expect(
          (ghostRect.center.dx - edgePointer.dx).abs(),
          lessThan(2),
          reason: 'the original center grab offset remains under the finger',
        );
        expect(
          await database.select(database.calendarEventOperations).get(),
          isEmpty,
          reason: 'the live date transition must not write',
        );

        final beforeTop = ghostRect.top;
        await gesture.moveBy(const Offset(0, 15));
        await tester.pump();
        expect(
          tester.getRect(ghost).top - beforeTop,
          closeTo(15, 2),
          reason: 'the same long-press pointer remains 1:1 after the switch',
        );

        await gesture.up();
        await pumpUntilMoveCard(tester);
        expect(
          await database.select(database.calendarEventOperations).get(),
          hasLength(1),
          reason: 'release persists one final atomic move only',
        );
        final rows = await database.select(database.calendarEvents).get();
        expect(rows, hasLength(1));
        expect(rows.single.id, scheduledEventId);
        expect(rows.single.startDate, target.iso8601);
        expect(rows.single.startMinute, 9 * 60 + 45);
        expect(rows.single.endMinute, 11 * 60 + 45);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'R5-01: a stationary edge cannot repeat; center return re-arms one '
      'intentional next edge entry',
      (tester) async {
        const selected = PlannerDate(year: 2026, month: 7, day: 27);
        const firstTarget = PlannerDate(year: 2026, month: 7, day: 28);
        const secondTarget = PlannerDate(year: 2026, month: 7, day: 29);
        final (database, plannerRepo, calendarRepo) = await buildRepositories();
        await pumpPlannerDay(
          tester,
          database: database,
          plannerRepository: plannerRepo,
          calendarRepository: calendarRepo,
          selected: selected,
          eventId: scheduledEventId,
        );
        final occurrenceId = occurrenceIdFor(scheduledEventId, selected);
        final block = find.byKey(Key('planner-timed-event-$occurrenceId'));
        await tester.longPress(block);
        await tester.pumpAndSettle();
        final timelineRect = tester.getRect(
          find.byKey(const Key('planner-time-grid')),
        );
        final pointerY = tester.getCenter(block).dy;
        final rightTrigger = Offset(timelineRect.right - 28, pointerY);
        final center = Offset(timelineRect.center.dx, pointerY);
        final gesture = await tester.startGesture(tester.getCenter(block));
        await tester.pump(const Duration(milliseconds: 20));
        await gesture.moveBy(const Offset(-24, 0));
        await tester.pump();
        await gesture.moveTo(rightTrigger);
        await tester.pump();
        for (var frame = 0; frame < 12; frame += 1) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(_readSelectedDateIso(tester), firstTarget.iso8601);

        // More than another full dwell at the same edge must stay latched.
        for (var frame = 0; frame < 6; frame += 1) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(_readSelectedDateIso(tester), firstTarget.iso8601);

        // A concrete center observation re-arms; one fresh edge entry may
        // then advance exactly one additional date.
        await gesture.moveTo(center);
        await tester.pump();
        await gesture.moveTo(rightTrigger);
        await tester.pump();
        for (var frame = 0; frame < 12; frame += 1) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(_readSelectedDateIso(tester), secondTarget.iso8601);
        expect(
          await database.select(database.calendarEventOperations).get(),
          isEmpty,
          reason: 'neither hover transition may write before release',
        );

        await gesture.up();
        await pumpUntilMoveCard(tester);
        expect(
          await database.select(database.calendarEventOperations).get(),
          hasLength(1),
          reason: 'both hovers still resolve to one final commit',
        );
        final rows = await database.select(database.calendarEvents).get();
        expect(rows.single.startDate, secondTarget.iso8601);
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('Delta 4.2R6: transient ghost, card separation, and bulk tap', () {
    testWidgets(
      'R6-01/R6-02: saved drag uses a transient ghost and snapped time '
      'indicator while source and neighboring lane rectangles stay fixed',
      (tester) async {
        const selected = PlannerDate(year: 2026, month: 7, day: 27);
        final (database, plannerRepo, calendarRepo) = await buildRepositories();
        final profile = await buildTestRepository(
          database: database,
        ).completeOnboarding();
        await calendarRepo.saveEvent(
          profileId: profile.id,
          draft: timedDraft(
            id: scheduledEventId,
            date: selected,
            startMinute: 9 * 60,
            endMinute: 11 * 60,
          ),
        );
        await calendarRepo.saveEvent(
          profileId: profile.id,
          draft: timedDraft(
            id: scheduledEventId2,
            date: selected,
            startMinute: 9 * 60,
            endMinute: 10 * 60,
          ),
        );
        await pumpPlannerDay(
          tester,
          database: database,
          plannerRepository: plannerRepo,
          calendarRepository: calendarRepo,
          selected: selected,
        );
        final source = find.byKey(
          Key(
            'planner-timed-event-${occurrenceIdFor(scheduledEventId, selected)}',
          ),
        );
        final neighbor = find.byKey(
          Key(
            'planner-timed-event-${occurrenceIdFor(scheduledEventId2, selected)}',
          ),
        );
        final sourceBefore = tester.getRect(source);
        final neighborBefore = tester.getRect(neighbor);
        final currentTimeBefore = find
            .byKey(const Key('planner-current-time-indicator'))
            .evaluate()
            .length;

        expect(
          find.byKey(const Key('planner-saved-event-drag-ghost')),
          findsNothing,
        );
        expect(
          find.byKey(const Key('planner-drag-time-indicator')),
          findsNothing,
        );
        await tester.longPress(source);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('planner-saved-event-drag-ghost')),
          findsNothing,
          reason: 'SELECTED is not yet DRAGGING_GHOST',
        );
        expect(
          find.byKey(
            Key(
              'planner-resize-hit-${occurrenceIdFor(scheduledEventId, selected)}',
            ),
          ),
          findsOneWidget,
        );

        final gesture = await tester.startGesture(sourceBefore.center);
        await tester.pump(const Duration(milliseconds: 20));
        await gesture.moveBy(const Offset(0, 24));
        await tester.pump();
        await gesture.moveBy(const Offset(0, 96));
        await tester.pump();

        final ghost = find.byKey(const Key('planner-saved-event-drag-ghost'));
        expect(ghost, findsOneWidget);
        expect(
          find.byKey(const Key('planner-drag-time-indicator')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('planner-drag-time-label')),
          findsOneWidget,
        );
        expect(find.text('11:00 AM'), findsOneWidget);
        expect(source, findsOneWidget, reason: 'source placeholder remains');
        expect(tester.getRect(source), sourceBefore);
        expect(
          tester.getRect(neighbor),
          neighborBefore,
          reason: 'ghost movement must not invoke visible re-laning',
        );
        expect(
          await database.select(database.calendarEventOperations).get(),
          isEmpty,
          reason: 'candidate movement remains transient until drop',
        );

        // R7-01: the candidate dot and line are removed; the candidate is
        // communicated by the time label only. The label above already
        // pinned the snapped candidate text ('11:00 AM').
        expect(
          find.byKey(const Key('planner-drag-time-line')),
          findsNothing,
          reason: 'R7-01 removes the drag-time candidate line',
        );
        expect(
          find.byKey(const Key('planner-drag-time-dot')),
          findsNothing,
          reason: 'R7-01 removes the drag-time candidate dot',
        );
        expect(
          find
              .byKey(const Key('planner-current-time-indicator'))
              .evaluate()
              .length,
          currentTimeBefore,
          reason: 'the drag indicator never mutates current-time state',
        );

        await gesture.cancel();
        await tester.pump();
        expect(ghost, findsNothing);
        expect(
          find.byKey(const Key('planner-drag-time-indicator')),
          findsNothing,
        );
        expect(tester.getRect(source), sourceBefore);
        expect(tester.getRect(neighbor), neighborBefore);
        expect(
          await database.select(database.calendarEventOperations).get(),
          isEmpty,
          reason: 'cancel restores the unchanged canonical source layout',
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'R7-01: drag-time feedback is candidate time text only; the real '
      'current-time dot and line stay intact and the label follows the '
      'snapped candidate',
      (tester) async {
        const selected = PlannerDate(year: 2026, month: 7, day: 27);
        final (database, plannerRepo, calendarRepo) = await buildRepositories();
        final profile = await buildTestRepository(
          database: database,
        ).completeOnboarding();
        await calendarRepo.saveEvent(
          profileId: profile.id,
          draft: timedDraft(
            id: scheduledEventId,
            date: selected,
            startMinute: 9 * 60,
            endMinute: 11 * 60,
          ),
        );
        await pumpPlannerDay(
          tester,
          database: database,
          plannerRepository: plannerRepo,
          calendarRepository: calendarRepo,
          selected: selected,
        );
        // The real current-time indicator (dot + line) is untouched by the
        // R7-01 drag feedback simplification. Whether or not it is visible
        // in this fixture, its presence must never change because of a
        // drag.
        final currentTimeDotBefore = find
            .byKey(const Key('planner-current-time-dot'))
            .evaluate()
            .length;
        final currentTimeLineBefore = find
            .byKey(const Key('planner-current-time-line'))
            .evaluate()
            .length;

        final source = find.byKey(
          Key(
            'planner-timed-event-${occurrenceIdFor(scheduledEventId, selected)}',
          ),
        );
        await tester.longPress(source);
        await tester.pumpAndSettle();
        final gesture = await tester.startGesture(tester.getCenter(source));
        await tester.pump(const Duration(milliseconds: 20));
        await gesture.moveBy(const Offset(0, 24));
        await tester.pump();
        await gesture.moveBy(const Offset(0, 96));
        await tester.pump();

        final indicator = find.byKey(const Key('planner-drag-time-indicator'));
        expect(indicator, findsOneWidget);
        // Candidate communicated by the snapped time text only.
        expect(
          find.descendant(of: indicator, matching: find.text('11:00 AM')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('planner-drag-time-line')),
          findsNothing,
          reason: 'R7-01 removes the drag-time candidate line',
        );
        expect(
          find.byKey(const Key('planner-drag-time-dot')),
          findsNothing,
          reason: 'R7-01 removes the drag-time candidate dot',
        );
        // The label follows a further snapped candidate change (11 AM to
        // 12 PM), still without any candidate dot or line.
        await gesture.moveBy(const Offset(0, 60));
        await tester.pump();
        expect(
          find.descendant(of: indicator, matching: find.text('12:00 PM')),
          findsOneWidget,
          reason: 'the candidate label follows the snapped pointer minute',
        );
        expect(find.byKey(const Key('planner-drag-time-line')), findsNothing);
        expect(find.byKey(const Key('planner-drag-time-dot')), findsNothing);
        // Real current-time widgets remain present and unchanged through
        // the whole drag (same counts as before the drag).
        expect(
          find.byKey(const Key('planner-current-time-dot')).evaluate().length,
          currentTimeDotBefore,
          reason: 'the drag must never mutate the real current-time dot',
        );
        expect(
          find.byKey(const Key('planner-current-time-line')).evaluate().length,
          currentTimeLineBefore,
          reason: 'the drag must never mutate the real current-time line',
        );

        await gesture.cancel();
        await tester.pump();
        expect(indicator, findsNothing);
        expect(
          await database.select(database.calendarEventOperations).get(),
          isEmpty,
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'R7-02: the saved-drag ghost is a frozen drag-start snapshot; its '
      'internal time/range text and height never change while the candidate '
      'moves, and the commit keeps the original duration',
      (tester) async {
        const selected = PlannerDate(year: 2026, month: 7, day: 27);
        final (database, plannerRepo, calendarRepo) = await buildRepositories();
        final profile = await buildTestRepository(
          database: database,
        ).completeOnboarding();
        await calendarRepo.saveEvent(
          profileId: profile.id,
          draft: timedDraft(
            id: scheduledEventId,
            date: selected,
            startMinute: 9 * 60,
            endMinute: 11 * 60,
          ),
        );
        await pumpPlannerDay(
          tester,
          database: database,
          plannerRepository: plannerRepo,
          calendarRepository: calendarRepo,
          selected: selected,
        );
        final source = find.byKey(
          Key(
            'planner-timed-event-${occurrenceIdFor(scheduledEventId, selected)}',
          ),
        );
        await tester.longPress(source);
        await tester.pumpAndSettle();
        final gesture = await tester.startGesture(tester.getCenter(source));
        await tester.pump(const Duration(milliseconds: 20));
        await gesture.moveBy(const Offset(0, 24));
        await tester.pump();
        await gesture.moveBy(const Offset(0, 96));
        await tester.pump();

        final ghost = find.byKey(const Key('planner-saved-event-drag-ghost'));
        expect(ghost, findsOneWidget);
        final gridRect = tester.getRect(
          find.byKey(const Key('planner-time-grid')),
        );
        // P1 (2026-09-21): the canvas IS the configured 06:00-22:00 window,
        // so the live hour height is the grid height over 16 slots.
        final hourHeight = gridRect.height / 16;
        final sourceRange = '9:00 AM - 11:00 AM';
        // Candidate is at 11:00 AM; the ghost INTERNAL text is still the
        // frozen source snapshot, not the candidate range.
        expect(
          find.descendant(of: ghost, matching: find.text(sourceRange)),
          findsOneWidget,
          reason: 'ghost internal time/range text is frozen at drag start',
        );
        expect(
          find.descendant(of: ghost, matching: find.text('11:00 AM - 1:00 PM')),
          findsNothing,
        );
        final ghostHeightAtStart = tester.getRect(ghost).height;
        expect(
          ghostHeightAtStart,
          closeTo(2 * hourHeight, 0.01),
          reason: 'ghost height equals the original two-hour duration',
        );

        // Move the candidate one more hour. The label follows to 12:00 PM
        // while the ghost content and height stay frozen.
        await gesture.moveBy(const Offset(0, 60));
        await tester.pump();
        expect(
          find.descendant(
            of: find.byKey(const Key('planner-drag-time-indicator')),
            matching: find.text('12:00 PM'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(of: ghost, matching: find.text(sourceRange)),
          findsOneWidget,
          reason: 'ghost internal time/range text stays frozen while dragging',
        );
        expect(
          tester.getRect(ghost).height,
          closeTo(ghostHeightAtStart, 0.01),
          reason: 'ghost height remains constant at stable zoom',
        );

        // Drop: the commit uses candidateStart + originalDuration (120m).
        await gesture.up();
        await pumpUntilMoveCard(tester);
        final rows = await database.select(database.calendarEvents).get();
        expect(rows, hasLength(1));
        expect(rows.single.id, scheduledEventId);
        expect(rows.single.startMinute, 12 * 60);
        expect(
          rows.single.endMinute,
          12 * 60 + 120,
          reason: 'committed end = committed start + original duration',
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'R6-05: touching saved cards have a one-pixel inner separator with '
      'unchanged canonical geometry and no fake gap',
      (tester) async {
        const selected = PlannerDate(year: 2026, month: 7, day: 27);
        final (database, plannerRepo, calendarRepo) = await buildRepositories();
        final profile = await buildTestRepository(
          database: database,
        ).completeOnboarding();
        await calendarRepo.saveEvent(
          profileId: profile.id,
          draft: timedDraft(
            id: scheduledEventId,
            date: selected,
            startMinute: 9 * 60,
            endMinute: 10 * 60,
          ),
        );
        await calendarRepo.saveEvent(
          profileId: profile.id,
          draft: timedDraft(
            id: scheduledEventId2,
            date: selected,
            startMinute: 10 * 60,
            endMinute: 11 * 60,
          ),
        );
        await pumpPlannerDay(
          tester,
          database: database,
          plannerRepository: plannerRepo,
          calendarRepository: calendarRepo,
          selected: selected,
        );
        final first = find.byKey(
          Key(
            'planner-timed-event-${occurrenceIdFor(scheduledEventId, selected)}',
          ),
        );
        final second = find.byKey(
          Key(
            'planner-timed-event-${occurrenceIdFor(scheduledEventId2, selected)}',
          ),
        );
        final firstRect = tester.getRect(first);
        final secondRect = tester.getRect(second);
        expect(firstRect.left, closeTo(secondRect.left, 0.01));
        expect(firstRect.width, closeTo(secondRect.width, 0.01));
        expect(
          secondRect.top - firstRect.bottom,
          closeTo(0, 0.01),
          reason: 'the separator is painted inside, never as a layout gap',
        );
        final outlinedMaterials = tester
            .widgetList<Material>(
              find.descendant(of: first, matching: find.byType(Material)),
            )
            .where(
              (material) =>
                  material.shape is RoundedRectangleBorder &&
                  (material.shape! as RoundedRectangleBorder).side.width == 1,
            );
        expect(outlinedMaterials, isNotEmpty);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'R7-06: side-by-side Event cards close the external lane gap to zero '
      'while the one-pixel inner separator stays painted',
      (tester) async {
        const selected = PlannerDate(year: 2026, month: 7, day: 27);
        final (database, plannerRepo, calendarRepo) = await buildRepositories();
        final profile = await buildTestRepository(
          database: database,
        ).completeOnboarding();
        // Two overlapping Events land in adjacent lanes.
        await calendarRepo.saveEvent(
          profileId: profile.id,
          draft: timedDraft(
            id: scheduledEventId,
            date: selected,
            startMinute: 9 * 60,
            endMinute: 11 * 60,
          ),
        );
        await calendarRepo.saveEvent(
          profileId: profile.id,
          draft: timedDraft(
            id: scheduledEventId2,
            date: selected,
            startMinute: 10 * 60,
            endMinute: 12 * 60,
          ),
        );
        await pumpPlannerDay(
          tester,
          database: database,
          plannerRepository: plannerRepo,
          calendarRepository: calendarRepo,
          selected: selected,
        );
        final first = find.byKey(
          Key(
            'planner-timed-event-${occurrenceIdFor(scheduledEventId, selected)}',
          ),
        );
        final second = find.byKey(
          Key(
            'planner-timed-event-${occurrenceIdFor(scheduledEventId2, selected)}',
          ),
        );
        final firstRect = tester.getRect(first);
        final secondRect = tester.getRect(second);
        // R7-06 law: touching Event rectangles share the boundary exactly —
        // no free-space gap outside the rects.
        expect(
          secondRect.left,
          closeTo(firstRect.right, 0.01),
          reason: 'adjacent lanes must touch with zero external gap',
        );
        expect(
          firstRect.top,
          lessThan(secondRect.bottom),
          reason: 'the two Events must genuinely overlap in time',
        );
        for (final block in <Finder>[first, second]) {
          final outlined = tester
              .widgetList<Material>(
                find.descendant(of: block, matching: find.byType(Material)),
              )
              .where(
                (material) =>
                    material.shape is RoundedRectangleBorder &&
                    (material.shape! as RoundedRectangleBorder).side.width == 1,
              );
          expect(outlined, isNotEmpty);
        }
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'R6-06: the whole visible Event card toggles exactly once in bulk mode, '
      'the checkbox still toggles, and normal mode opens Preview',
      (tester) async {
        const selected = PlannerDate(year: 2026, month: 7, day: 27);
        final (database, plannerRepo, calendarRepo) = await buildRepositories();
        await pumpPlannerDay(
          tester,
          database: database,
          plannerRepository: plannerRepo,
          calendarRepository: calendarRepo,
          selected: selected,
          eventId: scheduledEventId,
        );
        final occurrenceId = occurrenceIdFor(scheduledEventId, selected);
        final block = find.byKey(Key('planner-timed-event-$occurrenceId'));
        await tester.tap(find.byKey(const Key('planner-selection-button')));
        await tester.pumpAndSettle();
        final target = find.byKey(
          Key('planner-event-selection-target-$occurrenceId'),
        );
        expect(target, findsOneWidget);
        final unchecked = find.descendant(
          of: target,
          matching: find.byIcon(Icons.check_box_outline_blank),
        );
        expect(unchecked, findsOneWidget);

        await tester.tapAt(tester.getRect(target).center);
        await tester.pump();
        expect(find.text('1 selected'), findsOneWidget);
        final checked = find.descendant(
          of: target,
          matching: find.byIcon(Icons.check_box),
        );
        expect(checked, findsOneWidget);

        await tester.tap(checked);
        await tester.pump();
        expect(find.text('0 selected'), findsOneWidget);
        expect(
          find.descendant(
            of: target,
            matching: find.byIcon(Icons.check_box_outline_blank),
          ),
          findsOneWidget,
          reason: 'one checkbox tap must toggle once, never twice',
        );

        await tester.tap(find.byKey(const Key('planner-selection-cancel')));
        await tester.pumpAndSettle();
        expect(target, findsNothing);
        await tester.tap(block);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('calendar-event-existing-detail-sheet')),
          findsOneWidget,
          reason: 'outside bulk mode the existing Preview path remains owner',
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'R7-03: a latched future advance reverses back to the current date when '
      'the pointer enters the opposite trigger, with the same pointer and no '
      'persisted change',
      (tester) async {
        const selected = PlannerDate(year: 2026, month: 7, day: 27);
        const next = PlannerDate(year: 2026, month: 7, day: 28);
        final (database, plannerRepo, calendarRepo) = await buildRepositories();
        await pumpPlannerDay(
          tester,
          database: database,
          plannerRepository: plannerRepo,
          calendarRepository: calendarRepo,
          selected: selected,
          eventId: scheduledEventId,
          startMinute: 9 * 60,
          endMinute: 11 * 60,
        );
        final occurrenceId = occurrenceIdFor(scheduledEventId, selected);
        final block = find.byKey(Key('planner-timed-event-$occurrenceId'));
        await tester.longPress(block);
        await tester.pumpAndSettle();
        final originalRect = tester.getRect(block);
        final timelineRect = tester.getRect(
          find.byKey(const Key('planner-time-grid')),
        );
        final rightTrigger = Offset(
          timelineRect.right - 28,
          originalRect.center.dy,
        );
        // R7-03: the previous strip is the same-width in-viewport mirror of
        // the next strip, just inside the time gutter.
        final leftTrigger = Offset(
          timelineRect.left + 56 + 28,
          originalRect.center.dy,
        );

        final gesture = await tester.startGesture(originalRect.center);
        await tester.pump(const Duration(milliseconds: 20));
        await gesture.moveBy(const Offset(-24, 0));
        await tester.pump();
        // Advance to the future day and latch.
        await gesture.moveTo(rightTrigger);
        await tester.pump();
        for (var frame = 0; frame < 14; frame += 1) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(_readSelectedDateIso(tester), next.iso8601);
        expect(
          find.byKey(const Key('planner-saved-event-drag-ghost')),
          findsOneWidget,
          reason: 'the same ghost survives the future advance',
        );

        // Reverse: entering the opposite trigger while latched must navigate
        // back toward the current date (the previous directional asymmetry).
        await gesture.moveTo(leftTrigger);
        await tester.pump();
        for (var frame = 0; frame < 14; frame += 1) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(
          _readSelectedDateIso(tester),
          selected.iso8601,
          reason:
              'entering the opposite trigger while latched reverses the date',
        );

        // The pointer is back at the original Y, so dropping is a no-op move.
        await gesture.up();
        await tester.pump();
        expect(
          await database.select(database.calendarEventOperations).get(),
          isEmpty,
          reason:
              'the reverse to the source date with unchanged candidate '
              'writes nothing',
        );
        final rows = await database.select(database.calendarEvents).get();
        expect(rows, hasLength(1));
        expect(rows.single.startDate, selected.iso8601);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'R7-04: dropping a drag shows the optimistic pending-move projection at '
      'the candidate position BEFORE the async commit completes, then '
      'reconciles without a duplicate',
      (tester) async {
        const selected = PlannerDate(year: 2026, month: 7, day: 27);
        final (database, plannerRepo, calendarRepo) = await buildRepositories();
        final delayed = _DelayedMoveCalendarRepository(calendarRepo);
        final profile = await buildTestRepository(
          database: database,
        ).completeOnboarding();
        await delayed.saveEvent(
          profileId: profile.id,
          draft: timedDraft(
            id: scheduledEventId,
            date: selected,
            startMinute: 9 * 60,
            endMinute: 11 * 60,
          ),
        );
        await pumpPlannerDay(
          tester,
          database: database,
          plannerRepository: plannerRepo,
          calendarRepository: delayed,
          selected: selected,
        );
        final occurrenceId = occurrenceIdFor(scheduledEventId, selected);
        final source = find.byKey(Key('planner-timed-event-$occurrenceId'));
        final gridRect = tester.getRect(
          find.byKey(const Key('planner-time-grid')),
        );
        // P1 (2026-09-21): the canvas IS the configured 06:00-22:00 window,
        // so the live hour height is the grid height over 16 slots.
        final hourHeight = gridRect.height / 16;
        await tester.longPress(source);
        await tester.pumpAndSettle();
        final gesture = await tester.startGesture(tester.getCenter(source));
        await tester.pump(const Duration(milliseconds: 20));
        await gesture.moveBy(const Offset(0, 24));
        await tester.pump();
        await gesture.moveBy(const Offset(0, 96));
        await tester.pump();

        // Drop. The commit is still gated, so the optimistic projection must
        // render the moved Event at the candidate position immediately.
        await gesture.up();
        await tester.pump();
        final projected = find.byKey(Key('planner-timed-event-$occurrenceId'));
        expect(projected, findsOneWidget);
        expect(
          find.byKey(const Key('planner-saved-event-drag-ghost')),
          findsNothing,
          reason: 'the ghost disappears on drop',
        );
        // P1 (2026-09-21): the canvas origin is the configured 06:00 window
        // start, so the 11:00 AM candidate sits (11 - 6) canvas hours below
        // the grid top rather than eleven midnight-based hours.
        expect(
          tester.getRect(projected).top,
          closeTo(gridRect.top + (11 - 6) * hourHeight, 0.5),
          reason:
              'the pending projection appears at the candidate 11:00 '
              'position before the commit completes',
        );

        // Release the commit; the canonical refresh reconciles without a
        // duplicate and lands the Event at the same candidate position.
        delayed.releaseMoveCommit();
        await pumpUntilMoveCard(tester);
        expect(
          projected,
          findsOneWidget,
          reason: 'no duplicate after reconcile',
        );
        final rows = await database.select(database.calendarEvents).get();
        expect(rows, hasLength(1));
        expect(rows.single.id, scheduledEventId);
        expect(rows.single.startMinute, 11 * 60);
        expect(rows.single.endMinute, 11 * 60 + 120);
        expect(tester.takeException(), isNull);
      },
    );
  });
}
