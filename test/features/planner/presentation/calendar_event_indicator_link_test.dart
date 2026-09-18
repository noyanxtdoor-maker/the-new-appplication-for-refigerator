import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/goals/presentation/widgets/goal_icon.dart';
import 'package:rmplanner/features/indicators/domain/life_indicator.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';

import '../../../support/test_dependencies.dart';

void main() {
  const selected = PlannerDate(year: 2026, month: 7, day: 27);

  testWidgets('VS-08: unified Life Goal link is reversible, forces Report '
      'Required, and persists only on Save', (tester) async {
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
    // M6 zero-goal law: completeOnboarding() seeds no Goals, and the accepted
    // Life Goal link picker only opens when an active Goal exists. This test
    // describes an EXISTING (pre-M6) user, so seed the canonical Goals the
    // link flow needs.
    final seededProfile = await startupRepository.completeOnboarding();
    await seedLegacyCanonicalGoals(database, seededProfile.id);

    await tester.pumpWidget(
      privacy.buildApp(
        environment: const AppEnvironment(
          name: AppEnvironmentName.production,
          label: 'PRODUCTION',
        ),
        diagnostics: SanitizedDiagnostics(),
        startupRepository: startupRepository,
        plannerDateSource: const FixedPlannerDateSource(selected),
        plannerIdentifierSource: SequenceIdentifierSource(<String>[
          '33333333-3333-4333-8333-333333333333',
          '44444444-4444-4444-8444-444444444444',
          '55555555-5555-4555-8555-555555555555',
          '66666666-6666-4666-8666-666666666666',
          '77777777-7777-4777-8777-777777777777',
          '88888888-8888-4888-8888-888888888888',
        ]),
      ),
    );
    await tester.pumpAndSettle();

    Future<void> openOtherForm() async {
      await tester.tap(find.text('Planner'));
      await tester.pumpAndSettle();
      // OWNER REVIEW #4: selecting Planner now passes the shell's notification
      // education gate BEFORE the Planner is mounted. This suite is about the
      // Life Goal link, so it declines the education to reach the Planner; the
      // education itself is covered at the shell boundary. No assertion in this
      // file changes.
      final education = find.byKey(
        const Key('planner-notification-education'),
      );
      if (education.evaluate().isNotEmpty) {
        await tester.tap(
          find.byKey(const Key('planner-notification-not-now')),
        );
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byKey(const Key('planner-create-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('create-calendar-event-action')));
      await tester.pumpAndSettle();
      final other = find.byKey(const Key('event-type-option-other'));
      await tester.ensureVisible(other);
      await tester.pumpAndSettle();
      await tester.tap(other);
      await tester.pumpAndSettle();
    }

    Future<void> revealLifeIndicatorLink() async {
      final formScroll = find.byElementPredicate((element) {
        if (element.widget is! Scrollable || element is! StatefulElement) {
          return false;
        }
        final state = element.state;
        return state is ScrollableState &&
            state.position.viewportDimension > 100 &&
            element.findAncestorWidgetOfExactType<ListView>()?.key ==
                const Key('calendar-event-form-scroll');
      });
      final formState = tester.state<ScrollableState>(formScroll.at(0));
      final indicatorSection = find.byKey(
        const Key('life-indicator-link-section'),
      );
      for (var attempt = 0; attempt < 12; attempt++) {
        if (indicatorSection.evaluate().isNotEmpty) {
          await tester.ensureVisible(indicatorSection);
          await tester.pumpAndSettle();
          return;
        }
        formState.position.jumpTo(
          (formState.position.pixels + 260)
              .clamp(0, formState.position.maxScrollExtent)
              .toDouble(),
        );
        await tester.pumpAndSettle();
      }
      expect(indicatorSection, findsOneWidget);
      await tester.pumpAndSettle();
    }

    Future<void> selectExerciseLifeIndicator() async {
      await tester.tap(find.byKey(const Key('life-indicator-link-section')));
      await tester.pumpAndSettle();
      expect(find.text('Link to Life Goal'), findsWidgets);
      expect(
        find.text('Choose the goal this Event should contribute to.'),
        findsOneWidget,
      );
      final exercise = find.descendant(
        of: find.byKey(const Key('life-indicator-picker')),
        matching: find.text('Exercise'),
      );
      await tester.ensureVisible(exercise);
      await tester.pumpAndSettle();
      await tester.tap(exercise);
      await tester.pumpAndSettle();
    }

    await openOtherForm();
    await tester.enterText(
      find.byKey(const Key('event-title-field')),
      'Indicator Link Event',
    );
    await revealLifeIndicatorLink();
    // Approved unlinked state: one Life Goal row, no WLI/Goal split.
    expect(
      find.byKey(const Key('life-indicator-link-section')),
      findsOneWidget,
    );
    expect(find.text('No Life Goal linked'), findsOneWidget);
    expect(find.text('Weekly Life Goal'), findsNothing);
    expect(find.text('Goal'), findsNothing);
    // Unlinked: Report Required is optional and editable (OFF).
    await tester.scrollUntilVisible(
      find.byKey(const Key('event-requires-report-switch')),
      220,
      scrollable: find
          .descendant(
            of: find.byKey(const Key('calendar-event-form-scroll')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.text('Optional — Report Required'), findsOneWidget);
    var reportSwitch = tester.widget<SwitchListTile>(
      find.byKey(const Key('event-requires-report-switch')),
    );
    expect(reportSwitch.value, isFalse);
    expect(reportSwitch.onChanged, isNotNull);

    await selectExerciseLifeIndicator();
    // Linked state: name + helper, Report Required forced ON and locked.
    expect(find.text('Exercise'), findsOneWidget);
    expect(find.text('Linked to this Event'), findsOneWidget);
    expect(find.text('Report Required'), findsOneWidget);
    expect(
      find.text(
        'Required because this Event is linked to a '
        'Life Goal.',
      ),
      findsOneWidget,
    );
    reportSwitch = tester.widget<SwitchListTile>(
      find.byKey(const Key('event-requires-report-switch')),
    );
    expect(reportSwitch.value, isTrue);
    expect(reportSwitch.onChanged, isNull);

    // GI-02: Event Life Goal surfaces are exactly 2x (26 -> 52 card;
    // 24 -> 48 sheet options).
    final linkedIcon = find.descendant(
      of: find.byKey(const Key('life-indicator-link-section')),
      matching: find.byType(GoalIcon),
    );
    expect(linkedIcon, findsOneWidget);
    expect(
      tester.widget<GoalIcon>(linkedIcon).size,
      52,
      reason: 'GI-02 event linked Life Goal card art must be 52dp (2x of 26)',
    );

    // Remove link: canonical link cleared, Report Required stays ON but
    // the toggle becomes editable again.
    await tester.tap(find.byKey(const Key('life-indicator-link-section')));
    await tester.pumpAndSettle();
    // GI-02: Event Life Goal sheet options are exactly 2x (24 -> 48).
    final sheetIcons = find.descendant(
      of: find.byKey(const Key('life-indicator-picker')),
      matching: find.byType(GoalIcon),
    );
    expect(sheetIcons, findsWidgets);
    for (final element in sheetIcons.evaluate()) {
      expect(
        (element.widget as GoalIcon).size,
        48,
        reason: 'GI-02 event Life Goal sheet option art must be 48dp '
            '(2x of 24)',
      );
    }
    await tester.tap(find.byKey(const Key('life-indicator-remove-link')));
    await tester.pumpAndSettle();
    expect(find.text('No Life Goal linked'), findsOneWidget);
    // The optional label returns once unlinked, but the value the user
    // already set stays ON and the toggle is editable again.
    expect(find.text('Optional — Report Required'), findsOneWidget);
    reportSwitch = tester.widget<SwitchListTile>(
      find.byKey(const Key('event-requires-report-switch')),
    );
    expect(reportSwitch.value, isTrue);
    expect(reportSwitch.onChanged, isNotNull);

    // Cancel is non-mutating and closing without Save persists nothing.
    await tester.tap(find.byKey(const Key('calendar-event-sheet-close')));
    await tester.pumpAndSettle();
    expect(await database.select(database.calendarEvents).get(), isEmpty);

    await openOtherForm();
    await tester.enterText(
      find.byKey(const Key('event-title-field')),
      'Indicator Link Event',
    );
    await revealLifeIndicatorLink();
    await selectExerciseLifeIndicator();
    await tester.tap(find.byKey(const Key('save-event-button')));
    await tester.pumpAndSettle();

    final saved = await database.select(database.calendarEvents).getSingle();
    // The canonical contribution rule follows the linked Goal's indicator.
    expect(
      saved.contributionRuleKey,
      const ScheduledPotentialRule(
        indicatorKey: 'exercise',
        value: IndicatorAmount(scaledValue: 1, scale: 0, unit: 'count'),
      ).encode(),
    );
    // Locked invariant at the repository layer: a linked Event is always
    // Report Required with its canonical Goal identity persisted.
    expect(saved.requiresReport, isTrue);
    expect(saved.goalId, isNotNull);
    expect(
      await database.select(database.activityLedgerEntries).get(),
      isEmpty,
    );
    expect(await database.select(database.outcomeReports).get(), isEmpty);
    expect(tester.takeException(), isNull);
  });
}
