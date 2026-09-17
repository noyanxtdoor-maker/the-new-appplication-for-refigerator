// VS-18 (owner steering, 2026-09-17): Backup & Restore must be reachable
// DIRECTLY from the hamburger drawer.
//
// OWNER LAW: the user must not have to walk Settings → Privacy and Data →
// Backup & Restore to reach the feature. The drawer row opens the canonical
// screen immediately. Both entry points resolve to the SAME route, the SAME
// screen and the SAME engine — there is exactly one Backup & Restore screen.
//
// The Privacy and Data entry is retained as a secondary route only.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:rmplanner/app/router/route_names.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/backup/presentation/backup_recovery_screen.dart';
import 'package:rmplanner/features/privacy/presentation/privacy_center_screen.dart';
import 'package:rmplanner/features/settings/presentation/settings_screen.dart';
import 'package:rmplanner/features/startup/presentation/home_screen.dart';

import '../../support/test_dependencies.dart';

void main() {
  Future<void> pumpApp(
    WidgetTester tester, {
    Size size = const Size(431, 912),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

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

  Future<void> openDrawerEntry(WidgetTester tester, String entryId) async {
    await tester.tap(find.byKey(const Key('home-hamburger')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(Key(entryId)),
      200,
      scrollable: find.descendant(
        of: find.byKey(const Key('global-app-drawer-list')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key(entryId)));
    await tester.pumpAndSettle();
  }

  testWidgets('the drawer offers Backup & Restore', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byKey(const Key('home-hamburger')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('drawer-backup-restore')),
      200,
      scrollable: find.descendant(
        of: find.byKey(const Key('global-app-drawer-list')),
        matching: find.byType(Scrollable),
      ),
    );

    expect(find.byKey(const Key('drawer-backup-restore')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('drawer-backup-restore')),
        matching: find.text('Backup & Restore'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('tapping it opens the canonical screen with no intermediate step',
      (tester) async {
    await pumpApp(tester);
    await openDrawerEntry(tester, 'drawer-backup-restore');

    // Straight to the feature: no Settings screen and no Privacy and Data
    // screen stood in the way.
    expect(find.byType(BackupRecoveryScreen), findsOneWidget);
    expect(find.byType(SettingsScreen), findsNothing);
    expect(find.byType(PrivacyCenterScreen), findsNothing);

    // And the screen offers exactly the two user actions.
    expect(find.text('Back up your data'), findsOneWidget);
    expect(find.text('Restore your backup'), findsOneWidget);
  });

  testWidgets('the canonical route is the same one the app already uses',
      (tester) async {
    await pumpApp(tester);
    await openDrawerEntry(tester, 'drawer-backup-restore');

    expect(
      GoRouterState.of(tester.element(find.byType(BackupRecoveryScreen)))
          .matchedLocation,
      RoutePaths.backupRecovery,
    );
  });

  testWidgets('Back returns to the screen the drawer was opened from',
      (tester) async {
    await pumpApp(tester);
    await openDrawerEntry(tester, 'drawer-backup-restore');
    expect(find.byType(BackupRecoveryScreen), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(find.byType(BackupRecoveryScreen), findsNothing);
    expect(find.byType(HomeScreen), findsOneWidget);
  });

  testWidgets(
      'the Privacy and Data entry opens the same canonical screen, not a copy',
      (tester) async {
    await pumpApp(tester);

    final router = GoRouter.of(tester.element(find.byType(HomeScreen)));
    unawaited(router.push(RoutePaths.privacyCenter));
    await tester.pumpAndSettle();
    expect(find.byType(PrivacyCenterScreen), findsOneWidget);

    await tester.ensureVisible(find.byKey(const Key('backup-recovery-tile')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('backup-recovery-tile')));
    await tester.pumpAndSettle();

    expect(find.byType(BackupRecoveryScreen), findsOneWidget);
    // One screen, one state: the same two actions, never a second flow.
    expect(find.text('Back up your data'), findsOneWidget);
    expect(find.text('Restore your backup'), findsOneWidget);
    expect(
      GoRouterState.of(tester.element(find.byType(BackupRecoveryScreen)))
          .matchedLocation,
      RoutePaths.backupRecovery,
    );
  });
}
