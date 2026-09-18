import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:rmplanner/app/theme/internal_screen.dart';
import 'package:rmplanner/features/backup/application/backup_providers.dart';
import 'package:rmplanner/features/backup/domain/backup_flow_notice.dart';

/// Backup & Restore (VS-18).
///
/// Two actions, in plain language: back up everything, or put everything back.
/// The user is never asked to choose packages, pick between merge and replace,
/// name a file, or understand a container format.
///
/// The screen is an operation surface, not a history feed. Exactly one
/// operation runs at a time, it says what it is doing while it runs, it reports
/// the outcome once as a transient message, and then it returns to its two
/// actions. Nothing accumulates, so a failure can never appear underneath an
/// older success.
///
/// Everything shown is truthful: a success message only appears after a file
/// really exists at the reported destination, and dates and counts come from
/// the file that was actually read. The engine underneath stays strict — full
/// classification coverage, dependency-safe restore, an atomic write, a
/// verified pre-restore checkpoint and a fail-closed parser all still apply,
/// invisibly.
final class BackupRecoveryScreen extends ConsumerWidget {
  const BackupRecoveryScreen({super.key});

  /// The title the restore flow publishes on a committed restore.
  static const String dataRestoredTitle = 'Data restored';

  /// OWNER REVIEW #4 (owner ruling, 2026-09-18) — a successful restore is
  /// acknowledged, never merely announced.
  ///
  /// A committed restore brings its own profile identity and can require a
  /// reopen before the restored data is on screen. That is precisely the state
  /// the owner read as "restore did nothing": the only instruction lived in a
  /// snackbar that expired while the app still looked empty. The acknowledgement
  /// therefore stays up until the user dismisses it, and it says what is true:
  /// the restore succeeded and the reopen is a display refresh, not a retry.
  ///
  /// It is deliberately NOT a forced close and NOT a programmatic restart.
  Future<void> acknowledgeRestore(
    BuildContext context,
    BackupFlowNotice notice,
  ) async {
    await showDialog<void>(
      context: context,
      // Persistent until acknowledged: dismissal must be a deliberate act.
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        key: const Key('backup-restore-acknowledged'),
        title: Text(
          notice.title,
          key: const Key('backup-notice-title'),
        ),
        content: notice.body == null
            ? null
            : Text(notice.body!, key: const Key('backup-notice-body')),
        actions: <Widget>[
          FilledButton(
            key: const Key('backup-restore-acknowledge'),
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(backupFlowControllerProvider);
    final controller = ref.read(backupFlowControllerProvider.notifier);

    // One transient acknowledgement per completed operation. It replaces any
    // older acknowledgement rather than stacking on top of one, and it is
    // consumed immediately so a later rebuild cannot replay it.
    ref.listen<BackupFlowState>(backupFlowControllerProvider, (previous, next) {
      final notice = next.notice;
      if (notice != null && notice != previous?.notice) {
        // A committed restore gets the persistent acknowledgement above; every
        // other outcome keeps the transient snackbar it already had.
        if (notice.title == dataRestoredTitle) {
          unawaited(acknowledgeRestore(context, notice));
          controller.consumeNotice();
          return;
        }
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              key: const Key('backup-notice'),
              content: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    notice.title,
                    key: const Key('backup-notice-title'),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  if (notice.body != null) ...<Widget>[
                    const SizedBox(height: 4),
                    Text(
                      notice.body!,
                      key: const Key('backup-notice-body'),
                    ),
                  ],
                ],
              ),
            ),
          );
        controller.consumeNotice();
        return;
      }
      // A snack bar lingers for seconds after the operation that produced it,
      // so a new operation — or a failure — must take it down. Otherwise the
      // screen would say an operation succeeded while it is failing.
      final startedOperation = next.running != null && previous?.running == null;
      final newFailure = next.message != null && next.message != previous?.message;
      if (startedOperation || newFailure) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
      }
    });

    final backingUp = state.running == BackupOperation.backup;
    final restoring = state.running == BackupOperation.restore;

    return Scaffold(
      appBar: InternalAppBar(title: const Text('Backup & Restore')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: <Widget>[
            const Text(
              'Keep your Next Transfer data safe when moving to another '
              'install or device.',
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              key: const Key('backup-create-button'),
              onPressed: state.busy ? null : controller.createBackup,
              icon: backingUp
                  ? const _ButtonSpinner()
                  : const Icon(Icons.file_download_outlined),
              label: Text(
                backingUp ? BackupOperation.backup.label : 'Back up your data',
              ),
            ),
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text('Create a backup of your Next Transfer data.'),
            ),
            const SizedBox(height: 20),
            OutlinedButton.icon(
              key: const Key('backup-restore-button'),
              onPressed: state.busy ? null : controller.chooseBackupToRestore,
              icon: restoring
                  ? const _ButtonSpinner()
                  : const Icon(Icons.file_upload_outlined),
              label: Text(
                restoring
                    ? BackupOperation.restore.label
                    : 'Restore your backup',
              ),
            ),
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text('Restore your Next Transfer data from a backup file.'),
            ),
            if (state.message != null) ...<Widget>[
              const SizedBox(height: 16),
              Semantics(
                liveRegion: true,
                child: Text(
                  state.message!,
                  key: const Key('backup-message'),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ],
            if (state.preview != null) _confirmRow(context, ref, state),
          ],
        ),
      ),
    );
  }

  /// One understandable confirmation. Nothing technical, nothing destructive
  /// without the user having said yes to it.
  Widget _confirmRow(
    BuildContext context,
    WidgetRef ref,
    BackupFlowState state,
  ) {
    final preview = state.preview!;
    final created = DateFormat.yMMMMd(
      Localizations.localeOf(context).toLanguageTag(),
    ).format(preview.createdAtUtc.toLocal());
    return Card(
      key: const Key('backup-restore-confirm-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Restore this backup?',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text('Backup from: $created', key: const Key('backup-restore-date')),
            const SizedBox(height: 8),
            Text(
              'Restoring will replace the Next Transfer data currently on this '
              'device.',
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            // An OverflowBar rather than a Row: the confirmation's own busy
            // label is long, and at a larger text scale a fixed row would push
            // the action off the edge of the card.
            OverflowBar(
              alignment: MainAxisAlignment.start,
              spacing: 12,
              overflowAlignment: OverflowBarAlignment.start,
              children: <Widget>[
                TextButton(
                  key: const Key('backup-restore-cancel'),
                  onPressed: state.busy
                      ? null
                      : () => ref
                          .read(backupFlowControllerProvider.notifier)
                          .cancelRestore(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  key: const Key('backup-restore-confirm'),
                  onPressed: state.busy
                      ? null
                      : () => ref
                          .read(backupFlowControllerProvider.notifier)
                          .applyRestore(),
                  child: Text(
                    state.running == BackupOperation.restore
                        ? BackupOperation.restore.label
                        : 'Restore',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

final class _ButtonSpinner extends StatelessWidget {
  const _ButtonSpinner();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      width: 18,
      height: 18,
      child: CircularProgressIndicator(strokeWidth: 2),
    );
  }
}
