/// Riverpod wiring for Backup & Restore.
///
/// Mirrors the app's existing pattern: construction lives in the composition
/// root (`main.dart`) and in the shared test harness, so tests never touch a
/// platform plugin.
///
/// The engine behind this is deliberately more sophisticated than the UI: the
/// ordinary user sees two actions, while classification, dependency-safe
/// restore, Merge and atomic rollback all remain implemented and tested.
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/notifications/transient_notification_gateway.dart';
import 'package:rmplanner/core/platform/app_info.dart';
import 'package:rmplanner/core/time/app_clock.dart';
import 'package:rmplanner/features/backup/application/backup_container_codec.dart';
import 'package:rmplanner/features/backup/application/backup_operation_notifier.dart';
import 'package:rmplanner/features/backup/application/backup_service.dart';
import 'package:rmplanner/features/backup/application/restore_service.dart';
import 'package:rmplanner/features/backup/data/backup_document_gateway.dart';
import 'package:rmplanner/features/backup/data/backup_downloads_writer.dart';
import 'package:rmplanner/features/backup/data/backup_recovery_checkpoint_store.dart';
import 'package:rmplanner/features/backup/data/backup_table_codec.dart';
import 'package:rmplanner/features/backup/domain/backup_domain_contract.dart';
import 'package:rmplanner/features/backup/domain/backup_errors.dart';
import 'package:rmplanner/features/backup/domain/backup_flow_notice.dart';
import 'package:rmplanner/features/backup/domain/backup_operation_notice.dart';
import 'package:rmplanner/features/backup/domain/restore_preview.dart';
import 'package:rmplanner/features/contacts/application/contact_providers.dart';
import 'package:rmplanner/features/goals/application/goal_providers.dart';
import 'package:rmplanner/features/maps/application/map_providers.dart';
import 'package:rmplanner/features/maps/application/saved_place_providers.dart';
import 'package:rmplanner/features/notifications/application/detailed_content_providers.dart';
import 'package:rmplanner/features/notifications/application/notification_privacy_refresh_provider.dart';
import 'package:rmplanner/features/planner/application/planner_providers.dart';
import 'package:rmplanner/features/privacy/application/privacy_providers.dart';
import 'package:rmplanner/features/privacy/domain/permission_summary.dart';
import 'package:rmplanner/features/startup/application/startup_providers.dart';
import 'package:rmplanner/features/startup/domain/startup_state.dart';
import 'package:rmplanner/features/weekly_planning/application/weekly_planning_providers.dart';

/// The app database. Overridden by the composition root and the test harness.
final appDatabaseProvider = Provider<AppDatabase>((ref) {
  throw UnimplementedError('appDatabaseProvider must be overridden');
});

/// User-visible document access (Storage Access Framework).
final backupDocumentGatewayProvider = Provider<BackupDocumentGateway>((ref) {
  throw UnimplementedError('backupDocumentGatewayProvider must be overridden');
});

/// Direct-to-Downloads writing. Null means this build cannot do it, and the
/// flow falls back to asking the user where to put the file.
final backupDownloadsWriterProvider = Provider<BackupDownloadsWriter?>(
  (ref) => null,
);

/// Device-bound checkpoint key material.
final checkpointKeyStoreProvider = Provider<CheckpointKeyStore>((ref) {
  throw UnimplementedError('checkpointKeyStoreProvider must be overridden');
});

/// Directory used for the temporary local recovery checkpoint.
final checkpointDirectoryProvider = Provider<Future<Directory> Function()>(
  (ref) {
    throw UnimplementedError(
      'checkpointDirectoryProvider must be overridden',
    );
  },
);

/// Full app version string used in the manifest (`0.1.0+1`).
final backupAppVersionProvider = Provider<String>(
  (ref) => '${AppInfo.version}+${AppInfo.buildNumber}',
);

final backupContainerCodecProvider = Provider<BackupContainerCodec>(
  (ref) => BackupContainerCodec(),
);

