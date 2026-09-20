import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:rmplanner/app/router/route_names.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/planner/data/drift_planner_repository.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_task.dart';

import '../../../support/test_dependencies.dart';

void main() {
  const selected = PlannerDate(year: 2026, month: 7, day: 27);

  testWidgets(
    'VS-08: one timeline tap selects a type before a prefilled form',
    (tester) async {
      tester.view.physicalSize = const Size(393, 874);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final database = openMemoryDatabase();
      addTearDown(database.close);
      final privacy = TestPrivacyDependencies(database: database);
      final startup = buildTestRepository(
        database: database,
        privacyGate: privacy.gate,
      );
      // M6 zero-goal law: this scenario describes an EXISTING (pre-M6) user.
      final firstProfile = await startup.completeOnboarding();
      await seedLegacyCanonicalGoals(database, firstProfile.id);

      await tester.pumpWidget(
        privacy.buildApp(
          environment: const AppEnvironment(
            name: AppEnvironmentName.production,
            label: 'PRODUCTION',
          ),
          diagnostics: SanitizedDiagnostics(),
          startupRepository: startup,
          plannerDateSource: const FixedPlannerDateSource(selected),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Planner'));
      await tester.pumpAndSettle();

      final plannerScroll = tester.state<ScrollableState>(
        find.descendant(
          of: find.byKey(const Key('planner-day-scroll')),
          matching: find.byType(Scrollable),
        ),
      );
      plannerScroll.position.jumpTo(0);
      await tester.pumpAndSettle();
      final surface = find.byKey(const Key('planner-timeline-create-surface'));
      final surfaceTopLeft = tester.getTopLeft(surface);
      final surfaceSize = tester.getSize(surface);
      // The canvas starts at 00:00 (full civil day), so the tap
      // Y is minute-of-day 570 (9:30 AM) at the default hour
      // height of 60 (pixelsPerMinute = 1).
      await tester.tapAt(surfaceTopLeft + Offset(surfaceSize.width / 2, 570));
      await tester.pumpAndSettle();

      expect(find.text('Select Event Type'), findsOneWidget);
      expect(find.text('New Calendar Event'), findsNothing);
      expect(await database.select(database.calendarEvents).get(), isEmpty);
      final pickerSize = tester.getSize(
        find.byKey(const Key('event-type-picker')),
      );
      final pickerRect = tester.getRect(
        find.byKey(const Key('event-type-picker')),
      );
      expect(
        pickerRect.center.dx,
        closeTo(tester.view.physicalSize.width / 2, 1),
        reason: 'Option A picker must remain horizontally centered',
      );
      expect(
        pickerRect.top,
        closeTo(kToolbarHeight + 13, 1),
        reason: 'measured picker top must remain anchored to the top bar',
      );
      // Delta 4.2D restores the last known-good Next Transfer selector
      // dimensions and density without changing its type semantics.
      expect(pickerRect.width, closeTo(347, 1));
      expect(pickerRect.height, closeTo(672, 1));
      expect(
        pickerRect.center.dy,
        lessThan(tester.view.physicalSize.height / 2),
        reason: 'Option A picker must remain above the true vertical center',
      );
      expect(
        pickerRect.bottom,
        lessThanOrEqualTo(tester.view.physicalSize.height),
      );
      expect(pickerSize.width, lessThan(390));
      expect(pickerSize.height, lessThan(730));
      expect(
        tester.getSize(find.byKey(const Key('event-type-icon-other'))).width,
        greaterThan(18),
      );
      expect(
        tester.getSize(find.byKey(const Key('event-type-icon-other'))).width,
        closeTo(22, 0.1),
      );
      expect(
        tester.getTopLeft(find.byKey(const Key('event-type-icon-other'))).dx,
        closeTo((393 - 347) / 2 + 26, 1),
      );
      final firstOption = find.byKey(
        const Key('event-type-option-job_application'),
      );
      expect(tester.getSize(firstOption).height, closeTo(44, .01));
      expect(
        tester.getTopLeft(firstOption).dy - pickerRect.top,
        closeTo(80, 1),
        reason: 'known-good 28 px header inset and 24 px header gap',
      );
      final pickerMaterial = tester.widget<Material>(
        find.byKey(const Key('event-type-picker')),
      );
      expect(pickerMaterial.borderRadius, BorderRadius.circular(12));
      final pickerTitle = tester.widget<Text>(find.text('Select Event Type'));
      expect(pickerTitle.style?.fontSize, 20);
      expect(pickerTitle.style?.fontWeight, FontWeight.w500);
      final cancelText = tester.widget<Text>(
        find.descendant(
          of: find.byKey(const Key('event-type-picker-cancel')),
          matching: find.text('Cancel'),
        ),
      );
      expect(cancelText.style?.fontSize, 16);
      expect(find.byType(DraggableScrollableSheet), findsNothing);
      expect(find.byKey(const Key('event-type-picker-scroll')), findsOneWidget);
      for (final stableKey in <String>[
        'job_application',
        'scripture_study',
        'exercise',
        'meaningful_connection',
        'budget_review',
        'temple_visit',
        'meeting',
        'study_or_plan',
        'service',
        'work',
        'travel',
        'meal',
        'other',
      ]) {
        expect(
          find.byKey(Key('event-type-option-$stableKey')),
          findsOneWidget,
          reason: 'Event Type $stableKey must remain reachable',
        );
      }

      await tester.tap(find.byKey(const Key('event-type-option-temple_visit')));
      await tester.pump(const Duration(milliseconds: 600));

      try {
        expect(find.text('New Calendar Event'), findsNothing);
        expect(
          find.byKey(const Key('calendar-event-form-entrance-fade')),
          findsNothing,
        );
        expect(
          find.byKey(const Key('calendar-event-provisional-draggable-sheet')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('planner-provisional-event-block')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('planner-provisional-resize-hit')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('calendar-event-detail-sheet')),
          findsOneWidget,
        );
        expect(
          tester
              .getTopLeft(find.byKey(const Key('calendar-event-detail-sheet')))
              .dy,
          greaterThan(450),
        );
        expect(find.text('Create Temple Visit'), findsNothing);
        expect(
          find.byKey(const Key('calendar-event-sheet-handle')),
          findsOneWidget,
        );
        expect(
          tester.getSize(find.byKey(const Key('calendar-event-sheet-handle'))),
          const Size(32, 4),
        );
        expect(
          tester.getSize(find.byKey(const Key('event-type-field'))),
          const Size(361, 52),
        );
        expect(
          tester.getSize(find.byKey(const Key('save-event-button'))).height,
          greaterThanOrEqualTo(44),
        );
        final sheet = find.byKey(const Key('calendar-event-detail-sheet'));
        final initialSheetTop = tester.getTopLeft(sheet).dy;
        // Delta 4.1 D4.1-04: the editor is a draggable bottom sheet now, so
        // dragging the grab handle upward EXPANDS it and dragging back down
        // returns it toward the initial editing position.
        await tester.drag(
          find.byKey(const Key('calendar-event-sheet-handle')),
          const Offset(0, -500),
        );
        await tester.drag(
          find.byKey(const Key('calendar-event-sheet-handle')),
          const Offset(0, -500),
        );
        await tester.pump(const Duration(milliseconds: 400));
        final handleExpandedTop = tester.getTopLeft(sheet).dy;
        expect(handleExpandedTop, lessThan(initialSheetTop));
        expect(initialSheetTop - handleExpandedTop, greaterThan(300));
        await tester.drag(
          find.byKey(const Key('calendar-event-sheet-handle')),
          const Offset(0, 325),
        );
        await tester.drag(
          find.byKey(const Key('calendar-event-sheet-handle')),
          const Offset(0, 325),
        );
        await tester.pump(const Duration(milliseconds: 400));
        expect(
          tester.getTopLeft(sheet).dy,
          greaterThan(handleExpandedTop + 300),
          reason:
              'the full-height Event sheet must collapse back toward partial.',
        );
        await tester.drag(
          find.byKey(const Key('calendar-event-sheet-header')),
          const Offset(0, -500),
        );
        await tester.drag(
          find.byKey(const Key('calendar-event-sheet-header')),
          const Offset(0, -500),
        );
        await tester.pump(const Duration(milliseconds: 400));
        final headerExpandedTop = tester.getTopLeft(sheet).dy;
        expect(headerExpandedTop, lessThan(initialSheetTop));
        expect(initialSheetTop - headerExpandedTop, greaterThan(300));
        await tester.drag(
          find.byKey(const Key('calendar-event-sheet-header')),
          const Offset(0, 325),
        );
        await tester.drag(
          find.byKey(const Key('calendar-event-sheet-header')),
          const Offset(0, 325),
        );
        await tester.pump(const Duration(milliseconds: 400));
        expect(
          tester.getTopLeft(sheet).dy,
          greaterThan(headerExpandedTop + 300),
          reason: 'the Event header drag must collapse the expanded sheet.',
        );
        // MP-19: the header save is now a circular check (no text pill).
        expect(find.text('Save'), findsNothing);
        expect(find.byIcon(Icons.check_rounded), findsNothing);
        expect(find.byIcon(Icons.check), findsOneWidget);
        expect(find.byKey(const Key('save-event-bottom-button')), findsNothing);
        expect(find.byKey(const Key('event-set-time-now')), findsNothing);
        expect(
          find.byKey(const Key('event-schedule-from-calendar')),
          findsNothing,
        );
        expect(
          find.descendant(
            of: find.byKey(const Key('event-type-field')),
            matching: find.text('Temple Visit'),
          ),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const Key('event-type-field')));
        await tester.pump(const Duration(milliseconds: 400));
        expect(
          find.byKey(const Key('event-type-dropdown-option-other')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('event-type-icon-other')), findsNothing);
        final dropdownOption = tester.getRect(
          find.byKey(const Key('event-type-dropdown-option-other')),
        );
        expect(dropdownOption.width, greaterThanOrEqualTo(340));
        expect(dropdownOption.width, lessThanOrEqualTo(361));
        expect(dropdownOption.height, greaterThanOrEqualTo(44));
        expect(dropdownOption.height, lessThanOrEqualTo(48));
        await tester.ensureVisible(
          find.byKey(const Key('event-type-dropdown-option-other')),
        );
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tap(
          find.byKey(const Key('event-type-dropdown-option-other')),
        );
        await tester.pump(const Duration(milliseconds: 400));
        expect(
          find.descendant(
            of: find.byKey(const Key('event-type-field')),
            matching: find.text('Other'),
          ),
          findsOneWidget,
        );
        Future<void> scrollFormTo(Finder target) async {
          for (var attempt = 0; attempt < 8; attempt++) {
            if (target.evaluate().isNotEmpty) {
              return;
            }
            await tester.drag(
              find.byKey(const Key('calendar-event-form-scroll')),
              const Offset(0, -220),
            );
            await tester.pump(const Duration(milliseconds: 400));
          }
        }

        final dateField = find.byKey(const Key('event-date-field'));
        await scrollFormTo(dateField);
        expect(dateField, findsWidgets);
        expect(find.text('Scheduling Details'), findsOneWidget);
        expect(find.text('Monday, July 27, 2026'), findsWidgets);
        final startTime = find.byKey(const Key('event-start-time'));
        await scrollFormTo(startTime);
        expect(startTime, findsWidgets);
        final startRect = tester.getRect(startTime.first);
        final endRect = tester.getRect(
          find.byKey(const Key('event-end-time')).first,
        );
        expect(startRect.width, closeTo(164.5, 1));
        expect(endRect.width, closeTo(164.5, 1));
        expect(endRect.left - startRect.right, closeTo(32, 1));
        expect(find.text('9:30 AM'), findsOneWidget);
        final endTime = find.byKey(const Key('event-end-time'));
        await scrollFormTo(endTime);
        expect(endTime, findsWidgets);
        expect(find.text('10:30 AM'), findsOneWidget);
        final peopleSection = find.byKey(const Key('event-people-section'));
        await scrollFormTo(peopleSection);
        await tester.ensureVisible(peopleSection.first);
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byKey(const Key('people-section-header')), findsOneWidget);
        expect(find.text('Contacts'), findsWidgets);
        final indicatorSection = find.byKey(
          const Key('life-indicator-link-section'),
        );
        await scrollFormTo(indicatorSection);
        await tester.ensureVisible(indicatorSection.first);
        await tester.pump(const Duration(milliseconds: 400));
        expect(
          find.byKey(const Key('life-indicator-link-section')),
          findsOneWidget,
        );
        expect(find.text('No Life Goal linked'), findsOneWidget);
        final reportSwitch = find.byKey(
          const Key('event-requires-report-switch'),
        );
        await scrollFormTo(reportSwitch);
        await tester.ensureVisible(reportSwitch.first);
        await tester.pump(const Duration(milliseconds: 400));
        // By this point the form's type was switched to 'Other' (unlocked, no
        // Goal link), so the Report Required toggle stays OFF and shows the
        // optional label introduced by the Part 11 goal-reporting work.  The
        // locked-WLI and Goal-linked label states are covered by the dedicated
        // goal-reporting form test.
        expect(find.text('Optional — Report Required'), findsOneWidget);
        final switchTile = tester.widget<SwitchListTile>(
          find.byKey(const Key('event-requires-report-switch')),
        );
        expect(switchTile.value, isFalse);
        expect(
          find.textContaining('saving never creates Actual'),
          findsNothing,
        );
        expect(
          find.textContaining('Elapsed time creates attention'),
          findsNothing,
        );
        expect(find.textContaining('Optional people context'), findsNothing);
        expect(find.text('Reporting & progress context'), findsOneWidget);
        expect(await database.select(database.calendarEvents).get(), isEmpty);
        expect(
          await database.select(database.activityLedgerEntries).get(),
          isEmpty,
        );
      } finally {
        final close = find.byKey(const Key('calendar-event-sheet-close'));
        if (close.evaluate().isNotEmpty) {
          tester.widget<IconButton>(close.first).onPressed?.call();
          await tester.pump(const Duration(milliseconds: 600));
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      }
      expect(
        find.byKey(const Key('planner-provisional-event-block')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'VS-08: Life Goal recommends its exact type and cancel writes nothing',
    (tester) async {
      tester.view.physicalSize = const Size(431, 912);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final database = openMemoryDatabase();
      addTearDown(database.close);
      final privacy = TestPrivacyDependencies(database: database);
      final startup = buildTestRepository(
        database: database,
        privacyGate: privacy.gate,
      );
      // M6 zero-goal law: this scenario describes an EXISTING (pre-M6) user
      // with the canonical Life Goal whose indicator detail it opens.
      final lifeGoalProfile = await startup.completeOnboarding();
      await seedLegacyCanonicalGoals(database, lifeGoalProfile.id);

      await tester.pumpWidget(
        privacy.buildApp(
          environment: const AppEnvironment(
            name: AppEnvironmentName.production,
            label: 'PRODUCTION',
          ),
          diagnostics: SanitizedDiagnostics(),
          startupRepository: startup,
          plannerDateSource: const FixedPlannerDateSource(selected),
        ),
      );
      await tester.pumpAndSettle();
      final homeContext = tester.element(
        find.byKey(const Key('main-bottom-navigation')),
      );
      GoRouter.of(
        homeContext,
      ).go(RoutePaths.indicatorDetail('job_applications', selected));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('indicator-schedule-activity')));
      await tester.pumpAndSettle();

      expect(find.text('Select Event Type'), findsOneWidget);
      expect(
        find.byKey(const Key('event-type-recommended-job_application')),
        findsOneWidget,
      );
      final recommendedTop = tester.getTopLeft(
        find.byKey(const Key('event-type-option-job_application')),
      );
      final otherTop = tester.getTopLeft(
        find.byKey(const Key('event-type-option-other')),
      );
      expect(recommendedTop.dy, lessThan(otherTop.dy));

      await tester.tap(find.byKey(const Key('event-type-picker-cancel')));
      await tester.pumpAndSettle();

      expect(find.text('Indicator Detail'), findsOneWidget);
      expect(await database.select(database.calendarEvents).get(), isEmpty);
      expect(
        await database.select(database.calendarEventOperations).get(),
        isEmpty,
      );
      expect(await database.select(database.outcomeReports).get(), isEmpty);
      expect(
        await database.select(database.activityLedgerEntries).get(),
        isEmpty,
      );
    },
  );

  testWidgets('VS-08: Task preview preserves Task semantics without legacy '
      'Calendar Event creation controls', (tester) async {
    tester.view.physicalSize = const Size(431, 912);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final database = openMemoryDatabase();
    addTearDown(database.close);
    final privacy = TestPrivacyDependencies(database: database);
    final startup = buildTestRepository(
      database: database,
      privacyGate: privacy.gate,
    );
    final profile = await startup.completeOnboarding();
    const taskId = '20000000-0000-4000-8000-000000000008';
    await DriftPlannerRepository(
      database: database,
      clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
    ).saveTask(
      profileId: profile.id,
      draft: const PlannerTaskDraft(
        id: taskId,
        title: 'Prepare a follow-up',
        dueDate: selected,
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
        startupRepository: startup,
        plannerDateSource: const FixedPlannerDateSource(selected),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Planner'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('planner-overflow-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tasks'));
    await tester.pumpAndSettle();
    // Owner law (2026-09-20): the Planner overflow `Tasks` row opens the ONE
    // canonical Tasks screen, so the row contract is `tasks-row-<id>`.
    final taskTile = find.byKey(const Key('tasks-row-$taskId'));
    await tester.scrollUntilVisible(
      taskTile,
      250,
      scrollable: find.descendant(
        of: find.byKey(const Key('tasks-incomplete-list')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.tap(taskTile);
    await tester.pumpAndSettle();
    expect(find.text('Prepare a follow-up'), findsWidgets);
    expect(find.text('Calendar Event links'), findsNothing);
    expect(find.byTooltip('Manage linked Calendar Events'), findsNothing);
    expect(find.byKey(const Key('create-event-from-task')), findsNothing);
    expect(find.text('Current Status'), findsOneWidget);
    expect(find.text('Date'), findsOneWidget);
    expect(find.text('2026-07-27'), findsOneWidget);
    expect(find.text('Does not repeat'), findsOneWidget);
    expect(find.text('Contacts'), findsOneWidget);
    expect(find.byKey(const Key('task-preview-sheet')), findsOneWidget);
    expect(
      find.byKey(const Key('task-activity-history-button')),
      findsOneWidget,
    );
    expect(await database.select(database.calendarEvents).get(), isEmpty);
  });

  testWidgets('VS-08: direct create route is guarded by the picker', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(431, 912);
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
        plannerDateSource: const FixedPlannerDateSource(selected),
      ),
    );
    await tester.pumpAndSettle();
    final router = GoRouter.of(tester.element(find.byType(Scaffold).first));
    unawaited(
      router.push<void>(
        '${RoutePaths.calendarEventCreate}?date=${selected.iso8601}',
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('Select Event Type'), findsOneWidget);
    expect(find.text('New Calendar Event'), findsNothing);
    await tester.tap(find.byKey(const Key('event-type-picker-cancel')));
    await tester.pumpAndSettle();
    expect(find.text('Home'), findsWidgets);
    expect(await database.select(database.calendarEvents).get(), isEmpty);
  });
}
