import 'dart:async';
import 'dart:io';

// `isNull`/`isNotNull` exist in both drift and matcher; the test uses matcher's.
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/features/backup/application/backup_container_codec.dart';
import 'package:rmplanner/features/backup/application/backup_providers.dart';
import 'package:rmplanner/features/backup/data/backup_document_gateway.dart';
import 'package:rmplanner/features/backup/data/backup_downloads_writer.dart';
import 'package:rmplanner/features/backup/data/backup_payload_codec.dart';
import 'package:rmplanner/features/backup/data/backup_recovery_checkpoint_store.dart';
import 'package:rmplanner/features/backup/domain/backup_domain_registry.dart';
import 'package:rmplanner/features/backup/domain/backup_manifest.dart';
import 'package:rmplanner/features/backup/presentation/backup_recovery_screen.dart';
import 'package:rmplanner/features/startup/application/startup_providers.dart';
import '../../support/view_size.dart';

final class _RecordingGateway implements BackupDocumentGateway {
  Uint8List? saved;
  Uint8List? toPick;
  int saveCalls = 0;

  @override
  Future<SavedBackupDocument?> saveDocument({
    required String suggestedFileName,
    required Uint8List bytes,
  }) async {
    saveCalls++;
    saved = bytes;
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

/// Stands in for the MediaStore channel. `null` means "this platform cannot
/// write to Downloads without a storage permission", which is the API 24–28
/// case the real channel reports.
final class _FakeDownloadsWriter implements BackupDownloadsWriter {
  _FakeDownloadsWriter({this.supported = true});

  final bool supported;
  int writes = 0;
  String? lastFileName;
  Uint8List? lastBytes;

  /// When set, the write is held open so a test can observe the screen while
  /// an operation is genuinely still running.
  Completer<void>? gate;

  @override
  Future<SavedBackupDocument?> writeToDownloads({
    required String fileName,
    required Uint8List bytes,
  }) async {
    final held = gate;
    if (held != null) {
      await held.future;
    }
    writes++;
    lastFileName = fileName;
    lastBytes = bytes;
    if (!supported) {
      return null;
    }
    return SavedBackupDocument(
      location: 'Downloads/$fileName',
      byteLength: bytes.length,
    );
  }
}

/// Returns a document whose reported length does not match what was handed to
/// it, the way a destination that truncated the file would.
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

final class _MemoryKeyStore implements CheckpointKeyStore {
  @override
  Future<Uint8List> readOrCreateKey() async =>
      Uint8List.fromList(List<int>.generate(32, (i) => 255 - i));
}

Future<void> _seed(AppDatabase database) async {
  const profileId = 'profile-widget';
  const created = 1750000000;
  await database.customInsert(
    'INSERT INTO local_profiles (id, slot, local_name, display_name, '
    'time_zone_id, created_at_utc, updated_at_utc) VALUES (?,?,?,?,?,?,?)',
    variables: <Variable<Object>>[
      const Variable<String>(profileId),
      const Variable<String>('primary'),
      const Variable<String>('Local'),
      const Variable<String>('Widget Tester'),
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
  late AppDatabase database;
  late Directory checkpointDirectory;
  late _RecordingGateway gateway;
  late List<String> refreshCalls;

  setUp(() async {
    checkpointDirectory = Directory.systemTemp.createTempSync('nt_screen_test');
    database = AppDatabase.forTesting(NativeDatabase.memory());
    await _seed(database);
    gateway = _RecordingGateway();
    refreshCalls = <String>[];
  });

  tearDown(() async {
    await database.close();
    try {
      if (checkpointDirectory.existsSync()) {
        checkpointDirectory.deleteSync(recursive: true);
      }
    } on FileSystemException {
      // Windows can still hold a handle on a just-written checkpoint; a
      // leftover temp directory is not a test failure.
    }
  });

  Future<void> pumpScreen(
    WidgetTester tester, {
    List<Override> extraOverrides = const <Override>[],
    BackupDownloadsWriter? downloadsWriter,
    BackupDocumentGateway? documentGateway,
    // A tall viewport so the whole scrollable flow is built; the responsive
    // test passes real device sizes explicitly.
    Size size = const Size(420, 4200),
  }) async {
    setLogicalViewSize(tester, size);
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          appDatabaseProvider.overrideWithValue(database),
          backupDocumentGatewayProvider
              .overrideWithValue(documentGateway ?? gateway),
          checkpointKeyStoreProvider.overrideWithValue(_MemoryKeyStore()),
          checkpointDirectoryProvider.overrideWithValue(
            () async => checkpointDirectory,
          ),
          diagnosticsProvider.overrideWithValue(SanitizedDiagnostics()),
          if (downloadsWriter != null)
            backupDownloadsWriterProvider.overrideWithValue(downloadsWriter),
          // The real refresh re-resolves the whole app; the flow's own tests
          // replace it so the screen tests stay about the screen.
          backupPostRestoreRefreshProvider.overrideWithValue(
            () async => refreshCalls.add('refresh'),
          ),
          ...extraOverrides,
        ],
        child: const MaterialApp(home: BackupRecoveryScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// What the screen says right now, if anything.
  String? messageOf(WidgetTester tester) {
    final finder = find.byKey(const Key('backup-message'));
    if (finder.evaluate().isEmpty) {
      return null;
    }
    return tester.widget<Text>(finder).data;
  }

  String? textOf(WidgetTester tester, Key key) {
    final finder = find.byKey(key);
    if (finder.evaluate().isEmpty) {
      return null;
    }
    return tester.widget<Text>(finder).data;
  }

  /// The headline of the transient acknowledgement currently on screen, if
  /// any.
  String? noticeOf(WidgetTester tester) {
    return textOf(tester, const Key('backup-notice-title'));
  }

  /// The acknowledgement's explanatory second line, when it has one.
  String? noticeBodyOf(WidgetTester tester) {
    return textOf(tester, const Key('backup-notice-body'));
  }

  /// A restore touches real files (the pre-restore recovery checkpoint), so
  /// alternate real time with pumping until the operation has reported.
  Future<void> settleRestore(WidgetTester tester) async {
    for (var attempt = 0; attempt < 40; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
      if (noticeOf(tester) != null || messageOf(tester) != null) {
        break;
      }
    }
    await tester.pumpAndSettle();
  }

  /// Produces a real backup through the same service the button uses.
  Future<Uint8List> seedBackupBytes() async {
    final container = ProviderContainer(
      overrides: <Override>[
        appDatabaseProvider.overrideWithValue(database),
        backupDocumentGatewayProvider.overrideWithValue(gateway),
        checkpointKeyStoreProvider.overrideWithValue(_MemoryKeyStore()),
        checkpointDirectoryProvider.overrideWithValue(
          () async => checkpointDirectory,
        ),
        diagnosticsProvider.overrideWithValue(SanitizedDiagnostics()),
      ],
    );
    addTearDown(container.dispose);
    await container.read(backupServiceProvider).createBackup(
          profileId: 'profile-widget',
        );
    return gateway.saved!;
  }

  group('two actions, no jargon', () {
    testWidgets('the screen offers exactly the two user actions',
        (tester) async {
      await pumpScreen(tester);

      expect(find.byKey(const Key('backup-create-button')), findsOneWidget);
      expect(find.byKey(const Key('backup-restore-button')), findsOneWidget);
      expect(find.text('Back up your data'), findsOneWidget);
      expect(find.text('Restore your backup'), findsOneWidget);
      expect(
        find.text('Create a backup of your Next Transfer data.'),
        findsOneWidget,
      );
      expect(
        find.text('Restore your Next Transfer data from a backup file.'),
        findsOneWidget,
      );
      expect(
        find.text(
          'Keep your Next Transfer data safe when moving to another install '
          'or device.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('no implementation vocabulary reaches the user',
        (tester) async {
      await pumpScreen(tester);

      for (final jargon in <String>[
        'Passphrase',
        'Confirm passphrase',
        'Replace local data',
        'Merge with local data',
        'Packages to restore',
        'domain',
        'Payload',
        'Recovery checkpoint',
        'Create readable export',
        'JSON',
        'CSV',
        'Schema',
      ]) {
        expect(
          find.textContaining(jargon),
          findsNothing,
          reason: 'user-visible screen must not say "$jargon"',
        );
      }
    });

    testWidgets('there is no passphrase field and no package selector',
        (tester) async {
      await pumpScreen(tester);

      expect(find.byKey(const Key('backup-passphrase-field')), findsNothing);
      expect(find.byKey(const Key('backup-package-selector')), findsNothing);
      expect(find.byKey(const Key('backup-export-button')), findsNothing);
      expect(find.byKey(const Key('backup-mode-merge')), findsNothing);
      expect(find.byKey(const Key('backup-mode-replace')), findsNothing);
      expect(find.byType(TextField), findsNothing);
    });
  });

  group('back up your data', () {
    testWidgets('one tap writes a real, readable backup', (tester) async {
      final downloads = _FakeDownloadsWriter();
      await pumpScreen(tester, downloadsWriter: downloads);

      await tester.tap(find.byKey(const Key('backup-create-button')));
      await tester.pumpAndSettle();

      // One acknowledgement, in plain language, and the screen is back to its
      // two actions.
      expect(noticeOf(tester), 'Backup created — saved to Downloads');
      expect(find.byKey(const Key('backup-create-button')), findsOneWidget);
      expect(find.byKey(const Key('backup-restore-button')), findsOneWidget);
      expect(find.byKey(const Key('backup-done-button')), findsNothing);
      // The user never had to name anything or choose anywhere.
      expect(gateway.saveCalls, 0);
      expect(find.byType(TextField), findsNothing);

      final saved = downloads.lastFileName;
      expect(saved, isNotNull);
      expect(
        saved,
        matches(
          RegExp(
            r'^NextTransfer_Backup_\d{4}-\d{2}-\d{2}_\d{6}\.ntbackup$',
          ),
        ),
      );
    });

    testWidgets('falls back to a chosen destination when Downloads is '
        'unavailable', (tester) async {
      final downloads = _FakeDownloadsWriter(supported: false);
      await pumpScreen(tester, downloadsWriter: downloads);

      await tester.tap(find.byKey(const Key('backup-create-button')));
      await tester.pumpAndSettle();

      // Tried Downloads first, then asked the platform picker exactly once.
      expect(downloads.writes, 1);
      expect(gateway.saveCalls, 1);
      expect(
        noticeOf(tester),
        'Backup created — saved to the location you chose',
      );
    });

    testWidgets('the saved file is unprotected and opens with no credential',
        (tester) async {
      final downloads = _FakeDownloadsWriter();
      await pumpScreen(tester, downloadsWriter: downloads);

      await tester.tap(find.byKey(const Key('backup-create-button')));
      await tester.pumpAndSettle();

      final header = BackupContainer.parseHeader(downloads.lastBytes!);
      expect(header.protectionId, BackupFormat.noneProtectionId);
      expect(header.isProtected, isFalse);
    });

    testWidgets('everything the registry classifies as user data is included',
        (tester) async {
      final downloads = _FakeDownloadsWriter();
      await pumpScreen(tester, downloadsWriter: downloads);

      await tester.tap(find.byKey(const Key('backup-create-button')));
      await tester.pumpAndSettle();

      // The user chose nothing; the registry decided. The file therefore has
      // to carry every domain the registry calls user state, not a subset the
      // screen happened to offer.
      final payload = BackupPayloadCodec.decode(
        BackupContainer.parseHeader(downloads.lastBytes!).body,
        currentSchema: database.schemaVersion,
      );
      expect(
        payload.manifest.includedDomains,
        BackupDomainRegistry.populatedDomains,
      );
      expect(payload.manifest.totalRows, greaterThan(1));
    });
  });

  group('restore your backup', () {
    testWidgets('shows one understandable confirmation before writing',
        (tester) async {
      gateway.toPick = await seedBackupBytes();
      await pumpScreen(tester);

      await tester.tap(find.byKey(const Key('backup-restore-button')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('backup-restore-confirm-card')),
        findsOneWidget,
      );
      expect(find.text('Restore this backup?'), findsOneWidget);
      expect(
        find.text(
          'Restoring will replace the Next Transfer data currently on this '
          'device.',
        ),
        findsOneWidget,
      );
      expect(find.byKey(const Key('backup-restore-date')), findsOneWidget);
      // Nothing technical, nothing acknowledged, and nothing written yet.
      expect(noticeOf(tester), isNull);
      final tasks = await database
          .customSelect('SELECT COUNT(*) AS c FROM planner_tasks')
          .getSingle();
      expect(tasks.read<int>('c'), 1);
    });

    testWidgets('Cancel writes nothing and dismisses the confirmation',
        (tester) async {
      gateway.toPick = await seedBackupBytes();
      await pumpScreen(tester);

      await tester.tap(find.byKey(const Key('backup-restore-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('backup-restore-cancel')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('backup-restore-confirm-card')),
        findsNothing,
      );
      expect(noticeOf(tester), isNull);
      expect(messageOf(tester), isNull);
    });

    testWidgets('restores the whole profile and reloads exactly once',
        (tester) async {
      gateway.toPick = await seedBackupBytes();
      final reconcileCalls = <String>[];
      await pumpScreen(
        tester,
        size: const Size(420, 9000),
        extraOverrides: <Override>[
          backupPostRestoreReconcilerProvider.overrideWithValue(
            (profileId) async => reconcileCalls.add(profileId),
          ),
        ],
      );

      await tester.tap(find.byKey(const Key('backup-restore-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('backup-restore-confirm')));
      await tester.pump();
      await settleRestore(tester);

      final failureMessage = messageOf(tester);
      if (failureMessage != null) {
        fail('The restore reported: $failureMessage');
      }

      expect(noticeOf(tester), 'Data restored');
      expect(
        noticeBodyOf(tester),
        'Please close and reopen Next Transfer to refresh all restored data.',
      );
      // The user stays exactly where they were, with no Done to press and no
      // result card left behind: the acknowledgement never navigates.
      expect(find.byType(BackupRecoveryScreen), findsOneWidget);
      expect(find.text('Backup & Restore'), findsOneWidget);
      expect(find.byKey(const Key('backup-create-button')), findsOneWidget);
      expect(find.byKey(const Key('backup-restore-button')), findsOneWidget);
      expect(find.byKey(const Key('backup-done-button')), findsNothing);
      expect(
        find.byKey(const Key('backup-restore-confirm-card')),
        findsNothing,
      );
      final tasks = await database
          .customSelect('SELECT COUNT(*) AS c FROM planner_tasks')
          .getSingle();
      expect(tasks.read<int>('c'), 1);
      expect(reconcileCalls, <String>['profile-widget']);
      // A restore replaces every row the UI had cached, so the app re-resolves
      // exactly once.
      expect(refreshCalls, <String>['refresh']);
    });

    testWidgets('a real post-restore warning replaces the generic guidance',
        (tester) async {
      // The canonical restore commits, then reminder reconciliation fails.
      // The acknowledgement must explain that — not send the user away with
      // the ordinary "close and reopen" sentence as if all was well.
      gateway.toPick = await seedBackupBytes();
      await pumpScreen(
        tester,
        size: const Size(420, 9000),
        extraOverrides: <Override>[
          backupPostRestoreReconcilerProvider.overrideWithValue(
            (profileId) async => throw StateError('no reminder scheduler'),
          ),
        ],
      );

      await tester.tap(find.byKey(const Key('backup-restore-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('backup-restore-confirm')));
      await tester.pump();
      await settleRestore(tester);

      expect(noticeOf(tester), 'Data restored');
      expect(
        noticeBodyOf(tester),
        'Your data was restored, but reminder schedules could not be rebuilt. '
        'They will be rebuilt the next time Next Transfer starts.',
      );
      // Still not a failure: the canonical data really is restored.
      expect(messageOf(tester), isNull);
      final tasks = await database
          .customSelect('SELECT COUNT(*) AS c FROM planner_tasks')
          .getSingle();
      expect(tasks.read<int>('c'), 1);
    });

    testWidgets('a file that is not a backup is refused truthfully',
        (tester) async {
      gateway.toPick = Uint8List.fromList(<int>[1, 2, 3, 4, 5, 6, 7, 8, 9]);
      await pumpScreen(tester);

      await tester.tap(find.byKey(const Key('backup-restore-button')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('backup-restore-confirm-card')),
        findsNothing,
      );
      expect(messageOf(tester), 'That file is not a Next Transfer backup.');
      final tasks = await database
          .customSelect('SELECT COUNT(*) AS c FROM planner_tasks')
          .getSingle();
      expect(tasks.read<int>('c'), 1);
    });

    testWidgets('cancelling the file picker says so without changing data',
        (tester) async {
      await pumpScreen(tester);

      await tester.tap(find.byKey(const Key('backup-restore-button')));
      await tester.pumpAndSettle();

      expect(messageOf(tester), 'No backup was selected.');
    });

    testWidgets('a failure replaces the earlier success instead of stacking on '
        'it', (tester) async {
      final downloads = _FakeDownloadsWriter();
      await pumpScreen(tester, downloadsWriter: downloads);

      await tester.tap(find.byKey(const Key('backup-create-button')));
      await tester.pumpAndSettle();
      expect(noticeOf(tester), 'Backup created — saved to Downloads');

      // Now a restore that cannot even be read. The owner saw exactly this
      // shape of contradiction: an old success card still visible underneath a
      // new failure.
      gateway.toPick = Uint8List.fromList(<int>[9, 9, 9]);
      await tester.tap(find.byKey(const Key('backup-restore-button')));
      await tester.pumpAndSettle();

      expect(messageOf(tester), 'That file is not a Next Transfer backup.');
      expect(
        noticeOf(tester),
        isNull,
        reason: 'the screen must never imply success and failure at once',
      );
    });

    testWidgets('starting an operation clears the previous acknowledgement',
        (tester) async {
      final downloads = _FakeDownloadsWriter();
      await pumpScreen(tester, downloadsWriter: downloads);

      await tester.tap(find.byKey(const Key('backup-create-button')));
      await tester.pumpAndSettle();
      expect(noticeOf(tester), isNotNull);

      // Cancel out of the file picker: a new operation has begun, so the old
      // acknowledgement is gone.
      await tester.tap(find.byKey(const Key('backup-restore-button')));
      await tester.pumpAndSettle();
      expect(noticeOf(tester), isNull);
    });

    testWidgets('the backup button says what it is doing while it runs',
        (tester) async {
      final downloads = _FakeDownloadsWriter();
      await pumpScreen(tester, downloadsWriter: downloads);

      // Held open so the running state is observable rather than already over.
      downloads.gate = Completer<void>();
      await tester.tap(find.byKey(const Key('backup-create-button')));
      await tester.pump();

      expect(find.text('Backing up your data…'), findsOneWidget);
      expect(find.text('Back up your data'), findsNothing);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('backup-create-button')))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(const Key('backup-restore-button')),
            )
            .onPressed,
        isNull,
      );

      downloads.gate!.complete();
      await tester.pumpAndSettle();
      expect(noticeOf(tester), 'Backup created — saved to Downloads');
    });

    testWidgets('a double tap still creates exactly one backup file',
        (tester) async {
      final downloads = _FakeDownloadsWriter();
      await pumpScreen(tester, downloadsWriter: downloads);

      downloads.gate = Completer<void>();
      await tester.tap(find.byKey(const Key('backup-create-button')));
      await tester.pump();
      // The second tap lands on a disabled button while the first operation is
      // still in flight, so exactly one file is ever written.
      await tester.tap(
        find.byKey(const Key('backup-create-button')),
        warnIfMissed: false,
      );
      await tester.pump();
      expect(downloads.writes, 0, reason: 'still running');

      downloads.gate!.complete();
      await tester.pumpAndSettle();

      expect(downloads.writes, 1);
      expect(noticeOf(tester), 'Backup created — saved to Downloads');
    });

    testWidgets('a destination that stores fewer bytes is never called a backup',
        (tester) async {
      await pumpScreen(
        tester,
        documentGateway: _ShortWriteGateway(),
      );

      await tester.tap(find.byKey(const Key('backup-create-button')));
      await tester.pumpAndSettle();

      expect(
        messageOf(tester),
        "Next Transfer couldn't save the backup file.",
      );
      expect(noticeOf(tester), isNull);
    });
  });

  group('responsive', () {
    testWidgets('renders on phone, compact landscape and tablet',
        (tester) async {
      for (final size in <Size>[
        const Size(393, 874),
        const Size(874, 393),
        const Size(1024, 640),
      ]) {
        await pumpScreen(tester, size: size);
        expect(tester.takeException(), isNull, reason: '$size');
        expect(find.byKey(const Key('backup-create-button')), findsOneWidget);
        expect(find.byKey(const Key('backup-restore-button')), findsOneWidget);
      }
    });

    testWidgets('survives a 1.3 text scale', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      await pumpScreen(tester, size: const Size(393, 874));

      expect(tester.takeException(), isNull);
      final listScrollable = find.descendant(
        of: find.byType(ListView),
        matching: find.byType(Scrollable),
      );
      await tester.scrollUntilVisible(
        find.byKey(const Key('backup-restore-button')),
        300,
        scrollable: listScrollable.first,
      );
      expect(tester.takeException(), isNull);
    });
  });
}
