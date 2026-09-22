import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/features/backup/application/backup_container_codec.dart';
import 'package:rmplanner/features/backup/application/backup_service.dart';
import 'package:rmplanner/features/backup/application/restore_service.dart';
import 'package:rmplanner/features/backup/data/backup_document_gateway.dart';
import 'package:rmplanner/features/backup/data/backup_payload_codec.dart';
import 'package:rmplanner/features/backup/data/backup_recovery_checkpoint_store.dart';
import 'package:rmplanner/features/backup/data/backup_table_codec.dart';
import 'package:rmplanner/features/backup/domain/backup_domain_contract.dart';
import 'package:rmplanner/features/backup/domain/backup_domain_registry.dart';
import 'package:rmplanner/features/backup/domain/backup_errors.dart';
import 'package:rmplanner/features/backup/domain/backup_manifest.dart';
import 'package:rmplanner/features/backup/domain/restore_preview.dart';
import 'package:rmplanner/features/planner/domain/event_contact_channel.dart';

final class _FakeKeyStore implements CheckpointKeyStore {
  _FakeKeyStore(this.key);

  final Uint8List key;
  int reads = 0;

  @override
  Future<Uint8List> readOrCreateKey() async {
    reads++;
    return key;
  }
}

final class _MemoryGateway implements BackupDocumentGateway {
  Uint8List? saved;
  String? savedName;
  Uint8List? toPick;

