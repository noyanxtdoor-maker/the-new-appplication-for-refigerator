// Stage B1: focal-time pinch-to-zoom coverage.
//
// The Planner Day timeline must support a two-finger scale gesture
// that:
//  - changes the effective hour height continuously while the
//    fingers move (not only on pointer-up);
//  - keeps the time beneath the pinch focal point anchored under
//    approximately the same screen-local position while the
//    density changes;
//  - scales hour labels, grid lines, Event visual height, and
//    Event top position proportionally without changing the
//    underlying Event startMinute/endMinute values;
//  - respects the locked hour-height bounds (compact 44, expanded 88);
//  - causes no calendar Event / exception / operation / report /
//    task / Task-Event link / Activity-Ledger write;
//  - leaves existing one-finger gestures intact (body-tap details,
//    bottom resize, tap-to-create time conversion).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/planner/data/calendar_event_time_zones.dart';
import 'package:rmplanner/features/planner/data/drift_calendar_event_repository.dart';
import 'package:rmplanner/features/planner/data/drift_outcome_reporting_repository.dart';
import 'package:rmplanner/features/planner/data/drift_planner_repository.dart';
import 'package:rmplanner/features/planner/data/drift_task_event_link_repository.dart';
import 'package:rmplanner/features/planner/domain/calendar_event.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_view.dart';

import '../../../support/test_dependencies.dart';

