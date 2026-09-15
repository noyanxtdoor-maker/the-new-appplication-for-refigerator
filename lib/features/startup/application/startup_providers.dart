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
  Future<bool>? _draftFlush;
  String? _pendingDraft;
  Future<void>? _completion;

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

  /// Serializes persistence and discards obsolete queued text.  Every caller
  /// joins the same flush; once its current write completes, only the newest
  /// draft observed during that write can be persisted next.
  Future<bool> saveDraft(String? displayName) {
    _pendingDraft = displayName;
    final active = _draftFlush;
    if (active != null) {
      return active;
    }
    final flush = _flushLatestDraft();
    _draftFlush = flush;
    return flush.whenComplete(() {
      if (identical(_draftFlush, flush)) {
        _draftFlush = null;
      }
    });
  }

  Future<bool> _flushLatestDraft() async {
    var saved = true;
    while (true) {
      final draft = _pendingDraft;
      _pendingDraft = null;
      final attempt = _attempt;
      try {
        final checkpoint = await _repository.saveOnboardingDraft(draft);
        if (!_isCurrent(attempt)) {
          return false;
        }
        state = StartupOnboarding(checkpoint);
      } on Object {
        if (!_isCurrent(attempt)) {
          return false;
        }
        saved = false;
        _diagnostics.record(
          'onboarding_draft_save_failed',
          context: const <String, Object?>{'onboarding_stage': 'profileDraft'},
        );
      }
      if (_pendingDraft == null) {
        return saved;
      }
    }
  }

  /// M6: the only caller-observable completion path.  It is single-flight —
  /// duplicate taps join the one running operation — and it NEVER publishes a
  /// fabricated [StartupReady] itself.  After the repository's atomic
  /// create/seed/complete transaction commits, the EXISTING startup
  /// resolution re-runs so the destination must pass the canonical gate
  /// (Privacy Lock, consistency checks, generation currency) exactly like a
  /// relaunch.  The onboarding button can therefore never authorize private
  /// access on its own, and a process death after the commit is recognized as
  /// a returning user on the next start.
  Future<void> completeOnboarding() {
    final active = _completion;
    if (active != null) {
      return active;
    }
    final completion = _completeAndResolve();
    _completion = completion;
    return completion.whenComplete(() {
      if (identical(_completion, completion)) {
        _completion = null;
      }
    });
  }

  Future<void> _completeAndResolve() async {
    final attempt = _attempt;
    try {
      await _repository.completeOnboarding();
    } on Object {
      if (!_isCurrent(attempt)) {
        return;
      }
      _diagnostics.record(
        'onboarding_completion_failed',
        context: const <String, Object?>{'onboarding_stage': 'profileDraft'},
      );
      state = const StartupRecovery(reasonCode: 'profile_creation_failed');
      return;
    }
    // Stale completion (a newer generation owns resolution, e.g. a relock
    // raced the commit) deliberately publishes nothing: that generation's own
    // resolution is authoritative.
    if (!_isCurrent(attempt)) {
      return;
    }
    await initialize();
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

  /// M6 ordering law: completed-without-profile data stays fail-closed
  /// Recovery, Privacy Lock outranks first-run presentation, and only a truly
  /// unlocked, unlocked-gated snapshot reaches the Welcome/Onboarding front
  /// door.  A no-profile snapshot with an enabled lock must never select
  /// onboarding, so a restored or copied data set cannot expose the front
  /// door ahead of authentication.
  StartupState _stateFromSnapshot(StartupSnapshot snapshot) {
    final profile = snapshot.profile;
    if (profile == null) {
      final checkpoint = snapshot.onboardingCheckpoint;
      if (checkpoint != null && checkpoint.stage == OnboardingStage.completed) {
        return const StartupRecovery(
          reasonCode: 'profile_checkpoint_inconsistent',
        );
      }
      if (snapshot.unlockRequired) {
        return const StartupProtected();
      }
      if (checkpoint == null) {
        return const StartupWelcome();
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
