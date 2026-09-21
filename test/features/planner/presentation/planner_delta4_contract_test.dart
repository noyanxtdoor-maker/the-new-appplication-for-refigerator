import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/planner/application/calendar_event_creation_draft_provider.dart';
import 'package:rmplanner/features/planner/domain/calendar_event.dart';
import 'package:rmplanner/features/planner/domain/event_type.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/presentation/widgets/repeating_event_scope_choices.dart';

import '../../../support/test_dependencies.dart';

void main() {
  testWidgets(
    'Delta 4 A3: repeating scope options are full-row radio-card actions '
    'with explicit helper text and distinct outcomes',
    (tester) async {
      CalendarEventEditScope? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RepeatingEventScopeChoices(
              originalDate: const PlannerDate(year: 2026, month: 8, day: 8),
              keyPrefix: 'delta4-scope',
              onSelected: (scope) => selected = scope,
            ),
          ),
        ),
      );

      expect(find.text('Choose what this change applies to.'), findsOneWidget);
      expect(find.text('This event only'), findsOneWidget);
      expect(find.text('Change only Saturday, Aug 8'), findsOneWidget);
      expect(find.text('All events'), findsOneWidget);
      expect(find.text('Update this repeating series'), findsOneWidget);
      expect(find.byIcon(Icons.radio_button_unchecked), findsNWidgets(2));
      expect(find.byIcon(Icons.chevron_right), findsNWidgets(2));
      expect(
        tester.getSize(find.byKey(const Key('delta4-scope-this'))).height,
        greaterThanOrEqualTo(64),
      );
      expect(
        tester.getSize(find.byKey(const Key('delta4-scope-all'))).height,
        greaterThanOrEqualTo(64),
      );

      await tester.tap(find.byKey(const Key('delta4-scope-this')));
      expect(selected, CalendarEventEditScope.occurrence);
      await tester.tap(find.byKey(const Key('delta4-scope-all')));
      expect(selected, CalendarEventEditScope.series);
    },
  );

  test('Delta 4 A6/A7: provisional block and form share one canonical draft '
      'for type, title, date, and start/end time until explicit clear', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    const firstType = EventType(
      id: 'type-one',
      stableKey: 'other',
      label: 'Other',
      icon: EventTypeIcon.calendar,
      colorValue: 0xFFE75480,
      isSystem: true,
      isArchived: false,
      reportRequiredDefault: false,
      defaultDurationMinutes: 60,
      position: 1,
      mappingVersion: 1,
      indicatorKeys: <String>{},
    );
    const changedType = EventType(
      id: 'type-two',
      stableKey: 'meeting',
      label: 'Meeting',
      icon: EventTypeIcon.appointment,
      colorValue: 0xFF6750A4,
      isSystem: true,
      isArchived: false,
      reportRequiredDefault: false,
      defaultDurationMinutes: 30,
      position: 2,
      mappingVersion: 1,
      indicatorKeys: <String>{},
    );
    const firstDate = PlannerDate(year: 2026, month: 8, day: 8);
    const changedDate = PlannerDate(year: 2026, month: 8, day: 9);
    const draftId = '11111111-1111-4111-8111-111111111111';
    final controller = container.read(
      plannerEventCreationDraftProvider.notifier,
    );

    controller.begin(
      id: draftId,
      date: firstDate,
      startMinute: 9 * 60 + 30,
      eventType: firstType,
    );
    var draft = container.read(plannerEventCreationDraftProvider)!;
    expect(draft.startMinute, 9 * 60 + 30);
    expect(draft.endMinute, 10 * 60 + 30);
    expect(draft.eventTypeLabel, 'Other');

    controller.updateTimes(startMinute: 10 * 60, endMinute: 11 * 60 + 15);
    controller.updateTitle('Synchronized title');
    controller.updateDate(changedDate);
    controller.updateEventType(changedType);
    draft = container.read(plannerEventCreationDraftProvider)!;
    expect(draft.id, draftId);
    expect(draft.startMinute, 10 * 60);
    expect(draft.endMinute, 11 * 60 + 15);
    expect(draft.title, 'Synchronized title');
    expect(draft.date, changedDate);
    expect(draft.eventTypeId, 'type-two');
    expect(draft.eventTypeLabel, 'Meeting');

    controller.clear('a-different-draft');
    expect(container.read(plannerEventCreationDraftProvider), isNotNull);
    controller.clear(draftId);
    expect(container.read(plannerEventCreationDraftProvider), isNull);
  });

  testWidgets(
    'Delta 4/4.2C A5-A8: gutter tap creates one provisional draft, direct '
    'handle drag synchronizes its form time, and Save persists exactly that '
    'draft once',
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
          plannerDateSource: const FixedPlannerDateSource(
            PlannerDate(year: 2026, month: 8, day: 8),
          ),
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
      final topLeft = tester.getTopLeft(surface);
      final threeAmLabel = find.descendant(
        of: find.byKey(const Key('planner-day-page-2026-08-08')),
        matching: find.text('6 AM'),
      );
      expect(threeAmLabel, findsOneWidget);
      await tester.tapAt(tester.getCenter(threeAmLabel));
      await tester.pumpAndSettle();
      expect(
        find.text('Select Event Type'),
        findsOneWidget,
        reason: 'the rendered gutter label must forward taps to creation',
      );
      await tester.tap(find.byKey(const Key('event-type-option-temple_visit')));
      await tester.pumpAndSettle();
      final labelForm = find.byKey(const Key('calendar-event-detail-sheet'));
      final labelContainer = ProviderScope.containerOf(
        tester.element(labelForm),
      );
      expect(
        labelContainer.read(plannerEventCreationDraftProvider)!.startMinute,
        6 * 60,
        reason:
            'tapping the first configured gutter label (6 AM) must create '
            'at exactly 6:00 AM',
      );
      tester
          .widget<IconButton>(
            find.byKey(const Key('calendar-event-sheet-close')),
          )
          .onPressed
          ?.call();
      await tester.pump(const Duration(milliseconds: 600));
      expect(labelContainer.read(plannerEventCreationDraftProvider), isNull);
      // x=20 is inside the left time gutter; P1 (2026-09-21) makes the
      // canvas origin the configured 06:00 start, so y=210 maps to 9:30 AM
      // (360 + 210) at the default 60 px/hour density — the same tap offset
      // now lands six hours later on the clock.
      await tester.tapAt(topLeft + const Offset(20, 210));
      await tester.pumpAndSettle();
      expect(find.text('Select Event Type'), findsOneWidget);
      await tester.tap(find.byKey(const Key('event-type-option-temple_visit')));
      await tester.pumpAndSettle();

      try {
        final form = find.byKey(const Key('calendar-event-detail-sheet'));
        expect(form, findsOneWidget);
        expect(
          find.byKey(const Key('planner-provisional-event-block')),
          findsOneWidget,
        );
        expect(await database.select(database.calendarEvents).get(), isEmpty);
        final container = ProviderScope.containerOf(tester.element(form));
        var draft = container.read(plannerEventCreationDraftProvider)!;
        expect(draft.startMinute, 9 * 60 + 30);
        // Delta 4.2R R9: the provisional draft follows the configured
        // Planner default (30 minutes), not the Event Type default.
        expect(draft.endMinute, 10 * 60);
        // Delta 4.1 draggable editor sheet: the form starts at ~40% so the
        // draft block and its endpoint handles stay above the sheet and
        // reachable.  Resize the draft FIRST (while the sheet is at its
        // initial position), then pull the sheet up to inspect the form.
        final resizeHandle = find.byKey(
          const Key('planner-provisional-resize-hit'),
        );
        final directResize = await tester.startGesture(
          tester.getCenter(resizeHandle),
        );
        await tester.pump(const Duration(milliseconds: 80));
        await directResize.moveBy(const Offset(0, 36));
        await tester.pump(const Duration(milliseconds: 80));
        await directResize.up();
        await tester.pump(const Duration(milliseconds: 200));
        draft = container.read(plannerEventCreationDraftProvider)!;
        expect(
          draft.endMinute,
          10 * 60 + 30,
          reason:
              'the endpoint handle must resize after ordinary touch slop '
              'without an additional hold',
        );

        // Pull the sheet upward (expanding it) and verify the draft/form
        // synchronization: the time tiles now show the resized range.
        final startTime = find.byKey(const Key('event-start-time'));
        for (
          var attempt = 0;
          attempt < 8 && startTime.evaluate().isEmpty;
          attempt += 1
        ) {
          await tester.drag(
            find.byKey(const Key('calendar-event-form-scroll')),
            const Offset(0, -180),
          );
          await tester.pump(const Duration(milliseconds: 150));
        }
        await tester.ensureVisible(startTime.first);
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('9:30 AM'), findsOneWidget);
        expect(find.text('10:30 AM'), findsOneWidget);

        final titleField = find.byKey(const Key('event-title-field'));
        for (
          var attempt = 0;
          attempt < 8 && titleField.evaluate().isEmpty;
          attempt += 1
        ) {
          await tester.drag(
            find.byKey(const Key('calendar-event-form-scroll')),
            const Offset(0, 220),
          );
          await tester.pump(const Duration(milliseconds: 150));
        }
        await tester.enterText(titleField.first, 'Delta 4 gutter Event');
        await tester.pump();
        expect(
          container.read(plannerEventCreationDraftProvider)!.title,
          'Delta 4 gutter Event',
        );
        await tester.tap(find.byKey(const Key('save-event-button')));
        await tester.pump(const Duration(milliseconds: 900));

        final rows = await database.select(database.calendarEvents).get();
        expect(rows, hasLength(1));
        expect(rows.single.title, 'Delta 4 gutter Event');
        expect(rows.single.startMinute, 9 * 60 + 30);
        expect(rows.single.endMinute, 10 * 60 + 30);
        expect(container.read(plannerEventCreationDraftProvider), isNull);
        expect(
          find.byKey(const Key('planner-provisional-event-block')),
          findsNothing,
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
    },
  );

  testWidgets('Delta 4 A6: leaving the owning Planner screen clears an unsaved '
      'provisional draft and cannot leave an orphan block', (tester) async {
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
    final profile = await startup.completeOnboarding();
    await seedLegacyCanonicalGoals(database, profile.id);

    await tester.pumpWidget(
      privacy.buildApp(
        environment: const AppEnvironment(
          name: AppEnvironmentName.production,
          label: 'PRODUCTION',
        ),
        diagnostics: SanitizedDiagnostics(),
        startupRepository: startup,
        plannerDateSource: const FixedPlannerDateSource(
          PlannerDate(year: 2026, month: 8, day: 8),
        ),
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
    await tester.tapAt(tester.getTopLeft(surface) + const Offset(20, 210));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('event-type-option-temple_visit')));
    await tester.pumpAndSettle();

    final form = find.byKey(const Key('calendar-event-detail-sheet'));
    final container = ProviderScope.containerOf(tester.element(form));
    try {
      expect(container.read(plannerEventCreationDraftProvider), isNotNull);
      expect(
        find.byKey(const Key('planner-provisional-event-block')),
        findsOneWidget,
      );

      await tester.tap(find.text('Home').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 900));
      expect(container.read(plannerEventCreationDraftProvider), isNull);
      expect(
        find.byKey(const Key('calendar-event-detail-sheet')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('planner-provisional-event-block')),
        findsNothing,
      );

      await tester.tap(find.text('Planner').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 900));
      expect(container.read(plannerEventCreationDraftProvider), isNull);
      expect(
        find.byKey(const Key('planner-provisional-event-block')),
        findsNothing,
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
  });
}
