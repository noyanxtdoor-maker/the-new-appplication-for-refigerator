import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/app/router/app_router.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/features/startup/application/startup_providers.dart';
import 'package:rmplanner/features/startup/application/startup_repository.dart';
import 'package:rmplanner/features/startup/domain/local_profile.dart';
import 'package:rmplanner/features/startup/domain/onboarding_checkpoint.dart';
import 'package:rmplanner/features/startup/domain/startup_snapshot.dart';

void main() {
  test('M2 P05 keeps one GoRouter through welcome, onboarding, and draft updates', () async {
    final repository = _RouterRepository();
    final container = ProviderContainer(
      overrides: [
        startupRepositoryProvider.overrideWithValue(repository),
        diagnosticsProvider.overrideWithValue(SanitizedDiagnostics()),
      ],
    );
    addTearDown(container.dispose);

    final router = container.read(appRouterProvider);
    final controller = container.read(startupControllerProvider.notifier);
    await controller.initialize();
    expect(container.read(appRouterProvider), same(router));

    await controller.continueLocalOnly();
    expect(container.read(appRouterProvider), same(router));

    await controller.saveDraft('latest');
    expect(container.read(appRouterProvider), same(router));
    expect(repository.drafts, <String?>['latest']);
  });
}

final class _RouterRepository implements StartupRepository {
  final drafts = <String?>[];

  @override
  Future<StartupSnapshot> resolveStartup() async => const StartupSnapshot(
    accountSessionState: AccountSessionState.localOnly,
    syncState: LocalSyncState.notConfigured,
    unlockRequired: false,
  );

  @override
  Future<OnboardingCheckpoint> beginOrResumeOnboarding() async => _checkpoint();

  @override
  Future<OnboardingCheckpoint> saveOnboardingDraft(String? displayName) async {
    drafts.add(displayName);
    return _checkpoint(displayName);
  }

  OnboardingCheckpoint _checkpoint([String? draft]) => OnboardingCheckpoint(
    pendingProfileId: 'pending',
    stage: OnboardingStage.profileDraft,
    updatedAtUtc: DateTime.utc(2026),
    draftDisplayName: draft,
  );

  @override
  Future<LocalProfile> completeOnboarding() => throw UnimplementedError();

  @override
  Future<LocalProfile> updateDisplayName(String? displayName) =>
      throw UnimplementedError();
}
