import 'package:rmplanner/core/background/background_repair_decision.dart';
import 'package:rmplanner/core/background/background_work_gateway.dart';
import 'package:rmplanner/core/background/background_work_request.dart';
import 'package:rmplanner/core/background/reminder_recovery_request.dart';
import 'package:rmplanner/core/notifications/notification_gateway.dart';
import 'package:rmplanner/core/notifications/notification_payload.dart';
import 'package:rmplanner/core/time/app_clock.dart';
import 'package:rmplanner/features/notifications/application/notification_foundation_repository.dart';
import 'package:rmplanner/features/notifications/application/reminder_recovery_coordinator.dart';

/// Whether an adapter could be reached at snapshot time.
///
/// `unknown` is a first-class value: a failed probe proves nothing, so it must
/// never be reported as available OR as absent.
enum BackgroundAdapterAvailability { available, unknown, unavailable }

/// Privacy-safe typed background-operational snapshot (contract section 38).
///
/// It contains ONLY enums, counts, booleans and UTC timestamps.  It never
/// carries an Event/Task/Contact name, notes, description, report or reflection
/// text, location, coordinates, notification body, raw payload, source/Contact/
/// profile identifier, unique work name, revision, stack trace or arbitrary
/// exception string.  It is built from explicit fields — never from
/// `toString()` of a work row or a `WorkInfo`.
///
/// Producing it performs NO reconciliation, NO enqueue, NO permission request
/// and NO export: it only reads current state.
final class BackgroundDiagnosticSnapshot {
  const BackgroundDiagnosticSnapshot({
    required this.capturedAtUtc,
    required this.notificationAdapter,
    required this.backgroundAdapter,
    required this.workCountsByState,
    required this.recoveryState,
    required this.recoveryAttemptCount,
    required this.recoveryLastAttemptAtUtc,
    required this.recoveryNextEligibleAtUtc,
    required this.recoveryCompletedAtUtc,
    required this.recoveryFailureCategory,
    required this.pendingNativeReminderCount,
    required this.recoveryWorkerRegistration,
  });

  final DateTime capturedAtUtc;
  final BackgroundAdapterAvailability notificationAdapter;
  final BackgroundAdapterAvailability backgroundAdapter;

  /// Counts per durable reminder-work state.  Counts only — never rows.
  final Map<BackgroundWorkState, int> workCountsByState;

  /// The reconciliation marker's own durable state, when a marker exists.
  final BackgroundWorkState? recoveryState;
  final int? recoveryAttemptCount;
  final DateTime? recoveryLastAttemptAtUtc;
  final DateTime? recoveryNextEligibleAtUtc;
  final DateTime? recoveryCompletedAtUtc;

  /// Only an allow-listed technical category can appear here.
  final String? recoveryFailureCategory;

  /// Native pending reminders owned by this profile, EXCLUDING the launcher
  /// badge.  Null means the platform could not be read — not zero.
  final int? pendingNativeReminderCount;

  /// What the OS reports for the recovery unique name.  Android exposes no
  /// attempt count or finish timestamp here, so none is fabricated.
  final BackgroundRegistrationState recoveryWorkerRegistration;
}

/// Reads the current background-operational snapshot (contract section 38).
final class BackgroundDiagnostics {
  const BackgroundDiagnostics({
    required this.repository,
    required this.gateway,
    required this.backgroundWork,
    required this.clock,
    required this.notificationsAdapterInstalled,
    required this.backgroundAdapterInstalled,
    required this.reservedPlatformId,
  });

  final NotificationFoundationRepository repository;
  final NotificationGateway gateway;
  final BackgroundWorkGateway backgroundWork;
  final AppClock clock;
  final bool notificationsAdapterInstalled;
  final bool backgroundAdapterInstalled;
  final int reservedPlatformId;