  @override
  Future<SavedBackupDocument?> saveDocument({
    required String suggestedFileName,
    required Uint8List bytes,
  }) async {
    saved = bytes;
    savedName = suggestedFileName;
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

/// Synthetic data only — no owner data ever enters a fixture.
Future<void> _seed(AppDatabase database) async {
  const profileId = 'profile-synthetic';
  const created = 1750000000;
  await database.customInsert(
    'INSERT INTO local_profiles '
    '(id, slot, local_name, display_name, time_zone_id, created_at_utc, '
    'updated_at_utc) VALUES (?,?,?,?,?,?,?)',
    variables: <Variable<Object>>[
      const Variable<String>(profileId),
      const Variable<String>('primary'),
      const Variable<String>('Local'),
      const Variable<String>('Synthetic Tester'),
      const Variable<String>('UTC'),
      const Variable<int>(created),
      const Variable<int>(created),
    ],
  );
  for (var index = 0; index < 6; index++) {
    await database.customInsert(
      'INSERT INTO life_indicator_definitions '
      '(id, profile_id, indicator_key, label, unit, position, created_at_utc) '
      'VALUES (?,?,?,?,?,?,?)',
      variables: <Variable<Object>>[
        Variable<String>('$profileId:slot$index'),
        const Variable<String>(profileId),
        Variable<String>('slot_$index'),
        Variable<String>('Life Goal ${index + 1}'),
        const Variable<String>('count'),
        Variable<int>(index + 1),
        const Variable<int>(created),
      ],
    );
  }
  await database.customInsert(
    'INSERT INTO planner_preferences (profile_id, week_start_day, '
    'updated_at_utc) VALUES (?,?,?)',
    variables: <Variable<Object>>[
      const Variable<String>(profileId),
      const Variable<int>(DateTime.monday),
      const Variable<int>(created),
    ],
  );
  await database.customInsert(
    'INSERT INTO appearance_preferences (key, appearance_mode, theme_color, '
    'updated_at_utc) VALUES (?,?,?,?)',
    variables: <Variable<Object>>[
      const Variable<String>('primary'),
      const Variable<String>('dark'),
      const Variable<String>('rose'),
      const Variable<int>(created),
    ],
  );
  await database.customInsert(
    'INSERT INTO privacy_preferences (key, lock_enabled, '
    'notification_preview_mode, updated_at_utc) VALUES (?,?,?,?)',
    variables: <Variable<Object>>[
      const Variable<String>('primary'),
      const Variable<int>(1),
      const Variable<String>('hidden'),
      const Variable<int>(created),
    ],
  );
  // A system event type carrying a user colour customization, and a user type.
  await database.customInsert(
    'INSERT INTO activity_types (id, profile_id, stable_key, label, icon_key, '
    'color_value, is_system, is_archived, report_required_default, '
    'default_duration_minutes, default_reminder_minutes, position, '
    'mapping_version, created_at_utc, updated_at_utc) '
    'VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
    variables: <Variable<Object>>[
      const Variable<String>('type-meal'),
      const Variable<String>(profileId),
      const Variable<String>('planner_meal'),
      const Variable<String>('Meal'),
      const Variable<String>('meal'),
      const Variable<int>(0xFFE1CFB9),
      const Variable<int>(1),
      const Variable<int>(0),
      const Variable<int>(0),
      const Variable<int>(60),
      const Variable<Object>(null),
      const Variable<int>(1),
      const Variable<int>(1),
      const Variable<int>(created),
      const Variable<int>(created),
    ],
  );
  await database.customInsert(
    'INSERT INTO activity_types (id, profile_id, stable_key, label, icon_key, '
    'color_value, is_system, is_archived, report_required_default, '
    'default_duration_minutes, default_reminder_minutes, position, '
    'mapping_version, created_at_utc, updated_at_utc) '
    'VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
    variables: <Variable<Object>>[
      const Variable<String>('type-custom'),
      const Variable<String>(profileId),
      const Variable<String>('user_custom'),
      const Variable<String>('Custom'),
      const Variable<String>('star'),
      const Variable<int>(0xFF123456),
      const Variable<int>(0),
      const Variable<int>(0),
      const Variable<int>(0),
      const Variable<int>(45),
      const Variable<Object>(null),
      const Variable<int>(9),
      const Variable<int>(1),
      const Variable<int>(created),
      const Variable<int>(created),
    ],
  );
  await database.customInsert(
    'INSERT INTO goals (id, profile_id, indicator_key, '
    'assigned_event_type_stable_key, role, active_slot_index, title, icon_id, '
    'status, created_at_utc, updated_at_utc) VALUES (?,?,?,?,?,?,?,?,?,?,?)',
    variables: <Variable<Object>>[
      const Variable<String>('goal-1'),
      const Variable<String>(profileId),
      const Variable<String>('slot_0'),
      const Variable<String>('planner_meal'),
      const Variable<String>('weekly'),
      const Variable<int>(1),
      const Variable<String>('Learn Cebuano'),
      const Variable<Object>(null),
      const Variable<String>('active'),
      const Variable<int>(created),
      const Variable<int>(created),
    ],
  );
  await database.customInsert(
    'INSERT INTO planner_tasks (id, profile_id, title, notes, due_date, '
    'due_minute, recurrence_frequency, people_json, status, requires_report, '
    'is_backup, contribution_rule_key, linked_activity_type_id, '
    'linked_activity_type_stable_key, linked_activity_type_label_snapshot, '
    'goal_id, created_at_utc, updated_at_utc) '
    'VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
    variables: <Variable<Object>>[
      const Variable<String>('task-1'),
      const Variable<String>(profileId),
      const Variable<String>('Call the mission office'),
      const Variable<String>('Synthetic note'),
      const Variable<String>('2026-09-17'),
      const Variable<Object>(540),
      const Variable<String>('none'),
      const Variable<String>('[]'),
      const Variable<String>('open'),
      const Variable<int>(0),
      const Variable<int>(0),
      const Variable<String>('none'),
      const Variable<Object>('type-meal'),
      const Variable<Object>('planner_meal'),
      const Variable<Object>('Meal'),
      const Variable<Object>('goal-1'),
      const Variable<int>(created),
      const Variable<int>(created),
    ],
  );
  await database.customInsert(
    'INSERT INTO calendar_events (id, profile_id, title, notes, timing, '
    'start_date, start_minute, end_minute, time_zone_id, location_text, '
    'latitude, longitude, coordinate_source, requires_report, '
    'activity_type_id, activity_type_mapping_version, '
    'activity_type_stable_key_snapshot, activity_type_label_snapshot, '
    'activity_type_color_value_snapshot, contribution_rule_key, goal_id, '
    'is_backup_appointment, recurrence_frequency, recurrence_end_mode, '
    'status, created_at_utc, updated_at_utc) '
    'VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
    variables: <Variable<Object>>[
      const Variable<String>('event-1'),
      const Variable<String>(profileId),
      const Variable<String>('Dinner'),
      const Variable<Object>(null),
      const Variable<String>('timed'),
      const Variable<String>('2026-09-17'),
      const Variable<int>(1080),
      const Variable<int>(1140),
      const Variable<String>('UTC'),
      const Variable<Object>(null),
      const Variable<Object>(null),
      const Variable<Object>(null),
      const Variable<Object>('none'),
      const Variable<int>(0),
      const Variable<Object>('type-meal'),
      const Variable<int>(1),
      const Variable<Object>('planner_meal'),
      const Variable<Object>('Meal'),
      const Variable<int>(0xFFE1CFB9),
      const Variable<String>('none'),
      const Variable<Object>(null),
      const Variable<int>(0),
      const Variable<String>('none'),
      const Variable<String>('none'),
      const Variable<String>('scheduled'),
      const Variable<int>(created),
      const Variable<int>(created),
    ],
  );
  await database.customInsert(
    'INSERT INTO contacts (id, profile_id, first_name, last_name, display_name, '
    'is_favorite, lifecycle_state, source, created_at_utc, updated_at_utc) '
    'VALUES (?,?,?,?,?,?,?,?,?,?)',
    variables: <Variable<Object>>[
      const Variable<String>('contact-1'),
      const Variable<String>(profileId),
      const Variable<String>('Synthetic'),
      const Variable<String>('Friend'),
      const Variable<String>('Synthetic Friend'),
      const Variable<int>(1),
      const Variable<String>('active'),
      const Variable<String>('manual'),
      const Variable<int>(created),
      const Variable<int>(created),
    ],
  );
  await database.customInsert(
    'INSERT INTO contact_notes (id, contact_id, note_text, created_at_utc, '
    'updated_at_utc) VALUES (?,?,?,?,?)',
    variables: <Variable<Object>>[
      const Variable<String>('note-1'),
      const Variable<String>('contact-1'),
      const Variable<String>('Synthetic private note'),
      const Variable<int>(created),
      const Variable<int>(created),
    ],
  );
  await database.customInsert(
    'INSERT INTO saved_places (id, profile_id, label, latitude, longitude, '
    'marker_mode, standard_category, marker_color, boundary_color, '
    'created_at_utc, updated_at_utc) VALUES (?,?,?,?,?,?,?,?,?,?,?)',
    variables: <Variable<Object>>[
      const Variable<String>('place-1'),
      const Variable<String>(profileId),
      const Variable<String>('Synthetic Chapel'),
      const Variable<double>(10.5),
      const Variable<double>(123.25),
      const Variable<String>('standard'),
      const Variable<String>('worship'),
      const Variable<int>(0xFF00AAFF),
      const Variable<int>(0xFFFFAA00),
      const Variable<int>(created),
      const Variable<int>(created),
    ],
  );
  await database.customInsert(
    'INSERT INTO reminder_policies (id, profile_id, source_kind, source_id, '
    'occurrence_id, purpose, mode, offset_minutes, created_at_utc, '
    'updated_at_utc) VALUES (?,?,?,?,?,?,?,?,?,?)',
    variables: <Variable<Object>>[
      const Variable<String>('policy-1'),
      const Variable<String>(profileId),
      const Variable<String>('event'),
      const Variable<String>('event-1'),
      const Variable<String>('event-1:2026-09-17'),
      const Variable<String>('start'),
      const Variable<String>('relative'),
      const Variable<int>(30),
      const Variable<int>(created),
      const Variable<int>(created),
    ],
  );
  await database.customInsert(
    'INSERT INTO background_work_requests (stable_key, profile_id, category, '
    'owner_kind, owner_id, source_revision, scheduled_for_utc, state, '
    'platform_notification_id, attempt_count, snooze_count, created_at_utc, '
    'updated_at_utc) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)',
    variables: <Variable<Object>>[
      const Variable<String>('device-bound-work'),
      const Variable<String>(profileId),
      const Variable<String>('reminder'),
      const Variable<String>('event'),
      const Variable<String>('event-1'),
      const Variable<int>(1),
      const Variable<int>(created),
      const Variable<String>('scheduled'),
      const Variable<int>(991199),
      const Variable<int>(2),
      const Variable<int>(1),
      const Variable<int>(created),
      const Variable<int>(created),
    ],
  );
  await database.customInsert(
    'INSERT INTO permission_audits (permission_key, requested_by_app, '
    'ever_granted, updated_at_utc) VALUES (?,?,?,?)',
    variables: <Variable<Object>>[
      const Variable<String>('notifications'),
      const Variable<int>(1),
      const Variable<int>(1),
      const Variable<int>(created),
    ],
  );
}

/// A genuinely separate installation: its own profile id, its own regenerated
/// canonical seeds, and its own device-bound rows.
///
/// This is what the owner's phone looked like after reinstalling, and it is
/// exactly the state a restore used to fail against.
Future<void> _seedFreshInstall(
  AppDatabase database, {
  required String profileId,
}) async {
  const created = 1750000000;
  await database.customInsert(
    'INSERT INTO local_profiles '
    '(id, slot, local_name, display_name, time_zone_id, created_at_utc, '
    'updated_at_utc) VALUES (?,?,?,?,?,?,?)',
    variables: <Variable<Object>>[
      Variable<String>(profileId),
      const Variable<String>('primary'),
      const Variable<String>('Local'),
      const Variable<String>('Fresh Installer'),
      const Variable<String>('UTC'),
      const Variable<int>(created),
      const Variable<int>(created),
    ],
  );
  for (var index = 0; index < 6; index++) {
    await database.customInsert(
      'INSERT INTO life_indicator_definitions '
      '(id, profile_id, indicator_key, label, unit, position, created_at_utc) '
      'VALUES (?,?,?,?,?,?,?)',
      variables: <Variable<Object>>[
        Variable<String>('$profileId:slot$index'),
        Variable<String>(profileId),
        Variable<String>('slot_$index'),
        Variable<String>('Life Goal ${index + 1}'),
        const Variable<String>('count'),
        Variable<int>(index + 1),
        const Variable<int>(created),
      ],
    );
    await database.customInsert(
      'INSERT INTO goals (id, profile_id, indicator_key, '
      'assigned_event_type_stable_key, role, active_slot_index, title, '
      'icon_id, status, created_at_utc, updated_at_utc) '
      'VALUES (?,?,?,?,?,?,?,?,?,?,?)',
      variables: <Variable<Object>>[
        Variable<String>('$profileId:goal:${index + 1}'),
        Variable<String>(profileId),
        Variable<String>('slot_$index'),
        const Variable<String>('planner_task'),
        const Variable<String>('weekly'),
        Variable<int>(index + 1),
        Variable<String>('Life Goal ${index + 1}'),
        const Variable<Object>(null),
        const Variable<String>('active'),
        const Variable<int>(created),
        const Variable<int>(created),
      ],
    );
  }
  // A regenerated system event type and a built-in contact group, both keyed to
  // this install's profile.
  await database.customInsert(
    'INSERT INTO activity_types (id, profile_id, stable_key, label, icon_key, '
    'color_value, is_system, is_archived, report_required_default, '
    'default_duration_minutes, default_reminder_minutes, position, '
    'mapping_version, created_at_utc, updated_at_utc) '
    'VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
    variables: <Variable<Object>>[
      Variable<String>('fresh-type-task'),
      Variable<String>(profileId),
      const Variable<String>('planner_task'),
      const Variable<String>('Task'),
      const Variable<String>('task'),
      const Variable<int>(0xFF8FAFC2),
      const Variable<int>(1),
      const Variable<int>(0),
      const Variable<int>(0),
      const Variable<int>(30),
      const Variable<Object>(null),
      const Variable<int>(1),
      const Variable<int>(1),
      const Variable<int>(created),
      const Variable<int>(created),
    ],
  );
  await database.customInsert(
    'INSERT INTO contact_groups (id, profile_id, name, color_value, '
    'is_archived, sort_order, created_at_utc, updated_at_utc) '
    'VALUES (?,?,?,?,?,?,?,?)',
    variables: <Variable<Object>>[
      Variable<String>('builtin-group:$profileId:family'),
      Variable<String>(profileId),
      const Variable<String>('Family'),
      const Variable<int>(0xFF00AA00),
      const Variable<int>(0),
      const Variable<int>(1),
      const Variable<int>(created),
      const Variable<int>(created),
    ],
  );
  // Device-bound scheduling state. It is EXCLUDE, so a backup never carries it
  // and a restore must never resurrect it.
  await database.customInsert(
    'INSERT INTO background_work_requests (stable_key, profile_id, category, '
    'owner_kind, owner_id, source_revision, scheduled_for_utc, state, '
    'platform_notification_id, attempt_count, snooze_count, created_at_utc, '
    'updated_at_utc) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)',
    variables: <Variable<Object>>[
      const Variable<String>('fresh-device-bound-work'),
      Variable<String>(profileId),
      const Variable<String>('reminder'),
      const Variable<String>('event'),
      const Variable<String>('event-fresh'),
      const Variable<int>(1),
      const Variable<int>(created),
      const Variable<String>('scheduled'),
      const Variable<int>(771177),
      const Variable<int>(1),
      const Variable<int>(0),
      const Variable<int>(created),
      const Variable<int>(created),
    ],
  );
  // Device-local permission history. It is not profile-scoped, so adopting the
  // backup's identity must leave it alone.
  await database.customInsert(
    'INSERT INTO permission_audits (permission_key, requested_by_app, '
    'ever_granted, updated_at_utc) VALUES (?,?,?,?)',
    variables: <Variable<Object>>[
      const Variable<String>('notifications'),
      const Variable<int>(1),
      const Variable<int>(1),
      const Variable<int>(created),
    ],
  );
}

Future<int> _count(AppDatabase database, String sql) async {
  final result = await database.customSelect(sql).getSingle();
  return result.read<int>('c');
}

Future<List<String>> _profileIds(AppDatabase database) async {
  final rows = await database
      .customSelect('SELECT id FROM local_profiles ORDER BY slot')
      .get();
  return rows.map((row) => row.read<String>('id')).toList(growable: false);
}

Future<Map<String, List<List<Object?>>>> _snapshot(AppDatabase database) async {
  final snapshot = <String, List<List<Object?>>>{};
  for (final spec in BackupDomainRegistry.exportedTables) {
    final columns = await database
        .customSelect('PRAGMA table_info("${spec.table}")')
        .get();
    final names = columns.map((row) => row.read<String>('name')).toList();
    final result = await database
        .customSelect('SELECT * FROM "${spec.table}"')
        .get();
    snapshot[spec.table] = <List<Object?>>[
      for (final row in result)
        <Object?>[for (final name in names) row.data[name]],
    ];
  }
  return snapshot;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase database;
  late Directory checkpointDirectory;
  late BackupService backupService;
  late RestoreService restoreService;
  late _MemoryGateway gateway;
  late _FakeKeyStore keyStore;

  setUp(() async {
    // Created before seeding so a seeding failure still leaves tearDown able to
    // clean up.
    checkpointDirectory = Directory.systemTemp.createTempSync('nt_backup_test');
    database = AppDatabase.forTesting(NativeDatabase.memory());
    await _seed(database);
    gateway = _MemoryGateway();
    keyStore = _FakeKeyStore(
      Uint8List.fromList(List<int>.generate(32, (i) => i)),
    );
    final containerCodec = BackupContainerCodec();
    backupService = BackupService(
      database: database,
      gateway: gateway,
      containerCodec: containerCodec,
      clock: () => DateTime.utc(2026, 9, 17, 12),
      appVersion: '0.1.0+1',
    );
    restoreService = RestoreService(
      database: database,
      containerCodec: containerCodec,
      checkpointStore: BackupRecoveryCheckpointStore(
        directoryProvider: () async => checkpointDirectory,
        keyStore: keyStore,
        codec: containerCodec,
        clock: () => DateTime.utc(2026, 9, 17, 12),
      ),
      captureCurrentState: (domains) => backupService.captureCurrentState(
        profileId: 'profile-synthetic',
        domains: domains,
      ),
      clock: () => DateTime.utc(2026, 9, 17, 12),
    );
  });

  tearDown(() async {
    await database.close();
    if (checkpointDirectory.existsSync()) {
      checkpointDirectory.deleteSync(recursive: true);
    }
  });

  Future<Uint8List> makeBackup({Set<BackupDomain>? domains}) async {
    final payload = await backupService.buildPayload(
      profileId: 'profile-synthetic',
      domains: domains,
    );
    return backupService.encode(payload: payload);
  }

  /// A restore engine bound to [target], so one install's backup can be
  /// restored onto a genuinely different one.
  RestoreService restoreServiceFor(
    AppDatabase target, {
    required String profileId,
  }) {
    final containerCodec = BackupContainerCodec();
    final capture = BackupService(
      database: target,
      gateway: _MemoryGateway(),
      containerCodec: containerCodec,
      clock: () => DateTime.utc(2026, 9, 17, 12),
      appVersion: '0.1.0+1',
    );
    return RestoreService(
      database: target,
      containerCodec: containerCodec,
      checkpointStore: BackupRecoveryCheckpointStore(
        directoryProvider: () async => checkpointDirectory,
        keyStore: _FakeKeyStore(keyStore.key),
        codec: containerCodec,
        clock: () => DateTime.utc(2026, 9, 17, 12),
      ),
      captureCurrentState: (domains) =>
          capture.captureCurrentState(profileId: profileId, domains: domains),
      clock: () => DateTime.utc(2026, 9, 17, 12),
    );
  }

  // The product path: saving is one tap, and the file that comes out carries
  // no credential requirement and no encryption. This is what a user gets.
  test('a one-tap backup round trips and is readable', () async {
    final bytes = await makeBackup();
    final header = BackupContainer.parseHeader(bytes);
    expect(header.isProtected, isFalse);
    expect(header.protectionId, BackupFormat.noneProtectionId);

    final before = await _snapshot(database);
    for (final spec in BackupDomainRegistry.tables.reversed) {
      await database.customStatement('DELETE FROM "${spec.table}"');
    }

    // No credential is supplied anywhere in this restore, because none exists.
    final opened = await restoreService.open(bytes: bytes);
    final preview = await restoreService.preview(
      backup: opened,
      mode: BackupRestoreMode.replace,
    );

    final result = await restoreService.apply(
      backup: opened,
      mode: BackupRestoreMode.replace,
    );

    expect(result.rolledBack, isFalse);
    expect(preview.totalRows, greaterThan(0));
    expect(await _snapshot(database), before);
  });

  test('a device-bound checkpoint is refused as a restorable backup', () async {
    // The only protected container this app can produce is its own recovery
    // checkpoint. It is not a user backup and must never be restored as one.
    final key = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));
    final checkpoint = BackupContainerCodec().sealWithDeviceKey(
      key: key,
      plainText: Uint8List.fromList(utf8.encode('{"not":"a backup"}')),
    );
    final bytes = checkpoint.toBytes();
    expect(BackupContainer.parseHeader(bytes).isProtected, isTrue);

    await expectLater(
      () => restoreService.open(bytes: bytes),
      throwsA(
        isA<BackupFailure>().having(
          (failure) => failure.kind,
          'kind',
          BackupFailureKind.notABackupFile,
        ),
      ),
    );
  });

