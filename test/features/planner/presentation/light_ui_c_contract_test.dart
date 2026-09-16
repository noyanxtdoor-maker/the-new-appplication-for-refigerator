import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/app/theme/app_theme.dart';
import 'package:rmplanner/app/theme/theme_color_mode.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/goals/presentation/widgets/goal_icon_choice_row.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/settings/application/appearance_repository.dart';

import '../../../support/test_dependencies.dart';

/// Light UI Final Polish (C) — gray-surface cleanup + Blue/Rose theme-leak
/// sweep on the Life Goal surfaces.
///
/// POLISH-04: the unlinked Life Goal placeholder/action icon resolves through
/// the ACTIVE Theme Color (it rendered Rose in Blue mode before); Light Life
/// Goal containers use the semantic near-white surface + outline, never a
/// gray container slab.
void main() {
  const selected = PlannerDate(year: 2026, month: 7, day: 27);

  Future<void> pumpApp(
    WidgetTester tester, {
    ThemeColorMode themeColor = ThemeColorMode.blue,
    AppearanceMode appearance = AppearanceMode.light,
  }) async {
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
    await startupRepository.completeOnboarding();
    await tester.pumpWidget(
      privacy.buildApp(
        environment: const AppEnvironment(
          name: AppEnvironmentName.production,
          label: 'PRODUCTION',
        ),
        diagnostics: SanitizedDiagnostics(),
        startupRepository: startupRepository,
        plannerDateSource: const FixedPlannerDateSource(selected),
        initialAppearance: appearance,
        initialThemeColor: themeColor,
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openEventForm(WidgetTester tester) async {
    await tester.tap(find.text('Planner'));
    await tester.pumpAndSettle();
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

  Future<void> revealLifeGoalSection(WidgetTester tester) async {
    final target = find.byKey(const Key('life-indicator-link-section'));
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
    for (var attempt = 0; attempt < 16; attempt++) {
      if (target.evaluate().isNotEmpty) {
        await tester.ensureVisible(target);
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
    fail('Life Goal section never became visible');
  }

  Finder lifeGoalCard(WidgetTester tester) =>
      find.byKey(const Key('life-indicator-link-section'));

  testWidgets('C1: unlinked Life Goal placeholder icon follows BLUE primary '
      'in Blue Light (recorded Rose leak fixed)', (tester) async {
    await pumpApp(tester);
    await openEventForm(tester);
    await revealLifeGoalSection(tester);

    final fallbackIcon = find.descendant(
      of: lifeGoalCard(tester),
      matching: find.byIcon(Icons.track_changes_outlined),
    );
    expect(fallbackIcon, findsOneWidget);
    final icon = tester.widget<Icon>(fallbackIcon);
    // M7 reconciliation (2026-09-16): the accepted placeholder law is the
    // artwork-family blue (AppTheme.goalIconFallbackBlue, #5CAEC9) so the
    // placeholder matches Planning/Home/choice-row. The retired expectation was
    // scheme.primary; the POLISH-05 intent stands: the active BLUE family, never
    // the Rose default.
    expect(
      icon.color,
      AppTheme.goalIconFallbackBlue,
      reason:
          'POLISH-05: placeholder must use the active BLUE family, '
          'never the Rose default',
    );
    expect(icon.color, isNot(AppTheme.rose));
  });

  // M7 reconciliation (2026-09-16): Step 8 (R01) fixed the Goal-icon fallback
  // to the artwork-family blue (AppTheme.goalIconFallbackBlue) at every call
  // site, INCLUDING Rose mode. The retired VS-15 expectation was the Rose
  // primary; POLISH-05's real intent stands: the placeholder must never leak
  // the Rose surface color as its icon tint.
  testWidgets(
    'C2: same placeholder keeps the artwork-family blue in Rose Light '
    '(symmetry)',
    (tester) async {
      await pumpApp(tester, themeColor: ThemeColorMode.rose);
      await openEventForm(tester);
      await revealLifeGoalSection(tester);

      final fallbackIcon = find.descendant(
        of: lifeGoalCard(tester),
        matching: find.byIcon(Icons.track_changes_outlined),
      );
      final icon = tester.widget<Icon>(fallbackIcon);
      expect(
        icon.color,
        AppTheme.goalIconFallbackBlue,
        reason:
            'POLISH-05/R01: Rose mode keeps the artwork-family blue '
            'placeholder',
      );
      expect(icon.color, isNot(AppTheme.rose));
    },
  );

  testWidgets('C3: Event Life Goal card uses the semantic near-white surface '
      'in Light, never a gray slab', (tester) async {
    await pumpApp(tester);
    await openEventForm(tester);
    await revealLifeGoalSection(tester);

    final section = lifeGoalCard(tester);
    final container = tester.widget<Container>(
      find.ancestor(of: section, matching: find.byType(Container)).first,
    );
    final decoration = container.decoration! as BoxDecoration;
    expect(
      decoration.color,
      Theme.of(tester.element(section)).colorScheme.surface,
      reason:
          'POLISH-04: Light Life Goal card must sit on the semantic '
          'surface with its outline',
    );
    expect(decoration.color, isNot(Colors.transparent));
  });

  testWidgets('C4: Task Life Goal card uses the semantic near-white surface '
      'in Blue Light', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('Planner'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('planner-create-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('create-task-action')));
    await tester.pumpAndSettle();

    // Task form is lazy: scroll the Life Goal section into view.
    final field = find.byKey(const Key('task-life-goal-field'));
    final scroll = find.byElementPredicate((element) {
      if (element.widget is! Scrollable || element is! StatefulElement) {
        return false;
      }
      final state = element.state;
      return state is ScrollableState &&
          element.findAncestorWidgetOfExactType<ListView>()?.key ==
              const Key('task-form-scroll');
    });
    if (scroll.evaluate().isNotEmpty) {
      final formState = tester.state<ScrollableState>(scroll.at(0));
      for (var attempt = 0; attempt < 16; attempt++) {
        if (field.evaluate().isNotEmpty) {
          await tester.ensureVisible(field);
          await tester.pumpAndSettle();
          break;
        }
        formState.position.jumpTo(
          (formState.position.pixels + 260)
              .clamp(0, formState.position.maxScrollExtent)
              .toDouble(),
        );
        await tester.pumpAndSettle();
      }
    }
    expect(field, findsOneWidget);

    final container = tester.widget<Container>(
      find.descendant(of: field, matching: find.byType(Container)).first,
    );
    final decoration = container.decoration! as BoxDecoration;
    expect(
      decoration.color,
      Theme.of(tester.element(field)).colorScheme.surface,
      reason:
          'POLISH-04: Light Task Life Goal card must use the semantic '
          'surface, never a gray slab',
    );
  });

  testWidgets('C5: Goal Icon choice row uses the semantic surface in Blue '
      'Light (no gray slab)', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(ThemeColorMode.blue),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: GoalIconChoiceRow(
              goalTitle: 'My Goal',
              iconId: null,
              fallbackIcon: Icons.flag_outlined,
              onTap: () {},
              showSuggestion: false,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final row = find.byType(GoalIconChoiceRow);
    final container = tester.widget<Container>(
      find.descendant(of: row, matching: find.byType(Container)).first,
    );
    final decoration = container.decoration! as BoxDecoration;
    expect(
      decoration.color,
      Theme.of(tester.element(row)).colorScheme.surface,
      reason: 'POLISH-04: Light choice row must use the semantic surface',
    );
    expect(tester.takeException(), isNull);
  });
}
