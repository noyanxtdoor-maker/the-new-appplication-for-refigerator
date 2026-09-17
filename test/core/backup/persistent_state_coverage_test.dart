import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/features/backup/domain/backup_coverage.dart';
import 'package:rmplanner/features/backup/domain/backup_domain_contract.dart';
import 'package:rmplanner/features/backup/domain/backup_domain_registry.dart';

/// Mechanisms that create durable state. If a slice introduces one of these in
/// a file that is not an allowed location of a registered store, the gate
/// fails. This is deliberate: it is what stops user data shipping without
/// VS-18 coverage.
const Map<String, List<String>> _mechanismMarkers = <String, List<String>>{
  'shared_preferences': <String>['SharedPreferences'],
  'flutter_secure_storage': <String>['FlutterSecureStorage'],
  'app_private_file': <String>[
    'getApplicationSupportDirectory',
    'getApplicationDocumentsDirectory',
    'writeAsBytes(',
    'writeAsString(',
    'openWrite(',
    'Directory(',
  ],
  'external_database': <String>[
    'package:sqflite',
    'package:hive',
    'package:isar',
    'package:objectbox',
  ],
};

Map<String, Set<String>> _scanLibForNonDriftUsage() {
  final usage = <String, Set<String>>{};
  final lib = Directory('lib');
  for (final entity in lib.listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) {
      continue;
    }
    final relative = entity.path.replaceAll(r'\', '/');
    final source = entity.readAsStringSync();
    for (final entry in _mechanismMarkers.entries) {
      for (final marker in entry.value) {
        if (source.contains(marker)) {
          usage.putIfAbsent(entry.key, () => <String>{}).add(relative);
          break;
        }
      }
    }
  }
  return usage;
}