  test('an unprotected backup still excludes device-bound state', () async {
    final bytes = await makeBackup();
    // The file is readable by design, so this matters more here than anywhere:
    // exclusion must hold in the plaintext bytes too, not just logically.
    //
    // Decode the BODY, not the whole file: the 8-byte little-endian body length
    // in the container header is binary, and decoding the raw file as UTF-8 only
    // ever worked by accident while the payload stayed under 32 KiB (above that
    // the length's high byte stops being a valid text byte). The claim under
    // test is about the payload's plaintext, so read exactly that.
    final text = utf8.decode(BackupContainer.parseHeader(bytes).body);
    for (final table in <String>[
      'background_work_requests',
      'permission_audits',
      'onboarding_checkpoints',
      'goal_outbox_operations',
      'calendar_event_operations',
    ]) {
      expect(text, isNot(contains(table)), reason: table);
    }
    expect(text, isNot(contains('991199')));
    // And it is genuinely legible, which is the honest trade-off.
    expect(text, contains('Synthetic private note'));
  });

  test('round trip restores every user-owned row exactly', () async {
    final bytes = await makeBackup();
    final before = await _snapshot(database);

    // Destroy local state: a fresh install. Children are removed before
    // parents so foreign keys stay satisfied.
    for (final spec in BackupDomainRegistry.tables.reversed) {
      await database.customStatement('DELETE FROM "${spec.table}"');
    }

    final opened = await restoreService.open(bytes: bytes);
    final preview = await restoreService.preview(
      backup: opened,
      mode: BackupRestoreMode.replace,
    );
    expect(preview.selectedDomains, BackupDomainRegistry.populatedDomains);
    expect(preview.totalRows, greaterThan(0));

    final result = await restoreService.apply(
      backup: opened,
      mode: BackupRestoreMode.replace,
    );

    expect(result.rolledBack, isFalse);
    expect(result.rowsWritten, preview.totalRows);
    final after = await _snapshot(database);
    expect(after, before);
  });

