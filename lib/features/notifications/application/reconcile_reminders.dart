import 'dart:async';

/// Serializes recovery triggers and performs one trailing pass when canonical
/// truth changes during a pass. Failures propagate and do not poison retries.
final class ReconcileReminders {
  ReconcileReminders({
    required this.reconcileEvents,
    required this.reconcileTasks,
    this.reconcilePlanning,
    this.beginRepair,
    this.completeRepair,
  });

  final Future<void> Function() reconcileEvents;
  final Future<void> Function() reconcileTasks;
  final Future<void> Function()? reconcilePlanning;

  /// M8 durable marker handoff.  [beginRepair] returns true when this drain
  /// owns a queued/retryScheduled repair episode; [completeRepair] closes a
  /// still-running episode after the passes.
  final Future<bool> Function()? beginRepair;
  final Future<void> Function()? completeRepair;
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
        var markerOwned = false;
        try {
          markerOwned = await beginRepair?.call() ?? false;
        } on Object {
          markerOwned = false;
        }
        await reconcileEvents();
        await reconcileTasks();
        await reconcilePlanning?.call();
        if (markerOwned) {
          try {
            await completeRepair?.call();
          } on Object {
            // A later trigger retries; source truth is already reconciled.
          }
          // One trailing pass absorbs a mutation that landed during this pass.
          _again = true;
        }
        _started = false;
      } while (_again);
    } finally {
      _started = false;
      _running = null;
    }
  }
}
