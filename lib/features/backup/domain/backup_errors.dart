/// Typed backup/restore failures.
///
/// Users never see a raw SQL or crypto stack trace: every failure carries a
/// [BackupFailureKind] and a truthful, non-technical message, while technical
/// detail is written through the existing sanitized diagnostics channel.
library;

enum BackupFailureKind {
  cancelled,
  noLocalProfile,
  notABackupFile,
  unsupportedContainerVersion,
  unsupportedBackupVersion,
  unsupportedDomainVersion,
  unknownDomain,
  corruptedPayload,
  validationFailed,
  dependencyViolation,
  missingDomain,
  differentProfile,

  /// The app could not read the file the user chose. Distinct from
  /// [storageError] (a write failed) and from [notABackupFile] / [
  /// corruptedPayload] (the file was read fine and is not usable): a user
  /// whose file was simply not readable must not be told their backup is
  /// damaged, and must not be told their data changed.
  fileAccessFailed,
  storageError,
  checkpointFailed,
  restoreFailed,
  postRestoreFailed,
}

final class BackupFailure implements Exception {
  const BackupFailure(this.kind, {this.detail});

  final BackupFailureKind kind;
  final String? detail;

  /// Truthful, user-facing message. No stack traces, no secrets.
  String get userMessage => switch (kind) {
        BackupFailureKind.cancelled => 'No backup was created.',
        BackupFailureKind.noLocalProfile =>
          'Finish setting up Next Transfer on this device first.',
        BackupFailureKind.notABackupFile =>
          'That file is not a Next Transfer backup.',
        BackupFailureKind.unsupportedContainerVersion =>
          'This backup was created by a newer version of Next Transfer '
              'than this one. Update Next Transfer and try again.',
        BackupFailureKind.unsupportedBackupVersion =>
          'This backup is older than the versions this app can restore.',
        BackupFailureKind.unsupportedDomainVersion =>
          'This backup contains data from a newer version of Next Transfer. '
              'Update Next Transfer and try again.',
        BackupFailureKind.unknownDomain =>
          'This backup contains a kind of data this version of Next Transfer '
              'does not understand. Update Next Transfer and try again.',
        BackupFailureKind.corruptedPayload =>
          'This backup file is damaged and could not be read. Nothing on this '
              'device was changed.',
        BackupFailureKind.validationFailed =>
          'This backup did not pass validation. Nothing on this device was '
              'changed.',
        BackupFailureKind.dependencyViolation =>
          'Those packages cannot be restored on their own because other data '
              'they rely on was not selected.',
        BackupFailureKind.missingDomain =>
          'This backup does not contain that data.',
        BackupFailureKind.differentProfile =>
          'This backup belongs to a different Next Transfer profile. Use '
              'Replace to restore it.',
        BackupFailureKind.fileAccessFailed =>
          "Next Transfer couldn't open that backup file. Please choose it again.",
        BackupFailureKind.storageError =>
          "Next Transfer couldn't save the backup file.",
        BackupFailureKind.checkpointFailed =>
          'A recovery checkpoint of your current data could not be created, '
              'so nothing was replaced.',
        BackupFailureKind.restoreFailed =>
          'The restore did not complete. Your data was left unchanged.',
        BackupFailureKind.postRestoreFailed =>
          'Your data was restored, but some background schedules could not be '
              'rebuilt. Nothing was lost.',
      };

  @override
  String toString() => 'BackupFailure(${kind.name}'
      '${detail == null ? '' : ': $detail'})';
}