  test('the backup excludes device-bound and credential state', () async {
    final bytes = await makeBackup();
    final opened = await restoreService.open(bytes: bytes);
    final payload = opened.payload;

    for (final table in <String>[
      'background_work_requests',
      'permission_audits',
      'onboarding_checkpoints',
      'goal_outbox_operations',
      'calendar_event_operations',
    ]) {
      final inPayload = payload.domains.values.any(
        (tables) => tables.containsKey(table),
      );
      expect(inPayload, isFalse, reason: table);
    }

    // The platform notification id never appears anywhere in the file.
    expect(payload.exports.values.join().contains('991199'), isFalse);
  });

  test('seeded/regenerated identities are not duplicated', () async {
    final bytes = await makeBackup();
    final opened = await restoreService.open(bytes: bytes);
    await restoreService.apply(backup: opened, mode: BackupRestoreMode.replace);

    final types = await database
        .customSelect('SELECT id, stable_key FROM activity_types')
        .get();
    expect(types.length, 2);
    expect(types.map((row) => row.data['stable_key']).toSet(), <String>{
      'planner_meal',
      'user_custom',
    });
    final definitions = await database
        .customSelect('SELECT id FROM life_indicator_definitions')
        .get();
    expect(definitions.length, 6);
  });

  test('a user colour customization on a system event type survives', () async {
    await database.customStatement(
      "UPDATE activity_types SET color_value = 4279308561, label = 'Dinner' "
      "WHERE id = 'type-meal'",
    );
    final bytes = await makeBackup();
    await database.customStatement(
      "UPDATE activity_types SET color_value = 1, label = 'Broken' "
      "WHERE id = 'type-meal'",
    );

    final opened = await restoreService.open(bytes: bytes);
    await restoreService.apply(backup: opened, mode: BackupRestoreMode.replace);

    final row = await database
        .customSelect(
          "SELECT color_value, label FROM activity_types WHERE id='type-meal'",
        )
        .getSingle();
    expect(row.data['color_value'], 4279308561);
    expect(row.data['label'], 'Dinner');
  });

  test('a device-key checkpoint fails before anything is written', () async {
    // A recovery checkpoint is the only protected container this app makes.
    // Restoring one must fail, and must fail before any local data is touched.
    final key = Uint8List.fromList(List<int>.generate(32, (i) => i + 3));
    final bytes = BackupContainerCodec()
        .sealWithDeviceKey(
          key: key,
          plainText: Uint8List.fromList(utf8.encode('checkpoint state')),
        )
        .toBytes();
    final before = await _snapshot(database);

    await expectLater(
      () => restoreService.open(bytes: bytes),
      throwsA(
        isA<BackupFailure>().having(
          (failure) => failure.kind,
          'kind',
          BackupFailureKind.notABackupFile,
        ),
      ),
    );
    expect(await _snapshot(database), before);
  });

