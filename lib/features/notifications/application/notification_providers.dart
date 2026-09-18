import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rmplanner/core/background/background_work_gateway.dart';
import 'package:rmplanner/core/background/reminder_recovery_request.dart';
import 'package:rmplanner/core/background/workmanager_background_work_gateway.dart';
import 'package:rmplanner/core/notifications/notification_gateway.dart';
import 'package:rmplanner/core/notifications/notification_response_controller.dart';
import 'package:rmplanner/core/time/app_clock.dart';
import 'package:rmplanner/features/notifications/application/background_diagnostics_provider.dart';
import 'package:rmplanner/features/notifications/application/notification_first_run_setup.dart';
import 'package:rmplanner/features/notifications/application/notification_foundation_repository.dart';
import 'package:rmplanner/features/notifications/application/notification_privacy_refresh_provider.dart';
import 'package:rmplanner/features/notifications/application/reminder_orphan_sweeper.dart';
import 'package:rmplanner/features/notifications/application/reminder_reconciler.dart';
import 'package:rmplanner/features/notifications/application/reminder_recovery_coordinator.dart';
import 'package:rmplanner/features/notifications/application/reminder_registration_repair.dart';
import 'package:rmplanner/features/notifications/data/drift_notification_foundation_repository.dart';
import 'package:rmplanner/features/notifications/domain/notification_preferences.dart';
import 'package:rmplanner/features/privacy/application/privacy_providers.dart';
import 'package:rmplanner/features/privacy/application/privacy_services.dart';
import 'package:rmplanner/features/privacy/domain/permission_summary.dart';
import 'package:rmplanner/features/startup/application/startup_providers.dart';
import 'package:rmplanner/features/startup/domain/startup_state.dart';
import 'package:timezone/timezone.dart' as tz;

/// Scoped only by the headless reminder runtime after reading an existing
/// primary profile. This does not alter StartupReady or any router guard.
final reminderRuntimeProfileIdProvider = Provider<String?>((ref) => null);

final notificationFoundationRepositoryProvider =
    Provider<NotificationFoundationRepository>((ref) {
      throw StateError(
        'NotificationFoundationRepository must be overridden at the app root',
      );
    });

final notificationGatewayProvider = Provider<NotificationGateway>((ref) {
  throw StateError('NotificationGateway must be overridden at the app root');
});

/// Canonical device zone for Quiet Hours arithmetic. The app root and the
/// headless runtime both override this so every delayed target uses the same
/// wall clock as Event/Task scheduling, in any isolate.
final reminderDeviceLocationProvider = Provider<Object?>((ref) {
  return null;
});

final reminderReconcilerProvider = Provider<ReminderReconciler>((ref) {
  return ReminderReconciler(
    repository: ref.read(notificationFoundationRepositoryProvider),
    gateway: ref.read(notificationGatewayProvider),
    clock: const SystemAppClock(),
    deviceLocation: ref.watch(reminderDeviceLocationProvider) as tz.Location?,
    // M7 section 6 transport selection.  The worker port is only supplied when
    // the app installed a real background-work gateway, so a key can never be
    // marked `m7w_` without a real worker registration behind it.  The
    // composition that owns the strict three-key spec (section 12/14) builds
    // the enqueue, keeping this service free of the WorkManager package.
    scheduleWorker: ref.watch(reminderWorkerTransportProvider),
    cancelWorker: ref.watch(reminderWorkerReleaseProvider),
  );
});

/// Canonical M7 worker-transport enqueue, or null when unavailable.
///
/// The app root and the headless runtime override this with the real
/// WorkManager registration.  Tests override it with a fake to assert transport
/// selection, exclusivity and the exact three-key input without a platform.
final reminderWorkerTransportProvider = Provider<ScheduleCanonicalReminderWork?>(
  (ref) => null,
);

/// Canonical M7 worker-transport release, or null when unavailable.
///
/// Paired with [reminderWorkerTransportProvider] so cancelling an obsolete
/// worker row also cancels its queued WorkManager job (contract section 6).
final reminderWorkerReleaseProvider = Provider<CancelCanonicalReminderWork?>(
  (ref) => null,
);

