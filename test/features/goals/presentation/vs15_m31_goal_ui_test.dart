import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/app/theme/internal_screen.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/ids/identifier_source.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/goals/data/drift_goal_repository.dart';
import 'package:rmplanner/features/goals/presentation/goal_edit_screen.dart';
import '../../../support/test_dependencies.dart';

void main() {
  testWidgets(
    'M3.1 Goal presentation dismisses focus and preserves same-ID save',
    (tester) async {
      tester.view.physicalSize = const Size(431, 912);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final db = openMemoryDatabase();
      addTearDown(db.close);
      final startup = buildTestRepository(database: db);
      final profile = await startup.completeOnboarding();
      // M6 zero-goal law: this test describes an EXISTING (pre-M6) user, so the canonical six Goals are
      // seeded explicitly instead of being created implicitly at onboarding.
      await seedLegacyCanonicalGoals(db, profile.id);
      final repo = DriftGoalRepository(
        database: db,
        clock: FixedClock(DateTime.utc(2026, 7, 27)),
        identifiers: const UuidIdentifierSource(),
      );
      final goal = (await repo.readActiveGoals(profile.id)).first;
      final privacy = TestPrivacyDependencies(database: db);
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
          MaterialPageRoute(
            builder: (_) => GoalEditScreen(goalId: goal.id, initialGoal: goal),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final bar = tester.widget<InternalAppBar>(
        find.descendant(
          of: find.byType(GoalEditScreen),
          matching: find.byType(InternalAppBar),
        ),
      );
      expect(bar.scrolledUnderElevation, 0);
      expect(find.byKey(const Key('goal-edit-save')), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('goal-title')),
        'M3.1 unchanged Goal semantics',
      );
      final field = find.descendant(
        of: find.byKey(const Key('goal-title')),
        matching: find.byType(EditableText),
      );
      expect(tester.widget<EditableText>(field).focusNode.hasFocus, isTrue);
      final blank = tester.widget<GestureDetector>(
        find.byKey(const Key('goal-edit-blank-space-dismiss')),
      );
      blank.onTap!();
      await tester.pump();
      expect(tester.widget<EditableText>(field).focusNode.hasFocus, isFalse);
      await tester.tap(find.byKey(const Key('goal-edit-save')));
      await tester.pumpAndSettle();
      final saved = await repo.readGoal(profileId: profile.id, goalId: goal.id);
      expect(saved!.id, goal.id);
      expect(saved.title, 'M3.1 unchanged Goal semantics');
      expect(saved.iconId, goal.iconId);
      expect(saved.assignedEventTypeStableKey, goal.assignedEventTypeStableKey);
      expect(saved.role, goal.role);
      expect(tester.takeException(), isNull);
    },
  );
}
