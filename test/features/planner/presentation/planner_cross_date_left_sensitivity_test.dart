// Left cross-date drag sensitivity correction — permanent regression tests.
//
// The approved production change removes the LEFT lower-bound
// (`local.dx >= timeColumnWidth`) from `_crossDateDirectionAt` in
// planner_screen.dart, so the previous-date trigger becomes:
//
//   LEFT active: [0, 112] dp   (was [56, 112] dp)
//   RIGHT active: [W - 56, W] dp  (unchanged)
//
// These tests drive the REAL saved-drag state machine through the widget
// tree (long-press selection -> global pointer route -> dwell timer ->
// pager commit), exactly like the existing R7-03 tests, and assert the
// pack contracts:
//
//   - the old time-gutter dead zone (x < 56) must advance previous after
//     a full 200ms+ dwell (FAILS on base 8f0e5b3);
//   - the existing inner-left region (56..112) must keep working;
//   - x > 112 and the center must never trigger;
//   - the right side must be unchanged;
//   - brief (<200ms) gutter entries must not advance;
//   - a long stationary hold must advance exactly once (latch + rearm);
//   - center return re-arms one fresh left entry;
//   - without an active saved drag, the time gutter must never navigate.
//
// Every saved-drag test releases its live pointer inside a `try/finally`
// so the state machine never leaks a captured pointer (or a pending
// dwell timer) when an assertion fails — which is exactly what the
// fail-first runs on base 8f0e5b3 rely on.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/planner/application/calendar_event_repository.dart';
import 'package:rmplanner/features/planner/data/calendar_event_time_zones.dart';
import 'package:rmplanner/features/planner/data/drift_calendar_event_repository.dart';
import 'package:rmplanner/features/planner/data/drift_outcome_reporting_repository.dart';
import 'package:rmplanner/features/planner/data/drift_planner_repository.dart';
import 'package:rmplanner/features/planner/data/drift_task_event_link_repository.dart';
import 'package:rmplanner/features/planner/domain/calendar_event.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';

import '../../../support/test_dependencies.dart';

/// Read the iso string of the currently selected date from the
/// `planner-selected-date` Semantics label (same helper as the day-swipe
/// suite).
String _readSelectedDateIso(WidgetTester tester) {
  final selectedSemantics = find.byKey(const Key('planner-selected-date'));
  expect(selectedSemantics, findsOneWidget);
  final widget = tester.widget<Semantics>(selectedSemantics);
  final String? rawLabel = widget.properties.label;
  expect(
    rawLabel,
    isNotNull,
    reason: 'planner-selected-date must carry a label',
  );
  final RegExpMatch? matcher = RegExp(
    r'(\d{4}-\d{2}-\d{2})',
  ).firstMatch(rawLabel!);
  expect(
    matcher,
    isNotNull,
    reason: 'planner-selected-date label must contain an iso date: $rawLabel',
  );
  return matcher!.group(1)!;
}