final notificationResponseControllerProvider =
    Provider<NotificationResponseController>((ref) {
      throw StateError(
        'NotificationResponseController must be overridden at the app root',
      );
    });

final backgroundWorkGatewayProvider = Provider<BackgroundWorkGateway>((ref) {
  throw StateError('BackgroundWorkGateway must be overridden at the app root');
});

/// The one shared transaction-local repair-marker writer, or null when the
/// composition has no database.
///
/// It is overridden at the app root (and in the headless runtime) with the same
/// instance every canonical repository already writes through, so the marker
/// lifecycle operates on the exact rows those mutations committed.
final reminderRecoveryRequestProvider = Provider<ReminderRecoveryRequest?>(
  (ref) => null,
);

/// Bounded recovery enqueue / refill maintenance (contract section 28).
final reminderRecoveryCoordinatorProvider =
    Provider<ReminderRecoveryCoordinator>((ref) {
      return ReminderRecoveryCoordinator(
        repository: ref.read(notificationFoundationRepositoryProvider),
        backgroundWork: ref.read(backgroundWorkGatewayProvider),
        clock: const SystemAppClock(),
      );
    });

/// Unbounded-in-time, profile-scoped orphan cleanup (contract section 34).
final reminderOrphanSweeperProvider = Provider<ReminderOrphanSweeper>((ref) {
  final gateway = ref.read(notificationGatewayProvider);
  // The platform's pending set is read ONCE per sweep and memoized, so the
  // forward and reverse sweeps agree on one platform snapshot instead of racing
  // two reads.  A read failure yields null = "unknown", never "empty".
  Future<Set<int>?>? pendingIds;
  Future<Set<int>?> readPendingIds() {
    return pendingIds ??= () async {
      try {
        final items = await gateway.pending();
        return items.map((item) => item.platformId).toSet();
      } on Object {
        return null;
      }
    }();
  }

  return ReminderOrphanSweeper(
    repository: ref.read(notificationFoundationRepositoryProvider),
    clock: const SystemAppClock(),
    reminders: ref.read(reminderReconcilerProvider),
    readPlatformPending: () => gateway.pending(),
    platformPendingIds: readPendingIds,
    cancelPlatform: gateway.cancel,
    reservedPlatformId:
        DriftNotificationFoundationRepository.reservedPlatformNotificationId,
  );
});

/// Both-transport registration repair (contract sections 28/36).
///
/// The exact worker unique name is derived by the ONE component that owns the
/// strict delivery-work identity, so a repair re-registers the identical
/// generation instead of a near-miss sibling name.
final reminderRegistrationRepairProvider =
    Provider<ReminderRegistrationRepair>((ref) {
      final backgroundWork = ref.read(backgroundWorkGatewayProvider);
      return ReminderRegistrationRepair(
        repository: ref.read(notificationFoundationRepositoryProvider),
        backgroundWork: backgroundWork,
        clock: const SystemAppClock(),
        uniqueNameFor: (row) => CanonicalReminderWorkSpec.uniqueName(
          platformNotificationId: row.platformNotificationId!,
          scheduledUtcMs: row.scheduledForUtc!.millisecondsSinceEpoch,
          sourceRevision: row.sourceRevision!,
        ),
        enqueueWorker: (row) async {
          final spec = CanonicalReminderWorkSpec(
            stableKey: row.stableKey,
            scheduledUtcMs: row.scheduledForUtc!.millisecondsSinceEpoch,
            sourceRevision: row.sourceRevision!,
          );
          await backgroundWork.enqueueUnique(
            spec.toWorkSpec(
              platformNotificationId: row.platformNotificationId!,
              nowUtc: const SystemAppClock().nowUtc(),
              // KEEP: repair must never replace a job that is already queued or
              // running, or a delivery could be duplicated and a retry budget
              // silently reset.
              existingPolicy: BackgroundExistingWorkPolicy.keep,
            ),
          );
        },
      );
    });

