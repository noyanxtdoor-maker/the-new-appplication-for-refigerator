import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/goals/presentation/widgets/goal_icon.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';

import '../../../support/test_dependencies.dart';

void main() {
  const selected = PlannerDate(year: 2026, month: 7, day: 27);

  testWidgets('B3.2/TF-01 Task form: Event Type absent from Task UX, order '
      'Title/Description -> Set Due Date -> Contacts -> Life Goal, single + '
      'Contacts, Life Goal picker/link/unlink', (tester) async {
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
    // M6 zero-goal law: completeOnboarding() seeds no Goals, and the Life Goal
    // picker only opens (production fail-closed law) when an active Goal
    // exists. This test describes an EXISTING (pre-M6) user, so seed the
    // canonical Goals the picker contract needs.
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
          'task-form-b3-2',
        ]),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Planner'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('planner-create-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('create-task-action')));
    await tester.pumpAndSettle();

    // The old Event-Type Goal-inference helper is gone.
    expect(
      find.textContaining('add progress to the Goal assigned to'),
      findsNothing,
    );

    // TF-01: EVENT TYPE — OPTIONAL is completely absent from Task UX.
    expect(find.byKey(const Key('task-event-type-field')), findsNothing);
    expect(find.textContaining('EVENT TYPE'), findsNothing);
    expect(find.byKey(const Key('task-goal-event-type-field')), findsNothing);
    expect(find.byKey(const Key('task-clear-event-type')), findsNothing);

    // TF-01: structural order in the Task form list is
    //   Title / Description / Set Due Date / Contacts / Life Goal.
    // Life Goal is the section header Column (task-life-goal-section);
    // Contacts is identified by its + Contacts action
    // (task-add-people-button); Set Due Date is the switch
    // (task-set-due-date-switch).
    final dueDateIndex = _firstChildIndexWithKey(
      tester,
      'task-set-due-date-switch',
    );
    final peopleIndex = _firstChildIndexWithKey(
      tester,
      'task-add-people-button',
    );
    final lifeGoalIndex = _firstChildIndexWithKey(
      tester,
      'task-life-goal-section',
    );
    expect(dueDateIndex, greaterThan(0));
    expect(peopleIndex, greaterThan(dueDateIndex));
    expect(lifeGoalIndex, greaterThan(peopleIndex));

    // Exactly ONE + Contacts affordance; legacy free-text dialog gone.
    await tester.scrollUntilVisible(
      find.byKey(const Key('task-add-people-button')),
      300,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('task-add-people-button')), findsOneWidget);
    expect(find.byKey(const Key('task-add-contacts-button')), findsNothing);
    expect(find.byKey(const Key('task-person-name-field')), findsNothing);

    // Life Goal sits BELOW Contacts (it is the last section): scrolling
    // down past the Contacts action must reveal it, unlinked by default.
    await tester.scrollUntilVisible(
      find.byKey(const Key('task-life-goal-field')),
      300,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('task-life-goal-section')), findsOneWidget);
    expect(find.text('Choose a Life Goal (optional)'), findsOneWidget);

    // Link to a Life Goal through the approved picker.
    await tester.tap(find.byKey(const Key('task-life-goal-field')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('task-life-goal-picker')), findsOneWidget);
    final option = find.byWidgetPredicate(
      (widget) =>
          widget.key is ValueKey<String> &&
          (widget.key as ValueKey<String>).value.startsWith(
            'task-life-goal-option-',
          ),
    );
    expect(option, findsWidgets);

    // GI-02: Task Life Goal sheet options are exactly 2x (24 -> 48).
    final sheetIcons = find.descendant(
      of: find.byKey(const Key('task-life-goal-picker')),
      matching: find.byType(GoalIcon),
    );
    expect(sheetIcons, findsWidgets);
    for (final element in sheetIcons.evaluate()) {
      expect(
        (element.widget as GoalIcon).size,
        48,
        reason:
            'GI-02 task Life Goal sheet option art must be 48dp '
            '(2x of 24)',
      );
    }

    await tester.tap(option.first);
    await tester.pumpAndSettle();

    // Linked card shows the Goal title + Unlink affordance.
    final linkedIcon = find.descendant(
      of: find.byKey(const Key('task-life-goal-field')),
      matching: find.byType(GoalIcon),
    );
    expect(linkedIcon, findsOneWidget);
    expect(
      tester.widget<GoalIcon>(linkedIcon).size,
      48,
      reason: 'GI-02 task linked Life Goal card art must be 48dp (2x of 24)',
    );
    expect(find.byKey(const Key('task-life-goal-unlink')), findsOneWidget);
    expect(find.text('Choose a Life Goal (optional)'), findsNothing);

    await tester.scrollUntilVisible(
      find.byKey(const Key('task-life-goal-unlink')),
      300,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('task-life-goal-unlink')));
    await tester.pumpAndSettle();
    expect(find.text('Choose a Life Goal (optional)'), findsOneWidget);
  });
}

/// First index in the Task form ListView's configured children whose subtree
/// contains the given `ValueKey<String>`.  The Task form builds a static
/// `children:` list (not a builder), so this proves the STRUCTURAL order of
/// the sections without depending on lazy-build visibility or pixel math.
int _firstChildIndexWithKey(WidgetTester tester, String key) {
  final listView = tester.widget<ListView>(
    find.byKey(const Key('task-form-scroll')),
  );
  final delegate = listView.childrenDelegate;
  final children = (delegate as SliverChildListDelegate).children;
  for (var i = 0; i < children.length; i++) {
    if (_subtreeHasKey(children[i], key)) {
      return i;
    }
  }
  return -1;
}

bool _subtreeHasKey(Widget widget, String key) {
  if (widget.key is ValueKey<String> &&
      (widget.key as ValueKey<String>).value == key) {
    return true;
  }
  if (widget is MultiChildRenderObjectWidget) {
    return widget.children.any((child) => _subtreeHasKey(child, key));
  }
  if (widget is SingleChildRenderObjectWidget) {
    final child = widget.child;
    return child != null && _subtreeHasKey(child, key);
  }
  return false;
}
