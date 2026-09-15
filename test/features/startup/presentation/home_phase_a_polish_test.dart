import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/app/theme/app_theme.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';

import '../../../support/test_dependencies.dart';

/// Phase A focused tests for the final Home polish:
///  A1 - visible heading is "Life Goals";
///  A2 - Today's Goal label is pinned to the left of the shaded inset;
///  A3 - the target progress value is centered directly beneath the label;
///  A4 - the value uses neutral primary text while minus/plus stay accent;
///  A5 - the controls sit on the right with deliberate spacing;
///  A6 - zero-state minus is hidden and absent from accessibility semantics;
///  A8 - no layout jump and no overflow at 360/393/411 dp.
void main() {
  const monday = PlannerDate(year: 2026, month: 7, day: 27);

  Future<void> pumpHome(
    WidgetTester tester, {
    Size viewport = const Size(393, 874),
    double textScale = 1.3,
  }) async {
    tester.view.physicalSize = viewport;
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final database = openMemoryDatabase();
    addTearDown(database.close);
    final startup = buildTestRepository(database: database);
    final profile = await startup.completeOnboarding();
    // M6 zero-goal law: this test describes an EXISTING (pre-M6) user, so the canonical six Goals are
    // seeded explicitly instead of being created implicitly at onboarding.
    await seedLegacyCanonicalGoals(database, profile.id);
    await establishWeeklyPlan(
      database: database,
      profileId: profile.id,
      date: monday,
    );
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
    await tester.pumpAndSettle();
  }

  Finder quickControl() =>
      find.byKey(const Key('home-daily-target-quick-control'));
  Finder minus() => find.byKey(const Key('home-daily-target-minus'));
  Finder plus() => find.byKey(const Key('home-daily-target-plus'));
  Finder asideValue() =>
      find.descendant(of: quickControl(), matching: find.textContaining('/'));

  testWidgets('A1: Home heading reads Life Goals', (tester) async {
    await pumpHome(tester);
    expect(find.text('Life Goals'), findsOneWidget);
    expect(find.text('Weekly Life Indicators'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'A2/A3/A5: label left, value centered beneath it, controls right',
    (tester) async {
      await pumpHome(tester);
      // Raise the daily target to 1 so both controls are visible.
      await tester.tap(plus());
      await tester.pumpAndSettle();
      final label = find.text("Today's Goal");
      expect(label, findsOneWidget);
      final value = asideValue();
      expect(value, findsOneWidget);

      final insetLeft = tester.getTopLeft(quickControl()).dx;
      final insetRight = tester.getTopRight(quickControl()).dx;
      final labelLeft = tester.getTopLeft(label).dx;
      // The label sits inside the compact Today block (POLISH-02: the block
      // is its own row, never sharing the Goal title row).
      expect(labelLeft, greaterThanOrEqualTo(insetLeft));
      expect(labelLeft, lessThan(insetLeft + 14));

      // The value is centered directly beneath the label.
      expect(
        (tester.getCenter(value).dx - tester.getCenter(label).dx).abs(),
        lessThan(2),
      );

      // HR-02: the +/- controls live INSIDE the opaque gray Today's Goal
      // inset (no floating + outside it); the plus is the right-most element
      // of the inset.
      final minusCenter = tester.getCenter(minus());
      final plusCenter = tester.getCenter(plus());
      expect(minusCenter.dx, greaterThan(insetLeft));
      expect(minusCenter.dx, lessThan(insetRight));
      expect(plusCenter.dx, greaterThan(minusCenter.dx));
      expect(plusCenter.dx, lessThanOrEqualTo(insetRight + 0.5));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('A4: value neutral primary text, plus control accent', (
    tester,
  ) async {
    await pumpHome(tester);
    final value = asideValue();
    final valueText = tester.widget<Text>(value);
    expect(valueText.style?.color, const Color(0xFFF4F1F2));
    expect(valueText.style?.color, isNot(AppTheme.rose));

    // The plus icon is accent at the zero state.
    final plusIcon = tester.widget<Icon>(
      find.descendant(of: plus(), matching: find.byType(Icon)),
    );
    expect(plusIcon.color, AppTheme.roseDarkPrimary);
    expect(tester.takeException(), isNull);
  });

  testWidgets('A4: left-side actual Goal progress keeps its accent style', (
    tester,
  ) async {
    await pumpHome(tester);
    // Goal 1 shows two progress values: the actual progress on the left
    // (keeps the approved accent) and the Today's Goal target inside the
    // shaded inset (neutral).  The left one is the value outside the inset.
    final goalOneValues = find.descendant(
      of: find.byKey(const Key('home-indicator-job_applications')),
      matching: find.textContaining('/'),
    );
    final quickRect = tester.getRect(quickControl());
    for (final element in goalOneValues.evaluate()) {
      final box = element.renderObject! as RenderBox;
      final center = box.localToGlobal(box.size.center(Offset.zero));
      final style = (element.widget as Text).style?.color;
      if (quickRect.contains(center)) {
        expect(style, const Color(0xFFF4F1F2));
      } else {
        expect(style, AppTheme.roseDarkPrimary);
      }
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('A6: zero-state minus hidden and semantics-excluded', (
    tester,
  ) async {
    await pumpHome(tester);
    // Default daily target is 0: no minus, reserved slot retained, plus shown.
    expect(minus(), findsNothing);
    expect(plus(), findsOneWidget);
    // The minus is absent from accessibility semantics at zero, while the
    // plus remains an accessible button.
    expect(find.bySemanticsLabel('Decrease daily target'), findsNothing);
    expect(find.bySemanticsLabel('Increase daily target'), findsOneWidget);

    // Tap plus -> target 1 -> minus appears with the same plus position.
    final plusBefore = tester.getTopLeft(plus());
    await tester.tap(plus());
    await tester.pumpAndSettle();
    expect(minus(), findsOneWidget);
    expect(find.bySemanticsLabel('Decrease daily target'), findsOneWidget);
    final plusAfter = tester.getTopLeft(plus());
    expect(
      (plusAfter.dx - plusBefore.dx).abs(),
      lessThan(0.5),
      reason: 'plus must not jump when the minus appears (A6 no-layout-jump)',
    );

    // Tap minus -> back to zero -> minus disappears again.
    await tester.tap(minus());
    await tester.pumpAndSettle();
    expect(minus(), findsNothing);
    expect(plus(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('A5: deliberate spacing between block, minus, and plus', (
    tester,
  ) async {
    await pumpHome(tester);
    // Raise the target to 1 so the minus is visible.
    await tester.tap(plus());
    await tester.pumpAndSettle();
    final value = asideValue();
    final gapToMinus =
        tester.getCenter(minus()).dx - tester.getTopRight(value).dx;
    final gapMinusToPlus =
        tester.getCenter(plus()).dx - tester.getCenter(minus()).dx;
    expect(gapToMinus, greaterThanOrEqualTo(8));
    expect(gapMinusToPlus, greaterThanOrEqualTo(4));
    expect(tester.takeException(), isNull);
  });

  testWidgets('A8: no overflow at 360, 393, and 411 dp', (tester) async {
    for (final width in <double>[360, 393, 411]) {
      await pumpHome(tester, viewport: Size(width, 820));
      expect(
        tester.getSize(quickControl()).height,
        lessThanOrEqualTo(60),
        reason: 'inset must stay compact within the 76 dp Goal card',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    }
  });
}