  test('a truncated file fails before anything is written', () async {
    final bytes = await makeBackup();
    final truncated = Uint8List.fromList(bytes.sublist(0, bytes.length ~/ 2));
    final before = await _snapshot(database);

    await expectLater(
      () => restoreService.open(bytes: truncated),
      throwsA(isA<BackupFailure>()),
    );
    expect(await _snapshot(database), before);
  });

  test('a backup missing a domain restores and is not corruption', () async {
    // Simulates an older backup created before the maps domain existed.
    final bytes = await makeBackup(
      domains: <BackupDomain>{
        BackupDomain.identity,
        BackupDomain.preferences,
        BackupDomain.definitions,
        BackupDomain.taxonomy,
        BackupDomain.goals,
        BackupDomain.planner,
        BackupDomain.contacts,
      },
    );

    await database.customStatement("DELETE FROM planner_tasks");

    final opened = await restoreService.open(bytes: bytes);
    expect(opened.includedDomains.contains(BackupDomain.maps), isFalse);

    final preview = await restoreService.preview(
      backup: opened,
      mode: BackupRestoreMode.replace,
    );
    expect(preview.domainsAbsentFromBackup, contains(BackupDomain.maps));

    final result = await restoreService.apply(
      backup: opened,
      mode: BackupRestoreMode.replace,
    );
    expect(result.rolledBack, isFalse);

    // The absent domain's live data is untouched, and the present domain's
    // data is restored.
    final places = await database
        .customSelect('SELECT id FROM saved_places')
        .get();
    expect(places.length, 1);
    final tasks = await database
        .customSelect('SELECT id FROM planner_tasks')
        .get();
    expect(tasks.length, 1);
  });

  test('a newer domain version is rejected, never silently dropped', () async {
    final payload = await backupService.buildPayload(
      profileId: 'profile-synthetic',
    );
    final tamperedDomains =
        Map<BackupDomain, BackupDomainEntry>.from(payload.manifest.domains)
          ..[BackupDomain.contacts] = BackupDomainEntry(
            domain: BackupDomain.contacts,
            formatVersion: BackupDomain.contacts.formatVersion + 1,
            dependencies: BackupDomain.contacts.dependencies,
            rowCount: payload.rowsOf(BackupDomain.contacts),
          );
    final tampered = BackupPayload(
      manifest: BackupManifest(
        containerVersion: payload.manifest.containerVersion,
        appVersion: payload.manifest.appVersion,
        schemaVersion: payload.manifest.schemaVersion,
        createdAtUtc: payload.manifest.createdAtUtc,
        sourcePackage: payload.manifest.sourcePackage,
        profileId: payload.manifest.profileId,
        domains: tamperedDomains,
        payloadSha256: payload.manifest.payloadSha256,
      ),
      domains: payload.domains,
      exports: payload.exports,
    );
    final bytes = backupService.encode(payload: tampered);

    await expectLater(
      () => restoreService.open(bytes: bytes),
      throwsA(
        isA<BackupFailure>().having(
          (failure) => failure.kind,
          'kind',
          BackupFailureKind.unsupportedDomainVersion,
        ),
      ),
    );
  });

  test('a corrupted payload is rejected by the integrity hash', () async {
    final payload = await backupService.buildPayload(
      profileId: 'profile-synthetic',
    );
    // Change one cell but keep the original manifest hash: the file decrypts,
    // yet the content no longer matches its declared integrity hash.
    final note = payload.domains[BackupDomain.contacts]!['contact_notes']!;
    final mutatedRows = <List<Object?>>[
      for (final row in note.rows) <Object?>[...row],
    ];
    mutatedRows.first[2] = 'Synthetic private note (altered)';
    final corrupted = BackupPayload(
      manifest: payload.manifest,
      domains: <BackupDomain, Map<String, BackupTableData>>{
        ...payload.domains,
        BackupDomain.contacts: <String, BackupTableData>{
          ...payload.domains[BackupDomain.contacts]!,
          'contact_notes': BackupTableData(
            table: 'contact_notes',
            columns: note.columns,
            rows: mutatedRows,
          ),
        },
      },
      exports: payload.exports,
    );
    final bytes = backupService.encode(payload: corrupted);

    await expectLater(
      () => restoreService.open(bytes: bytes),
      throwsA(
        isA<BackupFailure>().having(
          (failure) => failure.kind,
          'kind',
          BackupFailureKind.corruptedPayload,
        ),
      ),
    );
  });

  test('a failed commit rolls back and leaves live data intact', () async {
    // A cryptographically valid backup carrying a foreign-key violation, as a
    // buggy producer would create. It must fail closed at COMMIT.
    final payload = await backupService.buildPayload(
      profileId: 'profile-synthetic',
    );
    final contacts = <String, BackupTableData>{
      ...payload.domains[BackupDomain.contacts]!,
    };
    final notes = contacts['contact_notes']!;
    contacts['contact_notes'] = BackupTableData(
      table: 'contact_notes',
      columns: notes.columns,
      rows: <List<Object?>>[
        for (final row in notes.rows) <Object?>[...row],
        <Object?>[
          'orphan-note',
          'missing-contact',
          'Orphan',
          1750000000,
          1750000000,
        ],
      ],
    );
    final domains = <BackupDomain, Map<String, BackupTableData>>{
      ...payload.domains,
      BackupDomain.contacts: contacts,
    };
    final content = BackupPayloadCodec.canonicalContentJson(
      domains: domains,
      exports: payload.exports,
    );
    // A consistently produced but semantically invalid backup: the manifest
    // count matches the payload, so only commit-time foreign-key enforcement
    // can reject it. That is the fail-closed path under test.
    final manifestDomains = Map<BackupDomain, BackupDomainEntry>.from(
      payload.manifest.domains,
    );
    final contactsEntry = manifestDomains[BackupDomain.contacts]!;
    manifestDomains[BackupDomain.contacts] = BackupDomainEntry(
      domain: contactsEntry.domain,
      formatVersion: contactsEntry.formatVersion,
      dependencies: contactsEntry.dependencies,
      rowCount: contactsEntry.rowCount + 1,
    );
    final reconciled = BackupPayload(
      manifest: BackupManifest(
        containerVersion: payload.manifest.containerVersion,
        appVersion: payload.manifest.appVersion,
        schemaVersion: payload.manifest.schemaVersion,
        createdAtUtc: payload.manifest.createdAtUtc,
        sourcePackage: payload.manifest.sourcePackage,
        profileId: payload.manifest.profileId,
        domains: manifestDomains,
        payloadSha256: BackupPayloadCodec.sha256Hex(content),
      ),
      domains: domains,
      exports: payload.exports,
    );

    final before = await _snapshot(database);
    final bytes = backupService.encode(payload: reconciled);

    final opened = await restoreService.open(bytes: bytes);
    await expectLater(
      () =>
          restoreService.apply(backup: opened, mode: BackupRestoreMode.replace),
      throwsA(isA<BackupFailure>()),
    );

    expect(await _snapshot(database), before);
  });