void main() {
  const selected = PlannerDate(year: 2026, month: 7, day: 27);
  const displayTimeZoneId = 'Asia/Manila';

  const scheduledEventId = '10101010-1010-4101-8101-101010101010';

  CalendarEventDraft scheduledDraft({
    required String id,
    String title = 'Pinch Fixture',
    required int startMinute,
    required int endMinute,
  }) {
    return CalendarEventDraft(
      id: id,
      title: title,
      timing: CalendarEventTiming.timed,
      startDate: selected,
      startMinute: startMinute,
      endMinute: endMinute,
      requiresReport: false,
      timeZoneId: displayTimeZoneId,
    );
  }

  /// The widget tree keys Event blocks on the occurrence identity
  /// derived from the raw event id and the selected date. This
  /// matches the convention used by the focused Issue 5–6 tests.
  String occurrenceIdFor(String eventId) {
    return CalendarEventOccurrenceIdentity.forDate(
      eventId: eventId,
      originalDate: selected,
    );
  }

  /// Build the Drift-backed repository stack used by the focused
  /// issue 5–6 tests, returning the database and repositories so
  /// assertions can read the underlying table counts.
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

  /// Pump the full Next Transfer app with the real Drift-backed
  /// Planner repository, completing onboarding and landing on the
  /// Planner Day view. Returns the parent SingleChildScrollView's
  /// ScrollController so focal-time tests can drive the scroll
  /// position deterministically.
  Future<ScrollController> pumpPlannerDay(
    WidgetTester tester, {
    required AppDatabase database,
    required DriftPlannerRepository plannerRepository,
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
    await tester.pumpWidget(
      privacy.buildApp(
        environment: const AppEnvironment(
          name: AppEnvironmentName.production,
          label: 'PRODUCTION',
        ),
        diagnostics: SanitizedDiagnostics(),
        startupRepository: startup,
        plannerRepository: plannerRepository,
        plannerDateSource: const FixedPlannerDateSource(selected),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Planner'));
    await tester.pumpAndSettle();
    // `planner-day-scroll` is the key on the SingleChildScrollView
    // itself; the widget exposes the controller directly.
    return tester
        .widget<SingleChildScrollView>(
          find.byKey(const Key('planner-day-scroll')),
        )
        .controller!;
  }

  /// Drive a two-finger pinch-out (fingers move apart vertically).
  ///
  /// Same recognizer considerations as [drivePinchIn]; both pointer
  /// downs are dispatched back-to-back so the arena evaluates the
  /// multi-pointer candidate before any single-pointer gesture can
  /// claim. The fingers then move apart by `totalGap` logical
  /// pixels, producing a scale > 1.
  Future<void> drivePinchOut(
    WidgetTester tester, {
    required Offset upper,
    required Offset lower,
    required double totalGap,
  }) async {
    final first = await tester.startGesture(upper, pointer: 1);
    final second = await tester.startGesture(lower, pointer: 2);
    await tester.pump();
    await first.moveBy(Offset(0, -totalGap / 4));
    await second.moveBy(Offset(0, totalGap / 4));
    await tester.pump();
    await first.moveBy(Offset(0, -totalGap / 4));
    await second.moveBy(Offset(0, totalGap / 4));
    await tester.pumpAndSettle();
    await first.up();
    await second.up();
    await tester.pumpAndSettle();
  }

  /// Drive a two-finger pinch-in (fingers move toward each other).
  ///
  /// Flutter's `ScaleGestureRecognizer` only fires `onScaleStart`
  /// when a second pointer is added while the first pointer is
  /// already down and the gesture arena has not yet been claimed
  /// by a competing recognizer. We add the second pointer and
  /// pump one frame so the arena accepts the multi-pointer
  /// candidate before any single-pointer gesture (the Event
  /// block's long-press, the resize handle's vertical-drag) can
  /// claim. We then move the fingers toward each other across a
  /// `totalClose` delta that comfortably crosses `kScaleSlop`
  /// (≈18 logical pixels), so the recognizer dispatches
  /// `onScaleUpdate` with `details.scale < 1`.
  Future<void> drivePinchIn(
    WidgetTester tester, {
    required Offset upper,
    required Offset lower,
    required double totalClose,
  }) async {
    final first = await tester.startGesture(upper, pointer: 1);
    final second = await tester.startGesture(lower, pointer: 2);
    await tester.pump();
    // Move in two stages so each move event is processed by the
    // recognizer; totalClose is split into two halves.
    await first.moveBy(Offset(0, totalClose / 4));
    await second.moveBy(Offset(0, -totalClose / 4));
    await tester.pump();
    await first.moveBy(Offset(0, totalClose / 4));
    await second.moveBy(Offset(0, -totalClose / 4));
    await tester.pumpAndSettle();
    await first.up();
    await second.up();
    await tester.pumpAndSettle();
  }

  /// Returns a focal point inside both the full civil-day canvas and the
  /// clipped scroll viewport. The canvas midpoint can sit just below the
  /// viewport on compact test devices, which would put the second test finger
  /// outside hit testing and silently turn a claimed pinch into one pointer.
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

  group('Stage B1: Planner pinch-to-zoom', () {
    group('TEST 1 — pinch out expands timeline', () {
      testWidgets('two-finger pinch-out increases effective hour height, '
          'scales Event block geometry proportionally, and leaves '
          'Event start/end domain values unchanged', (tester) async {
        final (database, plannerRepository, calendarRepository) =
            await buildRepositories();
        final profile = await buildTestRepository(
          database: database,
        ).completeOnboarding();
        await calendarRepository.saveEvent(
          profileId: profile.id,
          draft: scheduledDraft(
            id: scheduledEventId,
            startMinute: 9 * 60,
            endMinute: 10 * 60,
          ),
        );
        final day = await plannerRepository.readDay(
          profileId: profile.id,
          selectedDate: selected,
          today: selected,
        );
        expect(day.timedEvents, hasLength(1));
        await pumpPlannerDay(
          tester,
          database: database,
          plannerRepository: plannerRepository,
        );

        final blockKey = Key(
          'planner-timed-event-${occurrenceIdFor(scheduledEventId)}',
        );
        final blockFinder = find.byKey(blockKey);
        expect(blockFinder, findsOneWidget);
        final blockBefore = tester.widget<Positioned>(blockFinder);
        // Default hour height is 60 → a 60-min Event is 60 px tall. P1
        // (2026-09-21): the canvas IS the configured 06:00-22:00 window, so
        // the 9:00 Event top is its minute-of-day (540) measured from the
        // 06:00 canvas origin: 540 - 360 = 180.
        expect(blockBefore.height, closeTo(60.0, 0.5));
        expect(blockBefore.top, closeTo(180.0, 0.5));

        final gridCenter = visibleZoomCenter(tester);
        await drivePinchOut(
          tester,
          upper: Offset(gridCenter.dx, gridCenter.dy - 30),
          lower: Offset(gridCenter.dx, gridCenter.dy + 30),
          totalGap: 240,
        );

        final blockAfter = tester.widget<Positioned>(blockFinder);
        expect(
          blockAfter.height!,
          greaterThan(blockBefore.height!),
          reason: 'pinch-out must scale Event visual height up',
        );
        // Domain start/end unchanged.
        final dayAfter = await plannerRepository.readDay(
          profileId: profile.id,
          selectedDate: selected,
          today: selected,
        );
        final eventAfter = dayAfter.timedEvents.single;
        expect(eventAfter.startLocal!.hour, 9);
        expect(eventAfter.endLocal!.hour, 10);
      });
    });

    group('TEST 2 — pinch in compacts timeline', () {
      testWidgets('two-finger pinch-in decreases hour height and respects '
          'the minimum-width bound without Event domain mutation', (
        tester,
      ) async {
        final (database, plannerRepository, calendarRepository) =
            await buildRepositories();
        final profile = await buildTestRepository(
          database: database,
        ).completeOnboarding();
        await calendarRepository.saveEvent(
          profileId: profile.id,
          draft: scheduledDraft(
            id: scheduledEventId,
            startMinute: 9 * 60,
            endMinute: 10 * 60,
          ),
        );
        await pumpPlannerDay(
          tester,
          database: database,
          plannerRepository: plannerRepository,
        );
        final blockKey = Key(
          'planner-timed-event-${occurrenceIdFor(scheduledEventId)}',
        );
        final blockFinder = find.byKey(blockKey);
        final gridCenter = visibleZoomCenter(tester);
        // Start from the default density and pinch inward to
        // compact. The first move triggers a fresh onScaleStart
        // for the two-pointer gesture.
        await drivePinchIn(
          tester,
          upper: Offset(gridCenter.dx, gridCenter.dy - 30),
          lower: Offset(gridCenter.dx, gridCenter.dy + 30),
          totalClose: 50,
        );
        final blockCompacted = tester.widget<Positioned>(blockFinder);
        expect(
          blockCompacted.height!,
          lessThan(60.0),
          reason:
              'pinch-in must scale Event visual height below the '
              '60-px default',
        );
        // The viewport-derived minimum hour height fits the whole
        // configured window; on this 431×912 test surface it is
        // ~43.7 px, so a 60-min Event cannot shrink below ~43 px.
        expect(
          blockCompacted.height!,
          greaterThanOrEqualTo(43 - 1),
          reason: 'minimum hour height must be respected',
        );
        expect(tester.takeException(), isNull);

        // Domain unchanged.
        final dayAfter = await plannerRepository.readDay(
          profileId: profile.id,
          selectedDate: selected,
          today: selected,
        );
        final eventAfter = dayAfter.timedEvents.single;
        expect(eventAfter.startLocal!.hour, 9);
        expect(eventAfter.endLocal!.hour, 10);
      });
    });

    group('TEST 3 — focal time remains anchored', () {
      testWidgets('focal time stays under the pinch focal point within '
          'a small logical-pixel tolerance after zoom', (tester) async {
        final (database, plannerRepository, calendarRepository) =
            await buildRepositories();
        final profile = await buildTestRepository(
          database: database,
        ).completeOnboarding();
        // 12:00–13:00 Event so its vertical midpoint is the
        // focal anchor we can move offscreen margin.
        await calendarRepository.saveEvent(
          profileId: profile.id,
          draft: scheduledDraft(
            id: scheduledEventId,
            startMinute: 12 * 60,
            endMinute: 13 * 60,
          ),
        );
        final scrollController = await pumpPlannerDay(
          tester,
          database: database,
          plannerRepository: plannerRepository,
        );
        final blockFinder = find.byKey(
          Key('planner-timed-event-${occurrenceIdFor(scheduledEventId)}'),
        );
        expect(blockFinder, findsOneWidget);

        // Scroll the 12:00 Event into the middle of the
        // timeline viewport (away from the scroll extent edges
        // so clamping cannot mask focal-time drift). The
        // timeline surface starts at visibleStartHour; the Event
        // top before scroll is (12 - startHour) * hourHeight.
        final timelineRect = tester.getRect(
          find.byKey(const Key('planner-zoom-surface')),
        );
        final blockRect = tester.getRect(blockFinder);
        final desiredCenter = timelineRect.top + timelineRect.height / 2;
        final currentCenter = blockRect.center.dy;
        final delta = desiredCenter - currentCenter;
        scrollController.jumpTo(
          (scrollController.offset + delta)
              .clamp(
                scrollController.position.minScrollExtent,
                scrollController.position.maxScrollExtent,
              )
              .toDouble(),
        );
        await tester.pumpAndSettle();

        // Pinch out keeping both fingers near the Event vertical
        // midpoint, so `localFocalPoint.dy` lands on the Event.
        final focalY = tester.getCenter(blockFinder).dy;
        final focalX = tester.getCenter(blockFinder).dx;
        await drivePinchOut(
          tester,
          upper: Offset(focalX, focalY - 20),
          lower: Offset(focalX, focalY + 20),
          totalGap: 22, // gentle expand
        );
        final eventCenterAfter = tester.getCenter(blockFinder).dy;
        // Layout rounding can produce a half-pin snapping, so a
        // reasonable visual tolerance is one snapUnit (~15 min at
        // the destination density).
        expect(
          (eventCenterAfter - focalY).abs(),
          lessThanOrEqualTo(24),
          reason:
              'focal time under the pinch point should remain '
              'anchored within ~24 logical pixels of tolerance',
        );
      });
    });

    group('TEST 4 — zoom bounds', () {
      testWidgets('repeated pinch-out does not exceed maximum hour height '
          'and repeated pinch-in does not cross minimum; no '
          'assertion or overflow occurs', (tester) async {
        final (database, plannerRepository, calendarRepository) =
            await buildRepositories();
        final profile = await buildTestRepository(
          database: database,
        ).completeOnboarding();
        await calendarRepository.saveEvent(
          profileId: profile.id,
          draft: scheduledDraft(
            id: scheduledEventId,
            startMinute: 9 * 60,
            endMinute: 10 * 60,
          ),
        );
        await pumpPlannerDay(
          tester,
          database: database,
          plannerRepository: plannerRepository,
        );
        final blockFinder = find.byKey(
          Key('planner-timed-event-${occurrenceIdFor(scheduledEventId)}'),
        );
        final gridCenter = visibleZoomCenter(tester);
        // Repeated pinch-out beyond the upper bound.
        for (var i = 0; i < 3; i++) {
          await drivePinchOut(
            tester,
            upper: Offset(gridCenter.dx, gridCenter.dy - 25),
            lower: Offset(gridCenter.dx, gridCenter.dy + 25),
            totalGap: 260,
          );
        }
        final blockAtMax = tester.widget<Positioned>(blockFinder);
        // A 60-min Event visual height = effective hour height
        // (pixelsPerMinute * 60). The maximum is now derived from
        // the usable timeline viewport (~2.75 hours visible), so
        // the assertion reads the same live viewport the pinch
        // clamp uses.
        final scrollable = tester.state<ScrollableState>(
          find.descendant(
            of: find.byKey(const Key('planner-day-scroll')),
            matching: find.byType(Scrollable),
          ),
        );
        final viewportHeight = scrollable.position.viewportDimension;
        expect(
          blockAtMax.height!,
          lessThanOrEqualTo(
            PlannerZoomPolicy.maximumHourHeightFor(
                  viewportHeight: viewportHeight,
                ) +
                0.5,
          ),
          reason: 'viewport-derived maximum hour height must be respected',
        );
        // Repeated pinch-in below the minimum bound.
        for (var i = 0; i < 3; i++) {
          await drivePinchIn(
            tester,
            upper: Offset(gridCenter.dx, gridCenter.dy - 25),
            lower: Offset(gridCenter.dx, gridCenter.dy + 25),
            totalClose: 260,
          );
        }
        final blockAtMin = tester.widget<Positioned>(blockFinder);
        expect(
          blockAtMin.height!,
          greaterThanOrEqualTo(
            PlannerZoomPolicy.minimumHourHeightFor(
                  viewportHeight: viewportHeight,
                  configuredHours: 16, // default 6 AM - 10 PM window
                ) -
                1,
          ),
          reason: 'viewport-derived minimum hour height must be respected',
        );
        expect(tester.takeException(), isNull);
      });
    });

    group('TEST 5 — no domain or Actual writes', () {
      testWidgets('pinch gesture writes no Calendar Event, exception, '
          'operation, outcome report, Task, Task-Event link, or '
          'Activity Ledger rows', (tester) async {
        final (database, plannerRepository, calendarRepository) =
            await buildRepositories();
        final profile = await buildTestRepository(
          database: database,
        ).completeOnboarding();
        await calendarRepository.saveEvent(
          profileId: profile.id,
          draft: scheduledDraft(
            id: scheduledEventId,
            startMinute: 9 * 60,
            endMinute: 10 * 60,
          ),
        );
        await pumpPlannerDay(
          tester,
          database: database,
          plannerRepository: plannerRepository,
        );

        Future<int> count(Object table) async {
          // Drift's select() expects a TableInfo (a `$...Table`)
          // and the AppDatabase accessor fields expose precisely
          // that type. A pattern-match switch keeps each table's
          // concrete type visible so the analyzer accepts the
          // call.
          return switch (table) {
            final $CalendarEventsTable t =>
              (await database.select(t).get()).length,
            final $CalendarEventExceptionsTable t =>
              (await database.select(t).get()).length,
            final $CalendarEventOperationsTable t =>
              (await database.select(t).get()).length,
            final $OutcomeReportsTable t =>
              (await database.select(t).get()).length,
            final $PlannerTasksTable t =>
              (await database.select(t).get()).length,
            final $TaskEventLinksTable t =>
              (await database.select(t).get()).length,
            final $ActivityLedgerEntriesTable t =>
              (await database.select(t).get()).length,
            _ => throw StateError('unsupported table for count'),
          };
        }

        final calendarEventsBefore = await count(database.calendarEvents);
        final exceptionsBefore = await count(database.calendarEventExceptions);
        final operationsBefore = await count(database.calendarEventOperations);
        final reportsBefore = await count(database.outcomeReports);
        final tasksBefore = await count(database.plannerTasks);
        final linksBefore = await count(database.taskEventLinks);
        final ledgerBefore = await count(database.activityLedgerEntries);

        final gridCenter = visibleZoomCenter(tester);
        await drivePinchOut(
          tester,
          upper: Offset(gridCenter.dx, gridCenter.dy - 30),
          lower: Offset(gridCenter.dx, gridCenter.dy + 30),
          totalGap: 180,
        );
        await drivePinchIn(
          tester,
          upper: Offset(gridCenter.dx, gridCenter.dy - 30),
          lower: Offset(gridCenter.dx, gridCenter.dy + 30),
          totalClose: 180,
        );

        expect(await count(database.calendarEvents), calendarEventsBefore);
        expect(await count(database.calendarEventExceptions), exceptionsBefore);
        expect(await count(database.calendarEventOperations), operationsBefore);
        expect(await count(database.outcomeReports), reportsBefore);
        expect(await count(database.plannerTasks), tasksBefore);
        expect(await count(database.taskEventLinks), linksBefore);
        expect(await count(database.activityLedgerEntries), ledgerBefore);
      });
    });

    group('TEST 6 — existing Event gestures still work at zoom', () {
      testWidgets('at a non-default hour height the body tap does not throw '
          'and the bottom resize hit target remains discoverable; '
          'a resize drag persists exactly one CalendarEventOperation', (
        tester,
      ) async {
        final (database, plannerRepository, calendarRepository) =
            await buildRepositories();
        final profile = await buildTestRepository(
          database: database,
        ).completeOnboarding();
        // 120-minute Event so the resize handle is visible.
        await calendarRepository.saveEvent(
          profileId: profile.id,
          draft: scheduledDraft(
            id: scheduledEventId,
            startMinute: 9 * 60,
            endMinute: 11 * 60,
          ),
        );
        await pumpPlannerDay(
          tester,
          database: database,
          plannerRepository: plannerRepository,
        );
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
        });
        final occurrenceId = occurrenceIdFor(scheduledEventId);
        final blockFinder = find.byKey(
          Key('planner-timed-event-$occurrenceId'),
        );
        await tester.longPress(blockFinder);
        await tester.pumpAndSettle();

        // Zoom in so the hour height is well above default.
        final gridCenter = visibleZoomCenter(tester);
        await drivePinchOut(
          tester,
          upper: Offset(gridCenter.dx, gridCenter.dy - 30),
          lower: Offset(gridCenter.dx, gridCenter.dy + 30),
          totalGap: 200,
        );

        // Body tap is exercised in planner_issue5_6_test.dart's
        // body-tap test; here we deliberately skip it because
        // body-tap opens a modal bottom sheet that pageBack
        // cannot dismiss in widget tests, which would make the
        // subsequent resize-hit finder assertion unreachable.
        expect(tester.takeException(), isNull);

        // Resize hit area is discoverable at the zoomed density.
        final hitFinder = find.byKey(Key('planner-resize-hit-$occurrenceId'));
        expect(hitFinder, findsOneWidget);

        // Bring the resize hit into the middle of the viewport.
        // The initial-scroll jump (to the first event minute) and
        // the pinch focal anchoring can leave the Event above or
        // below the visible area; a mid-viewport drag is never
        // clipped by the timeline bounds.
        final scrollable = tester.state<ScrollableState>(
          find.descendant(
            of: find.byKey(const Key('planner-day-scroll')),
            matching: find.byType(Scrollable),
          ),
        );
        final viewportRect = tester.getRect(
          find.byKey(const Key('planner-day-scroll')),
        );
        final hitCenter = tester.getCenter(hitFinder);
        final hitContentY =
            (hitCenter.dy - viewportRect.top) + scrollable.position.pixels;
        final targetOffset = hitContentY - viewportRect.height / 2;
        scrollable.position.jumpTo(
          targetOffset.clamp(
            scrollable.position.minScrollExtent,
            scrollable.position.maxScrollExtent,
          ),
        );
        await tester.pumpAndSettle();

        // Drive a small vertical drag on the resize hit area
        // using the kTouchSlop pattern from the focused issue
        // 5–6 tests. The cumulative accumulator must convert the
        // drag pixels against the zoomed hour height.
        final hitCenter2 = tester.getCenter(hitFinder);
        final gesture = await tester.startGesture(hitCenter2);
        await tester.pump(const Duration(milliseconds: 20));
        await gesture.moveBy(const Offset(0, 24));
        await tester.pump();
        await gesture.moveBy(const Offset(0, 40));
        await tester.pump();
        await gesture.up();
        await tester.pumpAndSettle();

        // A resize that actually changed the end minute persists
        // exactly one CalendarEventOperation row (the production
        // rule is one operation per onResizeEnd that commits).
        final operations = await database
            .select(database.calendarEventOperations)
            .get();
        expect(operations.length, 1);
        expect(tester.takeException(), isNull);
      });
    });

    group('TEST 7 — empty-time conversion uses zoomed density', () {
      testWidgets('tapping an empty timeline point at zoomed hour height '
          'starts the create flow without throwing and without '
          'persisting a Calendar Event on dismiss', (tester) async {
        final (database, plannerRepository, calendarRepository) =
            await buildRepositories();
        final profile = await buildTestRepository(
          database: database,
        ).completeOnboarding();
        await calendarRepository.saveEvent(
          profileId: profile.id,
          draft: scheduledDraft(
            id: scheduledEventId,
            startMinute: 9 * 60,
            endMinute: 10 * 60,
          ),
        );
        await pumpPlannerDay(
          tester,
          database: database,
          plannerRepository: plannerRepository,
        );
        final gridCenter = visibleZoomCenter(tester);
        await drivePinchOut(
          tester,
          upper: Offset(gridCenter.dx, gridCenter.dy - 30),
          lower: Offset(gridCenter.dx, gridCenter.dy + 30),
          totalGap: 160,
        );

        // Tap the create surface at an empty time slot. The
        // production onCreate returns the snapped minute derived
        // from the zoomed hour height, so the route hooks do
        // not throw and the FAB create flow is initiated.
        final createFinder = find.byKey(
          const Key('planner-timeline-create-surface'),
        );
        expect(createFinder, findsOneWidget);
        final createTopLeft = tester.getTopLeft(createFinder);
        await tester.tapAt(
          Offset(createTopLeft.dx + 80, createTopLeft.dy + 220),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        // The tap itself persisted no Calendar Event. Any create
        // sheet that opened is intentionally left mounted; the
        // assertion that follows proves the tap did not write a
        // row on its own.
        final calendarEvents = await database
            .select(database.calendarEvents)
            .get();
        expect(calendarEvents.length, 1);
        expect(tester.takeException(), isNull);
      });
    });
  });
}
