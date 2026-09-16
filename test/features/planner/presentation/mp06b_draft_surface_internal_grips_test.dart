// MP-06B owner correction (2026-08-17, HIGHEST AUTHORITY):
//   1. The provisional draft SURFACE follows the APP THEME FAMILY
//      (Blue appearance -> blue-family fill, Rose appearance -> rose-family
//      fill) in both Light and Dark, never a hardcoded pink.
//   2. The two visible grips are FULLY INSIDE the filled draft block
//      (START upper-right, END bottom-left), reusing the shared saved-event
//      Corner Tab Grip painter/shape.
//   3. Grip color follows the app theme family: grip = colorScheme.primary,
//      fill = colorScheme.primaryContainer (existing semantic tokens).
//      OWNER DECISION 2026-09-16 (Option A): the original "grip vs fill
//      >= 3.0" bar is SUPERSEDED by the owner-approved M6 palette and is NOT
//      replaced by a weaker threshold. The accepted accent + container are
//      locked EXACTLY per appearance/theme instead, and the accepted M6
//      contrast contracts (white-on-primary >= 4.5, dark primary vs the
//      documented dark background >= 4.0) are asserted in its place.
//      BETA ACCESSIBILITY REVIEW ITEM (recorded, deliberately not a gate):
//        provisional draft grip vs draft fill
//          dark/blue : #277CB5 on #123A5C = 2.5968:1
//          dark/rose : #C34D6E on #703346 = 2.0468:1
//          light/*   : above the historical 3.0 bar, unchanged.
//   4. Event Type MUST NOT recolor the draft surface or the draft grips.
//   5. Saved-Event surface/grip behavior is untouched (covered by the
//      existing MP-06/delta suites).
// Matrix: Light+Blue, Light+Rose, Dark+Blue, Dark+Rose, each with TWO
// different Event Type accents (Temple Visit = light teal, Study or Plan =
// purple). One independent test per cell keeps the run deterministic.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/app/theme/app_theme.dart';
import 'package:rmplanner/app/theme/theme_color_mode.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/settings/application/appearance_repository.dart';

import '../../../support/test_dependencies.dart';

double _relativeLuminance(Color color) {
  double channel(double c) {
    final v = c <= 0.03928 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4) as double;
    return v;
  }

  return 0.2126 * channel(color.r) +
      0.7152 * channel(color.g) +
      0.0722 * channel(color.b);
}