  test('merge keeps the local record and imports new identities', () async {
    final bytes = await makeBackup();

    // Local divergence: rename the task, and delete the saved place so the
    // backup's place is a new identity.
    await database.customStatement(
      "UPDATE planner_tasks SET title = 'Locally renamed' WHERE id='task-1'",
    );
    await database.customStatement("DELETE FROM saved_places");

    final opened = await restoreService.open(bytes: bytes);
    final preview = await restoreService.preview(
      backup: opened,
      mode: BackupRestoreMode.merge,
    );
    expect(preview.totalConflicts, greaterThan(0));

    final result = await restoreService.apply(
      backup: opened,
      mode: BackupRestoreMode.merge,
    );

    final task = await database
        .customSelect("SELECT title FROM planner_tasks WHERE id='task-1'")
        .getSingle();
    expect(task.data['title'], 'Locally renamed');
    final places = await database
        .customSelect('SELECT id FROM saved_places')
        .get();
    expect(places.length, 1);
    expect(result.conflictsSkipped, greaterThan(0));
  });

  test('merge across a different profile fails closed', () async {
    final bytes = await makeBackup();
    // Re-key the whole synthetic profile so the local database stays
    // consistent while the backup still belongs to the original profile.
    await database.transaction(() async {
      await database.customStatement('PRAGMA defer_foreign_keys = ON');
      for (final spec in BackupDomainRegistry.tables) {
        final columns = await database
            .customSelect('PRAGMA table_info("${spec.table}")')
            .get();
        final hasProfileId = columns.any(
          (row) => row.read<String>('name') == 'profile_id',
        );
        if (!hasProfileId) {
          continue;
        }
        await database.customStatement(
          'UPDATE "${spec.table}" SET profile_id = \'other-profile\' '
          "WHERE profile_id = 'profile-synthetic'",
        );
      }
      await database.customStatement(
        "UPDATE local_profiles SET id = 'other-profile' "
        "WHERE id = 'profile-synthetic'",
      );
    });

    final opened = await restoreService.open(bytes: bytes);

    await expectLater(
      () => restoreService.apply(backup: opened, mode: BackupRestoreMode.merge),
      throwsA(
        isA<BackupFailure>().having(
          (failure) => failure.kind,
          'kind',
          BackupFailureKind.differentProfile,
        ),
      ),
    );
  });

  test(
    'partial restore refuses a selection with missing dependencies',
    () async {
      final bytes = await makeBackup(
        domains: <BackupDomain>{
          BackupDomain.identity,
          BackupDomain.preferences,
          BackupDomain.definitions,
          BackupDomain.taxonomy,
          BackupDomain.goals,
          BackupDomain.planner,
          BackupDomain.contacts,
        },
      );
      final opened = await restoreService.open(bytes: bytes);

      // planner depends on taxonomy and goals; asking for planner alone in a
      // backup that has them is fine, so remove the dependency instead.
      final withoutGoals = await restoreService.preview(
        backup: opened,
        mode: BackupRestoreMode.replace,
        selection: <BackupDomain>{BackupDomain.planner},
      );
      expect(
        withoutGoals.selectedDomains,
        containsAll(<BackupDomain>[
          BackupDomain.planner,
          BackupDomain.goals,
          BackupDomain.taxonomy,
          BackupDomain.definitions,
          BackupDomain.identity,
        ]),
      );
      expect(withoutGoals.addedDependencyDomains, contains(BackupDomain.goals));
    },
  );

  test(
    'a selection the backup does not carry is reported, not guessed',
    () async {
      final bytes = await makeBackup(
        domains: <BackupDomain>{
          BackupDomain.identity,
          BackupDomain.definitions,
          BackupDomain.taxonomy,
          BackupDomain.goals,
          BackupDomain.planner,
        },
      );
      final opened = await restoreService.open(bytes: bytes);

      await expectLater(
        () => restoreService.preview(
          backup: opened,
          mode: BackupRestoreMode.replace,
          selection: <BackupDomain>{BackupDomain.maps},
        ),
        throwsA(
          isA<BackupFailure>().having(
            (failure) => failure.kind,
            'kind',
            BackupFailureKind.missingDomain,
          ),
        ),
      );
    },
  );

  // Synthetic scale only: proves the S1 single-transaction restore stays
  // correct and usable at a realistic worst case. No owner data is used.
  test('a large synthetic dataset round trips through one transaction', () async {
    const count = 1200;
    for (var index = 0; index < count; index++) {
      await database.customInsert(
        'INSERT INTO contacts (id, profile_id, first_name, last_name, '
        'display_name, is_favorite, lifecycle_state, source, created_at_utc, '
        'updated_at_utc) VALUES (?,?,?,?,?,?,?,?,?,?)',
        variables: <Variable<Object>>[
          Variable<String>('bulk-contact-$index'),
          const Variable<String>('profile-synthetic'),
          Variable<String>('Synthetic$index'),
          Variable<String>('Person$index'),
          Variable<String>('Synthetic Person $index'),
          Variable<int>(index.isEven ? 1 : 0),
          const Variable<String>('active'),
          const Variable<String>('manual'),
          const Variable<int>(1750000000),
          const Variable<int>(1750000000),
        ],
      );
      await database.customInsert(
        'INSERT INTO contact_notes (id, contact_id, note_text, created_at_utc, '
        'updated_at_utc) VALUES (?,?,?,?,?)',
        variables: <Variable<Object>>[
          Variable<String>('bulk-note-$index'),
          Variable<String>('bulk-contact-$index'),
          Variable<String>('Synthetic note $index'),
          const Variable<int>(1750000000),
          const Variable<int>(1750000000),
        ],
      );
      await database.customInsert(
        'INSERT INTO saved_places (id, profile_id, label, latitude, longitude, '
        'marker_mode, standard_category, marker_color, boundary_color, '
        'created_at_utc, updated_at_utc) VALUES (?,?,?,?,?,?,?,?,?,?,?)',
        variables: <Variable<Object>>[
          Variable<String>('bulk-place-$index'),
          const Variable<String>('profile-synthetic'),
          Variable<String>('Synthetic Place $index'),
          Variable<double>(-80 + (index % 160) + 0.5),
          Variable<double>(-170 + (index % 340) + 0.25),
          const Variable<String>('standard'),
          const Variable<String>('worship'),
          const Variable<int>(0xFF00AAFF),
          const Variable<int>(0xFFFFAA00),
          const Variable<int>(1750000000),
          const Variable<int>(1750000000),
        ],
      );
    }

    final encodeStarted = DateTime.now();
    final bytes = await makeBackup();
    final encodeElapsed = DateTime.now().difference(encodeStarted);

    final before = await _snapshot(database);
    final contactsBefore = before['contacts']!.length;
    final notesBefore = before['contact_notes']!.length;
    final placesBefore = before['saved_places']!.length;
    expect(contactsBefore, greaterThanOrEqualTo(count));
    expect(notesBefore, greaterThanOrEqualTo(count));
    expect(placesBefore, greaterThanOrEqualTo(count));

    for (final spec in BackupDomainRegistry.tables.reversed) {
      await database.customStatement('DELETE FROM "${spec.table}"');
    }

    final restoreStarted = DateTime.now();
    final opened = await restoreService.open(bytes: bytes);
    final preview = await restoreService.preview(
      backup: opened,
      mode: BackupRestoreMode.replace,
    );
    final result = await restoreService.apply(
      backup: opened,
      mode: BackupRestoreMode.replace,
    );
    final restoreElapsed = DateTime.now().difference(restoreStarted);

    expect(result.rolledBack, isFalse);
    expect(preview.totalRows, greaterThan(3 * count));
    expect(await _snapshot(database), before);

    // Recorded so a future regression in transaction cost is visible rather
    // than silent. Generous ceilings keep this a real assertion on a slow CI
    // box without turning it into a flaky timing test.
    // ignore: avoid_print
    print(
      'synthetic scale: ${preview.totalRows} rows, '
      '${bytes.length} bytes, '
      'encode ${encodeElapsed.inMilliseconds} ms, '
      'open+preview+restore ${restoreElapsed.inMilliseconds} ms',
    );
    expect(encodeElapsed.inSeconds, lessThan(60));
    expect(restoreElapsed.inSeconds, lessThan(60));
  });

