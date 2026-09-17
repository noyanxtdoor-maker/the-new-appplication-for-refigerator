/// Document access for backup and restore.
///
/// Backups must survive app uninstall/reinstall, so they are written to a
/// user-chosen document destination (Storage Access Framework) rather than to
/// private app storage. No runtime storage permission is requested.
library;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:rmplanner/features/backup/domain/backup_errors.dart';
import 'package:rmplanner/features/backup/domain/backup_manifest.dart';

final class SavedBackupDocument {
  const SavedBackupDocument({
    required this.location,
    required this.byteLength,
  });

  final String location;
  final int byteLength;
}

final class PickedBackupDocument {
  const PickedBackupDocument({
    required this.fileName,
    required this.bytes,
  });

  final String fileName;

  /// The complete file, already read.
  ///
  /// There is deliberately no path, URI or handle here. The chosen document is
  /// read through the platform's content stream at selection time and the
  /// bytes are all that survives it, so a confirmation step that takes as long
  /// as the user needs can never depend on a still-valid provider grant, an
  /// open file descriptor or a path that was never a real path.
  final Uint8List bytes;
}

/// Opens the platform's document picker. Injected so the file-access contract
/// can be tested without a live picker.
typedef BackupDocumentOpener = Future<XFile?> Function({
  List<XTypeGroup> acceptedTypeGroups,
});

abstract interface class BackupDocumentGateway {
  /// Writes [bytes] to a user-chosen destination. Returns `null` when the user
  /// cancels the destination picker.
  Future<SavedBackupDocument?> saveDocument({
    required String suggestedFileName,
    required Uint8List bytes,
  });

  /// Reads a user-selected document read-only. Returns `null` when the user
  /// cancels. The selected file is never modified or deleted (FR-S-018).
  Future<PickedBackupDocument?> pickDocument();
}

final class FileSelectorBackupDocumentGateway
    implements BackupDocumentGateway {
  const FileSelectorBackupDocumentGateway({this.open = _openWithFileSelector});

  static Future<XFile?> _openWithFileSelector({
    List<XTypeGroup> acceptedTypeGroups = const <XTypeGroup>[],
  }) => openFile(acceptedTypeGroups: acceptedTypeGroups);

  final BackupDocumentOpener open;

  /// `.ntbackup` is a custom extension, so the picker must not filter on a MIME
  /// type the platform may disagree about. A provider is free to describe the
  /// very file this app just wrote as `application/octet-stream`,
  /// `application/x-ntbackup` or anything else; filtering on one of those can
  /// hide the user's own backup from them. Nothing is trusted from the picker
  /// anyway — the container is validated by content before a restore is
  /// offered, so showing every file is safe and hiding a real backup is not.
  static const XTypeGroup _backupTypeGroup = XTypeGroup(
    label: 'Next Transfer backup',
    extensions: <String>['ntbackup'],
    mimeTypes: <String>['*/*'],
  );

  @override
  Future<SavedBackupDocument?> saveDocument({
    required String suggestedFileName,
    required Uint8List bytes,
  }) async {
    if (bytes.length > BackupFormat.maxFileBytes) {
      throw const BackupFailure(BackupFailureKind.storageError);
    }
    final location = await getSaveLocation(
      suggestedName: suggestedFileName,
      acceptedTypeGroups: const <XTypeGroup>[_backupTypeGroup],
    );
    if (location == null) {
      return null;
    }
    try {
      final file = XFile.fromData(
        bytes,
        name: suggestedFileName,
        mimeType: 'application/octet-stream',
      );
      await file.saveTo(location.path);
    } on Object catch (error) {
      throw BackupFailure(
        BackupFailureKind.storageError,
        detail: error.runtimeType.toString(),
      );
    }
    await _verifyStored(location.path, bytes.length);
    return SavedBackupDocument(
      location: location.path,
      byteLength: bytes.length,
    );
  }

  /// Confirms the chosen destination really holds what was written.
  ///
  /// A provider that reports a different length is a failure: the file would
  /// not restore. A provider this app cannot read back by path is not treated
  /// as a failure — the write itself succeeded — it simply cannot be verified
  /// from here.
  Future<void> _verifyStored(String path, int expectedLength) async {
    try {
      final stored = await XFile(path).length();
      if (stored != expectedLength) {
        throw const BackupFailure(
          BackupFailureKind.storageError,
          detail: 'verification_failed',
        );
      }
    } on BackupFailure {
      rethrow;
    } on Object {
      // Not verifiable through this document provider.
    }
  }

  /// Opens the picker and reads the whole chosen document **now**.
  ///
  /// Every step of reading happens inside this call, while the grant the
  /// picker handed back is at its freshest: nothing about the document is
  /// carried past it except the bytes. A failure to open or to read is
  /// reported as [BackupFailureKind.fileAccessFailed], never as a format
  /// problem and never as a changed-data problem.
  @override
  Future<PickedBackupDocument?> pickDocument() async {
    final XFile? file;
    try {
      file = await open(
        acceptedTypeGroups: const <XTypeGroup>[_backupTypeGroup],
      );    } on Object catch (error) {
      throw BackupFailure(
        BackupFailureKind.fileAccessFailed,
        detail: _accessDetail(error),
      );
    }
    if (file == null) {
      return null;
    }

    final Uint8List bytes;
    try {
      // The plugin's own reported length is deliberately not consulted: a
      // provider that cannot measure the document is not a reason to refuse to
      // read it, and a provider that measures it wrongly must not decide how
      // many bytes are read. The bytes are the truth.
      bytes = await file.readAsBytes();
    } on Object catch (error) {
      throw BackupFailure(
        BackupFailureKind.fileAccessFailed,
        detail: _accessDetail(error),
      );
    }

    if (bytes.isEmpty) {
      // The file was read successfully and is empty: that is a format
      // problem, not an access problem.
      throw const BackupFailure(BackupFailureKind.notABackupFile);
    }
    if (bytes.length > BackupFormat.maxFileBytes) {
      throw const BackupFailure(
        BackupFailureKind.fileAccessFailed,
        detail: 'file_too_large',
      );
    }
    return PickedBackupDocument(fileName: file.name, bytes: bytes);
  }

  /// Exception class (and, for a platform error, its code). Never a message:
  /// provider messages can quote the file name or path.
  static String _accessDetail(Object error) {
    if (error is PlatformException) {
      return 'PlatformException/${error.code}';
    }
    return error.runtimeType.toString();
  }
}
