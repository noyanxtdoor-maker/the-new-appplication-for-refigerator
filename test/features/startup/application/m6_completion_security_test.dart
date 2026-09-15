import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/features/startup/application/startup_providers.dart';
import 'package:rmplanner/features/startup/application/startup_repository.dart';
import 'package:rmplanner/features/startup/domain/local_profile.dart';
import 'package:rmplanner/features/startup/domain/onboarding_checkpoint.dart';
import 'package:rmplanner/features/startup/domain/startup_snapshot.dart';
import 'package:rmplanner/features/startup/domain/startup_state.dart';

/// M6 completion security: the onboarding button can never authorize private
/// access by itself, duplicate submissions collapse into one operation, and
/// no-profile snapshots with an enabled Privacy Lock fail closed to Protected
/// instead of exposing the front door.
void main() {
  /// Reading the notifier constructs it, which fires the controller's own
  /// unawaited build() initialization; this helper flushes the event/microtask
  /// queue so that resolution (and its single resolveStartup call) settles
  /// without a SECOND explicit initialize() call.
  Future<void> settleStartup() async {
    for (var i = 0; i < 6; i += 1) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  test(
    'completion is single-flight and publishes only after re-resolution',
    () async {
      // The post-commit resolution must observe an enabled Privacy Lock so
      // the destination is Protected — never a fabricated Ready.
      final gate = Completer<void>();
      final repository = _GatedCompletionRepository(
        gate,
        postCommitUnlockRequired: true,
      );
      final container = ProviderContainer(
        overrides: [
          startupRepositoryProvider.overrideWithValue(repository),
          diagnosticsProvider.overrideWithValue(SanitizedDiagnostics()),
        ],
      );
      addTearDown(container.dispose);

      final controller = container.read(startupControllerProvider.notifier);
      await settleStartup();
      expect(container.read(startupControllerProvider), isA<StartupWelcome>());

      await controller.continueLocalOnly();
      expect(
        container.read(startupControllerProvider),
        isA<StartupOnboarding>(),
      );

      // Two taps: both join the same single-flight operation — the
      // repository is entered exactly once even though each caller receives
      // its own completion future.
      final first = controller.completeOnboarding();
      final second = controller.completeOnboarding();
      await Future<void>.delayed(Duration.zero);
      expect(repository.completeCalls, 1);

      // While the atomic transaction runs, nothing Ready is published.
      expect(
        container.read(startupControllerProvider),
        isA<StartupOnboarding>(),
      );

      gate.complete();
      await Future.wait(<Future<void>>[first, second]);

      // The publication comes from the re-run canonical resolution, which
      // observes the enabled lock — Protected, never a fabricated Ready.
      expect(
        container.read(startupControllerProvider),
        isA<StartupProtected>(),
      );
      expect(repository.resolveCalls, 2);
    },
  );

  test(
    'completion failure surfaces Recovery without creating a profile',
    () async {
      final repository = _FailingCompletionRepository();
      final container = ProviderContainer(
        overrides: [
          startupRepositoryProvider.overrideWithValue(repository),
          diagnosticsProvider.overrideWithValue(SanitizedDiagnostics()),
        ],
      );
      addTearDown(container.dispose);

    final controller = container.read(startupControllerProvider.notifier);
    await settleStartup();
    await controller.continueLocalOnly();

    await controller.completeOnboarding();

      final state = container.read(startupControllerProvider);
      expect(state, isA<StartupRecovery>());
      expect((state as StartupRecovery).reasonCode, 'profile_creation_failed');
      expect(repository.completeCalls, 1);
      expect(
        container.read(startupControllerProvider),
        isNot(isA<StartupReady>()),
      );
    },
  );

  test(
    'no-profile snapshot with an enabled lock is Protected, never onboarding',
    () async {
      final repository = _StaticSnapshotRepository(
        StartupSnapshot(
          accountSessionState: AccountSessionState.localOnly,
          syncState: LocalSyncState.notConfigured,
          unlockRequired: true,
          onboardingCheckpoint: OnboardingCheckpoint(
            pendingProfileId: 'pending-lock',
            stage: OnboardingStage.profileDraft,
            updatedAtUtc: DateTime.utc(2026),
          ),
        ),
      );
      final container = ProviderContainer(
        overrides: [
          startupRepositoryProvider.overrideWithValue(repository),
          diagnosticsProvider.overrideWithValue(SanitizedDiagnostics()),
        ],
      );
      addTearDown(container.dispose);

      container.read(startupControllerProvider.notifier);
      await settleStartup();

      // The M6 ordering law: Privacy Lock outranks first-run presentation.
      expect(
        container.read(startupControllerProvider),
        isA<StartupProtected>(),
      );
    },
  );

  test(
    'completed checkpoint without a profile remains fail-closed Recovery',
    () async {
      final repository = _StaticSnapshotRepository(
        StartupSnapshot(
          accountSessionState: AccountSessionState.localOnly,
          syncState: LocalSyncState.notConfigured,
          unlockRequired: false,
          onboardingCheckpoint: OnboardingCheckpoint(
            pendingProfileId: 'pending-inconsistent',
            stage: OnboardingStage.completed,
            updatedAtUtc: DateTime.utc(2026),
          ),
        ),
      );
      final container = ProviderContainer(
        overrides: [
          startupRepositoryProvider.overrideWithValue(repository),
          diagnosticsProvider.overrideWithValue(SanitizedDiagnostics()),
        ],
      );
      addTearDown(container.dispose);

      container.read(startupControllerProvider.notifier);
      await settleStartup();

      expect(container.read(startupControllerProvider), isA<StartupRecovery>());
    },
  );

  test(
    'a stale completion (relock raced the commit) publishes nothing itself',
    () async {
      final gate = Completer<void>();
      final repository = _GatedCompletionRepository(gate);
      final container = ProviderContainer(
        overrides: [
          startupRepositoryProvider.overrideWithValue(repository),
          diagnosticsProvider.overrideWithValue(SanitizedDiagnostics()),
        ],
      );
      addTearDown(container.dispose);

      final controller = container.read(startupControllerProvider.notifier);
      await settleStartup();
      await controller.continueLocalOnly();
      expect(repository.resolveCalls, 1);

      // The completion starts and blocks inside the repository transaction.
      final completion = controller.completeOnboarding();
      await Future<void>.delayed(Duration.zero);

      // A newer startup generation resolves in parallel (the relock path).
      // It still observes no profile, so onboarding presentation continues.
      await controller.initialize();
      expect(
        container.read(startupControllerProvider),
        isA<StartupOnboarding>(),
      );
      expect(repository.resolveCalls, 2);

      // The commit now lands — but its attempt is stale.  The completion
      // must NOT publish anything of its own and must NOT run a second
      // resolution: the newer generation remains the only authority.
      gate.complete();
      await completion;
      expect(
        container.read(startupControllerProvider),
        isA<StartupOnboarding>(),
      );
      expect(repository.resolveCalls, 2);
    },
  );
}

final class _GatedCompletionRepository implements StartupRepository {
  _GatedCompletionRepository(
    this._gate, {
    this.postCommitUnlockRequired = false,
  });

  final Completer<void> _gate;

  /// Mirrors the real database: [beginOrResumeOnboarding] persists an
  /// incomplete checkpoint that every later resolution observes, and the
  /// profile becomes visible to resolutions only AFTER the commit lands.
  bool checkpointCreated = false;
  bool committed = false;
  int completeCalls = 0;
  int resolveCalls = 0;
  final bool postCommitUnlockRequired;

  @override
  Future<StartupSnapshot> resolveStartup() async {
    resolveCalls += 1;
    if (committed) {
      return StartupSnapshot(
        accountSessionState: AccountSessionState.localOnly,
        syncState: LocalSyncState.notConfigured,
        unlockRequired: postCommitUnlockRequired,
        profile: LocalProfile(
          id: '11111111-1111-4111-8111-111111111111',
          localName: 'Local Profile 11111111',
          createdAtUtc: DateTime.utc(2026),
          updatedAtUtc: DateTime.utc(2026),
        ),
      );
    }
    if (checkpointCreated) {
      return StartupSnapshot(
        accountSessionState: AccountSessionState.localOnly,
        syncState: LocalSyncState.notConfigured,
        unlockRequired: false,
        onboardingCheckpoint: OnboardingCheckpoint(
          pendingProfileId: 'pending-gated',
          stage: OnboardingStage.profileDraft,
          updatedAtUtc: DateTime.utc(2026),
        ),
      );
    }
    return StartupSnapshot(
      accountSessionState: AccountSessionState.localOnly,
      syncState: LocalSyncState.notConfigured,
      unlockRequired: false,
    );
  }

  @override
  Future<OnboardingCheckpoint> beginOrResumeOnboarding() async {
    checkpointCreated = true;
    return OnboardingCheckpoint(
      pendingProfileId: 'pending-gated',
      stage: OnboardingStage.profileDraft,
      updatedAtUtc: DateTime.utc(2026),
    );
  }

  @override
  Future<OnboardingCheckpoint> saveOnboardingDraft(String? displayName) async {
    checkpointCreated = true;
    return OnboardingCheckpoint(
      pendingProfileId: 'pending-gated',
      stage: OnboardingStage.profileDraft,
      updatedAtUtc: DateTime.utc(2026),
    );
  }

  @override
  Future<LocalProfile> completeOnboarding() async {
    completeCalls += 1;
    await _gate.future;
    committed = true;
    return LocalProfile(
      id: '11111111-1111-4111-8111-111111111111',
      localName: 'Local Profile 11111111',
      createdAtUtc: DateTime.utc(2026),
      updatedAtUtc: DateTime.utc(2026),
    );
  }

  @override
  Future<LocalProfile> updateDisplayName(String? displayName) =>
      throw UnimplementedError();
}

final class _FailingCompletionRepository implements StartupRepository {
  int completeCalls = 0;

  @override
  Future<StartupSnapshot> resolveStartup() async => StartupSnapshot(
    accountSessionState: AccountSessionState.localOnly,
    syncState: LocalSyncState.notConfigured,
    unlockRequired: false,
  );

  @override
  Future<OnboardingCheckpoint> beginOrResumeOnboarding() async =>
      OnboardingCheckpoint(
        pendingProfileId: 'pending-fail',
        stage: OnboardingStage.profileDraft,
        updatedAtUtc: DateTime.utc(2026),
      );

  @override
  Future<OnboardingCheckpoint> saveOnboardingDraft(String? displayName) async =>
      OnboardingCheckpoint(
        pendingProfileId: 'pending-fail',
        stage: OnboardingStage.profileDraft,
        updatedAtUtc: DateTime.utc(2026),
      );

  @override
  Future<LocalProfile> completeOnboarding() async {
    completeCalls += 1;
    throw StateError('injected completion failure');
  }

  @override
  Future<LocalProfile> updateDisplayName(String? displayName) =>
      throw UnimplementedError();
}

final class _StaticSnapshotRepository implements StartupRepository {
  _StaticSnapshotRepository(this._snapshot);

  final StartupSnapshot _snapshot;

  @override
  Future<StartupSnapshot> resolveStartup() async => _snapshot;

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