void main() {
  const displayTimeZoneId = 'Asia/Manila';
  const scheduledEventId = 'aaaa1111-aaaa-4aaa-8aaa-aaaa1111aaaa';

  CalendarEventDraft timedDraft({
    required String id,
    required PlannerDate date,
    required int startMinute,
    required int endMinute,
  }) {
    return CalendarEventDraft(
      id: id,
      title: 'Left Sensitivity Fixture $id',
      timing: CalendarEventTiming.timed,
      startDate: date,
      startMinute: startMinute,
      endMinute: endMinute,
      requiresReport: false,
      timeZoneId: displayTimeZoneId,
      recurrence: const CalendarRecurrenceRule(),
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

  Future<void> pumpPlannerDay(
    WidgetTester tester, {
    required AppDatabase database,
    required DriftPlannerRepository plannerRepository,
    required CalendarEventRepository calendarRepository,
    required PlannerDate selected,
    PlannerDate? eventDate,
    String? eventId,
    int startMinute = 9 * 60,
    int endMinute = 11 * 60,
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

  /// Long-press the saved Event, then start a fresh saved-drag gesture and
  /// hold it at the given horizontal trigger position (timeline-local x,
  /// i.e. `timelineRect.left + x`) for the full 200ms+ dwell, then run
  /// [verify] while the pointer is still live. The pointer is ALWAYS
  /// released and the tree settled in a `finally` block, so a failed
  /// assertion (fail-first on base) cannot leak a captured pointer.
  Future<void> holdSavedDragAt(
    WidgetTester tester, {
    required String occurrenceId,
    required double localDx,
    required Future<void> Function() verify,
    int dwellFrames = 12,
  }) async {
    final block = find.byKey(Key('planner-timed-event-$occurrenceId'));
    await tester.longPress(block);
    await tester.pumpAndSettle();
    final timelineRect = tester.getRect(
      find.byKey(const Key('planner-time-grid')),
    );
    final trigger = Offset(
      timelineRect.left + localDx,
      tester.getCenter(block).dy,
    );
    final gesture = await tester.startGesture(tester.getCenter(block));
    try {
      await tester.pump(const Duration(milliseconds: 20));
      await gesture.moveBy(const Offset(-24, 0));
      await tester.pump();
      await gesture.moveTo(trigger);
      await tester.pump();
      for (var frame = 0; frame < dwellFrames; frame += 1) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await verify();
    } finally {
      // Always release the live pointer, then unmount the planner tree
      // BEFORE the assertion failure propagates. Without the explicit
      // shrink-unmount, a failed test leaves the Planner mounted and the
      // suite teardown stalls (verified on this harness); the shrink is
      // the same clean-teardown pattern the existing R5-01 tests use.
      await gesture.up();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
  }

  group('Left cross-date drag sensitivity fix', () {
    const selected = PlannerDate(year: 2026, month: 7, day: 27);
    const previous = PlannerDate(year: 2026, month: 7, day: 26);
    const next = PlannerDate(year: 2026, month: 7, day: 28);

    // Pack 05 A/B + pack 07: the old time-gutter dead zone must become an
    // active previous-date trigger after the full 200ms+ dwell. These
    // FAIL on base 8f0e5b3 (local.dx < 56 never entered the trigger).
    for (final gutterX in const <double>[4, 28, 55]) {
      testWidgets(
        'pack05: full dwell at left x=$gutterX (old time-gutter dead zone) '
        'advances previous exactly once',
        (tester) async {
          final (database, plannerRepo, calendarRepo) =
              await buildRepositories();
          await pumpPlannerDay(
            tester,
            database: database,
            plannerRepository: plannerRepo,
            calendarRepository: calendarRepo,
            selected: selected,
            eventId: scheduledEventId,
          );
          await holdSavedDragAt(
            tester,
            occurrenceId: occurrenceIdFor(scheduledEventId, selected),
            localDx: gutterX,
            verify: () async {
              expect(
                _readSelectedDateIso(tester),
                previous.iso8601,
                reason:
                    'left x=$gutterX must advance to the previous date '
                    'after the full dwell',
              );
              expect(
                await database.select(database.calendarEventOperations).get(),
                isEmpty,
                reason: 'the live previous-date transition must not write',
              );
            },
          );
        },
      );
    }

    testWidgets(
      'pack05: full dwell at the physical left edge (x=0) advances previous '
      'exactly once',
      (tester) async {
        final (database, plannerRepo, calendarRepo) = await buildRepositories();
        await pumpPlannerDay(
          tester,
          database: database,
          plannerRepository: plannerRepo,
          calendarRepository: calendarRepo,
          selected: selected,
          eventId: scheduledEventId,
        );
        await holdSavedDragAt(
          tester,
          occurrenceId: occurrenceIdFor(scheduledEventId, selected),
          localDx: 0,
          verify: () async {
            expect(
              _readSelectedDateIso(tester),
              previous.iso8601,
              reason:
                  'the physical left edge must advance previous after dwell',
            );
          },
        );
      },
    );

    // Pack 05 C + pack 07: the existing 56..112 inner-left region must be
    // preserved byte-for-byte. These PASS on base and must keep passing.
    for (final innerX in const <double>[56, 80, 112]) {
      testWidgets(
        'pack05: existing inner-left x=$innerX still advances previous once '
        'after dwell',
        (tester) async {
          final (database, plannerRepo, calendarRepo) =
              await buildRepositories();
          await pumpPlannerDay(
            tester,
            database: database,
            plannerRepository: plannerRepo,
            calendarRepository: calendarRepo,
            selected: selected,
            eventId: scheduledEventId,
          );
          await holdSavedDragAt(
            tester,
            occurrenceId: occurrenceIdFor(scheduledEventId, selected),
            localDx: innerX,
            verify: () async {
              expect(
                _readSelectedDateIso(tester),
                previous.iso8601,
                reason:
                    'existing inner-left x=$innerX must keep advancing previous',
              );
            },
          );
        },
      );
    }

    // Pack 05 D + pack 07: right control unchanged.
    testWidgets(
      'pack05: right control x=W-28 still advances next once after dwell',
      (tester) async {
        final (database, plannerRepo, calendarRepo) = await buildRepositories();
        await pumpPlannerDay(
          tester,
          database: database,
          plannerRepository: plannerRepo,
          calendarRepository: calendarRepo,
          selected: selected,
          eventId: scheduledEventId,
        );
        final block = find.byKey(
          Key(
            'planner-timed-event-${occurrenceIdFor(scheduledEventId, selected)}',
          ),
        );
        await tester.longPress(block);
        await tester.pumpAndSettle();
        final timelineRect = tester.getRect(
          find.byKey(const Key('planner-time-grid')),
        );
        final rightTrigger = Offset(
          timelineRect.right - 28,
          tester.getCenter(block).dy,
        );
        final gesture = await tester.startGesture(tester.getCenter(block));
        try {
          await tester.pump(const Duration(milliseconds: 20));
          await gesture.moveBy(const Offset(-24, 0));
          await tester.pump();
          await gesture.moveTo(rightTrigger);
          await tester.pump();
          for (var frame = 0; frame < 12; frame += 1) {
            await tester.pump(const Duration(milliseconds: 50));
          }
          expect(
            _readSelectedDateIso(tester),
            next.iso8601,
            reason: 'the right edge control must keep advancing next',
          );
        } finally {
          await gesture.up();
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
        }
      },
    );

    // Pack 07: x > 112 must never trigger the left (and the center must
    // never trigger either direction).
    testWidgets(
      'pack07: x=112.001 just past the boundary must not advance previous',
      (tester) async {
        final (database, plannerRepo, calendarRepo) = await buildRepositories();
        await pumpPlannerDay(
          tester,
          database: database,
          plannerRepository: plannerRepo,
          calendarRepository: calendarRepo,
          selected: selected,
          eventId: scheduledEventId,
        );
        await holdSavedDragAt(
          tester,
          occurrenceId: occurrenceIdFor(scheduledEventId, selected),
          localDx: 112.001,
          verify: () async {
            expect(
              _readSelectedDateIso(tester),
              selected.iso8601,
              reason: 'x=112.001 must not enter the previous trigger',
            );
            expect(
              await database.select(database.calendarEventOperations).get(),
              isEmpty,
            );
          },
        );
      },
    );

    testWidgets('pack07: the center must not trigger either direction', (
      tester,
    ) async {
      final (database, plannerRepo, calendarRepo) = await buildRepositories();
      await pumpPlannerDay(
        tester,
        database: database,
        plannerRepository: plannerRepo,
        calendarRepository: calendarRepo,
        selected: selected,
        eventId: scheduledEventId,
      );
      final block = find.byKey(
        Key(
          'planner-timed-event-${occurrenceIdFor(scheduledEventId, selected)}',
        ),
      );
      await tester.longPress(block);
      await tester.pumpAndSettle();
      final timelineRect = tester.getRect(
        find.byKey(const Key('planner-time-grid')),
      );
      final center = Offset(timelineRect.center.dx, tester.getCenter(block).dy);
      final gesture = await tester.startGesture(tester.getCenter(block));
      try {
        await tester.pump(const Duration(milliseconds: 20));
        await gesture.moveBy(const Offset(-24, 0));
        await tester.pump();
        await gesture.moveTo(center);
        await tester.pump();
        for (var frame = 0; frame < 12; frame += 1) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(
          _readSelectedDateIso(tester),
          selected.iso8601,
          reason: 'the center must not trigger a date change',
        );
        expect(
          await database.select(database.calendarEventOperations).get(),
          isEmpty,
        );
      } finally {
        await gesture.up();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      }
    });

    // Pack 06 TEST 1: a brief (<200ms) gutter entry must not advance.
    testWidgets('pack06: a brief gutter entry (x=28, <200ms) must not advance', (
      tester,
    ) async {
      final (database, plannerRepo, calendarRepo) = await buildRepositories();
      await pumpPlannerDay(
        tester,
        database: database,
        plannerRepository: plannerRepo,
        calendarRepository: calendarRepo,
        selected: selected,
        eventId: scheduledEventId,
      );
      final block = find.byKey(
        Key(
          'planner-timed-event-${occurrenceIdFor(scheduledEventId, selected)}',
        ),
      );
      await tester.longPress(block);
      await tester.pumpAndSettle();
      final timelineRect = tester.getRect(
        find.byKey(const Key('planner-time-grid')),
      );
      final gutter = Offset(timelineRect.left + 28, tester.getCenter(block).dy);
      final center = Offset(timelineRect.center.dx, tester.getCenter(block).dy);
      final gesture = await tester.startGesture(tester.getCenter(block));
      var released = false;
      try {
        await tester.pump(const Duration(milliseconds: 20));
        await gesture.moveBy(const Offset(-24, 0));
        await tester.pump();
        await gesture.moveTo(gutter);
        await tester.pump(const Duration(milliseconds: 100));
        // Leave the trigger before the 200ms dwell elapses.
        await gesture.moveTo(center);
        await tester.pump();
        await gesture.up();
        released = true;
        await tester.pumpAndSettle();
        expect(
          _readSelectedDateIso(tester),
          selected.iso8601,
          reason: 'a sub-dwell gutter entry must not change the date',
        );
        expect(
          await database.select(database.calendarEventOperations).get(),
          isEmpty,
          reason: 'a sub-dwell gutter entry must not commit any move',
        );
      } finally {
        if (!released) {
          await gesture.up();
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      }
    });

    // Pack 06 TEST 3 + pack 15: a long stationary hold at the gutter must
    // advance exactly ONE date (latch + rearm rules; no repeat).
    testWidgets(
      'pack06: a long stationary hold at x=28 advances exactly one date and '
      'does not repeat',
      (tester) async {
        final (database, plannerRepo, calendarRepo) = await buildRepositories();
        await pumpPlannerDay(
          tester,
          database: database,
          plannerRepository: plannerRepo,
          calendarRepository: calendarRepo,
          selected: selected,
          eventId: scheduledEventId,
        );
        final block = find.byKey(
          Key(
            'planner-timed-event-${occurrenceIdFor(scheduledEventId, selected)}',
          ),
        );
        await tester.longPress(block);
        await tester.pumpAndSettle();
        final timelineRect = tester.getRect(
          find.byKey(const Key('planner-time-grid')),
        );
        final gutter = Offset(
          timelineRect.left + 28,
          tester.getCenter(block).dy,
        );
        final gesture = await tester.startGesture(tester.getCenter(block));
        try {
          await tester.pump(const Duration(milliseconds: 20));
          await gesture.moveBy(const Offset(-24, 0));
          await tester.pump();
          await gesture.moveTo(gutter);
          await tester.pump();
          for (var frame = 0; frame < 12; frame += 1) {
            await tester.pump(const Duration(milliseconds: 50));
          }
          expect(
            _readSelectedDateIso(tester),
            previous.iso8601,
            reason: 'the full gutter dwell must advance exactly one date',
          );
          // Keep the finger stationary in the gutter for ~600ms more: the
          // latch plus rebased residual must prevent a repeated date step.
          for (var frame = 0; frame < 12; frame += 1) {
            await tester.pump(const Duration(milliseconds: 50));
          }
          expect(
            _readSelectedDateIso(tester),
            previous.iso8601,
            reason: 'a stationary hold in the gutter must not advance again',
          );
          expect(
            await database.select(database.calendarEventOperations).get(),
            isEmpty,
            reason: 'hover must not write before release',
          );
        } finally {
          await gesture.up();
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
        }
      },
    );

    // Pack 06 TEST 4 + pack 15: center return re-arms one fresh left entry.
    testWidgets(
      'pack06: after a left advance, center return re-arms one fresh left '
      'entry that advances one more date',
      (tester) async {
        const secondPrevious = PlannerDate(year: 2026, month: 7, day: 25);
        final (database, plannerRepo, calendarRepo) = await buildRepositories();
        await pumpPlannerDay(
          tester,
          database: database,
          plannerRepository: plannerRepo,
          calendarRepository: calendarRepo,
          selected: selected,
          eventId: scheduledEventId,
        );
        final block = find.byKey(
          Key(
            'planner-timed-event-${occurrenceIdFor(scheduledEventId, selected)}',
          ),
        );
        await tester.longPress(block);
        await tester.pumpAndSettle();
        final timelineRect = tester.getRect(
          find.byKey(const Key('planner-time-grid')),
        );
        final pointerY = tester.getCenter(block).dy;
        final gutter = Offset(timelineRect.left + 28, pointerY);
        final center = Offset(timelineRect.center.dx, pointerY);
        final gesture = await tester.startGesture(tester.getCenter(block));
        try {
          await tester.pump(const Duration(milliseconds: 20));
          await gesture.moveBy(const Offset(-24, 0));
          await tester.pump();
          await gesture.moveTo(gutter);
          await tester.pump();
          for (var frame = 0; frame < 12; frame += 1) {
            await tester.pump(const Duration(milliseconds: 50));
          }
          expect(
            _readSelectedDateIso(tester),
            previous.iso8601,
            reason: 'the first left dwell must advance to the previous date',
          );
          // Concrete center observation re-arms; one fresh left entry may
          // then advance exactly one additional date.
          await gesture.moveTo(center);
          await tester.pump();
          await gesture.moveTo(gutter);
          await tester.pump();
          for (var frame = 0; frame < 12; frame += 1) {
            await tester.pump(const Duration(milliseconds: 50));
          }
          expect(
            _readSelectedDateIso(tester),
            secondPrevious.iso8601,
            reason: 'center return must re-arm exactly one more left advance',
          );
          expect(
            await database.select(database.calendarEventOperations).get(),
            isEmpty,
            reason: 'neither hover transition may write before release',
          );
        } finally {
          await gesture.up();
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
        }
      },
    );

    // Pack 12: without an active saved drag, the time gutter must never
    // navigate dates (the 0..56 gutter only becomes a cross-date target
    // while a saved Event drag is already active).
    testWidgets(
      'pack12: tapping the time gutter without an active saved drag must not '
      'navigate',
      (tester) async {
        final (database, plannerRepo, calendarRepo) = await buildRepositories();
        await pumpPlannerDay(
          tester,
          database: database,
          plannerRepository: plannerRepo,
          calendarRepository: calendarRepo,
          selected: selected,
        );
        // The accepted Planner auto-scrolls the timeline to the current time,
        // so the time grid's own top can sit above the scroll viewport. Reset
        // the day scroll first so this tap really lands on the visible time
        // gutter (its stated target) instead of above the timeline.
        final plannerScroll = tester.state<ScrollableState>(
          find.descendant(
            of: find.byKey(const Key('planner-day-scroll')),
            matching: find.byType(Scrollable),
          ),
        );
        plannerScroll.position.jumpTo(0);
        await tester.pumpAndSettle();

        final timelineRect = tester.getRect(
          find.byKey(const Key('planner-time-grid')),
        );
        await tester.tapAt(
          Offset(timelineRect.left + 28, timelineRect.top + 220),
        );
        await tester.pumpAndSettle();
        expect(
          _readSelectedDateIso(tester),
          selected.iso8601,
          reason: 'a plain gutter tap without a saved drag must not navigate',
        );
        expect(tester.takeException(), isNull);
        expect(
          await database.select(database.calendarEventOperations).get(),
          isEmpty,
          reason: 'a plain gutter tap must not commit any move',
        );
      },
    );
  });
}
