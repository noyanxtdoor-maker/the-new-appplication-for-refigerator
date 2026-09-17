/// Direct-to-Downloads writing for portable backups.
///
/// Saving a backup is meant to be one tap, so the app writes straight into the
/// user-visible Downloads folder instead of asking the user to choose a
/// destination every time.
///
/// This is deliberately narrow. Android's MediaStore Downloads collection
/// (API 29+) allows exactly this with **no runtime permission and no broad
/// storage access**, so that is the only thing the channel does. On older
/// Android, where the same write would require `WRITE_EXTERNAL_STORAGE`, the
/// channel reports "not supported" and the caller falls back to the existing
/// user-chosen destination picker. This app declares seven permissions and the
/// authority gate verifies that set exactly, so a storage permission is not an
/// available option — and it is not needed.
library;

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:rmplanner/features/backup/data/backup_document_gateway.dart';
import 'package:rmplanner/features/backup/domain/backup_errors.dart';

abstract interface class BackupDownloadsWriter {
  /// Writes [bytes] into the user-visible Downloads folder.
  ///
  /// Returns `null` when this platform or OS version cannot do that without a
  /// storage permission, so the caller can fall back to a destination picker.
  /// Throws [BackupFailure] only when a supported write genuinely failed.
  Future<SavedBackupDocument?> writeToDownloads({
    required String fileName,
    required Uint8List bytes,
  });
}

final class MethodChannelBackupDownloadsWriter implements BackupDownloadsWriter {
  const MethodChannelBackupDownloadsWriter();

  static const MethodChannel channel = MethodChannel(
    'com.nexttransfer.rmplanner/backup_downloads',
  );

  @override
  Future<SavedBackupDocument?> writeToDownloads({
    required String fileName,
    required Uint8List bytes,
  }) async {
    final expectedSha256 = sha256.convert(bytes).toString();
    try {
      final result = await channel.invokeMethod<Map<Object?, Object?>>(
        'writeBackup',
        <String, Object?>{
          'fileName': fileName,
          'bytes': bytes,
          // The platform hashes what it can read back and returns its own
          // digest, so "saved" means the stored bytes are the written bytes.
          'sha256': expectedSha256,
        },
      );
      if (result == null) {
        // Not supported on this OS version: the caller picks a destination.
        return null;
      }
      final location = result['location'];
      final byteLength = result['byteLength'];
      final storedSha256 = result['sha256'];
      if (location is! String || byteLength is! int || storedSha256 is! String) {
        throw const BackupFailure(
          BackupFailureKind.storageError,
          detail: 'unverified_write',
        );
      }
      if (byteLength != bytes.length || storedSha256 != expectedSha256) {
        // A file that does not read back as what was written cannot restore.
        throw const BackupFailure(
          BackupFailureKind.storageError,
          detail: 'verification_failed',
        );
      }
      return SavedBackupDocument(location: location, byteLength: byteLength);
    } on MissingPluginException {
      return null;
    } on PlatformException catch (error) {
      throw BackupFailure(
        BackupFailureKind.storageError,
        detail: error.code,
      );
    }
  }
}
