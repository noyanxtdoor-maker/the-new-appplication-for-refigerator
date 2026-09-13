import 'dart:async';

/// Serializes recovery triggers, consumes the durable repair marker, and
/// performs one trailing pass when canonical truth changes during a pass.
///
/// Contract sections 28/30:
/// * repeated foreground requests must NOT cancel or restart a running
///   recovery — a trigger arriving while work is in flight coalesces into the
///   running pass instead of starting a competing one;
/// * a mutation that lands WHILE a pass is running must not be lost, so the
///   marker's dirty generation is captured before the pass and re-checked after
///   it, producing exactly ONE trailing pass;
/// * a newer marker generation is never stamped `completed` by an older result.
///
/// Failures propagate (the caller decides what a failed foreground pass means)
/// but they are first recorded against the captured generation so the bounded
/// retry budget survives an exception.
final class ReconcileReminders {
  ReconcileReminders({
    required this.reconcileEvents,
    required this.reconcileTasks,
    this.reconcilePlanning,
    this.reconcileOrphans,
    this.claimRepair,
    this.completeRepair,
    this.failRepair,
  });

  final Future<void> Function() reconcileEvents;
  final Future<void> Function() reconcileTasks;
  final Future<void> Function()? reconcilePlanning;

  /// Unbounded-in-time, profile-scoped orphan cleanup (contract section 34).
  /// Runs inside the same coalesced pass so it can never race a sibling pass.
  final Future<void> Function()? reconcileOrphans;

  /// Marks the current dirty generation `running` and returns its captured
  /// token, or null when there is nothing to repair.
  final Future<String?> Function()? claimRepair;

  /// Completes the captured generation.  False means a newer dirty mark landed
  /// during the pass, so exactly one trailing pass is required.
  final Future<bool> Function(String capturedToken)? completeRepair;

  /// Records a failed attempt for the captured generation under the bounded
  /// retry law.  Must not run inside a transaction that will roll back.
  final Future<void> Function(String capturedToken, String failureCategory)?
  failRepair;

  /// The truthful technical category for a foreground pass that could not
  /// complete.  The pass cannot know WHY the runtime failed, so it reports the
  /// one category that is actually proven: the runtime was unavailable.
  static const String unavailableFailureCategory = 'runtime_unavailable';

  Future<void>? _running;
  bool _again = false;
  bool _started = false;
  int _holds = 0;
  Completer<void>? _resume;

  /// Permission dialogs can resume the app before the master write finishes.
  /// Keep those recovery triggers queued until the preference is durable.
  void Function() hold() {
    _holds++;
    _resume ??= Completer<void>();
    var released = false;
    return () {
      if (released) return;
      released = true;
      if (--_holds == 0) {
        final resume = _resume;
        _resume = null;
        resume?.complete();
      }
    };
  }

  Future<void> call() {
    final running = _running;
    if (running != null) {
      if (_started) _again = true;
      return running;
    }
    // Yield to the switch frame and merge triggers queued before work starts.
    final future = Future<void>(_drain);
    _running = future;
    return future;
  }

  Future<void> _drain() async {
    try {
      do {
        _again = false;
        await _resume?.future;
        _started = true;
        final token = await claimRepair?.call();
        try {
          await reconcileEvents();
          await reconcileTasks();
          await reconcilePlanning?.call();
          await reconcileOrphans?.call();
        } on Object {
          // Commit the failed attempt OUTSIDE the pass so an exception cannot
          // lose the bounded retry budget (section 31).
          if (token != null) {
            try {
              await failRepair?.call(token, unavailableFailureCategory);
            } on Object {
              // The failure could not be durably recorded — for example the
              // database is unavailable.  Section 31 forbids inventing an
              // attempt row or looping forever, and bookkeeping trouble must
              // never mask the real failure: terminate this invocation and let
              // a later real startup/resume/recovery trigger retry
              // initialization.
            }
          }
          rethrow;
        }
        if (token != null) {
          final unchanged = await completeRepair?.call(token) ?? true;
          // Truth changed underneath this pass: run one more pass for the newer
          // generation rather than marking it completed with a stale result.
          if (!unchanged) _again = true;
        }
        _started = false;
      } while (_again);
    } finally {
      _started = false;
      _running = null;
    }
  }
}