final backupRecoveryCheckpointStoreProvider =
    Provider<BackupRecoveryCheckpointStore>((ref) {
  return BackupRecoveryCheckpointStore(
    directoryProvider: ref.watch(checkpointDirectoryProvider),
    keyStore: ref.watch(checkpointKeyStoreProvider),
    codec: ref.watch(backupContainerCodecProvider),
    clock: () => const SystemAppClock().nowUtc(),
  );
});

final backupServiceProvider = Provider<BackupService>((ref) {
  return BackupService(
    database: ref.watch(appDatabaseProvider),
    gateway: ref.watch(backupDocumentGatewayProvider),
    containerCodec: ref.watch(backupContainerCodecProvider),
    downloadsWriter: ref.watch(backupDownloadsWriterProvider),
    clock: () => const SystemAppClock().nowUtc(),
    appVersion: ref.watch(backupAppVersionProvider),
    diagnostics: ref.watch(diagnosticsProvider),
  );
});

/// Immediate (non-scheduled) notification delivery, satisfied at the app root
/// by the same plugin-backed gateway the reminders use. There is no second
/// notification plugin, no second permission and no scheduler.
final transientNotificationGatewayProvider =
    Provider<TransientNotificationGateway>((ref) {
  throw StateError(
    'TransientNotificationGateway must be overridden at the app root',
  );
});

/// Android notification-shade feedback for the operation in flight.
///
/// Tests override this with a recording fake to prove exactly what was
/// published, and when, against the real operation state machine.
final backupOperationNotifierProvider = Provider<BackupOperationNotifier>(
  (ref) {
    final permissions = ref.watch(permissionGatewayProvider);
    return SystemBackupOperationNotifier(
      gateway: ref.watch(transientNotificationGatewayProvider),
      canNotify: () async =>
          await permissions.status(OptionalPermission.notifications) ==
          OperatingSystemPermissionState.granted,
    );
  },
);

/// The existing canonical reminder reconciliation pass, reused exactly once
/// after a successful restore so device-local schedules are rebuilt from the
/// restored canonical policies. Tests override this with a recording fake to
/// prove the pass runs once and that a failing pass never rolls back a restore.
final backupPostRestoreReconcilerProvider =
    Provider<Future<void> Function(String profileId)?>((ref) {
  return (profileId) async {
    await ref.read(reconcileRemindersProvider)();
  };
});

/// Everything the app must re-read once a restore has replaced local state.
///
/// A restore rewrites every row the UI has cached, and a backup carries its own
/// profile identity, so a completed restore leaves the running app holding a
/// profile that no longer exists. Providers that read the profile id with
/// `ref.read` do not rebuild when the startup state changes, so they are
/// invalidated explicitly here rather than left serving stale identity. The
/// re-resolution itself is the app's existing canonical snapshot gate, so the
/// Privacy Lock and every consistency check still apply.
final backupPostRestoreRefreshProvider =
    Provider<Future<void> Function()>((ref) {
  return () async {
    ref
      ..invalidate(activeProfileIdProvider)
      ..invalidate(goalProfileIdProvider)
      ..invalidate(contactProfileIdProvider)
      ..invalidate(mapProfileIdProvider)
      ..invalidate(savedPlaceProfileIdProvider)
      ..invalidate(weeklyPlanningProfileIdProvider)
      ..invalidate(detailedContentProfileIdProvider)
      ..invalidate(plannerDateSourceProvider)
      ..invalidate(goalPlanningProvider)
      ..invalidate(weeklyPlanEstablishedProvider);
    await ref.read(startupControllerProvider.notifier).refreshAfterRestore();

    // A restore replaces the receiving install's rows wholesale, so canonical
    // rows the backup does not carry have to be laid down again by the current
    // app — the registry's REGENERATE law. Built-in Contact groups are
    // identity-derived per profile and their ensure is idempotent and never
    // overwrites an existing row, so it fills gaps without disturbing what the
    // backup restored.
    final startup = ref.read(startupControllerProvider);
    if (startup is StartupReady) {
      try {
        await ref
            .read(contactRepositoryProvider)
            .ensureBuiltInGroups(startup.profile.id);
      } on Object {
        // Canonical repair is opportunistic; it must never turn a completed
        // restore into a reported failure or hide its confirmation.
      }
    }
  };
});

