import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:rmplanner/core/background/background_retry_policy.dart';
import 'package:rmplanner/core/background/background_work_gateway.dart';
import 'package:rmplanner/features/notifications/application/reminder_background_runtime.dart';
import 'package:rmplanner/features/notifications/application/reminder_delivery_service.dart';
import 'package:workmanager/workmanager.dart';

/// The only permitted WorkManager delivery input (contract sections 12/14/32).
///
/// Exactly three technical keys are accepted:
/// `stable_key`, `scheduled_utc_ms`, `source_revision`.
/// Anything else — extra keys, missing keys, wrong types, or the legacy
/// two-key delivery shape — is a terminal handled no-op that must never mutate
/// domain state and must never be replayed.
final class CanonicalReminderWorkSpec {
  const CanonicalReminderWorkSpec({
    required this.stableKey,
    required this.scheduledUtcMs,
    required this.sourceRevision,
  });

  static const String taskName = 'nt.reminder.delivery';
  static const String stableKeyField = 'stable_key';
  static const String scheduledUtcMsField = 'scheduled_utc_ms';
  static const String sourceRevisionField = 'source_revision';

  static const Set<String> allowedFields = <String>{
    stableKeyField,
    scheduledUtcMsField,
    sourceRevisionField,
  };

  static final RegExp _stableKeyPattern = RegExp(
    r'^reminder:[A-Za-z0-9_.:-]{1,240}$',
  );
  static final RegExp _revisionPattern = RegExp(r'^[A-Za-z0-9_.:-]{1,256}$');

  final String stableKey;
  final int scheduledUtcMs;
  final String sourceRevision;

  DateTime get scheduledAtUtc =>
      DateTime.fromMillisecondsSinceEpoch(scheduledUtcMs, isUtc: true);

  /// `nt.reminder.<platformId>.<utcMs>.<SHA256(revision)[0:16]>`
  String uniqueNameFor(int platformNotificationId) => uniqueName(
    platformNotificationId: platformNotificationId,
    scheduledUtcMs: scheduledUtcMs,
    sourceRevision: sourceRevision,
  );

  /// The one authoritative unique-name derivation.
  ///
  /// Both the enqueue path and the release/cancel path MUST call this, so a
  /// cancellation always targets the exact generation that was registered.
  /// Deriving the name anywhere else would let a release miss its own job and
  /// leave two live delivery owners for one logical reminder (section 6/65).
  static String uniqueName({
    required int platformNotificationId,
    required int scheduledUtcMs,
    required String sourceRevision,
  }) {
    final digest = sha256.convert(utf8.encode(sourceRevision)).toString();
    return 'nt.reminder.$platformNotificationId.$scheduledUtcMs.'
        '${digest.substring(0, 16)}';
  }

  Map<String, Object?> toInputData() => <String, Object?>{
    stableKeyField: stableKey,
    scheduledUtcMsField: scheduledUtcMs,
    sourceRevisionField: sourceRevision,
  };

  BackgroundWorkSpec toWorkSpec({
    required int platformNotificationId,
    required DateTime nowUtc,
    BackgroundExistingWorkPolicy existingPolicy =
        BackgroundExistingWorkPolicy.replace,
  }) {
    final delay = scheduledAtUtc.difference(nowUtc);
    final spec = BackgroundWorkSpec(
      uniqueName: uniqueNameFor(platformNotificationId),
      taskName: taskName,
      inputData: toInputData(),
      initialDelay: delay.isNegative ? Duration.zero : delay,
      existingPolicy: existingPolicy,
      // Section 31: bounded delivery retry uses the platform's EXPONENTIAL
      // policy with the minimum 30s step, which yields 30/60/120/240s for
      // attempts 1-4.  Attempt 5 is terminal `retry_exhausted`, so no further
      // retry is requested.  The OS remains the arbiter of actual timing.
      backoffPolicy: BackgroundBackoffPolicy.exponential,
      backoffPolicyDelay: BackgroundRetryPolicy.minimumBackoffFor(1),
    );
    spec.validate();
    return spec;
  }

  /// Strict three-key parse.  Returns null for malformed, extra-key or legacy
  /// (two-key) input; callers treat null as a terminal handled no-op.
  static CanonicalReminderWorkSpec? tryParse(Map<String, Object?>? input) {
    if (input == null || input.length != allowedFields.length) return null;
    if (input.keys.any((key) => !allowedFields.contains(key))) return null;
    final key = input[stableKeyField];
    final scheduled = input[scheduledUtcMsField];
    final revision = input[sourceRevisionField];
    if (key is! String || scheduled is! int || revision is! String) return null;
    if (scheduled < 0) return null;
    if (!_stableKeyPattern.hasMatch(key)) return null;
    if (!_revisionPattern.hasMatch(revision)) return null;
    return CanonicalReminderWorkSpec(
      stableKey: key,
      scheduledUtcMs: scheduled,
      sourceRevision: revision,
    );
  }
}

@pragma('vm:entry-point')
void nextTransferBackgroundDispatcher() {
  Workmanager().executeTask((task, input) async {
    if (task == 'nt.reminder.snooze') {
      // Snooze is DEFERRED (contract section 48).  Legacy/dormant Snooze jobs
      // terminate rather than retry: the input is still validated so a
      // malformed payload is not silently accepted, but NO reminder or domain
      // behavior is performed and the invocation is reported handled.
      const keys = {'profile_id', 'source_kind', 'source_id', 'occurrence_id', 'generation', 'action_utc_ms'};
      if (input == null ||
          input.length != keys.length ||
          input.keys.any((key) => !keys.contains(key))) {
        return true;
      }
      return true;
    }
    if (task == 'nt.reminder.recovery') {
      if (input != null && input.isNotEmpty) return false;
      return runReminderRuntime();
    }
    if (task != CanonicalReminderWorkSpec.taskName) {
      return false;
    }
    final spec = CanonicalReminderWorkSpec.tryParse(input);
    if (spec == null) {
      // Malformed, extra-key or legacy two-key delivery input is terminal:
      // handled as a no-op so the OS stops retrying, with no domain mutation.
      return true;
    }
    // The dispatcher only validates and forwards the EXACT three technical
    // fields.  No private text may enter this call, so it passes the typed spec
    // rather than a raw map.
    final outcome = await runCanonicalReminderDelivery(spec);
    return switch (outcome) {
      // A known pre-post transient failure is the only outcome that may ask the
      // OS to retry; everything else is terminal for WorkManager (section 31).
      ReminderDeliveryOutcome.retryable => false,
      _ => true,
    };
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
        BackgroundBackoffPolicy.linear => BackoffPolicy.linear,
        BackgroundBackoffPolicy.exponential => BackoffPolicy.exponential,
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
    final info = await _workmanager.getWorkInfo(uniqueName);
    if (info == null) return BackgroundGatewayWorkState.absent;
    // The installed plugin merges Android ENQUEUED and BLOCKED into
    // WorkState.scheduled, and its Dart DTO exposes no Android attempt count
    // (and no finish timestamp on Android).  Report exactly that combined
    // pending meaning: never invent a distinct BLOCKED state, a retry count or
    // a completion time from WorkInfo (contract sections 64/65).
    //
    // Terminal work is NOT pending, but it is also NOT proof that a
    // notification was delivered — the durable row decides that.
    return switch (info.state) {
      WorkState.scheduled || WorkState.running =>
        BackgroundGatewayWorkState.scheduled,
      WorkState.succeeded ||
      WorkState.failed ||
      WorkState.cancelled => BackgroundGatewayWorkState.absent,
    };
  }
}
