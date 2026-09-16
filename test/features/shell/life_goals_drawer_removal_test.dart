import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:rmplanner/app/router/route_names.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/indicators/presentation/indicator_list_screen.dart';

import '../../support/test_dependencies.dart';
import '../../support/view_size.dart';

/// PRE-BETA (owner law, 2026-09-16) — the `Life Goals` drawer row is gone.
///
/// SCOPE OF THE REMOVAL: the drawer ROW only. Everything underneath it survives:
/// the `/progress` route and its metric child routes, the Life Goals
/// list/detail/edit screens, Goal records and schema, Goal Planning, Plan
/// History, Activity History and every Home Goal surface.
///
/// The row was the app's ONLY navigation entry point to `/progress`, so the list
/// screen is intentionally unreachable from normal UI navigation while remaining
/// fully resolvable by route. That consequence is asserted here rather than
/// left implicit.
void main() {
  Future<void> pumpApp(WidgetTester tester, Size size) async {
    setLogicalViewSize(tester, size);
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

  Future<void> openDrawer(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('home-hamburger')));
    await tester.pumpAndSettle();
  }

  Finder drawer() => find.byKey(const Key('global-app-drawer'));

  /// The destinations that MUST remain, in their accepted order.
  const List<String> remainingEntries = <String>[
    'drawer-planner',
    'drawer-planning',
    'drawer-plan-history',
    'drawer-activity-history',
    'drawer-messages',
    'drawer-account-settings',
    'drawer-about',
  ];

  testWidgets('the Life Goals drawer row is gone', (tester) async {
    await pumpApp(tester, TestWindowSizes.phonePortrait);
    await openDrawer(tester);

    expect(drawer(), findsOneWidget);
    expect(
      find.byKey(const Key('drawer-life-indicators')),
      findsNothing,
      reason: 'the owner removed this drawer row',
    );
    expect(
      find.descendant(of: drawer(), matching: find.text('Life Goals')),
      findsNothing,
      reason: 'no Life Goals label may remain in the drawer',
    );
  });

  testWidgets('every other drawer destination survives, in order', (
    tester,
  ) async {
    await pumpApp(tester, TestWindowSizes.phonePortrait);
    await openDrawer(tester);

    final Finder list = find.byKey(const Key('global-app-drawer-list'));
    double lastY = double.negativeInfinity;
    for (final String id in remainingEntries) {
      await tester.scrollUntilVisible(
        find.byKey(Key(id)),
        200,
        scrollable: find.descendant(
          of: list,
          matching: find.byType(Scrollable),
        ),
      );
      expect(find.byKey(Key(id)), findsOneWidget, reason: '$id must remain');
      final double y = tester.getTopLeft(find.byKey(Key(id))).dy;
      expect(y, greaterThan(lastY), reason: '$id is out of order');
      lastY = y;
    }

    // Goal Planning, Plan History and Activity History are the Goal-related
    // destinations that remain reachable from the drawer.
    for (final String label in <String>[
      'Goal Planning',
      'Plan History',
      'Activity History',
    ]) {
      expect(
        find.descendant(of: drawer(), matching: find.text(label)),
        findsOneWidget,
        reason: '$label must stay reachable from the drawer',
      );
    }
  });

  testWidgets('no replacement entry point was invented', (tester) async {
    await pumpApp(tester, TestWindowSizes.phonePortrait);
    await openDrawer(tester);

    // The removal must not have added a substitute row: the drawer holds exactly
    // the accepted seven entries.
    for (final String id in remainingEntries) {
      expect(find.byKey(Key(id)), findsOneWidget);
    }
    expect(find.byKey(const Key('drawer-sync')), findsNothing);
    expect(find.byKey(const Key('drawer-backup')), findsNothing);
    expect(find.byKey(const Key('drawer-progress')), findsNothing);
  });

  testWidgets('the /progress route still resolves to the Life Goals screen', (
    tester,
  ) async {
    await pumpApp(tester, TestWindowSizes.phonePortrait);

    final BuildContext context = tester.element(
      find.byKey(const Key('home-hamburger')),
    );
    context.go(RoutePaths.progress);
    await tester.pumpAndSettle();

    // The route and the screen are intact: only the drawer row was removed.
    expect(find.byType(IndicatorListScreen), findsOneWidget);
    expect(find.text('Life Goals'), findsOneWidget);
  });

  testWidgets('the Goal feature itself is untouched by the removal', (
    tester,
  ) async {
    await pumpApp(tester, TestWindowSizes.largeTablet);
    await openDrawer(tester);

    // Goal Planning still opens from the drawer on a wide window too.
    await tester.tap(find.byKey(const Key('drawer-planning')));
    await tester.pumpAndSettle();
    expect(find.text('Goal Planning'), findsOneWidget);
  });
}
