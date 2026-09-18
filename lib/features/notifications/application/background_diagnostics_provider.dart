import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rmplanner/core/background/reminder_recovery_request.dart';
import 'package:rmplanner/core/notifications/flutter_local_notifications_launcher_badge_gateway.dart';
import 'package:rmplanner/core/time/app_clock.dart';
import 'package:rmplanner/features/notifications/application/notification_providers.dart';
import 'package:rmplanner/features/startup/application/startup_providers.dart';
import 'package:rmplanner/features/startup/domain/startup_state.dart';

enum DiagnosticAdapterState { available, unavailable, unknown }

/// Explicit, privacy-safe M8 background technical snapshot.
///
/// Built from typed fields only: enums, counts and UTC timestamps.  It never
/// contains Event/Task/Contact names, notes, locations, payloads, source or
/// profile IDs, unique work names, revisions or raw error strings.
final class BackgroundDiagnosticSnapshot {
  const BackgroundDiagnosticSnapshot({
    required this.capturedAtUtc,
    required this.notificationAdapter,
    required this.backgroundAdapter,
    required this.countsByState,
    required this.recoveryState,
    required this.pendingNativeReminderCount,
    required this.workerState,
    this.recoveryAttempts,
    this.lastAttemptAtUtc,
    this.nextEligibleAtUtc,
    this.completedAtUtc,
    this.recoveryFailureCategory,
  });

  final DateTime capturedAtUtc;
  final DiagnosticAdapterState notificationAdapter;
  final DiagnosticAdapterState backgroundAdapter;

  /// Counts per [BackgroundWorkState] name for the current profile.
  final Map<String, int> countsByState;
  final String recoveryState;
  final int? recoveryAttempts;
  final DateTime? lastAttemptAtUtc;
  final DateTime? nextEligibleAtUtc;
  final DateTime? completedAtUtc;
  final String? recoveryFailureCategory;
  final int pendingNativeReminderCount;
  final String workerState;
}

final backgroundDiagnosticsProvider =
    FutureProvider<BackgroundDiagnosticSnapshot>((ref) async {
      final clock = const SystemAppClock();
      final capturedAtUtc = clock.nowUtc();
      String? profileId = ref.read(reminderRuntimeProfileIdProvider);
      if (profileId == null) {
        final startup = ref.read(startupControllerProvider);
        if (startup is StartupReady) profileId = startup.profile.id;
      }
      if (profileId == null) {
        return BackgroundDiagnosticSnapshot(
          capturedAtUtc: capturedAtUtc,
          notificationAdapter: DiagnosticAdapterState.unknown,
          backgroundAdapter: DiagnosticAdapterState.unknown,
          countsByState: const <String, int>{},
          recoveryState: 'Not recorded',
          pendingNativeReminderCount: 0,
          workerState: 'Not recorded',
        );
      }
      final foundation = ref.read(notificationPlatformFoundationProvider);
      final repository = ref.read(notificationFoundationRepositoryProvider);
      final active = await repository.readActiveReminderWork(
        profileId: profileId,
      );
      final counts = <String, int>{};
      for (final work in active) {
        counts.update(work.state.name, (value) => value + 1, ifAbsent: () => 1);
      }
      final marker = active
          .where(
            (work) =>
                work.stableKey ==
                ReminderRecoveryRequest.stableKeyFor(profileId!),
          )
          .firstOrNull;
      var pendingCount = 0;
      try {
        final pending = await ref.read(notificationGatewayProvider).pending();
        pendingCount = pending
            .where(
              (item) =>
                  item.platformId !=
                  FlutterLocalNotificationsLauncherBadgeGateway.notificationId,
            )
            .length;
      } on Object {
        pendingCount = 0;
      }
      var workerState = 'Not recorded';
      try {
        final observed = await ref
            .read(backgroundWorkGatewayProvider)
            .inspect('nt.reminder.recovery');
        workerState = observed.name;
      } on Object {
        workerState = 'Unavailable';
      }
      return BackgroundDiagnosticSnapshot(
        capturedAtUtc: capturedAtUtc,
        notificationAdapter: foundation.notificationsAvailable
            ? DiagnosticAdapterState.available
            : DiagnosticAdapterState.unavailable,
        backgroundAdapter: foundation.backgroundWorkAvailable
            ? DiagnosticAdapterState.available
            : DiagnosticAdapterState.unavailable,
        countsByState: counts,
        recoveryState: marker?.state.name ?? 'Not recorded',
        recoveryAttempts: marker?.attemptCount,
        lastAttemptAtUtc: marker?.lastAttemptAtUtc,
        nextEligibleAtUtc: marker?.nextEligibleAtUtc,
        completedAtUtc: marker?.completedAtUtc,
        recoveryFailureCategory: marker?.lastFailureCategory,
        pendingNativeReminderCount: pendingCount,
        workerState: workerState,
      );
    });