/// Privacy-safe typed background-operational snapshot (contract sections 38/39).
final backgroundDiagnosticsProvider = Provider<BackgroundDiagnostics>((ref) {
  final foundation = ref.read(notificationPlatformFoundationProvider);
  return BackgroundDiagnostics(
    repository: ref.read(notificationFoundationRepositoryProvider),
    gateway: ref.read(notificationGatewayProvider),
    backgroundWork: ref.read(backgroundWorkGatewayProvider),
    clock: const SystemAppClock(),
    notificationsAdapterInstalled: foundation.notificationsAvailable,
    backgroundAdapterInstalled: foundation.backgroundWorkAvailable,
    reservedPlatformId:
        DriftNotificationFoundationRepository.reservedPlatformNotificationId,
  );
});

/// The profile a foreground recovery pass may operate on.
///
/// Resolution order is the runtime override FIRST (headless), then an ACTUAL
/// `StartupReady` profile.  No `StartupReady` is ever fabricated and no profile
/// is ever created for a recovery pass (contract sections 26/35).
String? resolveReminderRecoveryProfileId(Ref ref) {
  final runtime = ref.read(reminderRuntimeProfileIdProvider);
  if (runtime != null) return runtime;
  final startup = ref.read(startupControllerProvider);
  return startup is StartupReady ? startup.profile.id : null;
}

final class NotificationPlatformFoundation {
  const NotificationPlatformFoundation({
    required this.notificationsAvailable,
    required this.backgroundWorkAvailable,
  });

  final bool notificationsAvailable;
  final bool backgroundWorkAvailable;
}

final notificationPlatformFoundationProvider =
    Provider<NotificationPlatformFoundation>((ref) {
      return const NotificationPlatformFoundation(
        notificationsAvailable: false,
        backgroundWorkAvailable: false,
      );
    });

final class NotificationSettingsState {
  const NotificationSettingsState({
    required this.loading,
    required this.preferences,
    required this.permission,
    required this.permissionRequested,
    required this.pendingWorkCount,
    this.message,
  });

  const NotificationSettingsState.loading()
    : loading = true,
      preferences = const NotificationPreferences.defaults(),
      permission = OperatingSystemPermissionState.unavailable,
      permissionRequested = false,
      pendingWorkCount = 0,
      message = null;

  final bool loading;
  final NotificationPreferences preferences;
  final OperatingSystemPermissionState permission;
  final bool permissionRequested;
  final int pendingWorkCount;
  final String? message;

  NotificationSettingsState copyWith({
    bool? loading,
    NotificationPreferences? preferences,
    OperatingSystemPermissionState? permission,
    bool? permissionRequested,
    int? pendingWorkCount,
    String? message,
    bool clearMessage = false,
  }) => NotificationSettingsState(
    loading: loading ?? this.loading,
    preferences: preferences ?? this.preferences,
    permission: permission ?? this.permission,
    permissionRequested: permissionRequested ?? this.permissionRequested,
    pendingWorkCount: pendingWorkCount ?? this.pendingWorkCount,
    message: clearMessage ? null : message ?? this.message,
  );
}

final notificationSettingsControllerProvider =
    NotifierProvider<NotificationSettingsController, NotificationSettingsState>(
      NotificationSettingsController.new,
    );

