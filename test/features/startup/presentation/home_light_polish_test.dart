import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/app/theme/app_theme.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/ids/identifier_source.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/goals/data/drift_goal_repository.dart';
import 'package:rmplanner/features/goals/domain/goal.dart';
import 'package:rmplanner/features/goals/presentation/widgets/goal_icon.dart';
import 'package:rmplanner/features/indicators/domain/life_indicator.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/settings/application/appearance_repository.dart';

import '../../../support/test_dependencies.dart';

/// Light UI Final Polish (B) focused Home contracts.
///
/// POLISH-01/02/04 — Light Home hierarchy:
/// - Goal cards use the semantic near-white surface in Light (no canvas-gray
///   transparent slab) while Dark keeps its current transparent behavior;
/// - Today's Goal is a compact, controlled-width right-side block (~112 dp)
///   that can never grow into the Goal title/progress region;
/// - the + action is a distinct, stable touch target to the right of the
///   Today block (minus hidden at zero without moving the plus);
/// - long Goal names render with clean two-line/ellipsis treatment — no
///   mid-word character breaking at normal phone widths;
/// - no RenderFlex overflow at 360/393/411 dp with max supported text scale;
/// - GI-02 exact 2x icon sizes (72 compact / 80 wide) are unchanged.
AppDatabase? _lastDatabase;
String? _lastProfileId;

