import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/features/backup/application/backup_operation_notifier.dart';
import 'package:rmplanner/features/backup/application/backup_providers.dart';
import 'package:rmplanner/features/backup/data/backup_document_gateway.dart';
import 'package:rmplanner/features/backup/data/backup_downloads_writer.dart';
import 'package:rmplanner/features/backup/data/backup_recovery_checkpoint_store.dart';
import 'package:rmplanner/features/backup/domain/backup_errors.dart';
import 'package:rmplanner/features/backup/domain/backup_flow_notice.dart';
import 'package:rmplanner/features/backup/domain/backup_operation_notice.dart';
import 'package:rmplanner/features/startup/application/startup_providers.dart';

/// A Downloads writer that can be held open, so a test can observe what
/// happens while an operation is genuinely in flight.
final class _GatedDownloadsWriter implements BackupDownloadsWriter {
  Completer<void>? gate;
  int writes = 0;
  String? lastFileName;

  /// True when this build/device cannot write straight to Downloads.
  bool declines = false;

  @override
  Future<SavedBackupDocument?> writeToDownloads({
    required String fileName,
    required Uint8List bytes,
  }) async {
    final held = gate;
    if (held != null) {
      await held.future;
    }
    if (declines) {
      return null;
    }
    writes++;
    lastFileName = fileName;
    return SavedBackupDocument(
      location: 'Downloads/$fileName',
      byteLength: bytes.length,
    );
  }
}

final class _Gateway implements BackupDocumentGateway {
  int saveCalls = 0;
  Uint8List? toPick;

  /// True when the user closes the destination picker without saving.
  bool declineSave = false;

  @override
  Future<SavedBackupDocument?> saveDocument({
    required String suggestedFileName,
    required Uint8List bytes,
  }) async {
    saveCalls++;
    if (declineSave) {
      return null;
    }
    return SavedBackupDocument(
      location: '/synthetic/$suggestedFileName',
      byteLength: bytes.length,
    );
  }

  @override
  Future<PickedBackupDocument?> pickDocument() async {
    final bytes = toPick;
    if (bytes == null) {
      return null;
    }
    return PickedBackupDocument(fileName: 'picked.ntbackup', bytes: bytes);
  }
}

/// A gateway whose picker cannot hand the file over at all — the device case
/// where Android refused the document read.
final class _UnreadableGateway implements BackupDocumentGateway {
  @override
  Future<SavedBackupDocument?> saveDocument({
    required String suggestedFileName,
    required Uint8List bytes,
  }) async => throw UnimplementedError();

  @override
  Future<PickedBackupDocument?> pickDocument() async =>
      throw const BackupFailure(BackupFailureKind.fileAccessFailed);
}

/// Records the notification states the flow published, in order, so a test can
/// prove what the shade was told and — more importantly — when.
final class _RecordingOperationNotifier implements BackupOperationNotifier {
  _RecordingOperationNotifier({this.onPublish});

  final List<String> notices = <String>[];
  final Future<void> Function(BackupOperationNotice notice)? onPublish;

  @override
  Future<void> publish(BackupOperationNotice notice) async {
    notices.add(notice.title ?? '<dismiss>');
    await onPublish?.call(notice);
  }
}

/// A notifier whose transport is broken, to prove feedback can never fail an
/// operation.
final class _BrokenOperationNotifier implements BackupOperationNotifier {
  @override
  Future<void> publish(BackupOperationNotice notice) async =>
      throw StateError('no notification transport');
}

final class _MemoryKeyStore implements CheckpointKeyStore {
  @override
  Future<Uint8List> readOrCreateKey() async =>
      Uint8List.fromList(List<int>.generate(32, (i) => i));
}

