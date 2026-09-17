/// Restore (FR-S-010…FR-S-018, AG-3, AG-4, AG-6).
///
/// Order of operations is the contract: decrypt → parse → version-check →
/// integrity-check → validate → preview → mandatory verified recovery
/// checkpoint → **one atomic transaction** → post-restore rebuild. No live data
/// changes before the checkpoint exists and is verified.
library;

import 'dart:typed_data';

import 'package:drift/drift.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/features/backup/application/backup_container_codec.dart';
import 'package:rmplanner/features/backup/data/backup_payload_codec.dart';
import 'package:rmplanner/features/backup/data/backup_recovery_checkpoint_store.dart';
import 'package:rmplanner/features/backup/data/backup_table_codec.dart';
import 'package:rmplanner/features/backup/domain/backup_domain_contract.dart';
import 'package:rmplanner/features/backup/domain/backup_domain_registry.dart';
import 'package:rmplanner/features/backup/domain/backup_errors.dart';
import 'package:rmplanner/features/backup/domain/backup_manifest.dart';
import 'package:rmplanner/features/backup/domain/restore_preview.dart';

final class OpenedBackup {
  const OpenedBackup({required this.payload, required this.header});

  final BackupPayload payload;
  final ParsedContainerHeader header;

  BackupManifest get manifest => payload.manifest;

  Set<BackupDomain> get includedDomains => manifest.includedDomains;

  String get profileId => manifest.profileId;
}

final class RestoreService {
  RestoreService({
    required this.database,
    required this.containerCodec,
    required this.checkpointStore,
    required this.captureCurrentState,
    required this.clock,
    this.diagnostics,
    this.reconcileAfterRestore,
  }) : tableCodec = BackupTableCodec(database);

  final AppDatabase database;
  final BackupContainerCodec containerCodec;
  final BackupRecoveryCheckpointStore checkpointStore;

  /// Captures the current local state for the pre-restore recovery checkpoint.
  final Future<Uint8List> Function(Set<BackupDomain> domains)
      captureCurrentState;

  final DateTime Function() clock;
  final SanitizedDiagnostics? diagnostics;

  /// Rebuilds device-local schedules from the restored canonical policies. Runs
  /// once after a successful commit and can never roll back that commit.
  final Future<void> Function(String profileId)? reconcileAfterRestore;

  final BackupTableCodec tableCodec;

  /// Reads and fully validates a portable backup. Nothing is written.
  ///
  /// A portable backup needs no credential of any kind, so there is no
  /// passphrase parameter to supply. A device-bound checkpoint reaching this
  /// path is refused rather than guessed at.
  Future<OpenedBackup> open({required Uint8List bytes}) async {
    if (bytes.length > BackupFormat.maxFileBytes) {
      // Too large to be a backup this app can open. This is an access limit,
      // not a damaged payload, and not a failed save.
      throw const BackupFailure(BackupFailureKind.fileAccessFailed);
    }
    final header = BackupContainer.parseHeader(bytes);
    if (header.isProtected) {
      // Only the app's own recovery checkpoint is protected, and that is not a
      // user-restorable file.
      throw const BackupFailure(BackupFailureKind.notABackupFile);
    }
    final plainText = containerCodec.open(header: header);
    final payload = BackupPayloadCodec.decode(
      plainText,
      currentSchema: database.schemaVersion,
    );
    final opened = OpenedBackup(payload: payload, header: header);
    await _validate(opened, selected: opened.includedDomains);
    return opened;
  }

