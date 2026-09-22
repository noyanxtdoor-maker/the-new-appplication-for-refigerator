// POST-P2 OWNER DECISION (2026-09-22) — one settings card surface.
//
// The audit proved the difference the owner reported: Planner & Calendar and
// Privacy and Data drew the themed near-white card (`cardTheme.color` ==
// `colorScheme.surface`, #FAF8F5 in light), while Settings home, Notifications
// and Maps settings drew `Card(color: Colors.transparent)` and therefore showed
// the scaffold canvas (#F1EFEA) through them. Nothing else was involved — no
// opacity, blur, elevation or tint.
//
// The owner chose the lower-risk route: fix LIGHT to the semantic card surface
// and keep DARK byte-identical (still transparent over the dark canvas), so no
// dark settings surface is relit and no dark golden moves.
//
// These tests fail against the pre-change tree in light mode: every audited
// card resolved to `Colors.transparent`.
//
// The harness starts the app in DARK by default, so this file opts into light
// explicitly — the whole point is the light surface.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/settings/application/appearance_repository.dart';
import 'package:rmplanner/features/settings/presentation/maps_settings_screen.dart';
import 'package:rmplanner/features/settings/presentation/notifications_settings_screen.dart';
import 'package:rmplanner/features/settings/presentation/settings_screen.dart';

import '../../../support/test_dependencies.dart';

void main() {
  Future<void> pumpLightApp(WidgetTester tester) async {
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
        initialAppearance: AppearanceMode.light,
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openSettings(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('home-hamburger')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('drawer-account-settings')),
      200,
      scrollable: find.descendant(
        of: find.byKey(const Key('global-app-drawer-list')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('drawer-account-settings')));
    await tester.pumpAndSettle();
  }

  /// Every Card on the current screen must resolve the semantic card surface.
  void expectSemanticCards(WidgetTester tester, String screen) {
    final cards = find.byType(Card);
    final count = cards.evaluate().length;
    expect(count, greaterThan(0), reason: '$screen should render cards');
    for (var index = 0; index < count; index++) {
      final element = cards.at(index).evaluate().single;
      final card = element.widget as Card;
      final surface = Theme.of(element).colorScheme.surface;
      expect(
        Theme.of(element).brightness,
        Brightness.light,
        reason: 'this screen is measured in light mode',
      );
      expect(
        card.color,
        isNot(Colors.transparent),
        reason: '$screen card $index must not show the gray canvas through it',
      );
      expect(
        card.color,
        surface,
        reason: '$screen card $index must use the semantic card surface',
      );
    }
  }

  testWidgets('settings home cards use the semantic card surface in light', (
    tester,
  ) async {
    await pumpLightApp(tester);
    await openSettings(tester);
    expect(find.byType(SettingsScreen), findsOneWidget);
    expectSemanticCards(tester, 'Settings home');
  });

  testWidgets(
    'notifications settings cards use the semantic surface in light',
    (tester) async {
      await pumpLightApp(tester);
      await openSettings(tester);
      await tester.tap(find.byKey(const Key('settings-notifications')));
      await tester.pumpAndSettle();
      expect(find.byType(NotificationsSettingsScreen), findsOneWidget);
      expectSemanticCards(tester, 'Notifications');
    },
  );

  testWidgets('maps settings cards use the semantic surface in light', (
    tester,
  ) async {
    await pumpLightApp(tester);
    await openSettings(tester);
    await tester.tap(find.byKey(const Key('settings-maps')));
    await tester.pumpAndSettle();
    expect(find.byType(MapsSettingsScreen), findsOneWidget);
    expectSemanticCards(tester, 'Maps settings');
  });
}
