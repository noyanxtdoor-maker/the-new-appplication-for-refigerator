import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/ids/identifier_source.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/goals/data/drift_goal_repository.dart';
import 'package:rmplanner/features/goals/domain/goal.dart';
import 'package:rmplanner/features/goals/presentation/goal_icon_picker_screen.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';

import '../../../support/test_dependencies.dart';

Future<void> _pumpUi(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> _pumpRoute(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  const monday = PlannerDate(year: 2026, month: 8, day: 3);
  final clock = FixedClock(DateTime.utc(2026, 8, 3, 12));

  DriftGoalRepository repositoryFor(AppDatabase database) {
    return DriftGoalRepository(
      database: database,
      clock: clock,
      identifiers: const UuidIdentifierSource(),
    );
  }

  testWidgets(
    'Create and Edit preserve a manually selected icon through rename, '
    'archive, restore, and every visible Goal surface',
    (tester) async {
      tester.view.physicalSize = const Size(941, 1672);
      tester.view.devicePixelRatio = 2.5;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final database = openMemoryDatabase();
      addTearDown(database.close);
      final startup = buildTestRepository(database: database);
      final profile = await startup.completeOnboarding();
      // M6 zero-goal law: this test describes an EXISTING (pre-M6) user, so the canonical six Goals are
      // seeded explicitly instead of being created implicitly at onboarding.
      await seedLegacyCanonicalGoals(database, profile.id);
      final repository = repositoryFor(database);
      final exercise = (await repository.readActiveGoals(
        profile.id,
      )).firstWhere((goal) => goal.title == 'Exercise');

      final privacy = TestPrivacyDependencies(database: database);
      await tester.pumpWidget(
        privacy.buildApp(
          environment: const AppEnvironment(
            name: AppEnvironmentName.production,
            label: 'PRODUCTION',
          ),
          diagnostics: SanitizedDiagnostics(),
          startupRepository: startup,
          plannerDateSource: const FixedPlannerDateSource(monday),
        ),
      );
      await _pumpUi(tester);

      await tester.tap(find.byKey(const Key('weekly-targets-button')));
      await _pumpUi(tester);
      final exerciseMenu = find.byKey(
        Key('weekly-plan-goal-menu-${exercise.id}'),
      );
      await tester.scrollUntilVisible(
        exerciseMenu,
        240,
        scrollable: find.descendant(
          of: find.byKey(const Key('weekly-plan-list')),
          matching: find.byType(Scrollable),
        ),
      );
      await _pumpUi(tester);
      await tester.tap(exerciseMenu);
      await _pumpUi(tester);
      await tester.tap(find.text('Archive Goal'));
      await _pumpUi(tester);
      expect(find.text('Archive "Exercise"?'), findsOneWidget);
      await tester.tap(find.text('Archive').last);
      await _pumpUi(tester);
      final activeIdsBeforeCreate = (await repository.readActiveGoals(
        profile.id,
      )).map((goal) => goal.id).toSet();
      final weeklyScrollable = find.descendant(
        of: find.byKey(const Key('weekly-plan-list')),
        matching: find.byType(Scrollable),
      );
      tester.state<ScrollableState>(weeklyScrollable).position.jumpTo(0);
      await _pumpUi(tester);
      final createGoalButton = find.byKey(const Key('weekly-plan-create-goal'));
      expect(createGoalButton, findsOneWidget);
      await tester.tap(createGoalButton);
      await _pumpUi(tester);
      if (find.text('Goal limit reached').evaluate().isNotEmpty) {
        await tester.tap(find.text('Cancel'));
        await _pumpUi(tester);
        await tester.pump(const Duration(milliseconds: 250));
        await tester.tap(createGoalButton);
        await _pumpUi(tester);
      }
      final nameField = find.byKey(const Key('goal-name'));
      final createScrollable = find.byType(Scrollable).last;
      await tester.scrollUntilVisible(
        nameField,
        240,
        scrollable: createScrollable,
      );
      await tester.enterText(nameField, 'Scripture Study');
      await tester.pump();
      expect(find.text('Learning'), findsOneWidget);
      expect(find.text('Suggested from "Scripture Study"'), findsOneWidget);
      expect(
        (await repository.readActiveGoals(
          profile.id,
        )).map((goal) => goal.id).toSet(),
        activeIdsBeforeCreate,
      );

      final choiceRow = find.byKey(const Key('goal-icon-choice-row'));
      await tester.scrollUntilVisible(
        choiceRow,
        200,
        scrollable: createScrollable,
      );
      await tester.tap(choiceRow);
      await _pumpUi(tester);
      expect(find.text('Choose Icon'), findsOneWidget);
      // finance_wallet sits on row 4 of the 41-icon grid; scroll the picker
      // until the tile is built (lazy grid), then tap it.
      await tester.scrollUntilVisible(
        find.byKey(const Key('goal-icon-tile-finance_wallet')),
        200,
        scrollable: find
            .descendant(
              of: find.byType(GoalIconPickerScreen),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('goal-icon-tile-finance_wallet')));
      await tester.pump();
      expect(
        tester
            .widget<TextButton>(find.byKey(const Key('goal-icon-picker-save')))
            .onPressed,
        isNotNull,
        reason: 'Selecting an approved icon should enable picker Save',
      );
      await tester.tap(find.byKey(const Key('goal-icon-picker-save')));
      await tester.pump();
      await _pumpRoute(tester);
      expect(find.text('Choose Icon'), findsNothing);
      expect(
        find.descendant(of: choiceRow, matching: find.text('Pie Chart')),
        findsOneWidget,
      );
      expect(find.text('Suggested from "Scripture Study"'), findsNothing);

      await tester.enterText(nameField, 'Budget Plan');
      await tester.pump();
      expect(find.text('Pie Chart'), findsOneWidget);
      await tester.tap(find.byKey(const Key('goal-create-save')));
      await _pumpUi(tester);

      var saved = (await repository.readActiveGoals(
        profile.id,
      )).firstWhere((goal) => goal.title == 'Budget Plan');
      expect(saved.iconId, 'finance_wallet');
      final weeklyRow = find.byKey(Key('weekly-plan-goal-${saved.id}'));
      final weeklyPosition = tester
          .state<ScrollableState>(weeklyScrollable)
          .position;
      weeklyPosition.jumpTo(
        (weeklyPosition.maxScrollExtent - 120)
            .clamp(0.0, weeklyPosition.maxScrollExtent)
            .toDouble(),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(weeklyRow, findsOneWidget);
      await tester.tap(weeklyRow);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Edit Goal'), findsOneWidget);
      await _pumpRoute(tester);

      final editChoiceRow = find.byKey(
        const Key('goal-icon-choice-row'),
        skipOffstage: false,
      );
      await tester.scrollUntilVisible(
        editChoiceRow,
        200,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.pump();
      expect(find.text('Pie Chart'), findsOneWidget);
      await tester.tap(editChoiceRow);
      await _pumpUi(tester);
      await tester.scrollUntilVisible(
        find.byKey(const Key('goal-icon-tile-spiritual_temple')),
        200,
        scrollable: find
            .descendant(
              of: find.byType(GoalIconPickerScreen),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('goal-icon-tile-spiritual_temple')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('goal-icon-picker-save')));
      await tester.pump();
      expect(find.text('Temple', skipOffstage: false), findsOneWidget);

      final goalTitle = find.byKey(
        const Key('goal-title'),
        skipOffstage: false,
      );
      await tester.ensureVisible(goalTitle);
      await tester.enterText(goalTitle, 'Renamed Goal');
      await tester.tap(find.byKey(const Key('goal-edit-save')));
      await _pumpUi(tester);
      await tester.pump(const Duration(milliseconds: 700));
      saved = (await repository.readActiveGoals(
        profile.id,
      )).firstWhere((goal) => goal.id == saved.id);
      expect(saved.title, 'Renamed Goal');
      expect(saved.iconId, 'spiritual_temple');

      final menu = find.byKey(Key('weekly-plan-goal-menu-${saved.id}'));
      await tester.scrollUntilVisible(menu, 200, scrollable: weeklyScrollable);
      await tester.pump();
      final menuRect = tester.getRect(menu);
      if (menuRect.top < kToolbarHeight + 16) {
        final position = tester
            .state<ScrollableState>(weeklyScrollable)
            .position;
        position.jumpTo(
          (position.pixels - (kToolbarHeight + 16 - menuRect.top))
              .clamp(0.0, position.maxScrollExtent)
              .toDouble(),
        );
        await tester.pump();
      }
      await tester.tap(menu);
      await _pumpUi(tester);
      await tester.tap(find.text('Archive Goal'));
      await _pumpUi(tester);
      expect(find.text('Archive "Renamed Goal"?'), findsOneWidget);
      await tester.tap(find.text('Archive').last);
      await _pumpUi(tester);

      expect(find.byKey(Key('weekly-plan-goal-${saved.id}')), findsNothing);
      await tester.tap(find.byKey(const Key('goal-archive-button')));
      await _pumpUi(tester);
      expect(find.text('Goal Archive'), findsOneWidget);
      final archiveRow = find.byKey(Key('goal-archive-row-${saved.id}'));
      expect(archiveRow, findsOneWidget);
      await tester.scrollUntilVisible(
        archiveRow,
        200,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.pump();
      expect(
        tester.getSemantics(archiveRow).label,
        contains('Renamed Goal goal icon'),
      );
      await tester.tap(find.byKey(Key('goal-restore-${saved.id}')));
      await _pumpUi(tester);
      expect(find.byKey(Key('goal-archive-row-${saved.id}')), findsNothing);

      saved =
          await repository.readGoal(profileId: profile.id, goalId: saved.id)
              as Goal;
      expect(saved.status, GoalStatus.active);
      expect(saved.iconId, 'spiritual_temple');
      expect(tester.takeException(), isNull);
    },
  );
}
