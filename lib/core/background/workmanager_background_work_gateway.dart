import 'package:rmplanner/core/background/background_work_gateway.dart';
import 'package:rmplanner/features/notifications/application/reminder_background_runtime.dart';
import 'package:workmanager/workmanager.dart';

/// Targeted enriched delivery input (Astra §12/§14): EXACTLY the three
/// technical keys.  No private text ever enters WorkManager input.
final class CanonicalReminderWorkSpecInput {
  const CanonicalReminderWorkSpecInput({
    required this.stableKey,
    required this.scheduledUtcMs,
    required this.sourceRevision,
  });

  static const String stableKeyField = 'stable_key';
  static const String scheduledUtcMsField = 'scheduled_utc_ms';
  static const String sourceRevisionField = 'source_revision';

  static const Set<String> allowedKeys = <String>{
    stableKeyField,
    scheduledUtcMsField,
    sourceRevisionField,
  };

  final String stableKey;
  final int scheduledUtcMs;
  final String sourceRevision;

  Map<String, Object> toInput() => <String, Object>{
    stableKeyField: stableKey,
    scheduledUtcMsField: scheduledUtcMs,
    sourceRevisionField: sourceRevision,
  };

  /// Strict three-key parse: exact keys, types and shapes.  Legacy two-key
  /// input and any extra/malformed field are rejected (caller treats them as
  /// terminal obsolete, Astra §32 step 1).
  static CanonicalReminderWorkSpecInput? tryParse(Map<String, dynamic>? input) {
    if (input == null || input.length != allowedKeys.length) {
      return null;
    }
    for (final key in input.keys) {
      if (!allowedKeys.contains(key)) {
        return null;
      }
    }
    final stableKey = input[stableKeyField];
    final scheduled = input[scheduledUtcMsField];
    final revision = input[sourceRevisionField];
    if (stableKey is! String ||
        !RegExp(r'^reminder:[A-Za-z0-9_.:-]{1,240}$').hasMatch(stableKey)) {
      return null;
    }
    if (scheduled is! int || scheduled < 0) {
      return null;
    }
    if (revision is! String ||
        !RegExp(r'^[A-Za-z0-9_.:-]{1,256}$').hasMatch(revision)) {
      return null;
    }
    return CanonicalReminderWorkSpecInput(
      stableKey: stableKey,
      scheduledUtcMs: scheduled,
      sourceRevision: revision,
    );
  }

  /// Legacy two-key M4 delivery input — recognized only to be ignored.
  static bool isLegacyTwoKeyInput(Map<String, dynamic>? input) {
    if (input == null || input.length != 2) return false;
    return input.containsKey(stableKeyField) &&
        input.containsKey(scheduledUtcMsField) &&
        !input.containsKey(sourceRevisionField);
  }
}

@pragma('vm:entry-point')
void nextTransferBackgroundDispatcher() {
  Workmanager().executeTask((task, input) async {
    if (task == 'nt.reminder.snooze') {
      // Astra §48: Snooze is deferred.  Runtime handles it without scheduling
      // or domain mutation; legacy queued jobs terminate rather than retry.
      return runReminderRuntime(snoozeIgnored: true);
    }
    if (task == 'nt.reminder.recovery') {
      if (input != null && input.isNotEmpty) return false;
      return runReminderRuntime();
    }
    if (task != 'nt.reminder.delivery') {
      return false;
    }
    // Three-key targeted delivery; legacy two-key input is terminal obsolete
    // (handled true, no post, no domain mutation); anything else is malformed
    // and also handled without retry.
    final spec = CanonicalReminderWorkSpecInput.tryParse(input);
    if (spec != null) {
      return runReminderRuntime(
        deliveryKey: spec.stableKey,
        scheduledAtUtc: DateTime.fromMillisecondsSinceEpoch(
          spec.scheduledUtcMs,
          isUtc: true,
        ),
        deliverySourceRevision: spec.sourceRevision,
      );
    }
    if (CanonicalReminderWorkSpecInput.isLegacyTwoKeyInput(input)) {
      return runReminderRuntime(legacyDeliveryIgnored: true);
    }
    return false;
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
        BackgroundBackoffPolicy.none => BackoffPolicy.linear,
        BackgroundBackoffPolicy.exponential => BackoffPolicy.exponential,
      },
      backoffPolicyDelay: work.backoffPolicyDelay,
    );
  }

  @override
  Future<void> cancelUnique(String uniqueName) =>
      _workmanager.cancelByUniqueName(uniqueName);

  /// Astra §65 truthful WorkInfo mapping.  Android ENQUEUED/BLOCKED map to
  /// [BackgroundGatewayWorkState.scheduled] (the installed plugin cannot
  /// distinguish them in its Dart DTO); terminal states map truthfully;
  /// null is absent; query failure is UNKNOWN, never absence.
  @override
  Future<BackgroundGatewayWorkState> inspect(String uniqueName) async {
    final WorkInfo? info;
    try {
      info = await _workmanager.getWorkInfo(uniqueName);
    } on Object {
      return BackgroundGatewayWorkState.unknown;
    }
    if (info == null) {
      return BackgroundGatewayWorkState.absent;
    }
    return switch (info.state) {
      WorkState.scheduled => BackgroundGatewayWorkState.scheduled,
      WorkState.running => BackgroundGatewayWorkState.running,
      WorkState.succeeded => BackgroundGatewayWorkState.succeeded,
      WorkState.failed => BackgroundGatewayWorkState.failed,
      WorkState.cancelled => BackgroundGatewayWorkState.cancelled,
    };
  }
}
