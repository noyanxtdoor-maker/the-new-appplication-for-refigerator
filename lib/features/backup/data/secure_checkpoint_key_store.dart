/// Device-bound key material for the temporary local recovery checkpoint.
///
/// This key protects only the on-device checkpoint (OPD-4-014 permits
/// device-bound protection for temporary local recovery checkpoints). It is
/// **EXCLUDE**-class state: it is never exported, never written to a user
/// document and never logged, and losing it only means the local checkpoint
/// cannot be read.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:rmplanner/features/backup/data/backup_recovery_checkpoint_store.dart';
import 'package:rmplanner/features/backup/domain/backup_errors.dart';
import 'package:rmplanner/features/backup/domain/backup_manifest.dart';

final class SecureStorageCheckpointKeyStore implements CheckpointKeyStore {
  SecureStorageCheckpointKeyStore({
    FlutterSecureStorage? storage,
    Random? random,
  })  : _storage = storage ?? const FlutterSecureStorage(),
        _random = random ?? Random.secure();

  static const String storageKey = 'nt.backup.checkpoint.key';

  final FlutterSecureStorage _storage;
  final Random _random;

  @override
  Future<Uint8List> readOrCreateKey() async {
    try {
      final existing = await _storage.read(key: storageKey);
      if (existing != null) {
        final decoded = base64Decode(existing);
        if (decoded.length == BackupFormat.derivedKeyLength) {
          return Uint8List.fromList(decoded);
        }
      }
      final created = Uint8List(BackupFormat.derivedKeyLength);
      for (var index = 0; index < created.length; index++) {
        created[index] = _random.nextInt(256);
      }
      await _storage.write(key: storageKey, value: base64Encode(created));
      return created;
    } on Object catch (error) {
      throw BackupFailure(
        BackupFailureKind.checkpointFailed,
        detail: error.runtimeType.toString(),
      );
    }
  }
}