final class NotificationSettingsController
    extends Notifier<NotificationSettingsState> {
  NotificationFoundationRepository get _repository =>
      ref.read(notificationFoundationRepositoryProvider);
  PermissionGateway get _permissionGateway =>
      ref.read(permissionGatewayProvider);

  Future<void> _writes = Future<void>.value();
  int _revision = 0;
  int _pendingWrites = 0;
  bool _changingMaster = false;
  Future<void>? _masterOperation;
  bool _enableAfterSettings = false;
  NotificationPreferences _persisted = const NotificationPreferences.defaults();

  String get _profileId {
    final startup = ref.read(startupControllerProvider);
    if (startup is! StartupReady) {
      throw StateError('Notification settings require a ready Local Profile.');
    }
    return startup.profile.id;
  }

  @override
  NotificationSettingsState build() {
    unawaited(Future<void>.microtask(load));
    return const NotificationSettingsState.loading();
  }

  Future<void> load() async {
    if (_changingMaster || _pendingWrites != 0) return;
    final revision = _revision;
    try {
      final results = await Future.wait<Object>(<Future<Object>>[
        _repository.readPreferences(profileId: _profileId),
        _permissionGateway.status(OptionalPermission.notifications),
        ref
            .read(privacyRepositoryProvider)
            .readPermissionAudit(OptionalPermission.notifications),
        _repository.countPendingWork(profileId: _profileId),
      ]);
      if (!ref.mounted ||
          revision != _revision ||
          _changingMaster ||
          _pendingWrites != 0) {
        return;
      }
      _persisted = results[0] as NotificationPreferences;
      state = NotificationSettingsState(
        loading: false,
        preferences: results[0] as NotificationPreferences,
        permission: results[1] as OperatingSystemPermissionState,
        permissionRequested: (results[2] as PermissionAudit).requestedByApp,
        pendingWorkCount: results[3] as int,
      );
      if (_enableAfterSettings) {
        _enableAfterSettings = false;
        if (state.permission == OperatingSystemPermissionState.granted) {
          await setSystemNotificationsEnabled(true);
        }
      }
    } on Object {
      state = state.copyWith(
        loading: false,
        message: 'Notification settings could not be opened.',
      );
    }
  }

  Future<void> requestPermission({bool refreshReminders = true}) async {
    // OWNER REVIEW #4 race guard.  The OS dialog can suspend and resume the
    // app, so a permission answer can arrive after this controller was
    // invalidated, re-loaded, or had a newer master operation started.  `load()`
    // already refuses to publish a stale result; the request path is given the
    // same protection so a late answer can never overwrite newer truth.
    final revision = _revision;
    try {
      final privacy = ref.read(privacyRepositoryProvider);
      await privacy.recordPermissionRequested(OptionalPermission.notifications);
      final result = await _permissionGateway.request(
        OptionalPermission.notifications,
      );
      if (result == OperatingSystemPermissionState.granted) {
        await privacy.recordPermissionGranted(OptionalPermission.notifications);
      }
      if (!ref.mounted || revision != _revision) return;
      state = state.copyWith(
        permission: result,
        permissionRequested: true,
        clearMessage: true,
      );
      ref.invalidate(permissionSummariesProvider);
      if (result == OperatingSystemPermissionState.granted) {
        // First-ever setup only: a profile that has never had notification
        // preferences written receives the owner-approved defaults here, which
        // is the moment the app first knows Android will actually deliver.
        await _seedFirstRunDefaultsIfEligible();
      }
      if (refreshReminders) unawaited(_refreshReminders());
    } on Object {
      if (!ref.mounted) return;
      state = state.copyWith(
        message: 'Android notification permission could not be requested.',
      );
    }
  }

  /// Seeds the owner-approved new-user defaults exactly once per profile.
  ///
  /// Deliberately non-fatal: the user's action was to enable notifications, and
  /// a seeding failure must not be reported as if enabling failed. The next
  /// explicit enable retries, because the sentinel is still absent.
  Future<void> _seedFirstRunDefaultsIfEligible() async {
    try {
      final seeded = await ref
          .read(notificationFirstRunSetupProvider)
          .seedIfNeverConfigured(profileId: _profileId);
      if (!seeded) return;
      _persisted = await ref
          .read(notificationFoundationRepositoryProvider)
          .readPreferences(profileId: _profileId);
      if (!ref.mounted) return;
      state = state.copyWith(preferences: _persisted);
    } on Object {
      // Seeding is opportunistic; the explicit enable below still applies.
    }
  }

  Future<void> setSystemNotificationsEnabled(bool enabled) {
    final running = _masterOperation;
    if (running != null) {
      return running.then((_) => setSystemNotificationsEnabled(enabled));
    }
    final operation = _setSystemNotificationsEnabled(enabled);
    _masterOperation = operation;
    return operation.whenComplete(() => _masterOperation = null);
  }

  Future<void> _setSystemNotificationsEnabled(bool enabled) async {
    _changingMaster = true;
    _revision++;
    final release = ref.read(reconcileRemindersProvider).hold();
    try {
      if (!enabled) {
        _enableAfterSettings = false;
        await savePreferences(
          state.preferences.copyWith(systemNotificationsEnabled: false),
        );
        return;
      }
      // Read Android truth without running either reminder horizon first.
      final permission = await _permissionGateway.status(
        OptionalPermission.notifications,
      );
      state = state.copyWith(permission: permission, clearMessage: true);
      if (permission != OperatingSystemPermissionState.granted) {
        if (permission == OperatingSystemPermissionState.permanentlyDenied ||
            permission == OperatingSystemPermissionState.restricted) {
          await savePreferences(
            state.preferences.copyWith(systemNotificationsEnabled: false),
          );
          _enableAfterSettings = true;
          await openSystemSettings();
          return;
        }
        await requestPermission(refreshReminders: false);
      }
      // OWNER REVIEW #4: the first-run defaults are seeded on the GRANT itself
      // (`requestPermission`), which is the one moment the app learns Android
      // will actually deliver. Doing it here as well would seed on every master
      // toggle for a profile that merely happens to be already granted, which is
      // not "first-ever setup" and would fight the user's own master write.
      await savePreferences(
        state.preferences.copyWith(
          systemNotificationsEnabled:
              state.permission == OperatingSystemPermissionState.granted,
        ),
      );
      if (state.permission ==
              OperatingSystemPermissionState.permanentlyDenied ||
          state.permission == OperatingSystemPermissionState.restricted) {
        _enableAfterSettings = true;
        await openSystemSettings();
      }
    } on Object {
      state = state.copyWith(
        message: 'System notifications could not be changed.',
      );
    } finally {
      _changingMaster = false;
      release();
    }
  }

  Future<void> openSystemSettings() async {
    await _permissionGateway.openSystemSettings();
  }

  Future<void> savePreferences(NotificationPreferences preferences) {
    final revision = ++_revision;
    final profileId = _profileId;
    final repository = _repository;
    final gateway = ref.read(notificationGatewayProvider);
    _pendingWrites++;
    // Reflect the user's choice in this frame; persist writes in tap order.
    state = state.copyWith(preferences: preferences, clearMessage: true);
    final write = _writes.then((_) async {
      try {
        final saved = await repository.savePreferences(
          profileId: profileId,
          preferences: preferences,
        );
        _persisted = saved;
        if (!ref.mounted) return;
        if (revision == _revision) {
          state = state.copyWith(preferences: saved, clearMessage: true);
        }
        if (!saved.systemNotificationsEnabled) {
          // Cancel native alarms directly, before any 42-day source scan.
          // Durable recovery follows asynchronously and retries on failure.
          try {
            final pending = await gateway.pending();
            await Future.wait(
              pending.map((item) => gateway.cancel(item.platformId)),
            );
          } finally {
            unawaited(_refreshReminders());
          }
        } else {
          unawaited(_refreshReminders());
        }
      } on Object {
        if (ref.mounted && revision == _revision) {
          state = state.copyWith(
            preferences: _persisted,
            message: 'Notification preferences could not be fully applied.',
          );
        }
      } finally {
        _pendingWrites--;
      }
    });
    _writes = write;
    return write;
  }

  Future<void> _refreshReminders() async {
    try {
      await ref.read(reconcileRemindersProvider)();
    } on Object {
      // Preferences are durable; startup/resume/background recovery retries.
    }
  }

  Future<void> setEventRemindersEnabled(bool enabled) async {
    await savePreferences(
      state.preferences.copyWith(eventRemindersEnabled: enabled),
    );
  }

  Future<void> setTaskRemindersEnabled(bool enabled) async {
    await savePreferences(
      state.preferences.copyWith(taskRemindersEnabled: enabled),
    );
  }

  Future<void> setWeeklyReviewRemindersEnabled(bool enabled) async {
    await savePreferences(
      state.preferences.copyWith(weeklyReviewRemindersEnabled: enabled),
    );
  }

  Future<void> setAwaitingReportRemindersEnabled(bool enabled) async {
    await savePreferences(
      state.preferences.copyWith(awaitingReportRemindersEnabled: enabled),
    );
  }

  // M6 forward-rollback (Phase A): Goal completion notification and in-app
  // celebration preference setters were removed with the M6 Achievements UI;
  // the underlying v46 preference columns remain dormant in storage.
}
