import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:rmplanner/app/router/route_names.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/privacy/application/privacy_providers.dart';
import 'package:rmplanner/features/startup/application/startup_providers.dart';
import 'package:rmplanner/features/startup/domain/startup_state.dart';

import '../../../support/test_dependencies.dart';
import '../../../support/view_size.dart';

void main() {
  testWidgets(
    'AC-W-001..011,018,019,021,022: privacy journey is usable and non-destructive',
    (tester) async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      final privacy = TestPrivacyDependencies(database: database);
      final startupRepository = buildTestRepository(
        database: database,
        privacyGate: privacy.gate,
      );
      await startupRepository.completeOnboarding();
      final diagnostics = SanitizedDiagnostics()
        ..record(
          'startup_resolved',
          context: const <String, Object?>{'database_state': 'ready'},
        );

      await tester.pumpWidget(
        privacy.buildApp(
          environment: const AppEnvironment(
            name: AppEnvironmentName.production,
            label: 'PRODUCTION',
          ),
          diagnostics: diagnostics,
          startupRepository: startupRepository,
        ),
      );
      await tester.pumpAndSettle();

      // Open the global app drawer via the Home hamburger. Pack 3
      // centralizes Privacy and Data inside Settings, so the drawer no
      // longer lists it as a top-level destination: drawer -> Settings ->
      // Privacy and Data.
      await tester.tap(find.byKey(const Key('home-hamburger')));
      await tester.pumpAndSettle();
      // The drawer's inner ListView lazily builds its children, so the
      // Settings entry is unmounted when scrolled out of the visible
      // region. Use scrollUntilVisible (which keeps scrolling until the
      // tile is on screen) with a generous scroll step so the whole list
      // reveals the "Account and App" group in one pass.
      await tester.scrollUntilVisible(
        find.byKey(const Key('drawer-account-settings')),
        300,
        scrollable: find.descendant(
          of: find.byKey(const Key('global-app-drawer-list')),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('drawer-account-settings')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings-privacy-data')));
      await tester.pumpAndSettle();
      expect(find.text('Privacy controls'), findsOneWidget);
      const disclaimer =
          'Next Transfer does not claim full-database encryption or '
          'end-to-end encryption. It states only protections implemented '
          'and verified.';
      await tester.scrollUntilVisible(
        find.text(disclaimer),
        180,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text(disclaimer), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byKey(const Key('privacy-lock-switch')),
        -180,
        scrollable: find.byType(Scrollable).first,
      );

      await tester.tap(find.byKey(const Key('privacy-lock-switch')));
      await tester.pumpAndSettle();
      expect((await privacy.repository.readSettings()).lockEnabled, isTrue);
      final container = ProviderScope.containerOf(
        tester.element(find.byKey(const Key('privacy-lock-switch'))),
      );

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(minutes: 5));
      await tester.pumpAndSettle();
      expect(
        container.read(privacyControllerProvider).status,
        PrivacyLockStatus.locked,
      );
      expect(
        container.read(startupControllerProvider),
        isA<StartupProtected>(),
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('Next Transfer is locked'), findsOneWidget);

      await tester.tap(find.byKey(const Key('unlock-button')));
      await tester.pumpAndSettle();
      // PRE-BETA RESPONSIVE (owner law, 2026-09-16): navigation is a bar on a
      // compact window and a rail from 600 dp up, so the assertion targets the
      // ACTIVE presentation rather than the retired bar-at-every-width law.
      expect(navigationFinder(), findsOneWidget);
      expect(await privacy.gate.isUnlockRequired(), isFalse);

      // Open the global app drawer via the Home hamburger. Pack 3
      // centralizes Permissions inside Settings.
      final context = tester.element(find.byType(Scaffold).first);
      final location = GoRouter.of(context).state.uri.toString();
      expect(location, RoutePaths.home, reason: 'unlock must land on Home');
      await tester.tap(find.byKey(const Key('home-hamburger')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('global-app-drawer')),
        findsOneWidget,
        reason: 'the drawer must reopen after the lock/unlock cycle',
      );
      await tester.tap(find.byKey(const Key('drawer-account-settings')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings-permissions')));
      await tester.pumpAndSettle();
      expect(find.text('Not requested'), findsWidgets);
      await tester.scrollUntilVisible(
        find.text('Device calendar'),
        240,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Device calendar'), findsOneWidget);
      expect(
        find.textContaining('No permission is requested from this page'),
        findsNothing,
      );
      await tester.scrollUntilVisible(
        find.byKey(const Key('open-system-settings-button')),
        240,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byKey(const Key('open-system-settings-button')));
      await tester.pumpAndSettle();
      expect(privacy.permissionGateway.settingsOpened, isTrue);

      await tester.pageBack();
      await tester.pumpAndSettle();
      // Back from Permissions lands on Settings; open the canonical Privacy
      // Center to continue the remaining privacy-surface checks.
      await tester.tap(find.byKey(const Key('settings-privacy-data')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const Key('diagnostic-preview-tile')),
        240,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -120));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('diagnostic-preview-tile')));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Nothing is exported automatically'),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const Key('prepare-diagnostic-preview-button')),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('sanitized events ready for review'),
        findsOneWidget,
      );
      await tester.scrollUntilVisible(
        find.textContaining('no file or message'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.textContaining('no file or message'), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const Key('deletion-impact-tile')),
        240,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byKey(const Key('deletion-impact-tile')));
      await tester.pumpAndSettle();
      expect(find.text('Deletion impacts'), findsOneWidget);
      expect(find.text('Local app data'), findsOneWidget);
      expect(find.text('Optional synced data'), findsOneWidget);
      expect(find.text('Backups'), findsOneWidget);
      expect(find.text('Source files'), findsOneWidget);

      expect(await database.select(database.localProfiles).get(), hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('AC-W-008: Privacy Center remains usable at 200% text scale', (
    tester,
  ) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final database = openMemoryDatabase();
    addTearDown(database.close);
    final privacy = TestPrivacyDependencies(database: database);
    final startupRepository = buildTestRepository(
      database: database,
      privacyGate: privacy.gate,
    );
    await startupRepository.completeOnboarding();

    await tester.pumpWidget(
      privacy.buildApp(
        environment: const AppEnvironment(
          name: AppEnvironmentName.production,
          label: 'PRODUCTION',
        ),
        diagnostics: SanitizedDiagnostics(),
        startupRepository: startupRepository,
      ),
    );
    await tester.pumpAndSettle();

    // Open the global app drawer via the Home hamburger. Pack 3
    // centralizes Privacy and Data inside Settings.
    await tester.tap(find.byKey(const Key('home-hamburger')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('drawer-account-settings')),
      300,
      scrollable: find.descendant(
        of: find.byKey(const Key('global-app-drawer-list')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('drawer-account-settings')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-privacy-data')));
    await tester.pumpAndSettle();

    expect(find.text('Privacy controls'), findsOneWidget);
    expect(find.byType(ListView), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // VS16 M8 (contract section 38, scenario T73).
  //
  // The M8 background operational details do NOT widen the privacy boundary:
  // they stay inside the journey that already exists, they are produced only on
  // an explicit Prepare, they are withheld unless the owner has explicitly
  // opted into operational details, and no export ever happens automatically.
  testWidgets(
    'T73 background diagnostic details stay inside the existing privacy journey',
    (tester) async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      final privacy = TestPrivacyDependencies(database: database);
      final startupRepository = buildTestRepository(
        database: database,
        privacyGate: privacy.gate,
      );
      await startupRepository.completeOnboarding();

      await tester.pumpWidget(
        privacy.buildApp(
          environment: const AppEnvironment(
            name: AppEnvironmentName.production,
            label: 'PRODUCTION',
          ),
          diagnostics: SanitizedDiagnostics(),
          startupRepository: startupRepository,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('home-hamburger')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const Key('drawer-account-settings')),
        300,
        scrollable: find.descendant(
          of: find.byKey(const Key('global-app-drawer-list')),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('drawer-account-settings')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('settings-privacy-data')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const Key('diagnostic-preview-tile')),
        240,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -120));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('diagnostic-preview-tile')));
      await tester.pumpAndSettle();

      // The standing privacy promise is still the first thing the owner sees,
      // and M8 introduced no automatic collection on entry.
      expect(
        find.textContaining('Nothing is exported automatically'),
        findsOneWidget,
      );
      expect(find.text('Background work'), findsNothing);

      // Explicit Prepare, operational details OFF: no platform read, no cards.
      await tester.tap(
        find.byKey(const Key('prepare-diagnostic-preview-button')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Background work'), findsNothing);

      // Explicit opt-in + explicit Prepare: typed facts only, still no export.
      await tester.tap(find.byKey(const Key('diagnostic-context-checkbox')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('prepare-diagnostic-preview-button')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Background work'), findsOneWidget);
      expect(find.text('Notification scheduler'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.textContaining('no file or message'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.textContaining('no file or message'),
        findsOneWidget,
        reason: 'M8 must not introduce automatic export',
      );
      expect(tester.takeException(), isNull);
    },
  );
}