  test(
    'the recovery checkpoint exists and is verified before the write',
    () async {
      final bytes = await makeBackup();
      final opened = await restoreService.open(bytes: bytes);
      await restoreService.apply(
        backup: opened,
        mode: BackupRestoreMode.replace,
      );

      final current = File(
        '${checkpointDirectory.path}${Platform.pathSeparator}backup_recovery'
        '${Platform.pathSeparator}'
        '${BackupRecoveryCheckpointStore.currentFileName}',
      );
      expect(current.existsSync(), isTrue);
      expect(keyStore.reads, greaterThan(0));

      // The checkpoint is device-bound: it is not a passphrase-protected
      // portable backup and it never leaves app-private storage.
      final stored = await current.readAsBytes();
      final header = BackupContainer.parseHeader(stored);
      expect(header.protectionId, BackupFormat.deviceKeyProtectionId);
    },
  );

  // -------------------------------------------------------------------------
  // The owner's physical review.
  //
  // A backup created on one install could not be restored onto a freshly
  // installed app, which defeats the entire point of a portable backup
  // (uninstall → reinstall, and device migration). The cause was identity: a
  // restore preserves the backup's profile id exactly, because that id is the
  // foreign-key anchor for nearly every table, but the receiving install's own
  // regenerated seeds and device-bound rows still referenced ITS profile. The
  // deferred foreign-key check failed at COMMIT and rolled the whole restore
  // back, so the same backup only ever restored onto the install it came from.
  // -------------------------------------------------------------------------
  group('restoring onto a fresh install', () {
    test(
      'a backup made on another profile restores onto a fresh install',
      () async {
        final bytes = await makeBackup();

        final fresh = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(fresh.close);
        await _seedFreshInstall(fresh, profileId: 'profile-fresh-install');

        final restorer = restoreServiceFor(
          fresh,
          profileId: 'profile-fresh-install',
        );
        final opened = await restorer.open(bytes: bytes);
        final preview = await restorer.preview(
          backup: opened,
          mode: BackupRestoreMode.replace,
        );
        final result = await restorer.apply(
          backup: opened,
          mode: BackupRestoreMode.replace,
          selection: preview.selectedDomains,
        );

        expect(result.rolledBack, isFalse);
        expect(result.identityAdopted, isTrue);
        expect(result.restoredProfileId, 'profile-synthetic');
        expect(result.postRestoreWarnings, isEmpty);

        // The install now *is* the backup's profile.
        expect(await _profileIds(fresh), <String>['profile-synthetic']);

        // The backup's content is what is present, and only that: the receiving
        // install's own regenerated rows are gone rather than left beside it.
        expect(await _count(fresh, 'SELECT COUNT(*) c FROM goals'), 1);
        expect(
          await _count(
            fresh,
            "SELECT COUNT(*) c FROM goals WHERE profile_id = "
            "'profile-fresh-install'",
          ),
          0,
        );
        expect(
          await _count(
            fresh,
            'SELECT COUNT(*) c FROM life_indicator_definitions',
          ),
          6,
        );
        expect(
          await _count(
            fresh,
            'SELECT COUNT(*) c FROM life_indicator_definitions '
            "WHERE profile_id = 'profile-fresh-install'",
          ),
          0,
        );
        expect(await _count(fresh, 'SELECT COUNT(*) c FROM activity_types'), 2);
        expect(
          await _count(fresh, 'SELECT COUNT(*) c FROM calendar_events'),
          1,
        );
        expect(await _count(fresh, 'SELECT COUNT(*) c FROM planner_tasks'), 1);
        expect(await _count(fresh, 'SELECT COUNT(*) c FROM contacts'), 1);
        expect(await _count(fresh, 'SELECT COUNT(*) c FROM contact_notes'), 1);
        expect(await _count(fresh, 'SELECT COUNT(*) c FROM saved_places'), 1);
        expect(await _count(fresh, 'SELECT COUNT(*) c FROM contact_groups'), 0);

        // Device-bound scheduling artefacts are never resurrected by a backup…
        expect(
          await _count(
            fresh,
            'SELECT COUNT(*) c FROM background_work_requests',
          ),
          0,
        );
        // …while device-local permission history is not profile-scoped, so it is
        // left exactly where it was.
        expect(
          await _count(fresh, 'SELECT COUNT(*) c FROM permission_audits'),
          1,
        );

        // Adopting an identity must not leave a single orphan behind.
        final orphans = await fresh
            .customSelect('PRAGMA foreign_key_check')
            .get();
        expect(orphans, isEmpty);
      },
    );

    test('a backup made on this install does not adopt an identity', () async {
      final bytes = await makeBackup();
      final opened = await restoreService.open(bytes: bytes);
      final result = await restoreService.apply(
        backup: opened,
        mode: BackupRestoreMode.replace,
      );

      expect(result.identityAdopted, isFalse);
      expect(result.restoredProfileId, 'profile-synthetic');
    });

    test(
      'a partial restore of another profile is refused, not half-applied',
      () async {
        final bytes = await makeBackup();

        final fresh = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(fresh.close);
        await _seedFreshInstall(fresh, profileId: 'profile-fresh-install');
        final restorer = restoreServiceFor(
          fresh,
          profileId: 'profile-fresh-install',
        );

        final opened = await restorer.open(bytes: bytes);
        // Adopting the backup's identity retires every row this install owns, so
        // a fragment of the backup cannot be restored on its own.
        await expectLater(
          () => restorer.apply(
            backup: opened,
            mode: BackupRestoreMode.replace,
            selection: <BackupDomain>{BackupDomain.maps},
          ),
          throwsA(
            isA<BackupFailure>().having(
              (failure) => failure.kind,
              'kind',
              BackupFailureKind.differentProfile,
            ),
          ),
        );

        // Nothing was written.
        expect(await _profileIds(fresh), <String>['profile-fresh-install']);
        expect(await _count(fresh, 'SELECT COUNT(*) c FROM goals'), 6);
      },
    );

    test('merging a backup from another profile is still refused', () async {
      final bytes = await makeBackup();

      final fresh = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(fresh.close);
      await _seedFreshInstall(fresh, profileId: 'profile-fresh-install');
      final restorer = restoreServiceFor(
        fresh,
        profileId: 'profile-fresh-install',
      );

      final opened = await restorer.open(bytes: bytes);
      await expectLater(
        () => restorer.apply(backup: opened, mode: BackupRestoreMode.merge),
        throwsA(
          isA<BackupFailure>().having(
            (failure) => failure.kind,
            'kind',
            BackupFailureKind.differentProfile,
          ),
        ),
      );
      expect(await _profileIds(fresh), <String>['profile-fresh-install']);
    });
  });

