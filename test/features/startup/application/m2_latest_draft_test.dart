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

void main() {
  test('M2 P05 coalesces 30 edits to the in-flight and final draft only', () async {
    final repository = _DraftRepository();
    final container = ProviderContainer(
      overrides: [
        startupRepositoryProvider.overrideWithValue(repository),
        diagnosticsProvider.overrideWithValue(SanitizedDiagnostics()),
      ],
    );
    addTearDown(container.dispose);
    await Future<void>.delayed(Duration.zero);

    final controller = container.read(startupControllerProvider.notifier);
    final first = controller.saveDraft('draft-0');
    await repository.firstWriteStarted.future;
    final writes = <Future<bool>>[first];
    for (var index = 1; index < 30; index++) {
      writes.add(controller.saveDraft('draft-$index'));
    }
    repository.completeNext('draft-0');
    await repository.secondWriteStarted.future;
    repository.completeNext('draft-29');

    expect(await Future.wait(writes), everyElement(isTrue));
    expect(repository.receivedDrafts, <String?>['draft-0', 'draft-29']);
    final state = container.read(startupControllerProvider);
    expect(state, isA<StartupOnboarding>());
    expect((state as StartupOnboarding).checkpoint.draftDisplayName, 'draft-29');
  });

  test('M2 P05 returns final-save failure and retains the last confirmed state', () async {
    final repository = _DraftRepository();
    final container = ProviderContainer(
      overrides: [
        startupRepositoryProvider.overrideWithValue(repository),
        diagnosticsProvider.overrideWithValue(SanitizedDiagnostics()),
      ],
    );
    addTearDown(container.dispose);
    await Future<void>.delayed(Duration.zero);

    final controller = container.read(startupControllerProvider.notifier);
    final save = controller.saveDraft('will-fail');
    await repository.firstWriteStarted.future;
    repository.failNext();

    expect(await save, isFalse);
    expect(container.read(startupControllerProvider), isA<StartupWelcome>());
  });
}

final class _DraftRepository implements StartupRepository {
  final firstWriteStarted = Completer<void>();
  final secondWriteStarted = Completer<void>();
  final receivedDrafts = <String?>[];
  final _pending = <Completer<OnboardingCheckpoint>>[];

  @override
  Future<StartupSnapshot> resolveStartup() async => const StartupSnapshot(
    accountSessionState: AccountSessionState.localOnly,
    syncState: LocalSyncState.notConfigured,
    unlockRequired: false,
  );

  @override
  Future<OnboardingCheckpoint> saveOnboardingDraft(String? displayName) {
    receivedDrafts.add(displayName);
    if (receivedDrafts.length == 1) firstWriteStarted.complete();
    if (receivedDrafts.length == 2) secondWriteStarted.complete();
    final pending = Completer<OnboardingCheckpoint>();
    _pending.add(pending);
    return pending.future;
  }

  void completeNext(String? displayName) {
    _pending.removeAt(0).complete(_checkpoint(displayName));
  }

  void failNext() => _pending.removeAt(0).completeError(StateError('save failed'));

  OnboardingCheckpoint _checkpoint(String? value) => OnboardingCheckpoint(
    pendingProfileId: 'pending',
    stage: OnboardingStage.profileDraft,
    updatedAtUtc: DateTime.utc(2026),
    draftDisplayName: value,
  );

  @override
  Future<OnboardingCheckpoint> beginOrResumeOnboarding() async =>
      _checkpoint(null);

  @override
  Future<LocalProfile> completeOnboarding() => throw UnimplementedError();

  @override
  Future<LocalProfile> updateDisplayName(String? displayName) =>
      throw UnimplementedError();
}
