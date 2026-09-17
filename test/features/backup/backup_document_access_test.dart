// OWNER PHYSICAL-REVIEW CORRECTION #4 — the backup file-access boundary.
//
// The owner's device reported a file problem as a generic read/write failure,
// which reads exactly like a damaged backup and gives the user nothing to act
// on. These tests pin the boundary between the three genuinely different
// failures: the app could not open the file (access), the app opened it and it
// is not a usable backup (format), or the app could not write (save).
//
// They also pin the read contract itself:
//
// * the whole chosen document is read inside the picker result boundary,
//   through the platform's content stream, so the confirmation step that
//   follows can never depend on a live provider grant, an open descriptor or a
//   path derived from a content:// selection;
// * the bytes the app parses are the bytes the provider served — never a
//   provider-reported length, and never a filesystem path;
// * the picker is asked to show the user's backup whatever MIME type a
//   provider happens to describe it with.
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/features/backup/application/backup_container_codec.dart';
import 'package:rmplanner/features/backup/data/backup_document_gateway.dart';
import 'package:rmplanner/features/backup/domain/backup_errors.dart';
import 'package:rmplanner/features/backup/domain/backup_manifest.dart';

/// A picked file that records how it was read, and can be made to behave like a
/// provider whose stream has gone away.
final class _PickedFile extends XFile {
  _PickedFile({
    required this.payload,
    this.reportedLength,
    this.failReads = false,
    String path = '',
  }) : super(path);

  final Uint8List payload;
  final int? reportedLength;

  /// Set true to simulate the temporary provider grant no longer working.
  bool failReads;

  int reads = 0;

  @override
  Future<Uint8List> readAsBytes() async {
    reads++;
    if (failReads) {
      throw const FileSystemException('provider stream closed');
    }
    return payload;
  }

  @override
  Future<int> length() async => reportedLength ?? payload.length;
}

/// A real container-v2 header and body. The boundary must not care what the
/// payload means — only the format layer does.
Uint8List _backupBytes() {
  final bytes = BackupContainer.unprotected(
    body: Uint8List.fromList(utf8.encode('{"synthetic":true}')),
  ).toBytes();
  return bytes;
}

const String _contentUri =
    'content://com.android.providers.media.documents/document/msf%3A1000017279';

FileSelectorBackupDocumentGateway _gatewayReturning(XFile? file) =>
    FileSelectorBackupDocumentGateway(
      open: ({List<XTypeGroup> acceptedTypeGroups = const <XTypeGroup>[]}) async =>
          file,
    );

