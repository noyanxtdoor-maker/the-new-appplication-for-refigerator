import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:rmplanner/app/router/route_names.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/maps/presentation/maps_screen.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/startup/data/drift_startup_repository.dart';
import 'package:rmplanner/features/startup/domain/local_profile.dart';
import 'package:rmplanner/features/weekly_planning/domain/weekly_plan.dart';

import '../../support/test_dependencies.dart';

/// Pack 2 focused navigation tests.
///
/// Root tabs: Planner/Contacts + Android Back reveal the existing Home
/// root; the legacy /more route compat-redirects to Home (NX-07/08).  Home +
/// Back is left unhandled so the platform exits.  Child pages pop to
/// their logical parent; Planning week browsing stays local; Plan History
/// returns to Planning; dialogs dismiss before navigation; dirty forms keep
/// their existing unsaved-change protection on both toolbar and Android Back.
void main() {
  const monday = PlannerDate(year: 2026, month: 7, day: 27);

  Future<(DriftStartupRepository, LocalProfile)> pumpApp(
    WidgetTester tester, {
    bool seedPriorWeekPlan = false,
  }) async {
    tester.view.physicalSize = const Size(393, 874);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final database = openMemoryDatabase();
    addTearDown(database.close);
    final startup = buildTestRepository(database: database);
    // M6 zero-goal law: these scenarios describe an EXISTING (pre-M6) user
    // whose canonical Goals the app used to create implicitly at onboarding.
    final profile = await startup.completeOnboarding();
    await seedLegacyCanonicalGoals(database, profile.id);
    if (seedPriorWeekPlan) {
      await database
          .into(database.weeklyPlans)
          .insert(
            WeeklyPlansCompanion.insert(
              id: 'pack2-seed-prior-week-plan',
              profileId: profile.id,
              periodStartDate: '2026-07-20',
              periodEndDate: '2026-07-26',
              timeZoneId: 'Asia/Manila',
              state: WeeklyPlanState.historical.name,
              createdAtUtc: DateTime.utc(2026, 7, 20, 12),
              updatedAtUtc: DateTime.utc(2026, 7, 26, 12),
            ),
          );
    }
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
    return (startup, profile);
  }

  Finder bottomNav() => find.byKey(const Key('main-bottom-navigation'));
  Finder homeAppBar() => find.byKey(const Key('home-app-bar'));
  Finder plannerDateLabel() => find.byKey(const Key('planner-date-label'));

  Future<void> tapTab(WidgetTester tester, String label) async {
    await tester.tap(
      find.descendant(of: bottomNav(), matching: find.text(label)),
    );
    await tester.pumpAndSettle();
  }

  Future<void> goToPlanning(WidgetTester tester) async {
    await tester.ensureVisible(find.byKey(const Key('weekly-targets-button')));
    await tester.tap(find.byKey(const Key('weekly-targets-button')));
    await tester.pumpAndSettle();
    expect(find.text('Goal Planning'), findsOneWidget);
  }

  testWidgets(
    'primary navigation restores labels and the themed selected indicator',
    (tester) async {
      await pumpApp(tester);

      final navigation = tester.widget<NavigationBar>(bottomNav());
      final navigationTheme = NavigationBarTheme.of(
        tester.element(bottomNav()),
      );
      final colorScheme = Theme.of(tester.element(bottomNav())).colorScheme;

      expect(navigation.labelBehavior, isNull);
      expect(navigation.indicatorColor, isNull);
      expect(
        navigationTheme.labelBehavior,
        NavigationDestinationLabelBehavior.alwaysShow,
      );
      expect(
        navigationTheme.indicatorColor,
        colorScheme.brightness == Brightness.light
            ? colorScheme.primary
            : Colors.transparent,
      );
      expect(navigationTheme.height, 72);
      final selectedLabelColor = navigationTheme.labelTextStyle?.resolve(
        <WidgetState>{WidgetState.selected},
      )?.color;
      final unselectedLabelColor = navigationTheme.labelTextStyle
          ?.resolve(<WidgetState>{})
          ?.color;
      expect(selectedLabelColor, isNotNull);
      expect(selectedLabelColor, isNot(Colors.transparent));
      expect(unselectedLabelColor, isNotNull);
      expect(unselectedLabelColor, isNot(Colors.transparent));
    },
  );

  testWidgets('Planner tab + Android Back reveals the existing Home root', (
    tester,
  ) async {
    await pumpApp(tester);
    await tapTab(tester, 'Planner');
    expect(plannerDateLabel(), findsOneWidget);
    expect(homeAppBar(), findsNothing);

    final handled = await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(handled, isTrue, reason: 'root Back must be consumed by the app');
    expect(homeAppBar(), findsOneWidget);
    expect(plannerDateLabel(), findsNothing);
  });

  testWidgets('VS15 M1.1: Event Detail Back restores the same Maps instance', (
    tester,
  ) async {
    await pumpApp(tester);
    await tapTab(tester, 'Maps');
    final maps = find.byType(MapsScreen);
    expect(maps, findsOneWidget);
    final originalState = tester.state(maps);
    final context = tester.element(maps);

    unawaited(
      GoRouter.of(
        context,
      ).push(RoutePaths.calendarEventDetail('missing-event', monday)),
    );
    await tester.pumpAndSettle();
    expect(maps, findsNothing);

    final handled = await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(handled, isTrue);
    expect(maps, findsOneWidget);
    expect(tester.state(maps), same(originalState));
  });

  testWidgets(
    'NX-07/08: the legacy /more route compat-redirects to Home and never '
    'renders a More landing page',
    (tester) async {
      await pumpApp(tester);
      final context = tester.element(find.byType(Scaffold).first);
      GoRouter.of(context).go(RoutePaths.more);
      await tester.pumpAndSettle();
      expect(homeAppBar(), findsOneWidget);
      expect(find.byKey(const Key('more-settings')), findsNothing);
    },
  );

  testWidgets('Home + Android Back is left unhandled so the platform exits', (
    tester,
  ) async {
    await pumpApp(tester);
    expect(homeAppBar(), findsOneWidget);
    final handled = await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(handled, isFalse, reason: 'Home Back must reach the platform exit');
  });

  testWidgets(
    'Repeated tab switching never unwinds tabs and keeps one Home root',
    (tester) async {
      await pumpApp(tester);
      await tapTab(tester, 'Planner');
      await tapTab(tester, 'Contacts');
      await tapTab(tester, 'Planner');
      await tapTab(tester, 'Home');

      // One Android Back goes straight to Home (no tab-by-tab unwinding).
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(homeAppBar(), findsOneWidget);
      expect(find.byKey(const Key('home-app-bar')), findsOneWidget);
      // Exactly one Home root exists.
      expect(homeAppBar(), findsOneWidget);
    },
  );

  testWidgets(
    'NX-07/08: Settings (a /more child) opened from the drawer; Android Back '
    'returns to the Home root (no More root)',
    (tester) async {
      await pumpApp(tester);
      await tester.tap(find.byKey(const Key('home-hamburger')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('drawer-account-settings')));
      await tester.pumpAndSettle();
      expect(find.text('Settings'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(homeAppBar(), findsOneWidget);
    },
  );

  testWidgets('Planning toolbar Back and Android Back both return Home', (
    tester,
  ) async {
    await pumpApp(tester);
    await goToPlanning(tester);

    // Android Back.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(homeAppBar(), findsOneWidget);
    expect(find.byKey(const Key('weekly-plan-list')), findsNothing);

    // Toolbar Back.
    await goToPlanning(tester);
    await tester.tap(find.byKey(const Key('weekly-plan-back-home')));
    await tester.pumpAndSettle();
    expect(homeAppBar(), findsOneWidget);
    expect(find.byKey(const Key('weekly-plan-list')), findsNothing);
  });

  testWidgets('Week browsing is local state; Back returns Home directly', (
    tester,
  ) async {
    await pumpApp(tester);
    await goToPlanning(tester);
    expect(find.textContaining('Jul 27'), findsOneWidget);

    // Browse three previous weeks.  Each arrow changes local state only.
    for (var index = 0; index < 3; index += 1) {
      await tester.tap(find.byTooltip('Previous week'));
      await tester.pumpAndSettle();
    }
    expect(find.textContaining('Jul 6'), findsOneWidget);
    expect(find.text('Goal Planning'), findsOneWidget);

    // A single Back returns Home - no week-by-week unwinding.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(homeAppBar(), findsOneWidget);
  });

  testWidgets('Plan History Back returns to Planning (B5)', (tester) async {
    await pumpApp(tester);
    await goToPlanning(tester);
    await tester.tap(find.byKey(const Key('weekly-plan-history-button')));
    await tester.pumpAndSettle();
    expect(find.text('Plan History'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Goal Planning'), findsOneWidget);
    expect(find.text('Plan History'), findsNothing);
  });

  testWidgets('Selecting a prior week lands on Planning; Back returns Home', (
    tester,
  ) async {
    await pumpApp(tester, seedPriorWeekPlan: true);
    await goToPlanning(tester);
    await tester.tap(find.byKey(const Key('weekly-plan-history-button')));
    await tester.pumpAndSettle();
    expect(find.text('Plan History'), findsOneWidget);

    // Choose the seeded prior week.
    await tester.tap(find.textContaining('2026-07-20'));
    await tester.pumpAndSettle();
    expect(find.text('Goal Planning'), findsOneWidget);
    expect(find.textContaining('Jul 20'), findsOneWidget);

    // Back returns Home directly - no history stack unwinding.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(homeAppBar(), findsOneWidget);
    expect(find.byKey(const Key('weekly-plan-list')), findsNothing);
  });

  testWidgets(
    'Modal-first: Android Back dismisses the dialog, screen remains',
    (tester) async {
      await pumpApp(tester);
      await goToPlanning(tester);
      await tester.tap(find.byKey(const Key('weekly-plan-create-goal')));
      await tester.pumpAndSettle();
      expect(find.text('Goal limit reached'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Goal limit reached'), findsNothing);
      expect(find.text('Goal Planning'), findsOneWidget);
    },
  );

  testWidgets('Direct-entered /planner child falls back to Planner root (B7)', (
    tester,
  ) async {
    await pumpApp(tester);
    // Bypass the normal push flow: open weekly planning directly, as the
    // goal-create flow does (context.go), so no parent page sits beneath it.
    final context = tester.element(find.byType(Scaffold).first);
    GoRouter.of(context).go(RoutePaths.weeklyPlanning);
    await tester.pumpAndSettle();
    expect(find.text('Goal Planning'), findsOneWidget);

    final handled = await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(handled, isTrue);
    expect(
      plannerDateLabel(),
      findsOneWidget,
      reason: 'logical root is Planner',
    );
    expect(homeAppBar(), findsNothing);
  });

  testWidgets(
    'NX-07/08: Direct-entered /more child falls back to Home root (B7)',
    (tester) async {
      await pumpApp(tester);
      final context = tester.element(find.byType(Scaffold).first);
      GoRouter.of(context).go(RoutePaths.settings);
      await tester.pumpAndSettle();
      expect(find.text('Settings'), findsOneWidget);

      final handled = await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(handled, isTrue);
      expect(homeAppBar(), findsOneWidget);
    },
  );

  testWidgets(
    'Dirty Edit Goal: toolbar Back and Android Back share one guard (B4)',
    (tester) async {
      await pumpApp(tester);
      await goToPlanning(tester);
      await tester.tap(
        find.byKey(const Key('weekly-plan-indicator-job_applications')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Edit Goal'), findsOneWidget);

      // Modify the title -> dirty.
      await tester.enterText(find.byKey(const Key('goal-title')), 'Changed');
      await tester.pumpAndSettle();

      // Android Back invokes the existing unsaved-change protection.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Unsaved Changes'), findsOneWidget);
      await tester.tap(find.byKey(const Key('goal-continue-editing')));
      await tester.pumpAndSettle();
      expect(find.text('Edit Goal'), findsOneWidget);
      expect(find.text('Unsaved Changes'), findsNothing);

      // Toolbar Back invokes the same protection.
      await tester.tap(find.byKey(const Key('goal-edit-back')));
      await tester.pumpAndSettle();
      expect(find.text('Unsaved Changes'), findsOneWidget);
      await tester.tap(find.byKey(const Key('goal-discard-changes')));
      await tester.pumpAndSettle();
      expect(find.text('Goal Planning'), findsOneWidget);
      expect(find.text('Unsaved Changes'), findsNothing);
    },
  );
}