  /// Truly tells the user what a commit would do.
  Future<RestorePreview> preview({
    required OpenedBackup backup,
    required BackupRestoreMode mode,
    Set<BackupDomain>? selection,
  }) async {
    final resolved = _resolveSelection(backup, selection);
    await _validate(backup, selected: resolved.selected);

    final counts = <BackupDomain, int>{};
    for (final domain in resolved.selected) {
      counts[domain] = backup.payload.rowsOf(domain);
    }

    final conflicts = <BackupDomain, int>{};
    if (mode == BackupRestoreMode.merge) {
      for (final domain in resolved.selected) {
        var domainConflicts = 0;
        for (final spec in BackupDomainRegistry.tablesOf(domain)) {
          final data = backup.payload.domains[domain]?[spec.table];
          if (data == null) {
            continue;
          }
          final keyColumns = await tableCodec.primaryKeyOf(spec.table);
          if (keyColumns.isEmpty) {
            continue;
          }
          final local = await tableCodec.localPrimaryKeyValues(spec);
          for (final row in data.rows) {
            final token =
                BackupTableCodec.primaryKeyToken(data.columns, row, keyColumns);
            if (local.contains(token)) {
              domainConflicts++;
            }
          }
        }
        conflicts[domain] = domainConflicts;
      }
    }

    return RestorePreview(
      createdAtUtc: backup.manifest.createdAtUtc,
      appVersion: backup.manifest.appVersion,
      schemaVersion: backup.manifest.schemaVersion,
      containerVersion: backup.header.containerVersion,
      mode: mode,
      selectedDomains: resolved.selected,
      addedDependencyDomains: resolved.addedByDependency,
      rowCounts: counts,
      conflictCounts: conflicts,
      domainsAbsentFromBackup: BackupDomainRegistry.populatedDomains
          .difference(backup.includedDomains),
    );
  }

