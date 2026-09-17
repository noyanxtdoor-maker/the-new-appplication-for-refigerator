/// `.ntbackup` container codec (container version 2).
///
/// Cleartext header (little-endian, 21 bytes + optional nonce):
/// ```text
/// magic            8 bytes  "NTBACKUP"
/// containerVersion 1 byte   2
/// protectionId     1 byte   0 = none, 1 = device-bound key
/// cipherId         1 byte   0 = none, 1 = AES-256-GCM
/// reserved         1 byte   0
/// nonceLength      1 byte   0 or 12
/// nonce            n bytes  (12 only for a device-key container)
/// payloadLength    8 bytes uint64 (whole payload; includes the GCM tag when
///                                 the container is authenticated)
/// ```
///
/// Exactly two shapes exist, and the header states which one a file is so a
/// restore never has to guess:
///
/// * **Portable backup** (`protectionId = 0`) — the shape of every user backup.
///   Saving one is a single tap and never asks for a password, so the payload
///   is stored as-is and *is readable by anything that can open the file*. This
///   is not a claim of security: the user is told plainly that the file is not
///   encrypted. Integrity still holds — the manifest's `payloadSha256` covers
///   the payload body, so an altered or truncated file is rejected before any
///   restore parsing.
/// * **Device-bound checkpoint** (`protectionId = 1`) — AES-256-GCM under a
///   32-byte key held in secure device storage. Used only for the temporary
///   local recovery checkpoint, which never leaves app-private storage.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

// `AEADParameters`, `KeyParameter` and `InvalidCipherTextException` are all
// declared in pointycastle's public API library.
import 'package:pointycastle/api.dart';
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/gcm.dart';
import 'package:rmplanner/features/backup/domain/backup_errors.dart';
import 'package:rmplanner/features/backup/domain/backup_manifest.dart';

final class BackupContainer {
  const BackupContainer({
    required this.containerVersion,
    required this.protectionId,
    required this.cipherId,
    required this.nonce,
    required this.body,
  });

  /// A container that carries no encryption. [body] is the plain payload.
  BackupContainer.unprotected({required this.body})
      : containerVersion = BackupFormat.containerVersion,
        protectionId = BackupFormat.noneProtectionId,
        cipherId = BackupFormat.noneCipherId,
        nonce = Uint8List(0);

  final int containerVersion;
  final int protectionId;
  final int cipherId;
  final Uint8List nonce;

  /// The payload. Plain text for an unprotected container, ciphertext (and a
  /// GCM tag) for a device-key container.
  final Uint8List body;

  bool get isProtected => protectionId != BackupFormat.noneProtectionId;

  Uint8List toBytes() {
    final headerLength = 8 + 1 + 1 + 1 + 1 + 1 + nonce.length + 8;
    final header = Uint8List(headerLength);
    final view = ByteData.view(header.buffer);
    var offset = 0;
    header.setRange(offset, offset + 8, ascii.encode(BackupFormat.magic));
    offset += 8;
    header[offset++] = containerVersion;
    header[offset++] = protectionId;
    header[offset++] = cipherId;
    header[offset++] = 0;
    header[offset++] = nonce.length;
    header.setRange(offset, offset + nonce.length, nonce);
    offset += nonce.length;
    view.setUint64(offset, body.length, Endian.little);

    final builder = BytesBuilder(copy: false)
      ..add(header)
      ..add(body);
    return builder.toBytes();
  }