final restoreServiceProvider = Provider<RestoreService>((ref) {
  final service = ref.watch(backupServiceProvider);
  final reconciler = ref.watch(backupPostRestoreReconcilerProvider);
  return RestoreService(
    database: ref.watch(appDatabaseProvider),
    containerCodec: ref.watch(backupContainerCodecProvider),
    checkpointStore: ref.watch(backupRecoveryCheckpointStoreProvider),
    captureCurrentState: (domains) async => service.captureCurrentState(
      profileId: await resolveActiveProfileId(ref),
      domains: domains,
    ),
    clock: () => const SystemAppClock().nowUtc(),
    diagnostics: ref.watch(diagnosticsProvider),
    reconcileAfterRestore:
        reconciler == null ? null : (profileId) => reconciler(profileId),
  );
});

/// The active local profile id. The composition root may override this with the
/// startup-resolved profile; otherwise the single local profile is read from
/// canonical state, which is exactly the profile a backup describes.
final activeProfileIdProvider = Provider<String?>((ref) => null);

Future<String> resolveActiveProfileId(Ref ref) async {
  final overridden = ref.read(activeProfileIdProvider);
  if (overridden != null && overridden.isNotEmpty) {
    return overridden;
  }
  final profileId = await BackupTableCodec(ref.read(appDatabaseProvider))
      .singleProfileId();
  if (profileId == null) {
    throw const BackupFailure(BackupFailureKind.noLocalProfile);
  }
  return profileId;
}

/// Everything the flow needs for the pre-restore recovery checkpoint.
final backupCheckpointCaptureProvider =
    Provider<Future<Uint8List> Function(Set<BackupDomain> domains)>((ref) {
  final service = ref.watch(backupServiceProvider);
  return (domains) async => service.captureCurrentState(
        profileId: await resolveActiveProfileId(ref),
        domains: domains,
      );
});

/// The one operation a user can start. Naming it is what makes the busy state
/// truthful: the screen says what is actually running.
enum BackupOperation {
  backup('Backing up your data…'),
  restore('Restoring your data…');

  const BackupOperation(this.label);

  final String label;
}

/// UI state for the Backup & Restore flow.
///
/// Two actions, one confirmation, and exactly one operation at a time. There is
/// deliberately no history: a finished operation is acknowledged once, as a
/// transient message, and the screen returns to its two actions. Nothing
/// accumulates, so a failure can never sit underneath an older success.
final class BackupFlowState {
  const BackupFlowState({
    this.running,
    this.message,
    this.notice,
    this.preview,
  });

  /// The operation that is running, or null when the screen is idle. Both
  /// actions are disabled while it is set and re-entry is refused, so a double
  /// tap cannot start a second job.
  final BackupOperation? running;

  /// The current failure, in plain language. Cleared the moment a new operation
  /// starts, so it never describes anything but the latest attempt.
  final String? message;

  /// Transient acknowledgement of a finished operation. Shown once.
  final BackupFlowNotice? notice;

  /// Set once a file has been validated, so the screen can ask for one
  /// understandable confirmation before anything is written.
  final RestorePreview? preview;

  bool get busy => running != null;

  BackupFlowState copyWith({
    BackupOperation? running,
    bool clearRunning = false,
    String? message,
    bool clearMessage = false,
    BackupFlowNotice? notice,
    bool clearNotice = false,
    RestorePreview? preview,
    bool clearPreview = false,
  }) {
    return BackupFlowState(
      running: clearRunning ? null : (running ?? this.running),
      message: clearMessage ? null : (message ?? this.message),
      notice: clearNotice ? null : (notice ?? this.notice),
      preview: clearPreview ? null : (preview ?? this.preview),
    );
  }
}

final backupFlowControllerProvider =
    NotifierProvider<BackupFlowController, BackupFlowState>(
  BackupFlowController.new,
);

