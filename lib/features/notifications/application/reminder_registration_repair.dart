import 'package:rmplanner/core/background/background_repair_decision.dart';
import 'package:rmplanner/core/background/background_work_gateway.dart';
import 'package:rmplanner/core/background/background_work_request.dart';
import 'package:rmplanner/core/time/app_clock.dart';
import 'package:rmplanner/features/notifications/application/notification_foundation_repository.dart';
import 'package:rmplanner/features/notifications/application/reminder_reconciler.dart';

/// Repairs LOST platform registration for still-eligible reminder rows
/// (contract sections 28/36).
///
/// One logical reminder has exactly one live delivery owner.  When that owner
/// is the targeted worker, the durable row alone cannot prove the job still
/// exists: the app can be killed, the OS can drop the job, or the device can be
/// force-stopped.  The durable row would still read `scheduled` while nothing
/// would ever run.
///
/// This pass therefore asks the PLATFORM, per row, whether the exact generation
/// is still registered, and re-registers it with KEEP when it is demonstrably
/// gone.  KEEP is what makes the repair safe: it can never replace or reset a
/// job that is already queued or running, so it cannot duplicate a delivery or
/// discard a retry budget.
///
/// It never guesses: an unreadable platform produces no change, and a terminal
/// or expired row is left to the state machine and the orphan sweep.
final class ReminderRegistrationRepair {
  const ReminderRegistrationRepair({
    required this.repository,
    required this.backgroundWork,
    required this.clock,
    required this.uniqueNameFor,
    required this.enqueueWorker,
  });

  final NotificationFoundationRepository repository;
  final BackgroundWorkGateway backgroundWork;
  final AppClock clock;

  /// The exact unique name a row was registered under.  Supplied by the
  /// composition that owns the strict delivery-work identity (section 12).
  final String Function(BackgroundWorkRequest row) uniqueNameFor;

  /// Re-registers one worker-owned row through the canonical worker port.
  final Future<void> Function(BackgroundWorkRequest row) enqueueWorker;

  static bool _isTerminal(BackgroundWorkState state) => switch (state) {
    BackgroundWorkState.completed ||
    BackgroundWorkState.cancelledObsolete ||
    BackgroundWorkState.failedActionRequired => true,
    _ => false,
  };

  /// Returns how many registrations were repaired.
  Future<int> repair({required String profileId}) async {
    final now = clock.nowUtc();
    var repaired = 0;
    String? after;
    while (true) {
      final batch = await repository.readActiveReminderWork(
        profileId: profileId,
        afterStableKey: after,
      );
      if (batch.isEmpty) return repaired;
      for (final row in batch) {
        after = row.stableKey;
        if (!ReminderReconciler.ownsWorkerTransport(row.sourceRevision)) {
          // Ordinary native registration is rebuilt by the source pass, which
          // owns the request content.  Nothing is invented here.
          continue;
        }
        if (_isTerminal(row.state)) continue;
        final target = row.scheduledForUtc;
        if (target == null || !target.isAfter(now)) continue;

        final BackgroundRegistrationState platform;
        try {
          platform = switch (await backgroundWork.inspect(
            uniqueNameFor(row),
          )) {
            BackgroundGatewayWorkState.scheduled =>
              BackgroundRegistrationState.pending,
            BackgroundGatewayWorkState.absent =>
              BackgroundRegistrationState.absent,
          };
        } on Object {
          // The platform truth could not be read; change nothing.
          continue;
        }

        final action = BackgroundRepairDecision.decide(
          durable: BackgroundDurableEligibility.currentGenerationEligible,
          platform: platform,
          sameGeneration: true,
        );
        if (action != BackgroundRepairAction.enqueueKeep) continue;
        await enqueueWorker(row);
        repaired++;
      }
      if (batch.length < 200) return repaired;
    }
  }
}