void main() {
  const monday = PlannerDate(year: 2026, month: 7, day: 27);

  Future<void> pumpHome(
    WidgetTester tester, {
    Size viewport = const Size(393, 874),
    double textScale = 1.3,
    Brightness brightness = Brightness.light,
  }) async {
    tester.view.physicalSize = viewport;
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final database = openMemoryDatabase();
    addTearDown(database.close);
    _lastDatabase = database;
    final startup = buildTestRepository(database: database);
    final profile = await startup.completeOnboarding();
    // M6 zero-goal law: this test describes an EXISTING (pre-M6) user, so the canonical six Goals are
    // seeded explicitly instead of being created implicitly at onboarding.
    await seedLegacyCanonicalGoals(database, profile.id);
    _lastProfileId = profile.id;
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
        // Light is forced explicitly; Dark uses the null fallback (the
        // AppearanceNotifier's default is Dark).
        initialAppearance: brightness == Brightness.light
            ? AppearanceMode.light
            : null,
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
    );
  }

  Finder quickControl() =>
      find.byKey(const Key('home-daily-target-quick-control'));
  Finder minus() => find.byKey(const Key('home-daily-target-minus'));
  Finder plus() => find.byKey(const Key('home-daily-target-plus'));
  Finder dailyCard() => find.byKey(const Key('home-indicator-job_applications'));

  testWidgets('B1: Light Goal cards use the semantic surface fill; Dark stays '
      'transparent', (tester) async {
    await pumpHome(tester);
    final cardWidget = tester.widget<Card>(
      find.descendant(of: dailyCard(), matching: find.byType(Card)),
    );
    expect(
      cardWidget.color,
      AppTheme.cardOf(tester.element(dailyCard())),
      reason: 'POLISH-01: Light cards must sit on the semantic near-white '
          'surface, not the gray canvas',
    );
    expect(cardWidget.color, isNot(Colors.transparent));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    await pumpHome(tester, brightness: Brightness.dark);
    final darkCard = tester.widget<Card>(
      find.descendant(of: dailyCard(), matching: find.byType(Card)),
    );
    expect(
      darkCard.color,
      Colors.transparent,
      reason: 'Dark Home behavior must stay unchanged (transparent cards)',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('B2: Today Goal inset is compact, opaque gray, and never grows '
      'into the left Goal content', (tester) async {
    await pumpHome(tester);
    await tester.tap(plus());
    await tester.pumpAndSettle();
    final asideRect = tester.getRect(quickControl());
    // HR-02: the Today's Goal inset is a compact opaque-gray surface holding
    // label + value + the +/- controls.
    expect(
      asideRect.width,
      lessThanOrEqualTo(170),
      reason: 'HR-02: Today Goal inset must stay compact',
    );
    expect(
      asideRect.width,
      greaterThanOrEqualTo(135),
      reason: 'HR-02: inset must still hold label + value + controls',
    );
    // The inset is an OPAQUE neutral-gray surface (semantic block role), not
    // loose text floating on the white outer card.
    final insetWidget = tester.widget<Container>(quickControl());
    final insetDecoration = insetWidget.decoration! as BoxDecoration;
    expect(
      insetDecoration.color,
      AppTheme.blockOf(tester.element(quickControl())),
      reason: 'HR-02: Today Goal inset must use the neutral-gray surface role',
    );

    // HR-01 (approved reference): the Goal title shares the ONE horizontal
    // row with the Today block — title left, block right — and is never
    // placed below it or eaten by it.
    final title = find.descendant(
      of: dailyCard(),
      matching: find.text('Job Applications'),
    );
    expect(title, findsOneWidget);
    final titleRect = tester.getRect(title);
    expect(
      titleRect.right,
      lessThanOrEqualTo(asideRect.left + 0.5),
      reason: 'HR-01: Goal title must sit LEFT of the Today block, never '
          'behind it',
    );
    // The title region (between the icon and the Today block) keeps a
    // genuinely readable width (never the pre-polish 24-57 dp leftover next
    // to the Today block).  The title Text itself may ellipsize in the wide
    // test font; the REGION is what guarantees room for real-device titles.
    final icon = find.descendant(of: dailyCard(), matching: find.byType(GoalIcon));
    final iconRight = tester.getTopRight(icon).dx;
    expect(
      asideRect.left - iconRight - 8,
      greaterThanOrEqualTo(100),
      reason: 'HR-01: Goal title region must be readable, not eaten by the '
          'Today block',
    );

    // HR-02: the +/- controls are INSIDE the gray inset (no floating + on the
    // white card); the plus is the right-most element of the inset.
    final plusRect = tester.getRect(plus());
    expect(
      plusRect.left,
      greaterThanOrEqualTo(asideRect.left),
      reason: 'HR-02: + action must sit inside the Today Goal inset',
    );
    expect(
      plusRect.right,
      lessThanOrEqualTo(asideRect.right + 0.5),
      reason: 'HR-02: + action must stay inside the Today Goal inset',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('B3: + action stable at zero (minus hidden, plus does not jump) '
      'and minus toggles without reflowing the block', (tester) async {
    await pumpHome(tester);
    expect(minus(), findsNothing);
    expect(plus(), findsOneWidget);
    expect(find.bySemanticsLabel('Decrease daily target'), findsNothing);
    expect(find.bySemanticsLabel('Increase daily target'), findsOneWidget);

    final plusBefore = tester.getTopLeft(plus());
    final asideBefore = tester.getTopLeft(quickControl());
    await tester.tap(plus());
    await tester.pumpAndSettle();
    expect(minus(), findsOneWidget);
    final plusAfter = tester.getTopLeft(plus());
    final asideAfter = tester.getTopLeft(quickControl());
    expect(
      (plusAfter.dx - plusBefore.dx).abs(),
      lessThan(0.5),
      reason: 'plus must not jump when the minus appears',
    );
    expect(
      (asideAfter.dx - asideBefore.dx).abs(),
      lessThan(0.5),
      reason: 'Today block must not shift when the minus appears',
    );

    await tester.tap(minus());
    await tester.pumpAndSettle();
    expect(minus(), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('B4: long compact titles render clean two-line ellipsis — no '
      'mid-word character break at 393 dp', (tester) async {
    await pumpHome(tester);
    // Rename the first weekly (compact) Goal to the owner's observed title.
    final database = _lastDatabase;
    final repository = DriftGoalRepository(
      database: database!,
      clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
      identifiers: const UuidIdentifierSource(),
    );
    final goals = await repository.readActiveGoals(_lastProfileId!);
    final weekly = goals.firstWhere((goal) => goal.role == GoalRole.weekly);
    await repository.saveGoal(
      profileId: _lastProfileId!,
      goalId: weekly.id,
      title: 'Ministering Visit',
      iconId: weekly.iconId,
      targets: const GoalTargets(
        weekly: IndicatorAmount(scaledValue: 2, scale: 0, unit: 'count'),
      ),
      operationId: 'polish-b4-rename',
    );
    await tester.pumpAndSettle();

    // HR-01: the compact card is a horizontal icon + single-line title row
    // (approved reference shows truncated labels like "Work with Mission...").
    // The title never wraps (no second line, no mid-word character break) —
    // long labels ellipsize cleanly on the one line.
    final titleFinder = find.text('Ministering Visit');
    expect(titleFinder, findsWidgets);
    final textWidget = tester.widget<Text>(titleFinder.first);
    expect(
      textWidget.maxLines,
      1,
      reason: 'HR-01: compact titles stay on one line (ellipsis, never wrap)',
    );
    expect(
      textWidget.overflow,
      TextOverflow.ellipsis,
      reason: 'HR-01: long compact titles ellipsize cleanly',
    );
    // The compact title is inside its Goal card (icon beside text, no
    // icon-above-text stack).
    final card = find.ancestor(
      of: titleFinder.first,
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is Card &&
            widget.key?.toString().contains('home-indicator-goal') == true,
      ),
    );
    expect(card, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('B5: HI-02 Home icon sizes (top/Temple 64 / compact 60) — '
      'audited largest pair at 76dp, no GI-02 2x sizes on Home', (tester) async {
    await pumpHome(tester);
    final icons = find.descendant(of: dailyCard(), matching: find.byType(GoalIcon));
    expect(icons, findsOneWidget);
    expect(
      tester.widget<GoalIcon>(icons).size,
      64,
      reason: 'HI-02: top wide Goal icon is 64 dp (painted-art audit; was 54)',
    );
    // Compact weekly cards use 60 dp; no GI-02 72/80 sizes anywhere on Home.
    final allSizes = find
        .byType(GoalIcon)
        .evaluate()
        .map((e) => (e.widget as GoalIcon).size)
        .toList();
    expect(
      allSizes.contains(60),
      isTrue,
      reason: 'compact Home icons are 60 dp (painted-art audit; was 50)',
    );
    // HI-02 icon visibility: every Home icon must be the audited pair.
    for (final size in allSizes) {
      expect(
        size == 60 || size == 64,
        isTrue,
        reason: 'HI-02: Home icons must be the pinned 60/64 values, found '
            '$size',
      );
    }
    expect(
      allSizes.any((size) => size == 72 || size == 80),
      isFalse,
      reason: 'HI-02: Home uses compact 60/64 icons, not the GI-02 2x sizes',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('B6: no overflow at 360 / 393 / 411 with max text scale in '
      'Light', (tester) async {
    for (final width in <double>[360, 393, 411]) {
      await pumpHome(tester, viewport: Size(width, 820));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    }
  });

  testWidgets('B7: HR-02 special rows — ONE full-width top card with the '
      'Today inset inside, ONE full-width Temple card with the August inset '
      'inside (no split bottom pair)', (tester) async {
    await pumpHome(tester);
    // Top: the daily Goal card is ONE full-width card and the Today inset is
    // INSIDE it (not a sibling card, no floating + on the white surface).
    final daily = dailyCard();
    expect(daily, findsOneWidget);
    expect(
      tester.getSize(daily).width,
      closeTo(357, 0.01),
      reason: 'HR-02: top row must be ONE full-width Goal card',
    );
    expect(
      find.descendant(of: daily, matching: quickControl()),
      findsOneWidget,
      reason: 'HR-02: the Today Goal inset must live inside the top card',
    );

    // Bottom: the Temple card is ONE full-width card and the August Goal
    // inset is INSIDE it — there must be no separate half-width bottom cards.
    final temple = find.byKey(const Key('home-indicator-temple_visit'));
    expect(temple, findsOneWidget);
    expect(
      tester.getSize(temple).width,
      closeTo(357, 0.01),
      reason: 'HR-02: bottom row must be ONE full-width Temple card',
    );
    final monthInset = find.byKey(const Key('home-month-goal-card'));
    expect(monthInset, findsOneWidget);
    expect(
      find.descendant(of: temple, matching: monthInset),
      findsOneWidget,
      reason: 'HR-02: the August Goal inset must live inside the Temple card',
    );
    // The August inset is an OPAQUE neutral-gray surface, not a white card.
    final monthWidget = tester.widget<Container>(monthInset);
    final monthDecoration = monthWidget.decoration! as BoxDecoration;
    expect(
      monthDecoration.color,
      AppTheme.blockOf(tester.element(monthInset)),
      reason: 'HR-02: the August Goal inset must use the neutral-gray surface',
    );
    // The Temple icon is the HI-02 64 dp size.
    final templeIcon = find.descendant(
      of: temple,
      matching: find.byType(GoalIcon),
    );
    expect(templeIcon, findsOneWidget);
    expect(
      tester.widget<GoalIcon>(templeIcon).size,
      64,
      reason: 'HI-02: Temple icon must be 64 dp (painted-art audit; was 54)',
    );
    expect(tester.takeException(), isNull);
  });
}