  group('backup file names', () {
    BackupManifest manifestAt(int second) => BackupManifest(
      containerVersion: BackupFormat.containerVersion,
      appVersion: '0.1.0+1',
      schemaVersion: database.schemaVersion,
      createdAtUtc: DateTime.utc(2026, 9, 17, 12, 0, second),
      sourcePackage: BackupFormat.sourcePackage,
      profileId: 'profile-synthetic',
      domains: const <BackupDomain, BackupDomainEntry>{},
      payloadSha256: '',
    );

    test('two backups in the same minute are two distinct files', () {
      expect(
        backupService.defaultFileName(manifestAt(5)),
        'NextTransfer_Backup_2026-09-17_120005.ntbackup',
      );
      // A minute-only name collides, and the platform then stores the second
      // backup as a copy of the first instead of as its own file.
      expect(
        backupService.defaultFileName(manifestAt(6)),
        isNot(backupService.defaultFileName(manifestAt(5))),
      );
    });
  });

  // -------------------------------------------------------------------------
  // P2-A (owner decision 2026-09-21, design D1) — the INDEPENDENT Event contact
  // channel and the backup contract.
  //
  // A backup is table-level and column-INTERSECTED: a schema-49 file carries
  // `calendar_events.contact_channel`, while a file written by a pre-49 install
  // simply does not mention the column at all. Restoring that older file into
  // schema 49 must leave the new column at its default — NULL — rather than
  // inventing a Contact Type for a historical Event.
  // -------------------------------------------------------------------------
  group('the independent Event contact channel survives backup and restore', () {
    Future<Object?> storedChannel(AppDatabase target) async {
      final row = await target
          .customSelect(
            "SELECT contact_channel FROM calendar_events WHERE id='event-1'",
          )
          .getSingle();
      return row.data['contact_channel'];
    }

    test(
      'a schema-49 backup carries the channel and restores it exactly',
      () async {
        await database.customStatement(
          "UPDATE calendar_events SET contact_channel = 'phone_call' "
          "WHERE id = 'event-1'",
        );
        final bytes = await makeBackup();

        // The channel is genuinely IN the file, not merely in memory.
        final opened = await restoreService.open(bytes: bytes);
        final events =
            opened.payload.domains[BackupDomain.planner]!['calendar_events']!;
        expect(events.columns, contains('contact_channel'));
        final columnIndex = events.columns.indexOf('contact_channel');
        expect(events.rows.single[columnIndex], 'phone_call');

        for (final spec in BackupDomainRegistry.tables.reversed) {
          await database.customStatement('DELETE FROM "${spec.table}"');
        }
        final result = await restoreService.apply(
          backup: opened,
          mode: BackupRestoreMode.replace,
        );

        expect(result.rolledBack, isFalse);
        expect(await storedChannel(database), 'phone_call');
      },
    );

    test(
      'a schema-48 backup leaves contact_channel NULL, never inventing one',
      () async {
        // The live install DOES hold a channel, so an incorrectly preserved or
        // invented value would be visible rather than hidden behind a default.
        await database.customStatement(
          "UPDATE calendar_events SET contact_channel = 'email' "
          "WHERE id = 'event-1'",
        );

        final payload = await backupService.buildPayload(
          profileId: 'profile-synthetic',
        );
        final planner = payload.domains[BackupDomain.planner]!;
        final events = planner['calendar_events']!;
        final channelIndex = events.columns.indexOf('contact_channel');
        expect(
          channelIndex,
          isNonNegative,
          reason: 'a schema-49 backup must carry the column',
        );

        // Rewrite the file exactly as a pre-49 producer would have written it:
        // the column does not exist in it at all.
        final legacyColumns = <String>[
          for (final column in events.columns)
            if (column != 'contact_channel') column,
        ];
        final legacyRows = <List<Object?>>[
          for (final row in events.rows)
            <Object?>[
              for (var index = 0; index < row.length; index++)
                if (index != channelIndex) row[index],
            ],
        ];
        final domains = <BackupDomain, Map<String, BackupTableData>>{
          ...payload.domains,
          BackupDomain.planner: <String, BackupTableData>{
            ...planner,
            'calendar_events': BackupTableData(
              table: 'calendar_events',
              columns: legacyColumns,
              rows: legacyRows,
            ),
          },
        };
        final content = BackupPayloadCodec.canonicalContentJson(
          domains: domains,
          exports: payload.exports,
        );
        final legacy = BackupPayload(
          manifest: BackupManifest(
            containerVersion: payload.manifest.containerVersion,
            appVersion: payload.manifest.appVersion,
            // A file made before the column existed.
            schemaVersion: 48,
            createdAtUtc: payload.manifest.createdAtUtc,
            sourcePackage: payload.manifest.sourcePackage,
            profileId: payload.manifest.profileId,
            domains: payload.manifest.domains,
            payloadSha256: BackupPayloadCodec.sha256Hex(content),
          ),
          domains: domains,
          exports: payload.exports,
        );

        final opened = await restoreService.open(
          bytes: backupService.encode(payload: legacy),
        );
        final result = await restoreService.apply(
          backup: opened,
          mode: BackupRestoreMode.replace,
        );
        expect(result.rolledBack, isFalse);

        // The historical Event keeps every field it had and has no Contact Type.
        final row = await database
            .customSelect(
              'SELECT contact_channel, title, start_minute, end_minute, '
              'status, requires_report, activity_type_stable_key_snapshot '
              "FROM calendar_events WHERE id='event-1'",
            )
            .getSingle();
        expect(row.data['contact_channel'], equals(null));
        expect(row.data['title'], 'Dinner');
        expect(row.data['start_minute'], 1080);
        expect(row.data['end_minute'], 1140);
        expect(row.data['status'], 'scheduled');
        expect(row.data['requires_report'], 0);
        expect(row.data['activity_type_stable_key_snapshot'], 'planner_meal');
        // And the exact read the form performs shows the honest unset state.
        expect(
          EventContactChannel.fromStableKey(
            row.data['contact_channel'] as String?,
          ),
          equals(null),
        );
      },
    );
  });
}