  Future<BackgroundDiagnosticSnapshot> snapshot({
    required String profileId,
  }) async {
    final marker = await repository.readWorkRequest(
      ReminderRecoveryRequest.stableKeyFor(profileId),
    );

    // Counts are derived from the scoped active listing plus the marker; no row
    // content leaves this method.
    final counts = <BackgroundWorkState, int>{};
    String? after;
    while (true) {
      final batch = await repository.readActiveReminderWork(
        profileId: profileId,
        afterStableKey: after,
      );
      if (batch.isEmpty) break;
      for (final row in batch) {
        after = row.stableKey;
        counts[row.state] = (counts[row.state] ?? 0) + 1;
      }
      if (batch.length < 200) break;
    }
    if (marker != null) {
      counts[marker.state] = (counts[marker.state] ?? 0) + 1;
    }

    // Each adapter is probed EXACTLY ONCE so every field of one snapshot is
    // derived from a single observation of the platform.  Probing twice could
    // report availability from one platform state and registration from
    // another, i.e. a snapshot that never described any real instant.
    final background = await _probeBackground();
    final notifications = await _probeNotifications(profileId);

    return BackgroundDiagnosticSnapshot(
      capturedAtUtc: clock.nowUtc(),
      notificationAdapter: notifications.availability,
      backgroundAdapter: background.availability,
      workCountsByState: counts,
      recoveryState: marker?.state,
      recoveryAttemptCount: marker?.attemptCount,
      recoveryLastAttemptAtUtc: marker?.lastAttemptAtUtc,
      recoveryNextEligibleAtUtc: marker?.nextEligibleAtUtc,
      recoveryCompletedAtUtc: marker?.completedAtUtc,
      recoveryFailureCategory: marker?.lastFailureCategory,
      pendingNativeReminderCount: notifications.pendingReminderCount,
      recoveryWorkerRegistration: background.registration,
    );
  }

  /// One read of the background scheduler: availability AND registration.
  Future<_BackgroundProbe> _probeBackground() async {
    if (!backgroundAdapterInstalled) {
      return (
        availability: BackgroundAdapterAvailability.unavailable,
        registration: BackgroundRegistrationState.unavailable,
      );
    }
    final BackgroundGatewayWorkState state;
    try {
      state = await backgroundWork.inspect(
        ReminderRecoveryCoordinator.recoveryUniqueName,
      );
    } on Object {
      // A failed probe proves nothing, so registration is unavailable too.
      return (
        availability: BackgroundAdapterAvailability.unknown,
        registration: BackgroundRegistrationState.unavailable,
      );
    }
    return (
      availability: BackgroundAdapterAvailability.available,
      registration: switch (state) {
        BackgroundGatewayWorkState.scheduled =>
          BackgroundRegistrationState.pending,
        BackgroundGatewayWorkState.absent => BackgroundRegistrationState.absent,
      },
    );
  }

  /// One read of the notification platform: availability AND the pending
  /// reminder count for the CURRENT profile.
  ///
  /// The launcher badge is excluded, an undecodable/foreign payload is not
  /// counted, and a failed read reports null rather than a fabricated zero.
  Future<_NotificationProbe> _probeNotifications(String profileId) async {
    if (!notificationsAdapterInstalled) {
      return (
        availability: BackgroundAdapterAvailability.unavailable,
        pendingReminderCount: null,
      );
    }
    final List<PendingLocalNotification> pending;
    try {
      pending = await gateway.pending();
    } on Object {
      return (
        availability: BackgroundAdapterAvailability.unknown,
        pendingReminderCount: null,
      );
    }
    var count = 0;
    for (final item in pending) {
      if (item.platformId == reservedPlatformId) continue;
      final payload = item.payload;
      if (payload == null) continue;
      final intent = NotificationPayloadCodec.tryDecode(payload);
      if (intent == null || intent.profileId != profileId) continue;
      switch (intent.sourceKind) {
        case NotificationSourceKind.calendarEvent:
        case NotificationSourceKind.task:
        case NotificationSourceKind.weeklyReview:
        case NotificationSourceKind.awaitingReport:
          count++;
        case NotificationSourceKind.goalAchievement:
        case NotificationSourceKind.contactFollowUp:
        case NotificationSourceKind.unreportedSummary:
          // Dormant kinds and the persistent app-status/summary destination
          // are never counted as pending REMINDERS.
          break;
      }
    }
    return (
      availability: BackgroundAdapterAvailability.available,
      pendingReminderCount: count,
    );
  }
}

/// A single observation of the background scheduler.
typedef _BackgroundProbe = ({
  BackgroundAdapterAvailability availability,
  BackgroundRegistrationState registration,
});

/// A single observation of the notification platform.
typedef _NotificationProbe = ({
  BackgroundAdapterAvailability availability,
  int? pendingReminderCount,
});