void main() {
  group('reading a chosen backup file', () {
    test('the document is read through the stream and never as a path',
        () async {
      final bytes = _backupBytes();
      final file = _PickedFile(payload: bytes, path: _contentUri);
      final gateway = _gatewayReturning(file);

      // The selected URI is a MediaStore document, not a file on disk: had the
      // gateway treated the selection as a path, this would never have read.
      expect(File(_contentUri).existsSync(), isFalse);

      final picked = await gateway.pickDocument();

      expect(picked, isNotNull);
      expect(picked!.bytes, bytes);
      expect(file.reads, 1, reason: 'read exactly once, inside the picker call');
    });

    test('the bytes survive the provider grant going away', () async {
      final bytes = _backupBytes();
      final file = _PickedFile(payload: bytes, path: _contentUri);
      final gateway = _gatewayReturning(file);

      final picked = await gateway.pickDocument();
      expect(picked!.bytes, bytes);

      // Whatever the user does next, the grant the picker handed back is no
      // longer needed: the file is already captured.
      file.failReads = true;
      expect(picked.bytes, bytes);
      expect(picked.bytes.length, bytes.length);
    });

    test('a provider-reported length never decides how many bytes are read',
        () async {
      final bytes = _backupBytes();
      // A provider that under-reports the size must not truncate the restore
      // input, and one that over-reports must not make a readable file look
      // too large to open.
      for (final reported in <int>[7, 999999, BackupFormat.maxFileBytes + 1]) {
        final picked = await _gatewayReturning(
          _PickedFile(payload: bytes, reportedLength: reported),
        ).pickDocument();
        expect(picked!.bytes.length, bytes.length, reason: 'reported=$reported');
      }
    });

    test('the picked document carries no path, URI or handle', () async {
      final picked = await _gatewayReturning(
        _PickedFile(payload: _backupBytes(), path: _contentUri),
      ).pickDocument();

      // The only constructor arguments are the display name and the bytes, so
      // nothing that can expire or dangle can be carried into the confirmation.
      expect(picked, isA<PickedBackupDocument>());
      expect(picked!.fileName, isNotEmpty);
      expect(picked.bytes, isNotEmpty);
    });

    test('cancelling the picker is not a failure', () async {
      expect(await _gatewayReturning(null).pickDocument(), isNull);
    });

    test('the picker is asked to accept the backup whatever MIME it reports',
        () async {
      final seen = <XTypeGroup>[];
      final gateway = FileSelectorBackupDocumentGateway(
        open: ({List<XTypeGroup> acceptedTypeGroups = const <XTypeGroup>[]}) async {
          seen.addAll(acceptedTypeGroups);
          return null;
        },
      );

      await gateway.pickDocument();

      expect(seen, hasLength(1));
      expect(seen.single.extensions, contains('ntbackup'));
      // A provider is free to describe a .ntbackup as anything; filtering on one
      // MIME type can hide the user's own backup from them.
      expect(seen.single.mimeTypes, contains('*/*'));
    });
  });

  group('file-access failures are told apart from everything else', () {
    test('a picker that cannot hand the file over is a file-access failure',
        () async {
      final gateway = FileSelectorBackupDocumentGateway(
        open: ({List<XTypeGroup> acceptedTypeGroups = const <XTypeGroup>[]}) async =>
            throw PlatformException(
              code: 'channel-error',
              message: 'Failed to read file: $_contentUri',
            ),
      );

      await expectLater(
        gateway.pickDocument(),
        throwsA(
          isA<BackupFailure>()
              .having(
                (failure) => failure.kind,
                'kind',
                BackupFailureKind.fileAccessFailed,
              )
              .having(
                (failure) => failure.userMessage,
                'message',
                "Next Transfer couldn't open that backup file. "
                    'Please choose it again.',
              ),
        ),
      );
    });

    test('a stream that fails mid-read is a file-access failure', () async {
      final gateway = _gatewayReturning(
        _PickedFile(payload: _backupBytes(), failReads: true),
      );

      await expectLater(
        gateway.pickDocument(),
        throwsA(
          isA<BackupFailure>().having(
            (failure) => failure.kind,
            'kind',
            BackupFailureKind.fileAccessFailed,
          ),
        ),
      );
    });

    test('a file-access failure never claims the backup is damaged', () async {
      const failure = BackupFailure(BackupFailureKind.fileAccessFailed);
      expect(failure.userMessage, isNot(contains('damaged')));
      expect(failure.userMessage, isNot(contains('read or write')));
      expect(failure.userMessage, contains('choose it again'));
    });

    test('a file that reads fine but is not a backup is a format problem',
        () async {
      final gateway = _gatewayReturning(
        _PickedFile(
          payload: Uint8List.fromList(utf8.encode('definitely not a backup')),
        ),
      );

      // The read succeeds, so the boundary is not allowed to call this an
      // access failure...
      final picked = await gateway.pickDocument();
      expect(picked, isNotNull);

      // ...the format layer is the one that refuses it, with its own message.
      expect(
        () => BackupContainer.parseHeader(picked!.bytes),
        throwsA(
          isA<BackupFailure>().having(
            (failure) => failure.userMessage,
            'message',
            'That file is not a Next Transfer backup.',
          ),
        ),
      );
    });

    test('an empty file that was read successfully is a format problem',
        () async {
      await expectLater(
        _gatewayReturning(_PickedFile(payload: Uint8List(0))).pickDocument(),
        throwsA(
          isA<BackupFailure>().having(
            (failure) => failure.kind,
            'kind',
            BackupFailureKind.notABackupFile,
          ),
        ),
      );
    });
  });
}
