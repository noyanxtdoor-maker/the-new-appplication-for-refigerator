import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/notifications/transient_notification_gateway.dart';
import 'package:rmplanner/features/backup/application/backup_operation_notifier.dart';
import 'package:rmplanner/features/backup/domain/backup_flow_notice.dart';

/// Records every platform call the notifier makes.
final class _RecordingTransientGateway implements TransientNotificationGateway {
  final List<String> calls = <String>[];

  @override
  Future<void> showTransient({
    required int platformId,
    required String title,
    String? body,
  }) async {
    calls.add('show:$platformId:$title|${body ?? ''}');
  }

  @override
  Future<void> dismissTransient(int platformId) async {
    calls.add('dismiss:$platformId');
  }
}

void main() {
  group('operation notice wording', () {
    test('backup start, success and failure say exactly what happened', () {
      expect(BackupOperationNotices.backingUp().title, 'Backing up your data…');

      final toDownloads = BackupOperationNotices.backupCreated(
        savedToDownloads: true,
      );
      expect(toDownloads.title, 'Backup created');
      expect(
        toDownloads.body,
        'Your Next Transfer backup was saved to Downloads.',
      );

      // On older Android the destination is chosen by the user, and the card
      // must not claim a folder the file never reached.
      final toChosen = BackupOperationNotices.backupCreated(
        savedToDownloads: false,
      );
      expect(toChosen.title, 'Backup created');
      expect(
        toChosen.body,
        'Your Next Transfer backup was saved to the location you chose.',
      );

      final failed = BackupOperationNotices.backupFailed();
      expect(failed.title, "Backup didn't complete");
      expect(failed.body, 'Your data was not backed up.');
    });

    test('restore start, success and pre-commit failure are truthful', () {
      expect(BackupOperationNotices.restoring().title, 'Restoring your backup…');

      final restored = BackupOperationNotices.restored();
      expect(restored.title, 'Backup restored');
      // The same sentence the app shows in place: the shade must not tell the
      // user the data is already on screen when the app has to re-read it
      // first.
      expect(restored.body, restoreRefreshGuidance);
      expect(
        restoreRefreshGuidance,
        'Please close and reopen Next Transfer to refresh all restored data.',
      );

      // Everything that fails before the canonical write commits leaves the
      // local data untouched, which is exactly what this says.
      final incomplete = BackupOperationNotices.restoreIncomplete();
      expect(incomplete.title, "Restore didn't complete");
      expect(incomplete.body, 'Your current data was left unchanged.');
    });

    test('a committed restore with unfinished repair is never called failed',
        () {
      const detail =
          'Your data was restored, but reminder schedules could not be '
          'rebuilt. They will be rebuilt the next time Next Transfer starts.';
      final partial = BackupOperationNotices.restoredInPart(detail: detail);

      expect(
        partial.title,
        'Backup restored',
        reason: 'the canonical data really did commit',
      );
      expect(partial.body, detail, reason: 'the card repeats the app exactly');
      expect(partial.title, isNot(BackupOperationNotices.restoreIncomplete().title));
    });

    test('each operation owns exactly one card id, outside reminder ids', () {
      final backupIds = <int?>{
        BackupOperationNotices.backingUp().platformId,
        BackupOperationNotices.backupCreated(savedToDownloads: true).platformId,
        BackupOperationNotices.backupFailed().platformId,
        BackupOperationNotices.backupCancelled().platformId,
      };
      final restoreIds = <int?>{
        BackupOperationNotices.restoring().platformId,
        BackupOperationNotices.restored().platformId,
        BackupOperationNotices.restoreIncomplete().platformId,
        BackupOperationNotices.restoreCancelled().platformId,
      };

      // One operation, one card: every state rewrites the same notification.
      expect(backupIds, <int?>{BackupOperationNotices.backupPlatformId});
      expect(restoreIds, <int?>{BackupOperationNotices.restorePlatformId});
      expect(
        BackupOperationNotices.backupPlatformId,
        isNot(BackupOperationNotices.restorePlatformId),
      );

      // The reminder allocator only ever produces ids in [1, 0x7fffffff]
      // (hash of the stable reminder key, masked, never 0). A negative id can
      // therefore never be mistaken for, or collide with, a reminder.
      expect(BackupOperationNotices.backupPlatformId, isNegative);
      expect(BackupOperationNotices.restorePlatformId, isNegative);
    });

    test('an abandoned operation takes its card down', () {
      final backup = BackupOperationNotices.backupCancelled();
      final restore = BackupOperationNotices.restoreCancelled();

      expect(backup.dismisses, isTrue);
      expect(backup.title, isNull);
      expect(restore.dismisses, isTrue);
      expect(restore.title, isNull);
    });
  });

  group('the system notifier', () {
    test('a denied notification permission posts nothing and never throws',
        () async {
      final gateway = _RecordingTransientGateway();
      final notifier = SystemBackupOperationNotifier(
        gateway: gateway,
        canNotify: () async => false,
      );

      await notifier.publish(BackupOperationNotices.backingUp());
      await notifier.publish(
        BackupOperationNotices.backupCreated(savedToDownloads: true),
      );

      expect(
        gateway.calls,
        isEmpty,
        reason: 'a denied permission means no card, not a fake prompt',
      );
    });

    test('a granted permission shows one card per state', () async {
      final gateway = _RecordingTransientGateway();
      final notifier = SystemBackupOperationNotifier(
        gateway: gateway,
        canNotify: () async => true,
      );

      await notifier.publish(BackupOperationNotices.backingUp());
      await notifier.publish(
        BackupOperationNotices.backupCreated(savedToDownloads: true),
      );

      expect(gateway.calls, <String>[
        'show:${BackupOperationNotices.backupPlatformId}:'
            'Backing up your data…|',
        'show:${BackupOperationNotices.backupPlatformId}:Backup created|'
            'Your Next Transfer backup was saved to Downloads.',
      ]);
    });

    test('an abandoned operation dismisses its card', () async {
      final gateway = _RecordingTransientGateway();
      final notifier = SystemBackupOperationNotifier(
        gateway: gateway,
        canNotify: () async => true,
      );

      await notifier.publish(BackupOperationNotices.restoreCancelled());

      expect(gateway.calls, <String>[
        'dismiss:${BackupOperationNotices.restorePlatformId}',
      ]);
    });

    test('the permission is re-read, so a revocation mid-operation is honoured',
        () async {
      final gateway = _RecordingTransientGateway();
      var granted = true;
      final notifier = SystemBackupOperationNotifier(
        gateway: gateway,
        canNotify: () async => granted,
      );

      await notifier.publish(BackupOperationNotices.restoring());
      granted = false;
      await notifier.publish(BackupOperationNotices.restored());

      expect(
        gateway.calls,
        hasLength(1),
        reason: 'Android can revoke the permission while the app is open',
      );
    });
  });
}