double _contrastRatio(Color a, Color b) {
  final la = _relativeLuminance(a);
  final lb = _relativeLuminance(b);
  final lighter = math.max(la, lb);
  final darker = math.min(la, lb);
  return (lighter + 0.05) / (darker + 0.05);
}

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

    final visibleBlock = find.byKey(
      const Key('planner-provisional-event-visible'),
    );
    final startDot = find.byKey(
      const Key('planner-provisional-start-handle-dot'),
    );
    final endDot = find.byKey(
      const Key('planner-provisional-end-handle-dot'),
    );
    expect(startDot, findsOneWidget, reason: 'START grip visible');
    expect(endDot, findsOneWidget, reason: 'END grip visible');
    expect(tester.getSize(startDot), const Size(14, 14));
    expect(tester.getSize(endDot), const Size(14, 14));

    final colorScheme = Theme.of(
      tester.element(startDot),
    ).colorScheme;
    final grip = colorScheme.primary;
    final fill = colorScheme.primaryContainer;

    Color paintColor(Key key) {
      final paint = tester.widget<CustomPaint>(find.byKey(key));
      return (paint.painter! as dynamic).color as Color;
    }

    // MP-06B: draft fill follows the APP THEME FAMILY container token.
    final material = tester.widget<Material>(
      find.descendant(of: visibleBlock, matching: find.byType(Material)).first,
    );
    expect(
      material.color,
      fill,
      reason: 'MP-06B: draft surface must be the theme-family container '
          'token colorScheme.primaryContainer in $appearance/$themeColor '
          '($eventTypeKey) - never a hardcoded pink',
    );
    // The draft remains a SOLID FILLED provisional block.
    expect(material.color, isNotNull);
    expect(material.color!.a, 1.0);

    // MP-06B: grip color = theme primary, invariant across Event Type.
    final startColor = paintColor(
      const Key('planner-provisional-start-handle-dot'),
    );
    final endColor = paintColor(
      const Key('planner-provisional-end-handle-dot'),
    );
    expect(
      startColor,
      grip,
      reason: 'MP-06B: START grip must be colorScheme.primary in '
          '$appearance/$themeColor ($eventTypeKey)',
    );
    expect(
      endColor,
      grip,
      reason: 'MP-06B: END grip must be colorScheme.primary in '
          '$appearance/$themeColor ($eventTypeKey)',
    );

    // MP-06B OWNER DECISION (2026-09-16, Option A): the accepted M6 palette
    // wins over the historical grip/fill >= 3.0 bar, which is SUPERSEDED. No
    // weaker threshold replaces it: the accepted identity below is locked
    // exactly, and the M6 contrast contracts that remain in force are asserted
    // in its place. The measured pair is recorded as a BETA ACCESSIBILITY
    // REVIEW ITEM (see the file header).
    late final Color expectedAccent;
    late final Color expectedFill;
    if (appearance == AppearanceMode.dark) {
      if (themeColor == ThemeColorMode.blue) {
        expectedAccent = AppTheme.blueDarkPrimary;
        expectedFill = AppTheme.blueDarkPrimaryContainer;
      } else {
        expectedAccent = AppTheme.roseDarkPrimary;
        // The dark rose scheme deliberately leaves primaryContainer to
        // ColorScheme.fromSeed(seedColor: AppTheme.rose); this is that exact
        // resolved container, recorded so the accepted tone cannot drift.
        expectedFill = const Color(0xFF703346);
      }
    } else if (themeColor == ThemeColorMode.blue) {
      expectedAccent = AppTheme.blueLightPrimary;
      expectedFill = AppTheme.blueLightPrimaryContainer;
    } else {
      expectedAccent = AppTheme.roseLightPrimary;
      expectedFill = AppTheme.roseLightPrimaryContainer;
    }
    expect(
      grip,
      expectedAccent,
      reason: 'MP-06B: the accepted $appearance/$themeColor accent identity '
          'must not move ($eventTypeKey)',
    );
    expect(
      fill,
      expectedFill,
      reason: 'MP-06B: the accepted $appearance/$themeColor draft container '
          'must not move ($eventTypeKey)',
    );
    // Still two different colours, so the grips stay visible against the fill.
    // The exact accepted ratio is recorded for beta accessibility review
    // instead of being enforced as a threshold.
    final ratio = _contrastRatio(grip, fill);
    expect(
      ratio,
      greaterThan(1.0),
      reason: 'MP-06B: grip ($grip) must remain a different colour from the '
          'draft fill ($fill) in $appearance/$themeColor ($eventTypeKey); '
          'accepted ratio is the recorded beta item; got $ratio',
    );
    if (appearance == AppearanceMode.dark) {
      // The accepted M6 dark contracts, in force in place of the retired bar.
      expect(
        _contrastRatio(AppTheme.darkOnPrimary, grip),
        greaterThanOrEqualTo(4.5),
        reason: 'M6: white on the dark primary must stay >= 4.5:1',
      );
      expect(
        _contrastRatio(grip, AppTheme.background),
        greaterThanOrEqualTo(4.0),
        reason: 'M6: the dark primary against the documented dark background '
            'must stay >= 4.0:1',
      );
    }

    // MP-06B: the visible caps are FULLY INSIDE the filled draft block.
    final blockRect = tester.getRect(visibleBlock);
    final startRect = tester.getRect(startDot);
    final endRect = tester.getRect(endDot);
    expect(
      startRect.right,
      closeTo(blockRect.right, 0.01),
      reason: 'START grip must hug the block upper-RIGHT corner',
    );
    expect(
      startRect.top,
      closeTo(blockRect.top, 0.01),
      reason: 'MP-06B: START cap must sit fully INSIDE the block (top flush '
          'with the block top edge), not straddling outside, in '
          '$appearance/$themeColor',
    );
    expect(
      startRect.bottom,
      lessThanOrEqualTo(blockRect.bottom + 0.01),
      reason: 'MP-06B: START cap bottom must stay inside the block bounds',
    );
    expect(
      endRect.left,
      closeTo(blockRect.left, 0.01),
      reason: 'END grip must hug the block bottom-LEFT corner',
    );
    expect(
      endRect.bottom,
      closeTo(blockRect.bottom, 0.01),
      reason: 'MP-06B: END cap must sit fully INSIDE the block (bottom flush '
          'with the block bottom edge), not straddling outside, in '
          '$appearance/$themeColor',
    );
    expect(
      endRect.top,
      greaterThanOrEqualTo(blockRect.top - 0.01),
      reason: 'MP-06B: END cap top must stay inside the block bounds',
    );

    // Time-only provisional presentation is preserved (no Event Type title).
    expect(
      find.descendant(of: visibleBlock, matching: find.text(eventTypeKey)),
      findsNothing,
    );

    await tester.tap(find.byKey(const Key('calendar-event-sheet-close')));
    await tester.pump(const Duration(milliseconds: 600));
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
        'MP-06B: $appearance/$themeColor draft surface is theme-family '
        'filled and both grips are internal theme-color caps (Temple Visit)',
        (tester) async {
          await runMatrixCell(
            tester,
            appearance: appearance,
            themeColor: themeColor,
            eventTypeKey: 'temple_visit',
          );
        },
      );
      testWidgets(
        'MP-06B: $appearance/$themeColor draft surface is theme-family '
        'filled and both grips are internal theme-color caps (Study or Plan)',
        (tester) async {
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