final class BackupFlowController extends Notifier<BackupFlowState> {
  /// The bytes of the file the user picked, held only between validating it and
  /// confirming the restore so the file never has to be chosen twice. Kept off
  /// [BackupFlowState] so the payload is not exposed to the widget tree.
  Uint8List? _picked;

  /// Posts one state of the operation's single notification card.
  ///
  /// Notification feedback is advisory, so it is best-effort by design: a
  /// revoked permission, an unavailable platform transport or a plugin fault
  /// must never turn a completed backup or restore into a reported failure.
  /// The in-app state remains the source of truth either way.
  Future<void> _publishOperationNotice(BackupOperationNotice notice) async {
    try {
      await ref.read(backupOperationNotifierProvider).publish(notice);
    } on Object {
      // Intentionally swallowed: see above.
    }
  }

  /// Single-flight latch. [BackupFlowState.running] disables the buttons; this
  /// refuses re-entry outright, so a repeated tap, a rebuilt widget or a second
  /// callback cannot start a second job or write a second file.
  bool _inFlight = false;

  @override
  BackupFlowState build() => const BackupFlowState();

  /// Backs up everything the registry classifies as user data. One tap: no
  /// categories to choose and no password to invent.
  Future<bool> createBackup({Set<BackupDomain>? domains}) async {
    if (_inFlight) {
      return false;
    }
    _inFlight = true;
    state = state.copyWith(
      running: BackupOperation.backup,
      clearMessage: true,
      clearNotice: true,
    );
    await _publishOperationNotice(BackupOperationNotices.backingUp());
    try {
      final result = await ref.read(backupServiceProvider).createBackup(
            profileId: await resolveActiveProfileId(ref),
            domains: domains,
          );
      if (result == null) {
        // Nothing was written, so the progress card is taken down rather than
        // replaced with a failure the user did not experience.
        await _publishOperationNotice(
          BackupOperationNotices.backupCancelled(),
        );
        state = state.copyWith(
          clearRunning: true,
          message: 'No backup was created.',
        );
        return false;
      }
      // The service only returns a result once the destination really stored
      // the bytes, so reaching here is what "created" means.
      await _publishOperationNotice(
        BackupOperationNotices.backupCreated(
          savedToDownloads: result.savedToDownloads,
        ),
      );
      state = state.copyWith(
        clearRunning: true,
        clearMessage: true,
        notice: BackupFlowNotice(
          result.savedToDownloads
              ? 'Backup created — saved to Downloads'
              : 'Backup created — saved to the location you chose',
        ),
      );
      return true;
    } on Object catch (error) {
      await _publishOperationNotice(BackupOperationNotices.backupFailed());
      state = state.copyWith(
        clearRunning: true,
        message: _messageFor(error),
      );
      return false;
    } finally {
      _inFlight = false;
    }
  }

  /// Picks a file and validates it. Nothing is written: the screen shows one
  /// plain-language confirmation first.
  Future<bool> chooseBackupToRestore() async {
    if (_inFlight) {
      return false;
    }
    _inFlight = true;
    state = state.copyWith(
      running: BackupOperation.restore,
      clearMessage: true,
      clearNotice: true,
      clearPreview: true,
    );
    try {
      final picked =
          await ref.read(backupDocumentGatewayProvider).pickDocument();
      if (picked == null) {
        // No file was chosen, so there is nothing to report to the shade. The
        // card only ever appears once a restore genuinely begins.
        state = state.copyWith(
          clearRunning: true,
          message: 'No backup was selected.',
        );
        return false;
      }
      _picked = picked.bytes;
      final restore = ref.read(restoreServiceProvider);
      final opened = await restore.open(bytes: picked.bytes);
      // The public restore is a full-profile restore, which is the actual
      // closed-beta → production / reinstall / device-move use case.
      final preview = await restore.preview(
        backup: opened,
        mode: BackupRestoreMode.replace,
      );
      state = state.copyWith(clearRunning: true, preview: preview);
      return true;
    } on Object catch (error) {
      // Nothing was written, so this is exactly the pre-commit outcome: the
      // local data really is unchanged.
      await _publishOperationNotice(
        BackupOperationNotices.restoreIncomplete(),
      );
      state = state.copyWith(
        clearRunning: true,
        message: _messageFor(error),
        clearPreview: true,
      );
      return false;
    } finally {
      _inFlight = false;
    }
  }

