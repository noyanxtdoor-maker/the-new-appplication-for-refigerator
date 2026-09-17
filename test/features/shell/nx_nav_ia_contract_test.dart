// NX-04/07/08 — navigation / IA / drawer theme contract tests.
//
// NX-07/08: primary nav is exactly Home / Planner / Contacts; Pathways and
//           the standalone More destination are gone; /more redirects to
//           Home; drawer child destinations stay reachable.
// NX-04:    the drawer is theme-aware (Light surface in Light appearance,
//           exact dark surface in Dark appearance; readable text/icons).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/maps/presentation/maps_screen.dart';
import 'package:rmplanner/features/settings/application/appearance_repository.dart';
import 'package:rmplanner/features/settings/presentation/settings_screen.dart';
import 'package:rmplanner/features/startup/presentation/home_screen.dart';

import '../../support/test_dependencies.dart';

void main() {
  Future<void> pumpApp(
    WidgetTester tester, {
    AppearanceMode appearance = AppearanceMode.light,
  }) async {
    tester.view.physicalSize = const Size(431, 912);
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
        initialAppearance: appearance,
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder navFinder() => find.byKey(const Key('main-bottom-navigation'));

  List<String> navLabels(WidgetTester tester) {
    final destinations = tester.widgetList<NavigationDestination>(
      find.descendant(
        of: navFinder(),
        matching: find.byType(NavigationDestination),
      ),
    );
    return destinations.map((d) => d.label).toList();
  }

  testWidgets('NX-07/08 + MAPS V1: primary bottom navigation is exactly Home / '
      'Planner / Contacts / Maps — no More tab, no Pathways tab', (
    tester,
  ) async {
    await pumpApp(tester);
    expect(navLabels(tester), <String>['Home', 'Planner', 'Contacts', 'Maps']);
    expect(
      find.descendant(of: navFinder(), matching: find.text('More')),
      findsNothing,
    );
    expect(
      find.descendant(of: navFinder(), matching: find.text('Pathways')),
      findsNothing,
    );
  });

  testWidgets(
    'MAPS V1: the fourth tab opens the Maps screen (no fake placeholder) '
    'and back from it returns to Home',
    (tester) async {
      await pumpApp(tester);
      await tester.tap(
        find.descendant(of: navFinder(), matching: find.text('Maps')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(MapsScreen), findsOneWidget);
      // CLOSED-BETA HOTFIX (owner law, 2026-09-16): the FIRST Maps entry now
      // presents the ONE app-owned Location education surface. It is
      // dismissible and never gates the base map; answer it here so its modal
      // barrier cannot absorb the next tab tap. The Maps screen identity and
      // the tab-return law asserted below are unchanged.
      expect(
        find.byKey(const Key('maps-location-education')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const Key('maps-location-education-not-now')),
      );
      await tester.pumpAndSettle();
      // Switching back to Home restores the first tab (index 0).
      await tester.tap(
        find.descendant(of: navFinder(), matching: find.text('Home')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(find.byType(MapsScreen), findsNothing);
    },
  );

  testWidgets(
    'NX-07/08: the legacy /more route redirects to Home and never renders '
    'a More landing page; More children stay reachable',
    (tester) async {
      await pumpApp(tester);
      final router = GoRouter.of(tester.element(find.byType(HomeScreen)));
      router.go('/more');
      await tester.pumpAndSettle();
      expect(
        find.byType(HomeScreen),
        findsOneWidget,
        reason: '/more must redirect to the Home root',
      );
      expect(find.text('More'), findsNothing);
      // Child destinations remain reachable through the drawer: Settings
      // opens at /more/settings.
      await tester.tap(find.byKey(const Key('home-hamburger')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('drawer-account-settings')));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsOneWidget);
    },
  );

  testWidgets('NX-07/08: the drawer still exposes the secondary destinations '
      '(Planner, Goal Planning, Plan History, Activity History, '
      'Messages, Settings, About) and has no More entry', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byKey(const Key('home-hamburger')));
    await tester.pumpAndSettle();
    // PRE-BETA (owner law, 2026-09-16): `drawer-life-indicators` was removed
    // from the drawer on purpose.  Its absence is asserted explicitly below
    // by the Life Goals removal contract test; the row is gone while the route
    // and every Goal feature continue to exist.
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
      expect(
        find.byKey(Key(id)),
        findsOneWidget,
        reason: 'drawer entry $id must remain reachable',
      );
    }
    expect(find.byKey(const Key('global-app-drawer-list')), findsOneWidget);
  });

  testWidgets(
    'NX-04: Light appearance -> Light semantic drawer surface with readable '
    'semantic text; Dark appearance keeps the exact dark surface',
    (tester) async {
      await pumpApp(tester, appearance: AppearanceMode.light);
      await tester.tap(find.byKey(const Key('home-hamburger')));
      await tester.pumpAndSettle();
      final lightDrawer = tester.widget<Drawer>(
        find.byKey(const Key('global-app-drawer')),
      );
      final lightContext = tester.element(
        find.byKey(const Key('global-app-drawer')),
      );
      final lightScheme = Theme.of(lightContext).colorScheme;
      expect(
        lightDrawer.backgroundColor,
        isNot(lightScheme.surfaceContainerHigh),
        reason: 'Light drawer must not be a heavy slab',
      );
      expect(lightDrawer.backgroundColor, isNot(Colors.black));
      // Unselected entry text is readable dark semantic on the Light drawer.
      final entryContext = tester.element(
        find.byKey(const Key('drawer-account-settings')),
      );
      expect(Theme.of(entryContext).brightness, Brightness.light);

      await tester.pumpWidget(const SizedBox());
      await pumpApp(tester, appearance: AppearanceMode.dark);
      await tester.tap(find.byKey(const Key('home-hamburger')));
      await tester.pumpAndSettle();
      final darkDrawer = tester.widget<Drawer>(
        find.byKey(const Key('global-app-drawer')),
      );
      final darkContext = tester.element(
        find.byKey(const Key('global-app-drawer')),
      );
      expect(Theme.of(darkContext).brightness, Brightness.dark);
      expect(
        darkDrawer.backgroundColor,
        const Color(0xFF181A1E),
        reason:
            'NX-04: Dark drawer keeps the exact pre-fix dark surface '
            'token (byte-identical)',
      );
    },
  );
}
