import 'package:rmplanner/core/background/background_work_gateway.dart';
import 'package:rmplanner/core/background/reminder_recovery_request.dart';
import 'package:rmplanner/core/time/app_clock.dart';
import 'package:rmplanner/features/notifications/application/notification_foundation_repository.dart';

/// Bounded reminder-recovery maintenance (contract section 28).
///
/// Two responsibilities, both deliberately narrow:
///
/// * [enqueueIfDirty] — turns a DURABLE dirty marker into ONE bounded recovery
///   job so a committed repair intent survives the app being killed.  It uses
///   KEEP, never REPLACE: a repeated foreground request must not cancel a
///   recovery that is already running.  Nothing is lost by KEEP because the
///   marker's dirty generation is what proves a change arrived mid-pass, and the
///   pass itself runs one trailing pass for it.
/// * [armRefill] — re-arms the bounded 42-day horizon refill after a SUCCESSFUL
///   recovery.  Exactly one unique name, armed only by success, so a failing job
///   can never spawn a chain.  This is real LOCAL reminder maintenance, not a
///   content poll: no network constraint, no charging requirement, no content
///   refresh and no invented "last checked" status.
final class ReminderRecoveryCoordinator {
  const ReminderRecoveryCoordinator({
    required this.repository,
    required this.backgroundWork,
    required this.clock,
  });

  final NotificationFoundationRepository repository;
  final BackgroundWorkGateway backgroundWork;
  final AppClock clock;

  /// The existing recovery task name.  Empty input is valid ONLY for this task.
  static const String recoveryTaskName = 'nt.reminder.recovery';

  /// The one foreground/native recovery unique name.
  static const String recoveryUniqueName = 'nt.reminder.recovery';

  /// The one bounded horizon-refill unique name.
  static const String refillUniqueName = 'nt.reminder.refill';

  /// Bounded refill cadence for the 42-day reminder projection.
  static const Duration refillInterval = Duration(hours: 24);

  /// Enqueues one KEEP recovery job when a live repair marker is pending.
  ///
  /// Returns whether a job was enqueued.  No marker means nothing to repair, so
  /// no OS work is scheduled.
  Future<bool> enqueueIfDirty({required String profileId}) async {
    final marker = await repository.readWorkRequest(
      ReminderRecoveryRequest.stableKeyFor(profileId),
    );
    if (marker == null ||
        !ReminderRecoveryRequest.isLiveEpisode(marker.state)) {
      return false;
    }
    await _enqueue(recoveryUniqueName, recoveryTaskName);
    return true;
  }

  /// Re-arms the bounded horizon refill.  Only a successful recovery calls this.
  Future<void> armRefill() =>
      _enqueue(refillUniqueName, recoveryTaskName, initialDelay: refillInterval);

  Future<void> _enqueue(
    String uniqueName,
    String taskName, {
    Duration? initialDelay,
  }) async {
    final spec = BackgroundWorkSpec(
      uniqueName: uniqueName,
      taskName: taskName,
      initialDelay: initialDelay,
      // KEEP: a repeated trigger must never cancel running recovery work.
      existingPolicy: BackgroundExistingWorkPolicy.keep,
    );
    spec.validate();
    await backgroundWork.enqueueUnique(spec);
  }
}
