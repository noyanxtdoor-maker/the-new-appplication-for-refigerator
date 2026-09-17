/// Rolling, device-bound pre-restore recovery checkpoint (FR-S-011 / AG-5).
///
/// This is deliberately **not** a portable backup: OPD-4-014 permits
/// device-bound protection for temporary local recovery checkpoints, and this
/// key never leaves the device, is never exported and is never written to a
/// user document.
///
/// Contract: a checkpoint is created and **verified** before any destructive
/// write. Creation or verification failure aborts the restore. The previous
/// valid checkpoint is only pruned after the new one is verified, so a failed
/// restore never destroys the last good recovery point.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:rmplanner/features/backup/application/backup_container_codec.dart';
import 'package:rmplanner/features/backup/domain/backup_errors.dart';

/// Supplies the device-bound checkpoint key. Implemented over secure device
/// storage in production and in memory in tests.
abstract interface class CheckpointKeyStore {
  Future<Uint8List> readOrCreateKey();
}

final class BackupRecoveryCheckpointInfo {
  const BackupRecoveryCheckpointInfo({
    required this.fileName,
    required this.byteLength,
    required this.createdAtUtc,
  });

  final String fileName;
  final int byteLength;
  final DateTime createdAtUtc;
}

final class BackupRecoveryCheckpointStore {
  BackupRecoveryCheckpointStore({
    required this.directoryProvider,
    required this.keyStore,
    required this.codec,
    required this.clock,
  });

  final Future<Directory> Function() directoryProvider;
  final CheckpointKeyStore keyStore;
  final BackupContainerCodec codec;
  final DateTime Function() clock;

  static const String currentFileName = 'current.ntcp';
  static const String previousFileName = 'previous.ntcp';
  static const String temporaryFileName = 'current.ntcp.tmp';

  Directory? _cachedDirectory;

  Future<Directory> _directory() async {
    final cached = _cachedDirectory;
    if (cached != null) {
      return cached;
    }
    final base = await directoryProvider();
    final directory = Directory(
      '${base.path}${Platform.pathSeparator}backup_recovery',
    );
    if (!directory.existsSync()) {
      directory.createSync(recursive: true);
    }
    _cachedDirectory = directory;
    return directory;
  }

  Future<File> _file(String name) async =>
      File('${(await _directory()).path}${Platform.pathSeparator}$name');

  /// Writes and verifies a checkpoint of the current local state.
  ///
  /// Throws [BackupFailureKind.checkpointFailed] when the checkpoint cannot be
  /// created or cannot be read back, which must abort the restore.
  Future<BackupRecoveryCheckpointInfo> create({
    required Uint8List plainText,
  }) async {
    final temporary = await _file(temporaryFileName);
    try {
      final key = await keyStore.readOrCreateKey();
      final container = codec.sealWithDeviceKey(
        key: key,
        plainText: plainText,
      );
      await temporary.writeAsBytes(container.toBytes(), flush: true);

      // Verification: the checkpoint is only accepted if it opens back to
      // exactly the bytes that were captured.
      final written = await temporary.readAsBytes();
      final header = BackupContainer.parseHeader(written);
      final verified = codec.open(header: header, deviceKey: key);
      if (!_bytesEqual(verified, plainText)) {
        throw const BackupFailure(BackupFailureKind.checkpointFailed);
      }

      final current = await _file(currentFileName);
      final previous = await _file(previousFileName);
      if (current.existsSync()) {
        if (previous.existsSync()) {
          await previous.delete();
        }
        await current.rename(previous.path);
      }
      await temporary.rename(current.path);

      return BackupRecoveryCheckpointInfo(
        fileName: currentFileName,
        byteLength: plainText.length,
        createdAtUtc: clock().toUtc(),
      );
    } on BackupFailure {
      await _deleteQuietly(temporary);
      throw const BackupFailure(BackupFailureKind.checkpointFailed);
    } on Object {
      await _deleteQuietly(temporary);
      throw const BackupFailure(BackupFailureKind.checkpointFailed);
    }
  }

  /// The most recent verified checkpoint, if one exists.
  Future<BackupRecoveryCheckpointInfo?> describeCurrent() async {
    final current = await _file(currentFileName);
    if (!current.existsSync()) {
      return null;
    }
    final length = await current.length();
    return BackupRecoveryCheckpointInfo(
      fileName: currentFileName,
      byteLength: length,
      createdAtUtc: current.lastModifiedSync().toUtc(),
    );
  }

  /// Deletes every checkpoint. Used by the owner-facing "remove recovery data"
  /// action; never called automatically by a restore.
  Future<void> clear() async {
    await _deleteQuietly(await _file(currentFileName));
    await _deleteQuietly(await _file(previousFileName));
    await _deleteQuietly(await _file(temporaryFileName));
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      if (file.existsSync()) {
        await file.delete();
      }
    } on Object {
      // A missing or locked checkpoint file is not actionable here.
    }
  }

  static bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) {
      return false;
    }
    for (var index = 0; index < a.length; index++) {
      if (a[index] != b[index]) {
        return false;
      }
    }
    return true;
  }
}
