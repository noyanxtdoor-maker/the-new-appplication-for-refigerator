/// Android notification-shade feedback for a running backup or restore.
///
/// This is deliberately NOT the reminder transport. It posts one short-lived
/// card, permission-gated and best-effort, and it is never canonical data: the
/// card is not a row, not a reminder policy and not a background work request,
/// and nothing here is restorable or backed up.
library;

import 'package:rmplanner/core/notifications/transient_notification_gateway.dart';
import 'package:rmplanner/features/backup/domain/backup_flow_notice.dart';
import 'package:rmplanner/features/backup/domain/backup_operation_notice.dart';

/// Every word the shade shows for an operation, in one place, so the card can
/// never claim more than the app itself says.
///
/// A card is published only at the transition it describes: the success card
/// goes out after the written file has been verified on disk, and the restore
/// success card goes out after the canonical transaction, its integrity checks
/// and the app-state refresh have all completed.
abstract final class BackupOperationNotices {
  /// Negative ids, so they can never collide with a reminder platform id
  /// (allocated inside `[1, 0x7fffffff]`) or with the launcher badge id.
  /// `0x4e54` is 'NT'.
  static const int backupPlatformId = -0x4e540001;
  static const int restorePlatformId = -0x4e540002;

  static BackupOperationNotice backingUp() => const BackupOperationNotice(
        platformId: backupPlatformId,
        title: 'Backing up your data…',
      );

  /// Published only once the saved file has been verified to exist with the
  /// bytes that were written.
  static BackupOperationNotice backupCreated({required bool savedToDownloads}) =>
      BackupOperationNotice(
        platformId: backupPlatformId,
        title: 'Backup created',
        body: savedToDownloads
            ? 'Your Next Transfer backup was saved to Downloads.'
            : 'Your Next Transfer backup was saved to the location you chose.',
      );

  static BackupOperationNotice backupFailed() => const BackupOperationNotice(
        platformId: backupPlatformId,
        title: "Backup didn't complete",
        body: 'Your data was not backed up.',
      );

  /// The user left the destination picker without saving, so nothing happened
  /// and the progress card must not be left behind claiming otherwise.
  static BackupOperationNotice backupCancelled() =>
      const BackupOperationNotice(platformId: backupPlatformId);

  static BackupOperationNotice restoring() => const BackupOperationNotice(
        platformId: restorePlatformId,
        title: 'Restoring your backup…',
      );

  /// The body is the same [restoreRefreshGuidance] the app shows in place: a
  /// restore only becomes visible once the app has re-read its restored state,
  /// so the shade must not promise something the app does not ask for.
  static BackupOperationNotice restored() => const BackupOperationNotice(
        platformId: restorePlatformId,
        title: 'Backup restored',
        body: restoreRefreshGuidance,
      );

  /// The canonical restore committed, but an auxiliary post-restore step did
  /// not. [detail] is the same truthful sentence the app shows in place, so the
  /// shade cannot promise a cleaner outcome than the app reports.
  static BackupOperationNotice restoredInPart({required String detail}) =>
      BackupOperationNotice(
        platformId: restorePlatformId,
        title: 'Backup restored',
        body: detail,
      );

  /// Anything that failed before the canonical write committed. The local data
  /// is genuinely untouched, which is what this says.
  static BackupOperationNotice restoreIncomplete() =>
      const BackupOperationNotice(
        platformId: restorePlatformId,
        title: "Restore didn't complete",
        body: 'Your current data was left unchanged.',
      );

  /// The user closed the file picker without choosing anything.
  static BackupOperationNotice restoreCancelled() =>
      const BackupOperationNotice(platformId: restorePlatformId);
}

/// Publishes operation feedback to the Android notification shade.
abstract interface class BackupOperationNotifier {
  /// Best-effort. Implementations may fail freely: the caller treats a
  /// notification that could not be posted as a missing nicety, never as a
  /// failed backup or restore.
  Future<void> publish(BackupOperationNotice notice);
}

/// The real notifier: one transient card per operation, on the app's existing
/// notification transport.
final class SystemBackupOperationNotifier implements BackupOperationNotifier {
  const SystemBackupOperationNotifier({
    required this.gateway,
    required this.canNotify,
  });

  final TransientNotificationGateway gateway;

  /// Re-read on every publish, because Android lets the user grant or revoke
  /// the notification permission while the app is open. A denied permission
  /// means no card — never a failed operation and never a fake prompt.
  final Future<bool> Function() canNotify;

  @override
  Future<void> publish(BackupOperationNotice notice) async {
    if (!await canNotify()) {
      return;
    }
    final title = notice.title;
    if (title == null) {
      await gateway.dismissTransient(notice.platformId);
      return;
    }
    await gateway.showTransient(
      platformId: notice.platformId,
      title: title,
      body: notice.body,
    );
  }
}
