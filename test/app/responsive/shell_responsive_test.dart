import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';

import '../../support/test_dependencies.dart';
import '../../support/view_size.dart';

/// PRE-BETA RESPONSIVE (owner law, 2026-09-16) — the shell presents ONE
/// destination model in two presentations.
///
/// LAW: available window width < 600 logical px -> bottom navigation bar;
///      available window width >= 600 logical px -> side navigation rail.
/// The choice is WINDOW-based, never device-based, and selection still comes
/// from the router, so the two presentations can never hold independent state.
void main() {
  const PlannerDate monday = PlannerDate(year: 2026, month: 7, day: 27);

  Future<void> pumpShell(WidgetTester tester, Size size) async {
    setLogicalViewSize(tester, size);
    final database = openMemoryDatabase();
    addTearDown(database.close);
    final startup = buildTestRepository(database: database);
    await startup.completeOnboarding();
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

  Finder barFinder() => find.byKey(const Key('main-bottom-navigation'));
  Finder railFinder() => find.byKey(const Key('main-navigation-rail'));

  /// Every destination key must resolve in BOTH presentations, exactly once.
  void expectAllDestinationsPresent() {
    for (final String key in <String>[
      'nav-home',
      'nav-planner',
      'nav-contacts',
      'nav-maps',
    ]) {
      expect(find.byKey(Key(key)), findsOneWidget, reason: '$key missing');
    }
    for (final String label in <String>[
      'Home',
      'Planner',
      'Contacts',
      'Maps',
    ]) {
      expect(
        find.descendant(of: navigationFinder(), matching: find.text(label)),
        findsOneWidget,
        reason: '$label label missing',
      );
    }
  }

  void expectExactlyOnePresentation() {
    final int mounted =
        barFinder().evaluate().length + railFinder().evaluate().length;
    expect(
      mounted,
      1,
      reason: 'exactly one navigation presentation may be mounted',
    );
  }

  group('compact width keeps the accepted bottom bar', () {
    testWidgets('393x874 uses NavigationBar and no rail', (tester) async {
      await pumpShell(tester, TestWindowSizes.phonePortrait);
      expect(barFinder(), findsOneWidget);
      expect(railFinder(), findsNothing);
      expectExactlyOnePresentation();
      expectAllDestinationsPresent();
      expect(tester.widget<NavigationBar>(barFinder()).selectedIndex, 0);
    });

    testWidgets('a narrow phone still uses the bar', (tester) async {
      await pumpShell(tester, TestWindowSizes.narrowPhone);
      expect(barFinder(), findsOneWidget);
      expect(railFinder(), findsNothing);
      expectAllDestinationsPresent();
    });

    testWidgets('a compact split window still uses the bar', (tester) async {
      await pumpShell(tester, TestWindowSizes.compactSplit);
      expect(barFinder(), findsOneWidget);
      expect(railFinder(), findsNothing);
      expectExactlyOnePresentation();
    });
  });

  group('medium width and above use the side rail', () {
    testWidgets('600x800 uses NavigationRail and no bar', (tester) async {
      await pumpShell(tester, TestWindowSizes.mediumWidthBoundary);
      expect(railFinder(), findsOneWidget);
      expect(barFinder(), findsNothing);
      expectExactlyOnePresentation();
      expectAllDestinationsPresent();
      expect(tester.widget<NavigationRail>(railFinder()).selectedIndex, 0);
    });

    testWidgets('1024x640 uses the rail with no duplicate keys', (
      tester,
    ) async {
      await pumpShell(tester, TestWindowSizes.tabletLandscape);
      expect(railFinder(), findsOneWidget);
      expect(barFinder(), findsNothing);
      expectExactlyOnePresentation();
      expectAllDestinationsPresent();
    });

    testWidgets('a landscape phone uses the rail (width rule, not device)', (
      tester,
    ) async {
      await pumpShell(tester, TestWindowSizes.phoneLandscape);
      expect(railFinder(), findsOneWidget);
      expect(barFinder(), findsNothing);
      expectExactlyOnePresentation();
    });

    testWidgets('a large tablet window uses the rail', (tester) async {
      await pumpShell(tester, TestWindowSizes.largeTablet);
      expect(railFinder(), findsOneWidget);
      expect(barFinder(), findsNothing);
    });
  });

  group('the breakpoint is exact', () {
    testWidgets('599 is the bar, 600 is the rail, with no overlap', (
      tester,
    ) async {
      await pumpShell(tester, TestWindowSizes.compactWidthBoundary);
      expect(barFinder(), findsOneWidget);
      expect(railFinder(), findsNothing);

      await pumpShell(tester, TestWindowSizes.mediumWidthBoundary);
      expect(railFinder(), findsOneWidget);
      expect(barFinder(), findsNothing);
    });

    testWidgets('839 keeps the rail: the rail is not a second breakpoint', (
      tester,
    ) async {
      await pumpShell(tester, TestWindowSizes.mediumUpperBoundary);
      expect(railFinder(), findsOneWidget);
      expect(barFinder(), findsNothing);
    });
  });

  group('navigation behaviour is identical in both presentations', () {
    testWidgets('the rail routes to Planner, Contacts and Maps', (
      tester,
    ) async {
      await pumpShell(tester, TestWindowSizes.tabletLandscape);

      await tester.tap(navigationLabelFinder('Planner'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('planner-date-label')), findsOneWidget);
      expect(tester.widget<NavigationRail>(railFinder()).selectedIndex, 1);

      await tester.tap(navigationLabelFinder('Maps'));
      await tester.pumpAndSettle();
      expect(tester.widget<NavigationRail>(railFinder()).selectedIndex, 3);

      await tester.tap(navigationLabelFinder('Home'));
      await tester.pumpAndSettle();
      expect(tester.widget<NavigationRail>(railFinder()).selectedIndex, 0);
    });

    testWidgets('a live resize keeps the route AND the selection', (
      tester,
    ) async {
      await pumpShell(tester, TestWindowSizes.phonePortrait);

      await tester.tap(navigationLabelFinder('Planner'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('planner-date-label')), findsOneWidget);

      // Grow the window across the breakpoint while the shell stays mounted.
      tester.view.physicalSize = TestWindowSizes.tabletLandscape;
      tester.view.devicePixelRatio = 1;
      await tester.pumpAndSettle();

      expect(railFinder(), findsOneWidget);
      expect(barFinder(), findsNothing);
      expect(
        find.byKey(const Key('planner-date-label')),
        findsOneWidget,
        reason: 'the route must survive a window-size change',
      );
      expect(
        tester.widget<NavigationRail>(railFinder()).selectedIndex,
        1,
        reason: 'the selected destination must survive a resize',
      );
      // One shell, one router: never a second navigation system.
      expect(find.byType(Scaffold), findsWidgets);
      expect(railFinder(), findsOneWidget);

      // And back down again.
      tester.view.physicalSize = TestWindowSizes.phonePortrait;
      await tester.pumpAndSettle();
      expect(barFinder(), findsOneWidget);
      expect(railFinder(), findsNothing);
      expect(tester.widget<NavigationBar>(barFinder()).selectedIndex, 1);
      expect(find.byKey(const Key('planner-date-label')), findsOneWidget);
    });
  });

  group('the drawer survives both presentations', () {
    Future<void> openDrawer(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('home-hamburger')));
      await tester.pumpAndSettle();
    }

    testWidgets('drawer stays capped and complete at compact width', (
      tester,
    ) async {
      await pumpShell(tester, TestWindowSizes.phonePortrait);
      await openDrawer(tester);

      final Finder drawer = find.byKey(const Key('global-app-drawer'));
      expect(drawer, findsOneWidget);
      expect(tester.getSize(drawer).width, lessThanOrEqualTo(360));
      expect(find.byKey(const Key('drawer-planner')), findsOneWidget);
      expect(find.byKey(const Key('drawer-about')), findsOneWidget);
      expect(find.byKey(const Key('global-app-drawer-list')), findsOneWidget);
    });

    testWidgets('drawer stays capped and complete at expanded width', (
      tester,
    ) async {
      await pumpShell(tester, TestWindowSizes.tabletLandscape);
      await openDrawer(tester);

      final Finder drawer = find.byKey(const Key('global-app-drawer'));
      expect(drawer, findsOneWidget);
      // 86% of 1024 would be 880 dp; the accepted 360 dp cap must still win.
      expect(tester.getSize(drawer).width, lessThanOrEqualTo(360));
      expect(find.byKey(const Key('drawer-about')), findsOneWidget);
    });
  });
}
