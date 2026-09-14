import 'package:rmplanner/app/theme/theme_color_mode.dart';
import 'package:rmplanner/features/maps/application/maps_preferences_repository.dart';
import 'package:rmplanner/features/settings/application/appearance_repository.dart';
import 'package:rmplanner/features/startup/application/startup_repository.dart';
import 'package:rmplanner/features/startup/domain/local_profile.dart';
import 'package:rmplanner/features/startup/domain/onboarding_checkpoint.dart';
import 'package:rmplanner/features/startup/domain/startup_snapshot.dart';

/// The bounded pre-frame device-preference result.
///
/// It reads the existing device-scoped repositories exactly once.  A failed
/// read is represented explicitly so `main()` can mount the existing Startup
/// Recovery route rather than manufacturing a private Home frame from defaults.
final class StartupBootstrapResult {
  const StartupBootstrapResult.ready({
    required this.appearance,
    required this.themeColor,
    required this.mapsPreferences,
  }) : failure = null;

  const StartupBootstrapResult.failed() :
    appearance = null,
    themeColor = null,
    mapsPreferences = null,
    failure = const StartupBootstrapFailure();

  final AppearanceMode? appearance;
  final ThemeColorMode? themeColor;
  final MapsPreferencesModel? mapsPreferences;
  final StartupBootstrapFailure? failure;

  bool get isReady => failure == null;
}

final class StartupBootstrapFailure {
  const StartupBootstrapFailure();
}

/// Reads the existing single-row device seeds; it owns no database, router,
/// migration, notification, or worker lifecycle.
final class StartupBootstrap {
  const StartupBootstrap({
    required this._appearanceRepository,
    required this._mapsPreferencesRepository,
  });

  final AppearanceRepository _appearanceRepository;
  final MapsPreferencesRepository _mapsPreferencesRepository;

  Future<StartupBootstrapResult> resolve() async {
    try {
      final appearance = await _appearanceRepository.readAppearance();
      final themeColor = await _appearanceRepository.readThemeColor();
      final mapsPreferences = await _mapsPreferencesRepository.readPreferences();
      return StartupBootstrapResult.ready(
        appearance: appearance,
        themeColor: themeColor,
        mapsPreferences: mapsPreferences,
      );
    } on Object {
      return const StartupBootstrapResult.failed();
    }
  }
}

/// Routes one pre-frame seed failure through the existing StartupController
/// recovery state.  The existing RecoveryScreen retry then uses the original
/// startup repository; it never opens, resets, or replaces a database itself.
final class BootstrapFailureStartupRepository implements StartupRepository {
  BootstrapFailureStartupRepository({required this._delegate});

  final StartupRepository _delegate;
  var _initialFailurePending = true;

  @override
  Future<StartupSnapshot> resolveStartup() {
    if (_initialFailurePending) {
      _initialFailurePending = false;
      return Future<StartupSnapshot>.error(const StartupBootstrapFailure());
    }
    return _delegate.resolveStartup();
  }

  @override
  Future<OnboardingCheckpoint> beginOrResumeOnboarding() =>
      _delegate.beginOrResumeOnboarding();

  @override
  Future<OnboardingCheckpoint> saveOnboardingDraft(String? displayName) =>
      _delegate.saveOnboardingDraft(displayName);

  @override
  Future<LocalProfile> completeOnboarding() => _delegate.completeOnboarding();

  @override
  Future<LocalProfile> updateDisplayName(String? displayName) =>
      _delegate.updateDisplayName(displayName);
}
