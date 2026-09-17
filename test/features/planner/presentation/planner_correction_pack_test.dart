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
import 'package:rmplanner/features/planner/domain/calendar_event.dart';
import 'package:rmplanner/features/planner/domain/event_color_preferences.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_day.dart';
import 'package:rmplanner/features/planner/presentation/planner_screen.dart';
import 'package:rmplanner/features/planner/presentation/widgets/planner_event_block_content.dart';
import 'package:rmplanner/features/planner/presentation/widgets/planner_event_block_layout_policy.dart';
import 'package:rmplanner/features/planner/presentation/widgets/planner_event_report_status.dart';
import 'package:rmplanner/features/planner/presentation/widgets/planner_shared_viewport.dart';

import '../../../support/test_dependencies.dart';

void main() {
  const selected = PlannerDate(year: 2026, month: 7, day: 27);

  testWidgets(
    'Correction Pack: current-time indicator paints behind Event blocks '
    '(Phase 5 FINAL z-order) and stays non-interactive',
    (tester) async {
      tester.view.physicalSize = const Size(862, 1824);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final database = openMemoryDatabase();
      addTearDown(database.close);
      final privacy = TestPrivacyDependencies(database: database);
      final startupRepository = buildTestRepository(
        database: database,
        privacyGate: privacy.gate,
      );
      final profile = await startupRepository.completeOnboarding();
      final linkRepository = DriftTaskEventLinkRepository(
        database: database,
        clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
      );
      final reportingRepository = DriftOutcomeReportingRepository(
        database: database,
        clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
      );
      final calendarRepository = DriftCalendarEventRepository(
        database: database,
        clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
        timeZones: IanaCalendarEventTimeZones(displayTimeZoneId: 'Asia/Manila'),
        taskContextSource: linkRepository,
        linkContextTransfer: linkRepository,
        reportSource: reportingRepository,
      );
      final plannerRepository = DriftPlannerRepository(
        database: database,
        clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
        calendarSource: calendarRepository,
        taskContextSource: linkRepository,
        historicalEffectReader: reportingRepository,
      );
      const eventId = '99999999-9999-4999-9999-999999999999';
      await calendarRepository.saveEvent(
        profileId: profile.id,
        draft: const CalendarEventDraft(
          id: eventId,
          title: 'Crossing Event',
          timing: CalendarEventTiming.timed,
          startDate: selected,
          startMinute: 9 * 60,
          endMinute: 11 * 60,
          timeZoneId: 'Asia/Manila',
          requiresReport: false,
        ),
      );
      await tester.pumpWidget(
        privacy.buildApp(
          environment: const AppEnvironment(
            name: AppEnvironmentName.production,
            label: 'PRODUCTION',
          ),
          diagnostics: SanitizedDiagnostics(),
          startupRepository: startupRepository,
          plannerRepository: plannerRepository,
          calendarEventRepository: calendarRepository,
          plannerDateSource: const FixedPlannerDateSource(selected),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Planner'));
      await tester.pumpAndSettle();

      // The locked layer order is hour grid -> Event blocks -> current-time
      // overlay. Prove it structurally: inside the timeline Stack the
      // The current-time overlay Positioned.fill must come BEFORE the Event
      // block Positioned, so Event cards paint over the line where they
      // intersect (Phase 5 FINAL z-order: hour grid -> current-time
      // indicator -> Event blocks).
      final occurrenceId = CalendarEventOccurrenceIdentity.forDate(
        eventId: eventId,
        originalDate: selected,
      );
      final timelineStack = tester
          .widgetList<Stack>(
            find.descendant(
              of: find.byKey(const Key('planner-time-grid')),
              matching: find.byType(Stack),
            ),
          )
          .first;
      final eventIndex = timelineStack.children.indexWhere(
        (child) => child.key == Key('planner-timed-event-$occurrenceId'),
      );
      final overlayIndex = timelineStack.children.indexWhere(
        (child) => child.key == const Key('planner-current-time-overlay'),
      );
      expect(eventIndex, greaterThanOrEqualTo(0));
      expect(overlayIndex, greaterThanOrEqualTo(0));
      expect(
        eventIndex,
        greaterThan(overlayIndex),
        reason:
            'Event blocks must paint after (above) the current-time overlay '
            'so the line is covered where cards intersect it',
      );

      // The overlay remains non-interactive: tapping the Event body (where
      // the overlay also sits) still opens the Event detail sheet.
      final eventBlock = find.byKey(Key('planner-timed-event-$occurrenceId'));
      await tester.tap(eventBlock);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('event-detail-title')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Correction Pack: recurring deletion uses one destructive dialog with '
    'Delete This Event / Delete Entire Series / Keep Event and no second '
    'confirmation',
    (tester) async {
      tester.view.physicalSize = const Size(862, 1824);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final database = openMemoryDatabase();
      addTearDown(database.close);
      final privacy = TestPrivacyDependencies(database: database);
      final startupRepository = buildTestRepository(
        database: database,
        privacyGate: privacy.gate,
      );
      final profile = await startupRepository.completeOnboarding();
      final linkRepository = DriftTaskEventLinkRepository(
        database: database,
        clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
      );
      final reportingRepository = DriftOutcomeReportingRepository(
        database: database,
        clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
      );
      final calendarRepository = DriftCalendarEventRepository(
        database: database,
        clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
        timeZones: IanaCalendarEventTimeZones(displayTimeZoneId: 'Asia/Manila'),
        taskContextSource: linkRepository,
        linkContextTransfer: linkRepository,
        reportSource: reportingRepository,
      );
      final plannerRepository = DriftPlannerRepository(
        database: database,
        clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
        calendarSource: calendarRepository,
        taskContextSource: linkRepository,
        historicalEffectReader: reportingRepository,
      );
      const eventId = '88888888-8888-4888-8888-888888888889';
      await calendarRepository.saveEvent(
        profileId: profile.id,
        draft: const CalendarEventDraft(
          id: eventId,
          title: 'Weekly Recurring',
          timing: CalendarEventTiming.timed,
          startDate: selected,
          startMinute: 9 * 60,
          endMinute: 10 * 60,
          timeZoneId: 'Asia/Manila',
          requiresReport: false,
          recurrence: CalendarRecurrenceRule(
            frequency: CalendarRecurrenceFrequency.weekly,
          ),
        ),
      );
      await tester.pumpWidget(
        privacy.buildApp(
          environment: const AppEnvironment(
            name: AppEnvironmentName.production,
            label: 'PRODUCTION',
          ),
          diagnostics: SanitizedDiagnostics(),
          startupRepository: startupRepository,
          plannerRepository: plannerRepository,
          calendarEventRepository: calendarRepository,
          plannerDateSource: const FixedPlannerDateSource(selected),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Planner'));
      await tester.pumpAndSettle();

      final occurrenceId = CalendarEventOccurrenceIdentity.forDate(
        eventId: eventId,
        originalDate: selected,
      );

      Future<void> openDeleteDialog() async {
        await tester.tap(find.byKey(Key('planner-timed-event-$occurrenceId')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('event-detail-sheet-overflow-icon')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('event-overflow-delete')));
        await tester.pumpAndSettle();
      }

      // Keep Event: the single dialog closes, nothing is deleted, and no
      // second confirmation appears.
      await openDeleteDialog();
      expect(find.byKey(const Key('recurring-delete-dialog')), findsOneWidget);
      expect(find.text('Delete Repeating Event?'), findsOneWidget);
      expect(find.text('Delete This Event'), findsOneWidget);
      expect(find.text('Delete Entire Series'), findsOneWidget);
      expect(find.text('Keep Event'), findsOneWidget);
      expect(find.text('Change repeating event'), findsNothing);
      expect(find.byKey(const Key('confirm-delete-event')), findsNothing);
      await tester.tap(find.byKey(const Key('recurring-delete-keep-event')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('recurring-delete-dialog')), findsNothing);
      expect(
        await database.select(database.calendarEventExceptions).get(),
        isEmpty,
      );
      expect(
        await database.select(database.calendarEventOperations).get(),
        isEmpty,
      );

      // Delete This Event: one dialog, one destructive choice, one operation,
      // exactly one cancelled occurrence exception, no second confirmation.
      await tester.tap(find.byKey(const Key('event-detail-sheet-close')));
      await tester.pumpAndSettle();
      await openDeleteDialog();
      expect(find.byKey(const Key('recurring-delete-dialog')), findsOneWidget);
      await tester.tap(find.byKey(const Key('recurring-delete-this-event')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('recurring-delete-dialog')), findsNothing);
      expect(find.byKey(const Key('confirm-delete-event')), findsNothing);
      expect(find.text('Delete Calendar Event?'), findsNothing);
      final exceptions = await database
          .select(database.calendarEventExceptions)
          .get();
      expect(exceptions, hasLength(1));
      expect(exceptions.single.status, CalendarEventStatus.cancelled.name);
      final operations = await database
          .select(database.calendarEventOperations)
          .get();
      expect(operations, hasLength(1));
      expect(operations.single.command, 'cancel:occurrence');
    },
  );

  testWidgets(
    'Correction Pack: canonical color pipeline - an accent change derives the '
    'block surface so no stale old surface survives',
    (tester) async {
      tester.view.physicalSize = const Size(393, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final database = openMemoryDatabase();
      addTearDown(database.close);
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
        ),
      );
      await tester.pumpAndSettle();
      // NX-07/08: no More tab — Settings lives in the drawer.
      await tester.tap(find.byKey(const Key('home-hamburger')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('drawer-account-settings')));
      await tester.pumpAndSettle();
      // VS16-M1 added the Notifications row, pushing Colors below the fold at
      // this viewport; scroll to the row before tapping.
      await tester.scrollUntilVisible(
        find.byKey(const Key('settings-colors')),
        160,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings-colors')));
      await tester.pumpAndSettle();

      final current = PlannerEventColorDefaults.lockedJobApplication;
      // Closed-beta V2 (owner decision AG-2, 2026-09-17): the canonical
      // Job Application row now presents its neutral `Life Goal 1` placeholder
      // while the profile has no real Goal in slot 1, and the row's control
      // keys are derived from that display label. Read the rendered label
      // instead of hard-coding one the screen may legitimately present.
      final jobApplicationLabel =
          (find
                      .descendant(
                        of: find.byKey(
                          const Key('event-color-row-job_application'),
                        ),
                        matching: find.byType(Text),
                      )
                      .evaluate()
                      .first
                      .widget
                  as Text)
              .data!;
      final jobAccent = find.byKey(
        Key('event-color-swatch-$jobApplicationLabel-accent'),
      );
      await tester.tap(jobAccent);
      await tester.pumpAndSettle();
      await tester.drag(
        find.byKey(const Key('planner-event-color-sv-gesture')),
        const Offset(24, -18),
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('planner-event-color-save')));
      await tester.pumpAndSettle();

      final savedJson =
          (await database.select(database.plannerPreferences).getSingle())
              .eventColorPreferencesJson;
      final saved = EventColorPreferenceCodec.decode(
        savedJson,
      )['job_application'];
      expect(saved, isNotNull);
      expect(
        saved!.accentArgb,
        isNot(current.accentArgb),
        reason: 'the SV drag must produce a different accent',
      );
      expect(
        saved.surfaceArgb,
        PlannerEventBlockColorPolicy.resolvedSurfaceArgb(
          accentArgb: saved.accentArgb,
          currentAccentArgb: current.accentArgb,
          currentSurfaceArgb: current.surfaceArgb,
        ),
        reason:
            'the surface must derive from the new canonical accent and never '
            'stay stale',
      );
    },
  );

  test('Correction Pack: Unreported uses a muted amber, never neon', () {
    const brightWarning = Color(0xFFFFC857);
    expect(
      PlannerEventReportStatus.unreportedColor,
      isNot(brightWarning),
      reason: 'the bright shared warning token must not be used for status',
    );
    final hsl = HSLColor.fromColor(PlannerEventReportStatus.unreportedColor);
    expect(hsl.saturation, lessThan(0.7));
    expect(hsl.lightness, lessThan(0.75));
    expect(hsl.hue, inInclusiveRange(35, 55));
  });

  testWidgets(
    'Correction Pack: trailing report-status icon renders at compact block '
    'densities where title/time truncate first',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 180,
                height: 40,
                child: PlannerEventBlockContentView(
                  event: PlannerCalendarItem(
                    id: 'compact-event',
                    title: 'A Long Title That Must Truncate Before the Icon',
                    date: selected,
                    timing: PlannerEventTiming.timed,
                    state: PlannerEventState.scheduled,
                    requiresReport: true,
                    hasOutcomeReport: false,
                    activityTypeColorValue: 0xFF86CC7B,
                  ),
                  use24HourTime: false,
                  displayStartMinute: 9 * 60,
                  displayEndMinute: 10 * 60,
                  awaitingReport: true,
                  content: PlannerEventBlockContent.forHeight(
                    40,
                    interactive: false,
                  ),
                  titleKey: const Key('compact-title'),
                  statusKey: const Key('compact-status-badge'),
                ),
              ),
            ),
          ),
        ),
      );
      expect(
        find.byKey(const Key('compact-status-badge')),
        findsOneWidget,
        reason:
            'an elapsed report-required Event must show its trailing status '
            'icon even in a compact block',
      );
      // Compact blocks inline the time into the title; the title text is
      // still rendered (truncated by ellipsis) and the badge reserves its
      // own trailing gutter so text never paints under the icon.
      final title = tester.widget<Text>(find.byKey(const Key('compact-title')));
      expect(title.data, contains('A Long Title That Must Truncate'));
      final titleRect = tester.getRect(find.byKey(const Key('compact-title')));
      final badgeRect = tester.getRect(
        find.byKey(const Key('compact-status-badge')),
      );
      expect(titleRect.right, lessThanOrEqualTo(badgeRect.left + 0.5));
    },
  );

  testWidgets(
    'Correction Pack: configured start is reachable and the end boundary is '
    'exact with no dead scroll region',
    (tester) async {
      tester.view.physicalSize = const Size(393, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final database = openMemoryDatabase();
      addTearDown(database.close);
      final privacy = TestPrivacyDependencies(database: database);
      final startupRepository = buildTestRepository(
        database: database,
        privacyGate: privacy.gate,
      );
      await startupRepository.completeOnboarding();
      final plannerRepository = DriftPlannerRepository(
        database: database,
        clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
        calendarSource: DriftCalendarEventRepository(
          database: database,
          clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
          timeZones: IanaCalendarEventTimeZones(
            displayTimeZoneId: 'Asia/Manila',
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
        taskContextSource: DriftTaskEventLinkRepository(
          database: database,
          clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
        ),
        historicalEffectReader: DriftOutcomeReportingRepository(
          database: database,
          clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
        ),
      );
      await tester.pumpWidget(
        privacy.buildApp(
          environment: const AppEnvironment(
            name: AppEnvironmentName.production,
            label: 'PRODUCTION',
          ),
          diagnostics: SanitizedDiagnostics(),
          startupRepository: startupRepository,
          plannerRepository: plannerRepository,
          plannerDateSource: const FixedPlannerDateSource(selected),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Planner'));
      await tester.pumpAndSettle();

      final plannerElement = tester.element(find.byType(PlannerScreen));
      final container = ProviderScope.containerOf(plannerElement);
      final controller = container.read(eventTypeControllerProvider.notifier);
      final baseline = container.read(eventTypeControllerProvider).settings;
      await controller.saveSettings(
        baseline.copyWith(visibleStartHour: 1, visibleEndHour: 24),
      );
      await tester.pumpAndSettle();

      // Start boundary: the canvas spans the full civil day (PMG parity)
      // and the configured start (1 AM) is a soft planning-window boundary.
      // PMG hidden-midnight model: 1 AM is the first visible hour line and
      // the top 12 AM boundary line is hidden — the 12 AM-1 AM slot remains
      // fully usable above it.
      expect(find.byKey(const Key('planner-full-hour-line-1')), findsOneWidget);
      expect(find.byKey(const Key('planner-full-hour-line-0')), findsNothing);
      final scrollable = tester.state<ScrollableState>(
        find.descendant(
          of: find.byKey(const Key('planner-day-scroll')),
          matching: find.byType(Scrollable),
        ),
      );
      scrollable.position.jumpTo(0);
      await tester.pump();
      expect(
        tester.getRect(find.byKey(const Key('planner-full-hour-line-1'))).top,
        greaterThanOrEqualTo(0),
        reason: 'the configured start boundary must be reachable at the top',
      );
      expect(find.text('1 AM'), findsWidgets);

      // End boundary: 11 PM is the last visible line; the bottom 12 AM
      // boundary line and label are hidden (the 11 PM-12 AM slot remains
      // fully usable below) and no fake 1 AM row follows.
      expect(
        find.byKey(const Key('planner-full-hour-line-23')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('planner-full-hour-line-24')), findsNothing);
      expect(find.byKey(const Key('planner-full-hour-line-25')), findsNothing);
      expect(find.text('12 AM'), findsNothing);
      expect(find.text('11 PM'), findsWidgets);

      // Delta 4.2A / BetterCalendar discipline: the final visible boundary
      // is painted first and its 11 PM label sits below it inside the final
      // 11 PM-midnight cell.
      final lastLabelRect = tester.getRect(find.text('11 PM').first);
      final lastLineRect = tester.getRect(
        find.byKey(const Key('planner-full-hour-line-23')),
      );
      expect(
        lastLabelRect.top,
        greaterThanOrEqualTo(lastLineRect.bottom - 0.5),
        reason: 'the 11 PM label must sit below its hour boundary',
      );
      expect(
        lastLabelRect.top,
        greaterThanOrEqualTo(0),
        reason: 'the 12 AM label must not be clipped at the top',
      );

      // At maximum scroll the final boundary sits inside the viewport and the
      // scroll extent is bounded: content is exactly the timeline height plus
      // the small bottom-boundary spacer and top padding - no large black/dead
      // scroll region.
      final scrollViewport = tester.getRect(
        find.byKey(const Key('planner-day-scroll')),
      );
      scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
      await tester.pump();
      final boundaryRect = tester.getRect(
        find.byKey(const Key('planner-timeline-bottom-boundary')),
      );
      expect(
        boundaryRect.bottom,
        lessThanOrEqualTo(scrollViewport.bottom + 0.5),
      );
      final hourHeight = baseline.timelineHourHeight;
      final expectedContent =
          24 * hourHeight + kPlannerTimelineBottomBoundaryExtent + 14.0;
      expect(
        scrollable.position.maxScrollExtent,
        lessThanOrEqualTo(expectedContent - scrollViewport.height + 1.0),
        reason:
            'the scrollable must not contain a large dead region below the '
            'final configured boundary',
      );
    },
  );
}