  /// Applies the restore: checkpoint first, then one atomic transaction.
  Future<BackupRestoreResult> apply({
    required OpenedBackup backup,
    required BackupRestoreMode mode,
    Set<BackupDomain>? selection,
  }) async {
    final resolved = _resolveSelection(backup, selection);
    await _validate(backup, selected: resolved.selected);

    final localProfileId = await tableCodec.singleProfileId();
    final identityChanged =
        localProfileId != null && localProfileId != backup.profileId;
    if (mode == BackupRestoreMode.merge && identityChanged) {
      // Merging a different profile would need invented id remapping, which
      // the contract forbids. Fail closed and tell the user to use Replace.
      throw const BackupFailure(BackupFailureKind.differentProfile);
    }
    if (identityChanged &&
        !resolved.selected.containsAll(backup.includedDomains)) {
      // Adopting the backup's identity retires every row this install owns, so
      // it is only coherent as a whole-profile restore: a partial one would
      // silently discard the packages it skipped.
      throw const BackupFailure(
        BackupFailureKind.differentProfile,
        detail: 'the backup belongs to another profile and cannot be restored '
            'as a partial selection',
      );
    }

    diagnostics?.record(
      'backup_restore_started',
      context: <String, Object?>{
        'mode': mode.name,
        'domains': resolved.selected.length,
        'identity_adopted': identityChanged,
      },
    );

    // FR-S-011: a recoverable copy of current local data must exist and be
    // verified BEFORE the destructive write. Failure aborts the restore.
    final checkpointPlainText = await captureCurrentState(
      BackupDomainRegistry.populatedDomains,
    );
    await checkpointStore.create(plainText: checkpointPlainText);

    final outcomes = <RestoredDomainOutcome>[];

    try {
      await database.transaction(() async {
        // FK checks stay on; they are deferred to COMMIT so the delete/insert
        // ordering inside the transaction cannot create false violations.
        await database.customStatement('PRAGMA defer_foreign_keys = ON');

        if (identityChanged) {
          // The backup's profile identity is preserved exactly (it is the FK
          // anchor for nearly every table), so this install's own rows are
          // retired first. They belong to a profile that is about to stop
          // existing, and leaving them would fail the deferred foreign-key
          // check at COMMIT and roll the whole restore back — which is exactly
          // how a backup used to be restorable only onto the install it was
          // made on. Removed rows are either restored from the backup or
          // rebuilt by the current app, per the registry's classification.
          await tableCodec.detachLocalProfileIdentity(
            liveProfileId: localProfileId,
          );
        }

        if (mode == BackupRestoreMode.replace) {
          for (final spec in BackupDomainRegistry.exportedTables.reversed) {
            if (!resolved.selected.contains(spec.domain)) {
              continue;
            }
            await tableCodec.clearTableForReplace(spec);
          }
        }

        final skippedParentTokens = <String, Set<String>>{};

        for (final spec in BackupDomainRegistry.exportedTables) {
          final domain = spec.domain;
          if (domain == null || !resolved.selected.contains(domain)) {
            continue;
          }
          final data = backup.payload.domains[domain]?[spec.table];
          if (data == null) {
            continue;
          }
          final restorable = await tableCodec.restorableColumns(
            spec.table,
            data.columns,
          );
          if (restorable.isEmpty) {
            continue;
          }

          if (mode == BackupRestoreMode.replace) {
            final rows = <List<Object?>>[
              for (final row in data.rows)
                BackupTableCodec.projectRow(data.columns, row, restorable),
            ];
            await tableCodec.insertRows(
              table: spec.table,
              columns: restorable,
              rows: rows,
              mode: spec.insertMode,
            );
            outcomes.add(
              RestoredDomainOutcome(
                domain: domain,
                rowsWritten: rows.length,
                conflictsSkipped: 0,
                dependencySkips: 0,
                skippedTableCount: 0,
              ),
            );
            continue;
          }

          // Merge: keep the local record, skip the conflicting incoming record.
          final keyColumns = await tableCodec.primaryKeyOf(spec.table);
          final localKeys = await tableCodec.localPrimaryKeyValues(spec);
          final foreignKeys = await _foreignKeysOf(spec.table);
          final rowsToInsert = <List<Object?>>[];
          final insertedTokens = <String>{};
          var conflicts = 0;
          var dependencySkips = 0;
          final skippedHere = <String>{};

          for (final row in data.rows) {
            final token = keyColumns.isEmpty
                ? null
                : BackupTableCodec.primaryKeyToken(
                    data.columns,
                    row,
                    keyColumns,
                  );
            if (token != null) {
              if (insertedTokens.contains(token) || localKeys.contains(token)) {
                // Keep the local record. This identity therefore *is* present
                // locally, so it is not a missing parent and must not cascade
                // skips onto its children.
                conflicts++;
                continue;
              }
            }
            final parentToken = _skippedParentToken(
              foreignKeys: foreignKeys,
              skippedParents: skippedParentTokens,
              columns: data.columns,
              row: row,
            );
            if (parentToken != null) {
              // Only genuinely unavailable rows cascade: this row was skipped
              // because the row it depends on is absent locally and was not
              // restored, so its own children cannot be restored either.
              dependencySkips++;
              if (token != null) {
                skippedHere.add(token);
              }
              continue;
            }
            rowsToInsert.add(
              BackupTableCodec.projectRow(data.columns, row, restorable),
            );
            if (token != null) {
              insertedTokens.add(token);
            }
          }

          if (skippedHere.isNotEmpty) {
            skippedParentTokens[spec.table] = skippedHere;
          }

          await tableCodec.insertRows(
            table: spec.table,
            columns: restorable,
            rows: rowsToInsert,
            mode: BackupInsertMode.insert,
          );

          outcomes.add(
            RestoredDomainOutcome(
              domain: domain,
              rowsWritten: rowsToInsert.length,
              conflictsSkipped: conflicts,
              dependencySkips: dependencySkips,
              skippedTableCount: dependencySkips == 0 ? 0 : 1,
            ),
          );
        }
      });
    } on BackupFailure {
      diagnostics?.record('backup_restore_failed');
      rethrow;
    } on Object catch (error) {
      diagnostics?.record('backup_restore_failed');
      throw BackupFailure(
        BackupFailureKind.restoreFailed,
        detail: error.runtimeType.toString(),
      );
    }

    final warnings = <String>[];
    try {
      await tableCodec.quickCheck();
    } on Object {
      // The commit succeeded and FK checks passed; a failing quick_check is
      // reported, never silently ignored.
      warnings.add(
        'The restored data could not be fully verified on this device.',
      );
    }
    try {
      if (await tableCodec.foreignKeyViolationCount() > 0) {
        warnings.add(
          'Some restored items could not be linked to their parent records.',
        );
      }
    } on Object {
      // Same contract as quick_check: a failed post-commit check is surfaced,
      // never converted into a silent success.
      warnings.add(
        'The restored data could not be fully verified on this device.',
      );
    }

    if (reconcileAfterRestore != null) {
      try {
        await reconcileAfterRestore!(backup.profileId);
      } on Object {
        warnings.add(
          'Your data was restored, but reminder schedules could not be '
          'rebuilt. They will be rebuilt the next time Next Transfer starts.',
        );
      }
    }

    diagnostics?.record(
      'backup_restore_completed',
      context: <String, Object?>{
        'mode': mode.name,
        'rows': outcomes.fold<int>(
          0,
          (total, outcome) => total + outcome.rowsWritten,
        ),
      },
    );

    return BackupRestoreResult(
      mode: mode,
      outcomes: outcomes,
      postRestoreWarnings: warnings,
      rolledBack: false,
      identityAdopted: identityChanged,
      restoredProfileId: backup.profileId,
    );
  }

