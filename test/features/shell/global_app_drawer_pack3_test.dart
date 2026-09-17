// Pack 3 — focused tests for the canonical global navigation drawer.
//
// Covers: opens from every approved root, canonical IA (sections, labels,
// filtered destinations), no chevrons/subtitles/badges, tap-outside close,
// Android Back closes the drawer first, current-destination tap adds no
// route, root selection, child destinations with correct Back behavior,
// direct-entry fallbacks, and no duplicate Home / shell.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/planner/presentation/activity_history_screen.dart';
import 'package:rmplanner/features/planner/presentation/planner_screen.dart';
import 'package:rmplanner/features/settings/presentation/settings_screen.dart';
import 'package:rmplanner/features/shell/about_screen.dart';
import 'package:rmplanner/features/shell/messages_screen.dart';
import 'package:rmplanner/features/startup/presentation/home_screen.dart';
import 'package:rmplanner/features/weekly_planning/presentation/weekly_planning_screen.dart';

import '../../support/test_dependencies.dart';

void main() {
  Future<void> pumpApp(
    WidgetTester tester, {
    Size size = const Size(431, 912),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final database = openMemoryDatabase();
    addTearDown(database.close);
    final privacy = TestPrivacyDependencies(database: database);
    final startup = buildTestRepository(
      database: database,
      privacyGate: privacy.gate,
    );
    await startup.completeOnboarding();
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
  }

  Finder drawerFinder() => find.byKey(const Key('global-app-drawer'));

  Finder entryFinder(String id) => find.byKey(Key(id));

  Future<void> openDrawerFromHome(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('home-hamburger')));
    await tester.pumpAndSettle();
  }

  Future<void> tapTab(WidgetTester tester, String label) async {
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('main-bottom-navigation')),
        matching: find.text(label),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('Pack 3 drawer — shell', () {
    testWidgets('opens from Home and Planner via hamburger', (tester) async {
      await pumpApp(tester);

      await openDrawerFromHome(tester);
      expect(drawerFinder(), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(drawerFinder(), findsNothing);

      // Planner root.
      await tapTab(tester, 'Planner');
      await tester.tap(find.byKey(const Key('planner-hamburger')));
      await tester.pumpAndSettle();
      expect(drawerFinder(), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(drawerFinder(), findsNothing);
      expect(find.byType(PlannerScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Android Back closes the drawer from a non-Home root first', (
      tester,
    ) async {
      await pumpApp(tester);
      await tapTab(tester, 'Planner');
      await tester.tap(find.byKey(const Key('planner-hamburger')));
      await tester.pumpAndSettle();
      expect(drawerFinder(), findsOneWidget);

      // One Back closes the drawer and stays on Planner (never double-Back,
      // never navigating away while the drawer is open).
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(drawerFinder(), findsNothing);
      expect(find.byType(PlannerScreen), findsOneWidget);

      // The next Back applies the normal Pack 2 root policy (Planner -> Home).
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('edge swipe opens the drawer from any shell page', (
      tester,
    ) async {
      await pumpApp(tester);
      // The drawer remains reachable from any shell page through the edge
      // drag (NX-07/08: Pathways is hidden from primary navigation).
      await tester.dragFrom(const Offset(2, 400), const Offset(220, 0));
      await tester.pumpAndSettle();
      expect(drawerFinder(), findsOneWidget);
      await tester.tapAt(const Offset(430, 400));
      await tester.pumpAndSettle();
      expect(drawerFinder(), findsNothing);
    });

    testWidgets('drawer width is 84-88% of phone width, capped at 360', (
      tester,
    ) async {
      await pumpApp(tester, size: const Size(360, 720));
      await openDrawerFromHome(tester);
      final drawer = tester.widget<Drawer>(drawerFinder());
      expect(drawer.width, closeTo(360 * 0.86, 0.01));
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
    });

    testWidgets('open/close adds no route and keeps the current root', (
      tester,
    ) async {
      await pumpApp(tester);
      final homeBefore = find.byType(HomeScreen).evaluate().length;
      for (var i = 0; i < 3; i++) {
        await openDrawerFromHome(tester);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
      }
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(find.byType(HomeScreen).evaluate().length, homeBefore);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Android Back closes the drawer before any navigation', (
      tester,
    ) async {
      await pumpApp(tester);
      await openDrawerFromHome(tester);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(drawerFinder(), findsNothing);
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('Pack 3 drawer — destinations', () {
    testWidgets('canonical sections and labels appear in order', (
      tester,
    ) async {
      await pumpApp(tester);
      await openDrawerFromHome(tester);

      final expectedSections = <String>[
        'Planning and Records',
        'Personal Tools',
        'Account and App',
        'Support',
      ];
      var lastY = 0.0;
      for (final section in expectedSections) {
        final finder = find.text(section);
        await tester.scrollUntilVisible(
          finder,
          200,
          scrollable: find.descendant(
            of: find.byKey(const Key('global-app-drawer-list')),
            matching: find.byType(Scrollable),
          ),
        );
        expect(finder, findsOneWidget);
        final y = tester.getTopLeft(finder).dy;
        expect(y, greaterThan(lastY), reason: '$section must come later');
        lastY = y;
      }

      // Every implemented destination is present.
      //
      // PRE-BETA (owner law, 2026-09-16): the `Life Goals` row was removed from
      // the drawer deliberately, so it is no longer an expected destination.
      // Only the drawer ROW is gone: `/progress`, the Life Goals screens and all
      // Goal data/features remain intact (see life_goals_drawer_removal_test).
      for (final id in <String>[
        'drawer-planner',
        'drawer-planning',
        'drawer-plan-history',
        'drawer-activity-history',
        'drawer-messages',
        'drawer-backup-restore',
        'drawer-account-settings',
        'drawer-about',
      ]) {
        await tester.scrollUntilVisible(
          entryFinder(id),
          200,
          scrollable: find.descendant(
            of: find.byKey(const Key('global-app-drawer-list')),
            matching: find.byType(Scrollable),
          ),
        );
        expect(entryFinder(id), findsOneWidget, reason: id);
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('no chevrons, no subtitles, no fake badges, no placeholders', (
      tester,
    ) async {
      await pumpApp(tester);
      await openDrawerFromHome(tester);
      final drawer = drawerFinder();

      expect(
        find.descendant(of: drawer, matching: find.byIcon(Icons.chevron_right)),
        findsNothing,
        reason: 'drawer rows must not render chevrons',
      );
      // Unsupported/placeholder destinations and copy must be absent.
      for (final text in <String>[
        'Tasks',
        'Unreported',
        'Quick Notes',
        'Personal Journal',
        'Sync and Backup',
        'Export Data',
        'Report a Problem',
        'Suggest a Feature',
        'Release Notes',
        'BYU-Pathway Worldwide',
        'My Plan',
        'will open when its slice is delivered',
        'Timeline, Event Types, snapping, zoom, display',
        'Targets and weekly review',
      ]) {
        expect(
          find.descendant(of: drawer, matching: find.text(text)),
          findsNothing,
          reason: 'unexpected destination/copy in drawer: $text',
        );
      }
      // Approved labels appear exactly once inside the drawer.
      expect(
        find.descendant(of: drawer, matching: find.text('Goal Planning')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: drawer, matching: find.text('Plan History')),
        findsOneWidget,
      );
      // PRE-BETA (owner law, 2026-09-16): the owner removed the Life Goals
      // drawer row, so its absence is now the invariant, not its presence.
      expect(
        find.descendant(of: drawer, matching: find.text('Life Goals')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('drawer scrolls when contents exceed the viewport', (
      tester,
    ) async {
      await pumpApp(tester, size: const Size(360, 480));
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await openDrawerFromHome(tester);
      await tester.scrollUntilVisible(
        entryFinder('drawer-about'),
        120,
        scrollable: find.descendant(
          of: find.byKey(const Key('global-app-drawer-list')),
          matching: find.byType(Scrollable),
        ),
      );
      expect(entryFinder('drawer-about'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('Pack 3 drawer — routing', () {
    testWidgets('root destination selects the existing root (Planner)', (
      tester,
    ) async {
      await pumpApp(tester);
      await openDrawerFromHome(tester);
      await tester.tap(find.byKey(const Key('drawer-planner')));
      await tester.pumpAndSettle();
      expect(drawerFinder(), findsNothing);
      expect(find.byType(PlannerScreen), findsOneWidget);
      // Bottom navigation reflects the selection.
      final nav = tester.widget<NavigationBar>(
        find.byKey(const Key('main-bottom-navigation')),
      );
      expect(nav.selectedIndex, 1);
    });

    testWidgets('current-destination tap closes only and adds no route', (
      tester,
    ) async {
      await pumpApp(tester);
      await tester.tap(find.text('Planner').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('planner-hamburger')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('drawer-planner')));
      await tester.pumpAndSettle();
      expect(drawerFinder(), findsNothing);
      expect(find.byType(PlannerScreen), findsOneWidget);
      expect(
        find.byType(PlannerScreen).evaluate().length,
        1,
        reason: 'no duplicate Planner route may be created',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('Planning opens the canonical weekly planning and Back lands '
        'on Planner root', (tester) async {
      await pumpApp(tester);
      await openDrawerFromHome(tester);
      await tester.tap(find.byKey(const Key('drawer-planning')));
      await tester.pumpAndSettle();
      expect(drawerFinder(), findsNothing);
      expect(find.byType(WeeklyPlanningScreen), findsOneWidget);
      // One Android Back returns to the Planner root (Pack 2 direct-entry
      // fallback for /planner/* children); no week-by-week unwinding.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(PlannerScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Activity History opens above the shell and Back returns to '
        'Home', (tester) async {
      await pumpApp(tester);
      await openDrawerFromHome(tester);
      await tester.tap(find.byKey(const Key('drawer-activity-history')));
      await tester.pumpAndSettle();
      expect(find.byType(ActivityHistoryScreen), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Messages opens and Back returns to Home', (tester) async {
      await pumpApp(tester);
      await openDrawerFromHome(tester);
      await tester.tap(find.byKey(const Key('drawer-messages')));
      await tester.pumpAndSettle();
      expect(find.byType(MessagesScreen), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(HomeScreen), findsOneWidget);
    });

    testWidgets('About opens and Back returns to Home', (tester) async {
      await pumpApp(tester);
      await openDrawerFromHome(tester);
      await tester.scrollUntilVisible(
        find.byKey(const Key('drawer-about')),
        200,
        scrollable: find.descendant(
          of: find.byKey(const Key('global-app-drawer-list')),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.tap(find.byKey(const Key('drawer-about')));
      await tester.pumpAndSettle();
      expect(find.byType(AboutScreen), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(HomeScreen), findsOneWidget);
    });

    testWidgets('Settings opens and Back lands on the Home root (NX-07/08: '
        'the More root no longer exists)', (tester) async {
      await pumpApp(tester);
      await openDrawerFromHome(tester);
      await tester.scrollUntilVisible(
        find.byKey(const Key('drawer-account-settings')),
        200,
        scrollable: find.descendant(
          of: find.byKey(const Key('global-app-drawer-list')),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.tap(find.byKey(const Key('drawer-account-settings')));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('repeated drawer/root navigation creates no duplicate Home', (
      tester,
    ) async {
      await pumpApp(tester);
      for (var i = 0; i < 2; i++) {
        await openDrawerFromHome(tester);
        await tester.tap(find.byKey(const Key('drawer-planner')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Home').last);
        await tester.pumpAndSettle();
      }
      expect(find.byType(HomeScreen).evaluate().length, 1);
      expect(
        find.byType(PlannerScreen).evaluate().length,
        0,
        reason: 'only one shell page is live at a time',
      );
      expect(tester.takeException(), isNull);
    });
  });
}
