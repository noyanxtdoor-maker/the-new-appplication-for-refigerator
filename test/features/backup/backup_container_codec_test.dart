import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/features/backup/application/backup_container_codec.dart';
import 'package:rmplanner/features/backup/domain/backup_errors.dart';
import 'package:rmplanner/features/backup/domain/backup_manifest.dart';

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

Uint8List _key() =>
    Uint8List.fromList(List<int>.generate(32, (index) => index + 7));

void main() {
  final codec = BackupContainerCodec(random: Random(7));

  group('portable backup', () {
    test('carries no protection and opens with no credential', () {
      final container = codec.sealPortable(
        plainText: _bytes('{"hello":"next transfer"}'),
      );
      final bytes = container.toBytes();
      final header = BackupContainer.parseHeader(bytes);

      expect(header.protectionId, BackupFormat.noneProtectionId);
      expect(header.cipherId, BackupFormat.noneCipherId);
      expect(header.nonce, isEmpty);
      expect(header.isProtected, isFalse);

      // Saving a backup must never demand a password, so opening one must not
      // need anything either.
      final opened = codec.open(header: header);
      expect(utf8.decode(opened), '{"hello":"next transfer"}');
    });

    test('is readable, and that is stated rather than hidden', () {
      final bytes = codec
          .sealPortable(plainText: _bytes('readable by design'))
          .toBytes();

      // The honest consequence of a one-tap, credential-free backup: the file
      // itself is legible. No part of the app claims otherwise.
      expect(utf8.decode(bytes), contains('readable by design'));
    });

    test('round trips through the header unchanged', () {
      final plainText = _bytes('{"manifest":{"magic":"NEXTTRANSFER-BACKUP"}}');
      final bytes = codec.sealPortable(plainText: plainText).toBytes();
      final header = BackupContainer.parseHeader(bytes);
      expect(header.body, plainText);
      expect(header.containerVersion, BackupFormat.containerVersion);
    });
  });

  group('device-bound checkpoint', () {
    test('round trips with its key', () {
      final container = codec.sealWithDeviceKey(
        key: _key(),
        plainText: _bytes('current local state'),
      );
      final header = BackupContainer.parseHeader(container.toBytes());

      expect(header.protectionId, BackupFormat.deviceKeyProtectionId);
      expect(header.cipherId, BackupFormat.cipherId);
      expect(header.nonce.length, BackupFormat.gcmNonceLength);
      expect(header.isProtected, isTrue);

      expect(utf8.decode(codec.open(header: header, deviceKey: _key())),
          'current local state');
    });

    test('its payload is not readable without the key', () {
      final bytes = codec
          .sealWithDeviceKey(key: _key(), plainText: _bytes('private state'))
          .toBytes();
      expect(utf8.decode(bytes, allowMalformed: true),
          isNot(contains('private state')));
    });

    test('a wrong key cannot open it', () {
      final bytes = codec
          .sealWithDeviceKey(key: _key(), plainText: _bytes('private state'))
          .toBytes();
      final header = BackupContainer.parseHeader(bytes);
      final wrongKey = Uint8List.fromList(List<int>.generate(32, (i) => i));

      expect(
        () => codec.open(header: header, deviceKey: wrongKey),
        throwsA(
          isA<BackupFailure>().having(
            (failure) => failure.kind,
            'kind',
            BackupFailureKind.checkpointFailed,
          ),
        ),
      );
    });

    test('no key at all is refused, never returned as plaintext', () {
      final bytes = codec
          .sealWithDeviceKey(key: _key(), plainText: _bytes('private state'))
          .toBytes();
      final header = BackupContainer.parseHeader(bytes);

      expect(
        () => codec.open(header: header),
        throwsA(
          isA<BackupFailure>().having(
            (failure) => failure.kind,
            'kind',
            BackupFailureKind.checkpointFailed,
          ),
        ),
      );
    });

    test('a tampered payload is rejected', () {
      final bytes = codec
          .sealWithDeviceKey(key: _key(), plainText: _bytes('private state'))
          .toBytes();
      final tampered = Uint8List.fromList(bytes);
      tampered[tampered.length - 1] = tampered.last ^ 0xFF;
      final header = BackupContainer.parseHeader(tampered);

      expect(
        () => codec.open(header: header, deviceKey: _key()),
        throwsA(isA<BackupFailure>()),
      );
    });

    test('encrypts to different bytes each time', () {
      final plain = _bytes('same state');
      final first = codec
          .sealWithDeviceKey(key: _key(), plainText: plain)
          .toBytes();
      final second = codec
          .sealWithDeviceKey(key: _key(), plainText: plain)
          .toBytes();
      expect(first, isNot(second));
    });
  });

  group('fail-closed parsing', () {
    test('rejects a file that is not a backup', () {
      expect(
        () => BackupContainer.parseHeader(_bytes('not a backup at all')),
        throwsA(
          isA<BackupFailure>().having(
            (failure) => failure.kind,
            'kind',
            BackupFailureKind.notABackupFile,
          ),
        ),
      );
    });

    test('rejects anything shorter than a header', () {
      expect(
        () => BackupContainer.parseHeader(Uint8List(12)),
        throwsA(
          isA<BackupFailure>().having(
            (failure) => failure.kind,
            'kind',
            BackupFailureKind.notABackupFile,
          ),
        ),
      );
    });

    test('rejects a newer container version', () {
      final forged = Uint8List.fromList(
        codec.sealPortable(plainText: _bytes('future')).toBytes(),
      );
      forged[8] = BackupFormat.containerVersion + 1;
      expect(
        () => BackupContainer.parseHeader(forged),
        throwsA(
          isA<BackupFailure>().having(
            (failure) => failure.kind,
            'kind',
            BackupFailureKind.unsupportedContainerVersion,
          ),
        ),
      );
    });

    test('rejects the retired version 1 container', () {
      // Version 1 was a development-only passphrase shape that never shipped.
      final forged = Uint8List.fromList(
        codec.sealPortable(plainText: _bytes('prerelease')).toBytes(),
      );
      forged[8] = 1;
      expect(
        () => BackupContainer.parseHeader(forged),
        throwsA(
          isA<BackupFailure>().having(
            (failure) => failure.kind,
            'kind',
            BackupFailureKind.unsupportedBackupVersion,
          ),
        ),
      );
    });

    test('rejects a protection id that disagrees with its cipher', () {
      final forged = Uint8List.fromList(
        codec.sealPortable(plainText: _bytes('mislabelled')).toBytes(),
      );
      // Claim no protection while declaring a cipher.
      forged[10] = BackupFormat.cipherId;
      expect(
        () => BackupContainer.parseHeader(forged),
        throwsA(
          isA<BackupFailure>().having(
            (failure) => failure.kind,
            'kind',
            BackupFailureKind.unsupportedBackupVersion,
          ),
        ),
      );
    });

    test('rejects an unknown protection id', () {
      final forged = Uint8List.fromList(
        codec.sealPortable(plainText: _bytes('unknown')).toBytes(),
      );
      forged[9] = 9;
      expect(
        () => BackupContainer.parseHeader(forged),
        throwsA(
          isA<BackupFailure>().having(
            (failure) => failure.kind,
            'kind',
            BackupFailureKind.unsupportedBackupVersion,
          ),
        ),
      );
    });

    test('rejects a portable header that declares a nonce', () {
      final forged = Uint8List.fromList(
        codec.sealPortable(plainText: _bytes('claims a nonce')).toBytes(),
      );
      // Byte 12 is the nonce-length field for this shape.
      forged[12] = BackupFormat.gcmNonceLength;
      expect(
        () => BackupContainer.parseHeader(forged),
        throwsA(
          isA<BackupFailure>().having(
            (failure) => failure.kind,
            'kind',
            BackupFailureKind.notABackupFile,
          ),
        ),
      );
    });

    test('rejects a truncated container', () {
      final bytes =
          codec.sealPortable(plainText: _bytes('whole payload')).toBytes();
      final truncated =
          Uint8List.fromList(bytes.sublist(0, bytes.length - 4));
      expect(
        () => BackupContainer.parseHeader(truncated),
        throwsA(
          isA<BackupFailure>().having(
            (failure) => failure.kind,
            'kind',
            BackupFailureKind.corruptedPayload,
          ),
        ),
      );
    });

    test('rejects an empty payload', () {
      final forged = Uint8List.fromList(
        codec.sealPortable(plainText: _bytes('x')).toBytes(),
      );
      // The declared length occupies the eight bytes before the one-byte
      // payload. A declared length of zero must never be accepted.
      final lengthFieldStart = forged.length - 1 - 8;
      for (var index = 0; index < 8; index++) {
        forged[lengthFieldStart + index] = 0;
      }
      expect(
        () => BackupContainer.parseHeader(forged),
        throwsA(
          isA<BackupFailure>().having(
            (failure) => failure.kind,
            'kind',
            BackupFailureKind.corruptedPayload,
          ),
        ),
      );
    });
  });
}
