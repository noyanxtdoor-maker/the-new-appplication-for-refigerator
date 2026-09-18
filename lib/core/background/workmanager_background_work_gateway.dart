import 'package:rmplanner/core/background/background_work_gateway.dart';
import 'package:rmplanner/features/notifications/application/reminder_background_runtime.dart';
import 'package:workmanager/workmanager.dart';

@pragma('vm:entry-point')
void nextTransferBackgroundDispatcher() {
  Workmanager().executeTask((task, input) async {
    if (task == 'nt.reminder.snooze') {
      // VS16 M7/M8: Snooze is deferred. Legacy or forged Snooze work must
      // terminate as a handled no-op without scheduling, domain mutation or
      // retry. Do not route it through the reminder runtime at all.
      return true;
    }
    if (task == 'nt.reminder.recovery') {
      // The recovery task and its one-off horizon-refill re-arm share this
      // task name; both always run with empty input (contract section 28).
      if (input != null && input.isNotEmpty) return false;
      return runReminderRuntime(
        backgroundGatewayOverride: const WorkmanagerBackgroundWorkGateway(),
      );
    }
    if (task != 'nt.reminder.delivery') {
      // Unknown/malformed legacy tasks terminate safely instead of retrying
      // forever under the plugin's exponential backoff.
      return true;
    }
    const keys = <String>{'stable_key', 'scheduled_utc_ms', 'source_revision'};
    if (input == null || input.length != keys.length) {
      // Two-key (or empty) delivery input is a pre-M7 legacy job with no
      // authoritative revision to re-read: terminal obsolete, never replayed.
      return true;
    }
    if (input.keys.any((key) => !keys.contains(key))) return true;
    final key = input['stable_key'];
    final timestamp = input['scheduled_utc_ms'];
    final revision = input['source_revision'];
    if (key is! String ||
        timestamp is! int ||
        revision is! String ||
        !RegExp(r'^reminder:[A-Za-z0-9_.:-]{1,240}$').hasMatch(key) ||
        !RegExp(r'^[A-Za-z0-9_.:-]{1,256}$').hasMatch(revision)) {
      return true;
    }
    return runReminderRuntime(
      deliveryKey: key,
      scheduledAtUtc: DateTime.fromMillisecondsSinceEpoch(
        timestamp,
        isUtc: true,
      ),
      sourceRevision: revision,
    );
  });
}

final class WorkmanagerBackgroundWorkGateway implements BackgroundWorkGateway {
  const WorkmanagerBackgroundWorkGateway();

  Workmanager get _workmanager => Workmanager();

  @override
  Future<void> initialize() =>
      _workmanager.initialize(nextTransferBackgroundDispatcher);

  @override
  Future<void> enqueueUnique(BackgroundWorkSpec work) {
    work.validate();
    return _workmanager.registerOneOffTask(
      work.uniqueName,
      work.taskName,
      inputData: Map<String, dynamic>.from(work.inputData),
      initialDelay: work.initialDelay,
      tag: work.tag,
      constraints: Constraints(
        networkType: switch (work.constraints.network) {
          BackgroundNetworkConstraint.notRequired => NetworkType.notRequired,
          BackgroundNetworkConstraint.connected => NetworkType.connected,
          BackgroundNetworkConstraint.unmetered => NetworkType.unmetered,
        },
        requiresCharging: work.constraints.requiresCharging,
        requiresBatteryNotLow: work.constraints.requiresBatteryNotLow,
        requiresStorageNotLow: work.constraints.requiresStorageNotLow,
      ),
      existingWorkPolicy: switch (work.existingPolicy) {
        BackgroundExistingWorkPolicy.keep => ExistingWorkPolicy.keep,
        BackgroundExistingWorkPolicy.replace => ExistingWorkPolicy.replace,
      },
      backoffPolicy: switch (work.backoffPolicy) {
        BackgroundBackoffPolicy.exponential => BackoffPolicy.exponential,
        BackgroundBackoffPolicy.linear => BackoffPolicy.linear,
        null => null,
      },
      backoffPolicyDelay: work.backoffPolicyDelay,
    );
  }

  @override
  Future<void> cancelUnique(String uniqueName) =>
      _workmanager.cancelByUniqueName(uniqueName);

  @override
  Future<BackgroundGatewayWorkState> inspect(String uniqueName) async {
    try {
      final info = await _workmanager.getWorkInfo(uniqueName);
      return switch (info?.state) {
        null => BackgroundGatewayWorkState.absent,
        WorkState.scheduled => BackgroundGatewayWorkState.scheduled,
        WorkState.running => BackgroundGatewayWorkState.running,
        WorkState.succeeded => BackgroundGatewayWorkState.succeeded,
        WorkState.failed => BackgroundGatewayWorkState.failed,
        WorkState.cancelled => BackgroundGatewayWorkState.cancelled,
      };
    } on Object {
      // A platform without a truthful query API must report unknown rather
      // than fabricate a runnable or delayed state.
      return BackgroundGatewayWorkState.unknown;
    }
  }
}
