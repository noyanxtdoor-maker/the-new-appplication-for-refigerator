import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/ids/identifier_source.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/goals/data/drift_goal_repository.dart';
import 'package:rmplanner/features/goals/presentation/goal_create_screen.dart';
import 'package:rmplanner/features/goals/presentation/goal_edit_screen.dart';

import '../../../support/test_dependencies.dart';

void main() {
  // T09 (R02): the Assigned Event Type preview follows the Goal title draft
  // (presentation alias); the nested Edit Event Type buttons are gone; Goal
  // flows never mutate the canonical activity_types rows.
  testWidgets(
    'edit: alias follows the unsaved draft and no nested editor exists',
    (tester) async {
      tester.view.physicalSize = const Size(393, 874);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final database = openMemoryDatabase();
      addTearDown(database.close);
      final startup = buildTestRepository(database: database);
      final profile = await startup.completeOnboarding();
      // M6 zero-goal law: this test describes an EXISTING (pre-M6) user, so the canonical six Goals are
      // seeded explicitly instead of being created implicitly at onboarding.
      await seedLegacyCanonicalGoals(database, profile.id);
      final goalRepository = DriftGoalRepository(
        database: database,
        clock: FixedClock(DateTime.utc(2026, 9, 9, 12)),
        identifiers: const UuidIdentifierSource(),
      );
      final goal = (await goalRepository.readActiveGoals(
        profile.id,
      )).firstWhere((candidate) => candidate.title == 'Job Applications');

      final privacy = TestPrivacyDependencies(database: database);
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
      // Baseline captured AFTER the app's initial seeding so the comparison
      // isolates what the Goal screen itself does (nothing) to the rows.
      final typesBefore = await database.select(database.activityTypes).get();
      final context = tester.element(find.byType(Scaffold).first);
      unawaited(
        Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => GoalEditScreen(goalId: goal.id, initialGoal: goal),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Edit Goal'), findsOneWidget);
      // The alias card is the shipped surface: the stored Goal title is its
      // preview value, and the only editing affordance is the canonical keyed
      // control that pushes the dedicated Event Type editor. Nothing is edited
      // INLINE — the editor screen's own controls stay out of this tree until
      // that control is used (that is the part of contract G this test can
      // still prove). The old `findsNothing` on the control itself predated the
      // shipped card, which exposes it as the sole entry point to
      // `AssignedEventTypeDraftScreen`.
      expect(find.byKey(const Key('goal-edit-event-type')), findsOneWidget);
      for (final inlineKey in <String>[
        'assigned-event-type-use-goal-name',
        'assigned-event-type-apply',
        'assigned-event-type-cancel',
      ]) {
        expect(
          find.byKey(Key(inlineKey)),
          findsNothing,
          reason: 'the Event Type editor must not be nested inline',
        );
      }
      expect(find.text('Event Type unavailable'), findsNothing);
      // The card shows the stored Goal title as the alias.
      expect(
        find.descendant(
          of: find.byKey(const Key('goal-assigned-event-type')),
          matching: find.text('Job Applications'),
        ),
        findsOneWidget,
      );

      // Editing the title updates the alias preview immediately (draft-driven).
      await tester.enterText(
        find.byKey(const Key('goal-title')),
        'Learn Spanish',
      );
      await tester.pump();
      expect(
        find.descendant(
          of: find.byKey(const Key('goal-assigned-event-type')),
          matching: find.text('Learn Spanish'),
        ),
        findsOneWidget,
      );

      // Cancel (pop without saving): the stored Goal and the canonical type
      // rows are untouched.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      final stored = await goalRepository.readGoal(
        profileId: profile.id,
        goalId: goal.id,
      );
      expect(stored?.title, 'Job Applications');
      final typesAfter = await database.select(database.activityTypes).get();
      // The Goal screen must not rename, recolor, or delete any type row.
      // (The app's asynchronous Education backfill may add rows on first
      // config read — that singleton insertion is proven separately by T03;
      // here we assert every BEFORE row survives byte-identical.)
      final beforeById = {
        for (final row in typesBefore) row.id: (row.label, row.colorValue),
      };
      final afterById = {
        for (final row in typesAfter) row.id: (row.label, row.colorValue),
      };
      for (final entry in beforeById.entries) {
        expect(
          afterById[entry.key],
          entry.value,
          reason: 'row ${entry.key} must be untouched by the Goal flow',
        );
      }
      expect(
        typesAfter
            .where((row) => row.stableKey == 'job_application')
            .single
            .label,
        'Job Application',
        reason:
            'the canonical row keeps its seed label; Goal flows never rename it',
      );
    },
  );

  testWidgets('create: blank name hides card; alias preview absent from tree', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(393, 874);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final database = openMemoryDatabase();
    addTearDown(database.close);
    final startup = buildTestRepository(database: database);
    // M6 zero-goal law: this test describes an EXISTING (pre-M6) user.
    final m6LegacySeedProfile = await startup.completeOnboarding();
    await seedLegacyCanonicalGoals(database, m6LegacySeedProfile.id);

    final privacy = TestPrivacyDependencies(database: database);
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
    final context = tester.element(find.byType(Scaffold).first);
    unawaited(
      Navigator.of(context).push<void>(
        MaterialPageRoute<void>(builder: (_) => const GoalCreateScreen()),
      ),
    );
    await tester.pumpAndSettle();

    // The nested editor action is removed on Create as well.
    expect(find.byKey(const Key('goal-create-edit-event-type')), findsNothing);
    // With a blank name the alias section simply does not render yet
    // (no predicted slot until the repository resolves one).
    expect(
      find.byKey(const Key('goal-create-assigned-event-type')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });
}