  /// Abandons a validated backup without writing anything. Local data is
  /// untouched and the user can pick a different file.
  void cancelRestore() {
    _picked = null;
    state = state.copyWith(clearPreview: true, clearMessage: true);
  }

  /// Applies the validated backup to the file that was already picked.
  ///
  /// The selection is every domain the backup carries, so a restore puts the
  /// whole profile back rather than a fragment of it.
  Future<bool> applyRestore() async {
    if (_inFlight) {
      return false;
    }
    final preview = state.preview;
    final bytes = _picked;
    if (preview == null || bytes == null) {
      state = state.copyWith(
        message: 'Choose a backup first.',
        clearPreview: true,
      );
      return false;
    }
    _inFlight = true;
    state = state.copyWith(
      running: BackupOperation.restore,
      clearMessage: true,
      clearNotice: true,
    );
    // Published here, not when the file picker opened: while the user is still
    // choosing a file (and may choose none) nothing is being restored, and
    // saying otherwise would be untrue.
    await _publishOperationNotice(BackupOperationNotices.restoring());
    try {
      final restore = ref.read(restoreServiceProvider);
      // `chooseBackupToRestore` already validated this exact file, so the same
      // bytes are re-opened rather than the user being asked to pick again.
      final opened = await restore.open(bytes: bytes);
      final result = await restore.apply(
        backup: opened,
        mode: BackupRestoreMode.replace,
        selection: preview.selectedDomains,
      );
      // A restore replaces every row the UI has cached and brings its own
      // profile identity, so the app re-resolves before the outcome is
      // acknowledged. A refresh that fails is reported truthfully instead of
      // being dressed up as a failed restore — the data really is restored.
      //
      // The engine reports post-commit repair it could not finish the same
      // way. Either way the canonical data is restored, so the wording is
      // partial success and never a failure.
      // A restore replaces local data wholesale, so the app cannot show the
      // restored state until it has re-read it: the acknowledgement's body is
      // that instruction, and it is the same sentence the shade shows.
      var complete = result.postRestoreWarnings.isEmpty;
      var body = restoreRefreshGuidance;
      if (!complete) {
        body = result.postRestoreWarnings.first;
      }
      try {
        await ref.read(backupPostRestoreRefreshProvider)();
      } on Object {
        body = 'Your data has been restored. Reopen Next Transfer to see it.';
        complete = false;
      }
      await _publishOperationNotice(
        complete
            ? BackupOperationNotices.restored()
            : BackupOperationNotices.restoredInPart(detail: body),
      );
      state = state.copyWith(
        clearRunning: true,
        clearPreview: true,
        notice: BackupFlowNotice('Data restored', body: body),
      );
      return true;
    } on Object catch (error) {
      await _publishOperationNotice(
        BackupOperationNotices.restoreIncomplete(),
      );
      state = state.copyWith(
        clearRunning: true,
        message: _messageFor(error),
        clearPreview: true,
      );
      return false;
    } finally {
      _picked = null;
      _inFlight = false;
    }
  }

  /// Acknowledges the transient notice so it is shown exactly once.
  void consumeNotice() {
    if (state.notice != null) {
      state = state.copyWith(clearNotice: true);
    }
  }

  /// Truthful, user-facing failure text. No stack traces, no secrets.
  String _messageFor(Object error) {
    if (error is BackupFailure) {
      return error.userMessage;
    }
    // A platform or file error that reached here without being classified is
    // still a file problem far more often than anything else, and saying so is
    // truthful in the cases that matter (unreadable picker result, unwritable
    // destination). It never claims the user's data changed.
    if (error is PlatformException || error is FileSystemException) {
      return const BackupFailure(BackupFailureKind.fileAccessFailed).userMessage;
    }
    return 'The operation could not be completed. Your data was not changed.';
  }
}
