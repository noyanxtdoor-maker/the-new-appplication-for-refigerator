import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/app/next_transfer_app.dart';
import 'package:rmplanner/app/startup_bootstrap.dart';
import 'package:rmplanner/app/theme/theme_color_mode.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/maps/application/map_session_provider.dart';
import 'package:rmplanner/features/maps/application/maps_preferences_repository.dart';
import 'package:rmplanner/features/settings/application/appearance_repository.dart';
import 'package:rmplanner/features/startup/application/startup_providers.dart';
import 'package:rmplanner/features/startup/application/startup_repository.dart';
import 'package:rmplanner/features/startup/domain/local_profile.dart';
import 'package:rmplanner/features/startup/domain/onboarding_checkpoint.dart';
import 'package:rmplanner/features/startup/domain/startup_snapshot.dart';
import 'package:rmplanner/features/startup/domain/startup_state.dart';

import '../support/test_dependencies.dart';

void main() {
  test('M2 P04 reads the three persisted seeds once and retains their values', () async {
    final appearance = _AppearanceFake();
    final maps = _MapsFake();

    final result = await StartupBootstrap(
      appearanceRepository: appearance,
      mapsPreferencesRepository: maps,
    ).resolve();

    expect(result.isReady, isTrue);
    expect(result.appearance, AppearanceMode.light);
    expect(result.themeColor, ThemeColorMode.rose);
    expect(result.mapsPreferences?.mapType, NextTransferMapType.terrain);
    expect(appearance.appearanceReads, 1);
    expect(appearance.themeReads, 1);
    expect(maps.reads, 1);
  });

  test('M2 P04 seed failure is explicit and only exposes Startup Recovery', () async {
    final result = await StartupBootstrap(
      appearanceRepository: _AppearanceFake(failAppearance: true),
      mapsPreferencesRepository: _MapsFake(),
    ).resolve();

    expect(result.isReady, isFalse);
    expect(result.appearance, isNull);
    expect(result.themeColor, isNull);
    expect(result.mapsPreferences, isNull);
    final delegate = _StartupFake();
    final recovery = BootstrapFailureStartupRepository(delegate: delegate);
    await expectLater(
      recovery.resolveStartup(),
      throwsA(isA<StartupBootstrapFailure>()),
    );
    expect(await recovery.resolveStartup(), same(delegate.snapshot));
  });

  testWidgets(
    'M2 P04 real app mounts Recovery before Home and Retry delegates startup',
    (tester) async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      final dependencies = TestPrivacyDependencies(database: database);
      final delegate = buildTestRepository(database: database);
      final startup = BootstrapFailureStartupRepository(delegate: delegate);

      await tester.pumpWidget(
        dependencies.buildApp(
          environment: AppEnvironment.fromDartDefines(),
          diagnostics: SanitizedDiagnostics(),
          startupRepository: startup,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('Local data needs attention'), findsOneWidget);
      expect(find.byType(NextTransferApp), findsOneWidget);
      expect(find.text('Home'), findsNothing);

      await tester.tap(find.text('Retry local startup'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      final container = ProviderScope.containerOf(
        tester.element(find.byType(NextTransferApp)),
      );
      expect(container.read(startupControllerProvider), isA<StartupWelcome>());
      await tester.pumpAndSettle();
      // M6: the front door is the locked Welcome presentation.
      expect(find.text('Get Started'), findsOneWidget);
      expect(find.text('Local data needs attention'), findsNothing);
    },
  );
}

final class _StartupFake implements StartupRepository {
  final snapshot = const StartupSnapshot(
    accountSessionState: AccountSessionState.localOnly,
    syncState: LocalSyncState.notConfigured,
    unlockRequired: false,
  );

  @override
  Future<StartupSnapshot> resolveStartup() async => snapshot;

  @override
  Future<OnboardingCheckpoint> beginOrResumeOnboarding() =>
      throw UnimplementedError();

  @override
  Future<OnboardingCheckpoint> saveOnboardingDraft(String? displayName) =>
      throw UnimplementedError();

  @override
  Future<LocalProfile> completeOnboarding() => throw UnimplementedError();

  @override
  Future<LocalProfile> updateDisplayName(String? displayName) =>
      throw UnimplementedError();
}

final class _AppearanceFake implements AppearanceRepository {
  _AppearanceFake({this.failAppearance = false});
  final bool failAppearance;
  int appearanceReads = 0;
  int themeReads = 0;

  @override
  Future<AppearanceMode> readAppearance() async {
    appearanceReads++;
    if (failAppearance) throw StateError('seed failure');
    return AppearanceMode.light;
  }

  @override
  Future<ThemeColorMode> readThemeColor() async {
    themeReads++;
    return ThemeColorMode.rose;
  }

  @override
  Future<void> saveAppearance(AppearanceMode mode) async {}

  @override
  Future<void> saveThemeColor(ThemeColorMode color) async {}
}

final class _MapsFake implements MapsPreferencesRepository {
  int reads = 0;

  @override
  Future<MapsPreferencesModel> readPreferences() async {
    reads++;
    return const MapsPreferencesModel(mapType: NextTransferMapType.terrain);
  }

  @override
  Future<void> savePreferences(MapsPreferencesModel preferences) async {}
}
