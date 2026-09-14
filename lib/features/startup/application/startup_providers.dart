import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/features/startup/application/startup_repository.dart';
import 'package:rmplanner/features/startup/domain/onboarding_checkpoint.dart';
import 'package:rmplanner/features/startup/domain/startup_snapshot.dart';
import 'package:rmplanner/features/startup/domain/startup_state.dart';

final startupRepositoryProvider = Provider<StartupRepository>((ref) {
  throw StateError('StartupRepository must be overridden at the app root');
});

final diagnosticsProvider = Provider<SanitizedDiagnostics>((ref) {
  throw StateError('SanitizedDiagnostics must be overridden at the app root');
});

final startupControllerProvider =
    NotifierProvider<StartupController, StartupState>(StartupController.new);

final class StartupController extends Notifier<StartupState> {
  int _attempt = 0;

  StartupRepository get _repository => ref.read(startupRepositoryProvider);
  SanitizedDiagnostics get _diagnostics => ref.read(diagnosticsProvider);

  @override
  StartupState build() {
    unawaited(initialize());
    return const StartupOpening();
  }

  /// M1 (S01): a result is published only while its attempt is still the newest
  /// security resolution and this notifier is still mounted.  Stale results and
  /// stale failures are discarded, never converted into a new state.
  bool _isCurrent(int attempt) => attempt == _attempt && ref.mounted;

  Future<void> initialize() async {
    final attempt = ++_attempt;
    state = const StartupOpening();
    _diagnostics.record(
      'startup_initialize',
      context: <String, Object?>{'attempt': attempt},
    );
    try {
      final snapshot = await _repository.resolveStartup();
      if (!_isCurrent(attempt)) {
        return;
      }
      state = _stateFromSnapshot(snapshot);
    } on Object {
      if (!_isCurrent(attempt)) {
        return;
      }
      _diagnostics.record(
        'startup_recovery_required',
        context: <String, Object?>{'attempt': attempt},
      );
      state = const StartupRecovery(reasonCode: 'database_open_failed');
    }
  }

  Future<void> continueLocalOnly() async {
    final attempt = _attempt;
    try {
      final checkpoint = await _repository.beginOrResumeOnboarding();
      if (!_isCurrent(attempt)) {
        return;
      }
      state = StartupOnboarding(checkpoint);
    } on Object {
      if (!_isCurrent(attempt)) {
        return;
      }
      state = const StartupRecovery(reasonCode: 'onboarding_start_failed');
    }
  }

  Future<void> saveDraft(String? displayName) async {
    final attempt = _attempt;
    try {
      final checkpoint = await _repository.saveOnboardingDraft(displayName);
      if (!_isCurrent(attempt)) {
        return;
      }
      state = StartupOnboarding(checkpoint);
    } on Object {
      if (!_isCurrent(attempt)) {
        return;
      }
      _diagnostics.record(
        'onboarding_draft_save_failed',
        context: const <String, Object?>{'onboarding_stage': 'profileDraft'},
      );
    }
  }

  Future<void> completeOnboarding() async {
    final attempt = _attempt;
    try {
      final profile = await _repository.completeOnboarding();
      if (!_isCurrent(attempt)) {
        return;
      }
      state = StartupReady(
        profile: profile,
        accountSessionState: AccountSessionState.localOnly,
        syncState: LocalSyncState.notConfigured,
      );
    } on Object {
      if (!_isCurrent(attempt)) {
        return;
      }
      state = const StartupRecovery(reasonCode: 'profile_creation_failed');
    }
  }

  Future<void> updateDisplayName(String? displayName) async {
    final current = state;
    if (current is! StartupReady) {
      return;
    }
    final attempt = _attempt;
    final profile = await _repository.updateDisplayName(displayName);
    if (!_isCurrent(attempt)) {
      return;
    }
    final latest = state;
    if (latest is! StartupReady || latest.profile.id != current.profile.id) {
      return;
    }
    state = StartupReady(
      profile: profile,
      accountSessionState: current.accountSessionState,
      syncState: current.syncState,
    );
  }

  StartupState _stateFromSnapshot(StartupSnapshot snapshot) {
    final profile = snapshot.profile;
    if (profile == null) {
      final checkpoint = snapshot.onboardingCheckpoint;
      if (checkpoint == null) {
        return const StartupWelcome();
      }
      if (checkpoint.stage == OnboardingStage.completed) {
        return const StartupRecovery(
          reasonCode: 'profile_checkpoint_inconsistent',
        );
      }
      return StartupOnboarding(checkpoint);
    }
    if (snapshot.unlockRequired) {
      return const StartupProtected();
    }
    return StartupReady(
      profile: profile,
      accountSessionState: snapshot.accountSessionState,
      syncState: snapshot.syncState,
    );
  }
}