Future<void> _seed(AppDatabase database) async {
  const profileId = 'profile-controller';
  const created = 1750000000;
  await database.customInsert(
    'INSERT INTO local_profiles (id, slot, local_name, display_name, '
    'time_zone_id, created_at_utc, updated_at_utc) VALUES (?,?,?,?,?,?,?)',
    variables: <Variable<Object>>[
      const Variable<String>(profileId),
      const Variable<String>('primary'),
      const Variable<String>('Local'),
      const Variable<String>('Controller Tester'),
      const Variable<String>('UTC'),
      const Variable<int>(created),
      const Variable<int>(created),
    ],
  );
  await database.customInsert(
    'INSERT INTO planner_tasks (id, profile_id, title, recurrence_frequency, '
    'people_json, status, requires_report, is_backup, contribution_rule_key, '
    'created_at_utc, updated_at_utc) VALUES (?,?,?,?,?,?,?,?,?,?,?)',
    variables: <Variable<Object>>[
      const Variable<String>('task-1'),
      const Variable<String>(profileId),
      const Variable<String>('Synthetic task'),
      const Variable<String>('none'),
      const Variable<String>('[]'),
      const Variable<String>('open'),
      const Variable<int>(0),
      const Variable<int>(0),
      const Variable<String>('none'),
      const Variable<int>(created),
      const Variable<int>(created),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase database;
  late Directory checkpointDirectory;
  late _GatedDownloadsWriter downloads;
  late _Gateway gateway;
  late List<String> refreshes;
  late _RecordingOperationNotifier operationNotices;

  setUp(() async {
    checkpointDirectory = Directory.systemTemp.createTempSync('nt_flow_test');
    database = AppDatabase.forTesting(NativeDatabase.memory());
    await _seed(database);
    downloads = _GatedDownloadsWriter();
    gateway = _Gateway();
    refreshes = <String>[];
    operationNotices = _RecordingOperationNotifier();
  });

  tearDown(() async {
    await database.close();
    try {
      if (checkpointDirectory.existsSync()) {
        checkpointDirectory.deleteSync(recursive: true);
      }
    } on FileSystemException {
      // A held handle on a just-written checkpoint is not a test failure.
    }
  });

  ProviderContainer makeContainer({
    BackupOperationNotifier? notifier,
    Future<void> Function(String profileId)? reconcile,
    Future<void> Function()? refresh,
  }) {
    final container = ProviderContainer(
      overrides: <Override>[
        appDatabaseProvider.overrideWithValue(database),
        backupDocumentGatewayProvider.overrideWithValue(gateway),
        backupDownloadsWriterProvider.overrideWithValue(downloads),
        checkpointKeyStoreProvider.overrideWithValue(_MemoryKeyStore()),
        checkpointDirectoryProvider.overrideWithValue(
          () async => checkpointDirectory,
        ),
        diagnosticsProvider.overrideWithValue(SanitizedDiagnostics()),
        backupOperationNotifierProvider.overrideWithValue(
          notifier ?? operationNotices,
        ),
        backupPostRestoreReconcilerProvider.overrideWithValue(
          reconcile ?? (profileId) async {},
        ),
        backupPostRestoreRefreshProvider.overrideWithValue(
          refresh ?? () async => refreshes.add('refresh'),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  /// A real backup of this profile, produced by the same service the button
  /// uses, so the restore path under test is the product path.
  Future<Uint8List> realBackup(ProviderContainer container) async {
    final service = container.read(backupServiceProvider);
    final payload =
        await service.buildPayload(profileId: 'profile-controller');
    return service.encode(payload: payload);
  }

  test('a second backup while one is running is refused, not written twice',
      () async {
    final container = makeContainer();
    final controller = container.read(backupFlowControllerProvider.notifier);

    // Hold the first write open so the second call genuinely overlaps it.
    downloads.gate = Completer<void>();
    final first = controller.createBackup();
    expect(
      container.read(backupFlowControllerProvider).running,
      BackupOperation.backup,
    );
    final second = await controller.createBackup();
    expect(second, isFalse, reason: 're-entry must be refused outright');

    downloads.gate!.complete();
    expect(await first, isTrue);
    expect(downloads.writes, 1, reason: 'one tap must create exactly one file');
    expect(
      container.read(backupFlowControllerProvider).running,
      isNull,
    );
    // One operation, one card: the refused second tap published nothing.
    expect(operationNotices.notices, <String>[
      'Backing up your data…',
      'Backup created',
    ]);
  });

  test('a finished backup is acknowledged once and then consumed', () async {
    final container = makeContainer();
    final controller = container.read(backupFlowControllerProvider.notifier);

    expect(await controller.createBackup(), isTrue);
    expect(
      container.read(backupFlowControllerProvider).notice,
      const BackupFlowNotice('Backup created — saved to Downloads'),
    );
    // The screen acknowledges it, and nothing is left to replay.
    controller.consumeNotice();
    expect(container.read(backupFlowControllerProvider).notice, isNull);
    expect(container.read(backupFlowControllerProvider).message, isNull);
  });

  test('a failure never sits underneath an older success', () async {
    final container = makeContainer();
    final controller = container.read(backupFlowControllerProvider.notifier);

    expect(await controller.createBackup(), isTrue);
    expect(container.read(backupFlowControllerProvider).notice, isNotNull);

    // The next operation fails.
    gateway.toPick = Uint8List.fromList(<int>[1, 2, 3]);
    expect(await controller.chooseBackupToRestore(), isFalse);

    final state = container.read(backupFlowControllerProvider);
    expect(state.notice, isNull, reason: 'the old success must be cleared');
    expect(state.message, 'That file is not a Next Transfer backup.');
  });

  test('a successful restore refreshes app state exactly once', () async {
    final container = makeContainer();
    final controller = container.read(backupFlowControllerProvider.notifier);

    gateway.toPick = await realBackup(container);
    expect(await controller.chooseBackupToRestore(), isTrue);
    expect(await controller.applyRestore(), isTrue);

    expect(refreshes, <String>['refresh']);
    expect(
      container.read(backupFlowControllerProvider).notice,
      const BackupFlowNotice(
        'Data restored',
        body: restoreRefreshGuidance,
      ),
    );
  });

  test('a failing refresh is reported truthfully, never as a failed restore',
      () async {
    final container = ProviderContainer(
      overrides: <Override>[
        appDatabaseProvider.overrideWithValue(database),
        backupDocumentGatewayProvider.overrideWithValue(gateway),
        backupDownloadsWriterProvider.overrideWithValue(downloads),
        checkpointKeyStoreProvider.overrideWithValue(_MemoryKeyStore()),
        checkpointDirectoryProvider.overrideWithValue(
          () async => checkpointDirectory,
        ),
        diagnosticsProvider.overrideWithValue(SanitizedDiagnostics()),
        backupOperationNotifierProvider.overrideWithValue(operationNotices),
        backupPostRestoreReconcilerProvider.overrideWithValue(
          (profileId) async {},
        ),
        backupPostRestoreRefreshProvider.overrideWithValue(
          () async => throw StateError('no container'),
        ),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(backupFlowControllerProvider.notifier);

    gateway.toPick = await realBackup(container);
    expect(await controller.chooseBackupToRestore(), isTrue);
    expect(await controller.applyRestore(), isTrue);

    final state = container.read(backupFlowControllerProvider);
    expect(state.message, isNull);
    expect(
      state.notice,
      const BackupFlowNotice(
        'Data restored',
        body: 'Your data has been restored. Reopen Next Transfer to see it.',
      ),
    );
    // The data really is restored: a refresh failure never rolls it back.
    final rows = await database
        .customSelect('SELECT COUNT(*) c FROM planner_tasks')
        .getSingle();
    expect(rows.read<int>('c'), 1);
  });

  test('a destination that does not store what was written is not a backup',
      () async {
    // Downloads cannot be used here, so the chosen destination is — and it
    // reports having stored a different number of bytes.
    final lying = ProviderContainer(
      overrides: <Override>[
        appDatabaseProvider.overrideWithValue(database),
        backupDocumentGatewayProvider.overrideWithValue(_ShortWriteGateway()),
        checkpointKeyStoreProvider.overrideWithValue(_MemoryKeyStore()),
        checkpointDirectoryProvider.overrideWithValue(
          () async => checkpointDirectory,
        ),
        diagnosticsProvider.overrideWithValue(SanitizedDiagnostics()),
        backupOperationNotifierProvider.overrideWithValue(operationNotices),
        backupPostRestoreRefreshProvider.overrideWithValue(() async {}),
      ],
    );
    addTearDown(lying.dispose);

    final created = await lying
        .read(backupFlowControllerProvider.notifier)
        .createBackup();

    expect(created, isFalse);
    final state = lying.read(backupFlowControllerProvider);
    expect(state.notice, isNull, reason: 'a short write is never "created"');
    expect(state.message, "Next Transfer couldn't save the backup file.");
    // The shade is told the same truth the screen tells.
    expect(operationNotices.notices, <String>[
      'Backing up your data…',
      "Backup didn't complete",
    ]);
  });

  group('Android notification-shade feedback', () {
    test('a backup reports progress, then a creation — in that order',
        () async {
      final container = makeContainer();
      final controller = container.read(backupFlowControllerProvider.notifier);

      expect(await controller.createBackup(), isTrue);

      expect(operationNotices.notices, <String>[
        'Backing up your data…',
        'Backup created',
      ]);
    });

    test('a backup the user abandoned takes the progress card down', () async {
      final container = makeContainer();
      final controller = container.read(backupFlowControllerProvider.notifier);

      // This install cannot write to Downloads, and the user closed the
      // destination picker without saving.
      downloads.declines = true;
      gateway.declineSave = true;

      expect(await controller.createBackup(), isFalse);

      expect(operationNotices.notices, <String>[
        'Backing up your data…',
        '<dismiss>',
      ], reason: 'nothing happened, so nothing is claimed');
      expect(
        container.read(backupFlowControllerProvider).message,
        'No backup was created.',
      );
    });

    test('the restore card is posted only after the write really committed',
        () async {
      final observed = <String>[];
      final recorder = _RecordingOperationNotifier(
        onPublish: (notice) async {
          if (notice.title != 'Backup restored') {
            return;
          }
          final row = await database
              .customSelect('SELECT title FROM planner_tasks LIMIT 1')
              .getSingleOrNull();
          observed.add(row?.read<String>('title') ?? '<no row>');
        },
      );
      final container = makeContainer(notifier: recorder);
      final controller = container.read(backupFlowControllerProvider.notifier);

      gateway.toPick = await realBackup(container);
      // Local state diverges after the backup was taken, so what the card sees
      // proves whether the canonical write had already happened.
      await database.customStatement(
        "UPDATE planner_tasks SET title = 'changed after backup'",
      );

      expect(await controller.chooseBackupToRestore(), isTrue);
      expect(await controller.applyRestore(), isTrue);

      expect(recorder.notices, <String>[
        'Restoring your backup…',
        'Backup restored',
      ]);
      expect(
        observed,
        <String>['Synthetic task'],
        reason: 'the transaction had committed before the card was posted',
      );
    });

    test('a file the app cannot open is reported as a file problem', () async {
      final container = ProviderContainer(
        overrides: <Override>[
          appDatabaseProvider.overrideWithValue(database),
          backupDocumentGatewayProvider.overrideWithValue(_UnreadableGateway()),
          backupDownloadsWriterProvider.overrideWithValue(downloads),
          checkpointKeyStoreProvider.overrideWithValue(_MemoryKeyStore()),
          checkpointDirectoryProvider.overrideWithValue(
            () async => checkpointDirectory,
          ),
          diagnosticsProvider.overrideWithValue(SanitizedDiagnostics()),
          backupOperationNotifierProvider.overrideWithValue(operationNotices),
          backupPostRestoreRefreshProvider.overrideWithValue(() async {}),
        ],
      );
      addTearDown(container.dispose);
      final controller = container.read(backupFlowControllerProvider.notifier);

      expect(await controller.chooseBackupToRestore(), isFalse);

      final state = container.read(backupFlowControllerProvider);
      // Truthful, actionable, and distinguishable from a damaged backup.
      expect(
        state.message,
        "Next Transfer couldn't open that backup file. Please choose it again.",
      );
      expect(state.message, isNot(contains('read or write')));
      // Nothing was read, so there is nothing to confirm and nothing was
      // written: the only truthful card is the pre-commit one.
      expect(state.preview, isNull);
      expect(operationNotices.notices, <String>["Restore didn't complete"]);
    });

    test('cancelling the picker writes nothing and reports no failure',
        () async {
      final container = makeContainer();
      final controller = container.read(backupFlowControllerProvider.notifier);

      gateway.toPick = null;
      expect(await controller.chooseBackupToRestore(), isFalse);

      final state = container.read(backupFlowControllerProvider);
      expect(state.message, 'No backup was selected.');
      expect(state.preview, isNull);
      // The user cancelled before anything was being restored, so the shade is
      // never told an operation failed.
      expect(operationNotices.notices, isEmpty);
    });

    test('a file that is not a backup reports the pre-commit outcome',
        () async {
      final container = makeContainer();
      final controller = container.read(backupFlowControllerProvider.notifier);

      gateway.toPick = Uint8List.fromList(<int>[1, 2, 3]);
      expect(await controller.chooseBackupToRestore(), isFalse);

      // Nothing was written, so the only truthful card is the pre-commit one.
      expect(operationNotices.notices, <String>["Restore didn't complete"]);
      expect(
        operationNotices.notices,
        isNot(contains('Backup restored')),
      );
    });

    test('a committed restore with unfinished repair is partial success',
        () async {
      final container = makeContainer(
        reconcile: (profileId) async =>
            throw StateError('no reminder scheduler'),
      );
      final controller = container.read(backupFlowControllerProvider.notifier);

      gateway.toPick = await realBackup(container);
      expect(await controller.chooseBackupToRestore(), isTrue);
      expect(await controller.applyRestore(), isTrue);

      const warning =
          'Your data was restored, but reminder schedules could not be '
          'rebuilt. They will be rebuilt the next time Next Transfer starts.';
      expect(operationNotices.notices, <String>[
        'Restoring your backup…',
        'Backup restored',
      ]);
      expect(operationNotices.notices, isNot(contains("Restore didn't complete")));
      // The in-app message carries the same truthful detail, so a warning the
      // engine reported is never quietly dropped now that there is no card.
      // The warning is the acknowledgement's *body*: a real post-restore
      // warning overrides the generic "close and reopen" guidance instead of
      // sitting beside it.
      expect(
        container.read(backupFlowControllerProvider).notice,
        const BackupFlowNotice('Data restored', body: warning),
      );
      expect(container.read(backupFlowControllerProvider).message, isNull);
    });

    test('a refresh that fails is partial success, never a failed restore',
        () async {
      final observed = <String>[];
      final recorder = _RecordingOperationNotifier(
        onPublish: (notice) async => observed.add(notice.body ?? ''),
      );
      final container = makeContainer(
        notifier: recorder,
        refresh: () async => throw StateError('no container'),
      );
      final controller = container.read(backupFlowControllerProvider.notifier);

      gateway.toPick = await realBackup(container);
      expect(await controller.chooseBackupToRestore(), isTrue);
      expect(await controller.applyRestore(), isTrue);

      expect(recorder.notices.last, 'Backup restored');
      expect(
        observed.last,
        'Your data has been restored. Reopen Next Transfer to see it.',
      );
    });

    test('a broken notification transport never fails the operation', () async {
      final container = makeContainer(notifier: _BrokenOperationNotifier());
      final controller = container.read(backupFlowControllerProvider.notifier);

      expect(
        await controller.createBackup(),
        isTrue,
        reason: 'feedback is advisory; the backup still happened',
      );
      expect(
        container.read(backupFlowControllerProvider).notice,
        const BackupFlowNotice('Backup created — saved to Downloads'),
      );
    });

    test('operation feedback creates no reminder or background-work rows',
        () async {
      final container = makeContainer();
      final controller = container.read(backupFlowControllerProvider.notifier);

      expect(await controller.createBackup(), isTrue);
      gateway.toPick = await realBackup(container);
      expect(await controller.chooseBackupToRestore(), isTrue);
      expect(await controller.applyRestore(), isTrue);

      for (final table in <String>[
        'reminder_policies',
        'background_work_requests',
      ]) {
        final count = await database
            .customSelect('SELECT COUNT(*) c FROM $table')
            .getSingle();
        expect(count.read<int>('c'), 0, reason: table);
      }
    });
  });
}

/// Reports a stored length that differs from what it was handed, the way a
/// destination that silently truncated the file would.
final class _ShortWriteGateway implements BackupDocumentGateway {
  @override
  Future<SavedBackupDocument?> saveDocument({
    required String suggestedFileName,
    required Uint8List bytes,
  }) async =>
      SavedBackupDocument(
        location: '/synthetic/$suggestedFileName',
        byteLength: bytes.length - 1,
      );

  @override
  Future<PickedBackupDocument?> pickDocument() async => null;
}