  /// Parses a container header without touching the payload.
  ///
  /// Fails with [BackupFailureKind.notABackupFile] for anything that is not a
  /// Next Transfer container and with
  /// [BackupFailureKind.unsupportedContainerVersion] for a newer container.
  static ParsedContainerHeader parseHeader(Uint8List bytes) {
    if (bytes.length < BackupFormat.minimumHeaderBytes) {
      throw const BackupFailure(BackupFailureKind.notABackupFile);
    }
    final magic = ascii.decode(bytes.sublist(0, 8), allowInvalid: true);
    if (magic != BackupFormat.magic) {
      throw const BackupFailure(BackupFailureKind.notABackupFile);
    }
    final view = ByteData.view(bytes.buffer, bytes.offsetInBytes);
    var offset = 8;
    final containerVersion = bytes[offset++];
    final protectionId = bytes[offset++];
    final cipherId = bytes[offset++];
    offset++; // reserved
    if (containerVersion > BackupFormat.containerVersion) {
      throw const BackupFailure(
        BackupFailureKind.unsupportedContainerVersion,
      );
    }
    if (containerVersion < BackupFormat.minimumReadableContainerVersion) {
      throw const BackupFailure(BackupFailureKind.unsupportedBackupVersion);
    }
    final unprotected = BackupFormat.isUnprotected(protectionId);
    if (!unprotected && protectionId != BackupFormat.deviceKeyProtectionId) {
      throw const BackupFailure(BackupFailureKind.unsupportedBackupVersion);
    }
    // The protection and cipher identifiers must agree. A file may not claim
    // one protection while declaring another cipher.
    final expectedCipher = unprotected
        ? BackupFormat.noneCipherId
        : BackupFormat.cipherId;
    if (cipherId != expectedCipher) {
      throw const BackupFailure(BackupFailureKind.unsupportedBackupVersion);
    }
    final expectedNonceLength =
        unprotected ? 0 : BackupFormat.gcmNonceLength;
    final nonceLength = bytes[offset++];
    if (nonceLength != expectedNonceLength) {
      throw const BackupFailure(BackupFailureKind.notABackupFile);
    }
    final nonce =
        Uint8List.fromList(bytes.sublist(offset, offset + nonceLength));
    offset += nonceLength;
    final payloadLength = view.getUint64(offset, Endian.little);
    offset += 8;
    if (payloadLength == 0 || offset + payloadLength != bytes.length) {
      throw const BackupFailure(BackupFailureKind.corruptedPayload);
    }
    return ParsedContainerHeader(
      containerVersion: containerVersion,
      protectionId: protectionId,
      cipherId: cipherId,
      nonce: nonce,
      body: Uint8List.fromList(bytes.sublist(offset, offset + payloadLength)),
    );
  }
}

final class ParsedContainerHeader {
  const ParsedContainerHeader({
    required this.containerVersion,
    required this.protectionId,
    required this.cipherId,
    required this.nonce,
    required this.body,
  });

  final int containerVersion;
  final int protectionId;
  final int cipherId;
  final Uint8List nonce;
  final Uint8List body;

  /// True when the payload needs the device-bound key to be read.
  bool get isProtected => protectionId != BackupFormat.noneProtectionId;
}

final class BackupContainerCodec {
  BackupContainerCodec({Random? random}) : _random = random ?? Random.secure();

  final Random _random;

  /// Seals a portable backup. No encryption is applied: the payload is stored
  /// as-is and remains readable, which is the honest consequence of saving
  /// without a password.
  BackupContainer sealPortable({required Uint8List plainText}) {
    return BackupContainer.unprotected(body: plainText);
  }

  /// Seals the temporary local recovery checkpoint under a directly supplied
  /// device-bound key. This container never leaves app-private storage.
  BackupContainer sealWithDeviceKey({
    required Uint8List key,
    required Uint8List plainText,
  }) {
    if (key.length != BackupFormat.derivedKeyLength) {
      throw const BackupFailure(BackupFailureKind.checkpointFailed);
    }
    final nonce = _randomBytes(BackupFormat.gcmNonceLength);
    return BackupContainer(
      containerVersion: BackupFormat.containerVersion,
      protectionId: BackupFormat.deviceKeyProtectionId,
      cipherId: BackupFormat.cipherId,
      nonce: nonce,
      body: _cipher(key: key, nonce: nonce, forEncryption: true)
          .process(plainText),
    );
  }

  /// Recovers the payload of a parsed container.
  ///
  /// An unprotected container needs no key at all and is returned as-is. A
  /// device-key container requires [deviceKey]; without one it fails with
  /// [BackupFailureKind.checkpointFailed] rather than reporting a wrong
  /// passphrase, because no passphrase exists anywhere in this app.
  Uint8List open({
    required ParsedContainerHeader header,
    Uint8List? deviceKey,
  }) {
    if (!header.isProtected) {
      return header.body;
    }
    if (deviceKey == null || deviceKey.length != BackupFormat.derivedKeyLength) {
      throw const BackupFailure(BackupFailureKind.checkpointFailed);
    }
    try {
      return _cipher(key: deviceKey, nonce: header.nonce, forEncryption: false)
          .process(header.body);
    } on InvalidCipherTextException {
      throw const BackupFailure(BackupFailureKind.checkpointFailed);
    } on ArgumentError {
      throw const BackupFailure(BackupFailureKind.corruptedPayload);
    } on StateError {
      throw const BackupFailure(BackupFailureKind.corruptedPayload);
    }
  }

  GCMBlockCipher _cipher({
    required Uint8List key,
    required Uint8List nonce,
    required bool forEncryption,
  }) {
    return GCMBlockCipher(AESEngine())
      ..init(
        forEncryption,
        AEADParameters(
          KeyParameter(key),
          BackupFormat.gcmTagLengthBits,
          nonce,
          Uint8List(0),
        ),
      );
  }

  Uint8List _randomBytes(int length) {
    final bytes = Uint8List(length);
    for (var index = 0; index < length; index++) {
      bytes[index] = _random.nextInt(256);
    }
    return bytes;
  }
}