List<String> _liveSchemaTables(AppDatabase database) => database
    .allSchemaEntities
    .whereType<TableInfo<Table, Object?>>()
    .map((table) => table.actualTableName)
    .toList(growable: false);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('persistent-state coverage gate', () {
    test('every schema-47 table is classified — 45/45, 0 unclassified',
        () async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);

      final report = BackupCoverage.evaluateSchema(_liveSchemaTables(database));

      expect(report.violations, isEmpty, reason: report.violations.join('\n'));
      expect(report.tableCount, BackupDomainRegistry.baselineTableCount);
      expect(
        report.backupAndRestoreCount,
        BackupDomainRegistry.baselineBackupAndRestoreCount,
      );
      expect(
        report.regenerateCount,
        BackupDomainRegistry.baselineRegenerateCount,
      );
      expect(report.excludeCount, BackupDomainRegistry.baselineExcludeCount);
    });

    test('the audit baseline classifications are preserved', () {
      // Corrections recorded in the controlling audit must not regress.
      expect(
        BackupDomainRegistry.classificationOf('life_indicator_definitions'),
        PersistentStateClass.backupAndRestore,
      );
      expect(
        BackupDomainRegistry.classificationOf('activity_types'),
        PersistentStateClass.backupAndRestore,
      );
      expect(
        BackupDomainRegistry.forTable('life_indicator_definitions')!.replaceMode,
        BackupReplaceMode.upsertOnly,
      );
      expect(
        BackupDomainRegistry.forTable('activity_types')!.replacePredicate,
        'is_system = 0',
      );
      expect(
        BackupDomainRegistry.classificationOf('background_work_requests'),
        PersistentStateClass.exclude,
      );
      expect(
        BackupDomainRegistry.classificationOf('permission_audits'),
        PersistentStateClass.exclude,
      );
      expect(
        BackupDomainRegistry.classificationOf('onboarding_checkpoints'),
        PersistentStateClass.exclude,
      );
      expect(
        BackupDomainRegistry.classificationOf('goal_outbox_operations'),
        PersistentStateClass.regenerate,
      );
      expect(
        BackupDomainRegistry.classificationOf('calendar_event_operations'),
        PersistentStateClass.regenerate,
      );
    });

    test('the gate fails closed on an unclassified new table', () async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);

      final live = <String>[
        ..._liveSchemaTables(database),
        'journal_entries',
      ];

      final report = BackupCoverage.evaluateSchema(live);

      expect(report.isClean, isFalse);
      expect(
        report.violations.join('\n'),
        contains('UNCLASSIFIED persistent table "journal_entries"'),
      );
    });

    test('the gate fails when a registered table disappears from the schema',
        () async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);

      final live = _liveSchemaTables(database)
          .where((table) => table != 'saved_places')
          .toList(growable: false);

      final report = BackupCoverage.evaluateSchema(live);

      expect(report.isClean, isFalse);
      expect(
        report.violations.join('\n'),
        contains('registered table "saved_places" is not in the live schema'),
      );
    });

    test('the gate fails when an exported table loses its domain package', () {
      // Structural guard: every exported table must resolve to a domain.
      for (final spec in BackupDomainRegistry.exportedTables) {
        expect(spec.domain == null, isFalse, reason: spec.table);
        expect(spec.stateClass, PersistentStateClass.backupAndRestore);
      }
      expect(BackupDomainRegistry.exportedTables.length, 40);
    });

    test('domain packages are dependency-closed and topologically ordered', () {
      expect(
        BackupCoverage.evaluateSchema(
          BackupDomainRegistry.tables.map((spec) => spec.table).toList(),
        ).violations,
        isEmpty,
      );
      final resolved = BackupDomainRegistry.resolveDependencies(
        <BackupDomain>[BackupDomain.maps],
      );
      expect(resolved, <BackupDomain>{BackupDomain.identity, BackupDomain.maps});
      final missing = BackupDomainRegistry.missingDependencies(
        <BackupDomain>[BackupDomain.contacts],
        <BackupDomain>{BackupDomain.identity},
      );
      // Dependency closure is transitive: contacts needs planner, and planner
      // needs taxonomy and goals, and goals needs definitions.
      expect(missing, <BackupDomain>{
        BackupDomain.planner,
        BackupDomain.taxonomy,
        BackupDomain.goals,
        BackupDomain.definitions,
      });
    });

    test('non-Drift durable stores are registered and enforced', () {
      final usage = _scanLibForNonDriftUsage();
      final violations = BackupCoverage.evaluateNonDrift(usage);

      expect(violations, isEmpty, reason: violations.join('\n'));

      final secureStorage = BackupDomainRegistry.nonDriftStores.firstWhere(
        (store) => store.mechanism == 'flutter_secure_storage',
      );
      expect(secureStorage.id, 'secure_storage_auth_token_bundle');
      expect(secureStorage.stateClass, PersistentStateClass.exclude);

      // Grounded proof that the arm is not vacuous: the secure-storage
      // mechanism is really used in source, and only from registered
      // locations. Two EXCLUDE-class stores use it today — the account token
      // bundle and the device-bound recovery-checkpoint key.
      expect(
        usage['flutter_secure_storage'],
        <String>{
          'lib/core/security/auth_token_store.dart',
          'lib/main.dart',
          'lib/features/backup/data/secure_checkpoint_key_store.dart',
        },
      );
      expect(
        BackupDomainRegistry.nonDriftStores
            .where((store) => store.mechanism == 'flutter_secure_storage')
            .map((store) => store.id)
            .toSet(),
        <String>{
          'secure_storage_auth_token_bundle',
          'secure_storage_backup_checkpoint_key',
        },
      );
      for (final store in BackupDomainRegistry.nonDriftStores) {
        expect(
          store.stateClass,
          PersistentStateClass.exclude,
          reason: store.id,
        );
      }
    });

    test('the non-Drift arm fails closed on an unregistered mechanism', () {
      final violations = BackupCoverage.evaluateNonDrift(<String, Set<String>>{
        'shared_preferences': <String>{'lib/features/journal/journal_store.dart'},
      });

      expect(violations, isNotEmpty);
      expect(
        violations.join('\n'),
        contains('UNCLASSIFIED durable persistence mechanism '
            '"shared_preferences"'),
      );
    });

    test('the non-Drift arm fails when a registered mechanism is used from '
        'an unregistered file', () {
      final violations = BackupCoverage.evaluateNonDrift(<String, Set<String>>{
        'flutter_secure_storage': <String>{
          'lib/core/security/auth_token_store.dart',
          'lib/features/journal/journal_secrets.dart',
        },
      });

      expect(
        violations.join('\n'),
        contains('lib/features/journal/journal_secrets.dart uses '
            '"flutter_secure_storage"'),
      );
    });
  });
}