  ({Set<BackupDomain> selected, Set<BackupDomain> addedByDependency})
      _resolveSelection(OpenedBackup backup, Set<BackupDomain>? selection) {
    final included = backup.includedDomains;
    final requested = selection ?? included;

    final absent = requested.difference(included);
    if (absent.isNotEmpty) {
      throw BackupFailure(
        BackupFailureKind.missingDomain,
        detail: absent.map((domain) => domain.manifestKey).join(', '),
      );
    }

    final missing =
        BackupDomainRegistry.missingDependencies(requested, included);
    if (missing.isNotEmpty) {
      throw BackupFailure(
        BackupFailureKind.dependencyViolation,
        detail: missing.map((domain) => domain.manifestKey).join(', '),
      );
    }

    final expanded = BackupDomainRegistry.resolveDependencies(requested);
    final selected =
        BackupDomain.restoreOrder.where(expanded.contains).toSet();
    final added = selected.difference(requested);
    return (selected: selected, addedByDependency: added);
  }

  /// Pre-write validation: shape, identity uniqueness and (for restore
  /// targets) the presence of a primary key to key Merge on.
  Future<void> _validate(
    OpenedBackup backup, {
    required Set<BackupDomain> selected,
  }) async {
    if (backup.manifest.profileId.trim().isEmpty) {
      throw const BackupFailure(BackupFailureKind.validationFailed);
    }
    for (final domain in selected) {
      final tables = backup.payload.domains[domain];
      if (tables == null) {
        throw BackupFailure(
          BackupFailureKind.validationFailed,
          detail: 'domain "${domain.manifestKey}" has no tables',
        );
      }
      final declared = backup.manifest.domains[domain];
      var actual = 0;
      for (final data in tables.values) {
        actual += data.rowCount;
      }
      if (declared != null && declared.rowCount != actual) {
        throw BackupFailure(
          BackupFailureKind.validationFailed,
          detail: 'domain "${domain.manifestKey}" declared '
              '${declared.rowCount} rows but carries $actual',
        );
      }
      for (final entry in tables.entries) {
        final keyColumns = await tableCodec.primaryKeyOf(entry.key);
        if (keyColumns.isEmpty) {
          continue;
        }
        final seen = <String>{};
        for (final row in entry.value.rows) {
          final token = BackupTableCodec.primaryKeyToken(
            entry.value.columns,
            row,
            keyColumns,
          );
          if (!seen.add(token)) {
            throw BackupTableCodec.duplicateRow(entry.key, token);
          }
        }
      }
    }
  }

  Future<List<({String table, String from, int id})>> _foreignKeysOf(
    String table,
  ) async {
    BackupTableCodec.validateIdentifier(table);
    final rows =
        await database.customSelect('PRAGMA foreign_key_list("$table")').get();
    return <({String table, String from, int id})>[
      for (final row in rows)
        (
          table: row.read<String>('table'),
          from: row.read<String>('from'),
          id: row.read<int>('id'),
        ),
    ];
  }

  /// Returns the skipped parent token a row refers to, or null when the row is
  /// safe. Composite foreign keys are left to commit-time enforcement.
  String? _skippedParentToken({
    required List<({String table, String from, int id})> foreignKeys,
    required Map<String, Set<String>> skippedParents,
    required List<String> columns,
    required List<Object?> row,
  }) {
    final compositeIds = <int>{};
    for (final key in foreignKeys) {
      final skipped = skippedParents[key.table];
      if (skipped == null || skipped.isEmpty) {
        continue;
      }
      if (!compositeIds.add(key.id)) {
        // Composite foreign key: not resolved here, commit-time FK
        // enforcement remains the backstop and it fails closed.
        continue;
      }
      final index = columns.indexOf(key.from);
      if (index < 0) {
        continue;
      }
      final value = row[index];
      if (value == null) {
        continue;
      }
      if (skipped.contains('$value')) {
        return '$value';
      }
    }
    return null;
  }
}
