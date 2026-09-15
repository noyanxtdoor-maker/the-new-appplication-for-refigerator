// MP-06 / MP-06B THEME GRIP + SURFACE COLOR CONTRACT (owner evidence
// 2026-08-16 + owner correction 2026-08-17).
//
// The provisional draft's two integrated corner grips must be colored by the
// selected APP THEME COLOR (Blue theme -> blue grips, Rose theme -> rose
// grips) in BOTH Light and Dark, and MUST NOT change when the draft's Event
// Type accent changes. MP-06B: the draft SURFACE follows the same theme
// family via colorScheme.primaryContainer, the grips use colorScheme.primary
// (contrast contract), and both visible caps sit FULLY INSIDE the filled
// block. Saved Event handles keep the Event accent (unchanged).
//
// Matrix: Light+Blue, Light+Rose, Dark+Blue, Dark+Rose, each with TWO
// different Event Type accents (Temple Visit = light teal 0xFF98CED8,
// Study or Plan = purple 0xFFA272C8). One independent test per cell keeps the run
// deterministic; every cell asserts both grips equal the theme's primary
// (which is identical across the two event types => invariant by construction).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/app/theme/theme_color_mode.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/settings/application/appearance_repository.dart';

import '../../../support/test_dependencies.dart';

void main() {
  const selected = PlannerDate(year: 2026, month: 8, day: 8);

  Future<void> pumpPlanner(
    WidgetTester tester, {
    required AppearanceMode appearance,
    required ThemeColorMode themeColor,
  }) async {
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
        initialAppearance: appearance,
        initialThemeColor: themeColor,
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
  }

  Future<void> openDraft(
    WidgetTester tester, {
    required String eventTypeKey,
  }) async {
    final surface = find.byKey(const Key('planner-timeline-create-surface'));
    await tester.tapAt(tester.getTopLeft(surface) + const Offset(20, 210));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.tap(find.byKey(Key('event-type-option-$eventTypeKey')));
    await tester.pump(const Duration(milliseconds: 600));
  }

  Color gripColor(WidgetTester tester, String dotKey) {
    final paint = tester.widget<CustomPaint>(
      find.byKey(Key(dotKey)),
    );
    return (paint.painter! as dynamic).color as Color;
  }

  Color themePrimary(WidgetTester tester) {
    return Theme.of(
      tester.element(
        find.byKey(const Key('planner-provisional-start-handle-dot')),
      ),
    ).colorScheme.primary;
  }

  Future<void> runMatrixCell(
    WidgetTester tester, {
    required AppearanceMode appearance,
    required ThemeColorMode themeColor,
    required String eventTypeKey,
  }) async {
    await pumpPlanner(
      tester,
      appearance: appearance,
      themeColor: themeColor,
    );
    await openDraft(tester, eventTypeKey: eventTypeKey);
    final startDot = find.byKey(
      const Key('planner-provisional-start-handle-dot'),
    );
    final endDot = find.byKey(
      const Key('planner-provisional-end-handle-dot'),
    );
    expect(
      startDot,
      findsOneWidget,
      reason: 'START grip must remain visible in $appearance/$themeColor',
    );
    expect(
      endDot,
      findsOneWidget,
      reason: 'END grip must remain visible in $appearance/$themeColor',
    );
    final primary = themePrimary(tester);
    final startColor = gripColor(
      tester,
      'planner-provisional-start-handle-dot',
    );
    final endColor = gripColor(
      tester,
      'planner-provisional-end-handle-dot',
    );
    expect(
      startColor,
      primary,
      reason: 'MP-06: START grip color must derive from the app Theme Color '
          '($appearance/$themeColor, $eventTypeKey), not the Event accent',
    );
    expect(
      endColor,
      primary,
      reason: 'MP-06: END grip color must derive from the app Theme Color '
          '($appearance/$themeColor, $eventTypeKey), not the Event accent',
    );

    // MP-06B (owner correction 2026-08-17): the draft surface follows the
    // APP THEME FAMILY via the semantic container token
    // colorScheme.primaryContainer (Blue -> blue-family fill, Rose ->
    // rose-family fill, Light and Dark), while the grips stay on
    // colorScheme.primary - so grip and fill are always distinguishable.
    final visibleBlock = find.byKey(
      const Key('planner-provisional-event-visible'),
    );
    final material = tester.widget<Material>(
      find.descendant(of: visibleBlock, matching: find.byType(Material)).first,
    );
    final colorScheme = Theme.of(
      tester.element(startDot),
    ).colorScheme;
    expect(
      material.color,
      colorScheme.primaryContainer,
      reason: 'MP-06B: the draft fill must be the theme-family container '
          'token colorScheme.primaryContainer in $appearance/$themeColor '
          '($eventTypeKey), never a hardcoded pink',
    );
    expect(material.color, isNotNull);
    expect(material.color!.a, 1.0);

    // MP-06B (owner correction 2026-08-17): the two visible 14dp caps sit
    // FULLY INSIDE the filled draft block - START upper-right (top edge
    // flush with the block top), END bottom-left (bottom edge flush with
    // the block bottom). No straddle; the grip/fill contrast keeps them
    // visible.
    final blockRect = tester.getRect(visibleBlock);
    final startRect = tester.getRect(startDot);
    final endRect = tester.getRect(endDot);
    expect(
      startRect.top,
      closeTo(blockRect.top, 0.01),
      reason: 'MP-06B: START cap must sit fully INSIDE the block (top flush '
          'with the block top edge) in $appearance/$themeColor',
    );
    expect(
      startRect.right,
      closeTo(blockRect.right, 0.01),
      reason: 'MP-06B: START cap still hugs the block upper-right corner',
    );
    expect(
      startRect.bottom,
      lessThanOrEqualTo(blockRect.bottom + 0.01),
      reason: 'MP-06B: START cap bottom must stay inside the block bounds',
    );
    expect(
      endRect.bottom,
      closeTo(blockRect.bottom, 0.01),
      reason: 'MP-06B: END cap must sit fully INSIDE the block (bottom flush '
          'with the block bottom edge) in $appearance/$themeColor',
    );
    expect(
      endRect.left,
      closeTo(blockRect.left, 0.01),
      reason: 'MP-06B: END cap still hugs the block lower-left corner',
    );
    expect(
      endRect.top,
      greaterThanOrEqualTo(blockRect.top - 0.01),
      reason: 'MP-06B: END cap top must stay inside the block bounds',
    );
  }

  for (final appearance in const <AppearanceMode>[
    AppearanceMode.light,
    AppearanceMode.dark,
  ]) {
    for (final themeColor in const <ThemeColorMode>[
      ThemeColorMode.rose,
      ThemeColorMode.blue,
    ]) {
      testWidgets(
        'MP-06: $appearance/$themeColor draft grips are visible and use the '
        'app Theme Color (Temple Visit draft)', (tester) async {
          await runMatrixCell(
            tester,
            appearance: appearance,
            themeColor: themeColor,
            eventTypeKey: 'temple_visit',
          );
        },
      );
      testWidgets(
        'MP-06: $appearance/$themeColor draft grips are visible and use the '
        'app Theme Color (Study or Plan draft)', (tester) async {
          await runMatrixCell(
            tester,
            appearance: appearance,
            themeColor: themeColor,
            eventTypeKey: 'study_or_plan',
          );
        },
      );
    }
  }
}
