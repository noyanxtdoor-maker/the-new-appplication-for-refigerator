/// Registry-driven table serialization.
///
/// Rows are read and written as raw SQLite primitives through the registry's
/// table list, so restoring an older backup into a newer app skips columns the
/// old backup does not have and lets the new columns take their defaults. Every
/// identifier is validated before it reaches SQL; table names come from the
/// registry, column names from the database's own metadata.
library;

import 'package:drift/drift.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/features/backup/domain/backup_domain_contract.dart';
import 'package:rmplanner/features/backup/domain/backup_domain_registry.dart';
import 'package:rmplanner/features/backup/domain/backup_errors.dart';

final class BackupTableData {
  BackupTableData({
    required this.table,
    required this.columns,
    required this.rows,
  });

  final String table;
  final List<String> columns;
  final List<List<Object?>> rows;

  int get rowCount => rows.length;

  Map<String, Object?> toJson() => <String, Object?>{
        'columns': columns,
        'rows': rows,
      };

  /// Strict decode of untrusted JSON. Only primitives are accepted; nested
  /// structures are rejected rather than coerced.
  static BackupTableData fromJson(String table, Object? json) {
    if (json is! Map) {
      throw BackupFailure(
        BackupFailureKind.validationFailed,
        detail: 'table "$table" payload is not an object',
      );
    }
    final columns = json['columns'];
    final rows = json['rows'];
    if (columns is! List || rows is! List) {
      throw BackupFailure(
        BackupFailureKind.validationFailed,
        detail: 'table "$table" is missing columns or rows',
      );
    }
    final decodedColumns = <String>[];
    for (final column in columns) {
      if (column is! String) {
        throw BackupFailure(
          BackupFailureKind.validationFailed,
          detail: 'table "$table" has a non-string column name',
        );
      }
      BackupTableCodec.validateIdentifier(column);
      decodedColumns.add(column);
    }
    if (decodedColumns.toSet().length != decodedColumns.length) {
      throw BackupFailure(
        BackupFailureKind.validationFailed,
        detail: 'table "$table" repeats a column name',
      );
    }
    final decodedRows = <List<Object?>>[];
    for (final row in rows) {
      if (row is! List || row.length != decodedColumns.length) {
        throw BackupFailure(
          BackupFailureKind.validationFailed,
          detail: 'table "$table" has a row of the wrong shape',
        );
      }
      final decodedRow = <Object?>[];
      for (final cell in row) {
        if (cell is Map || cell is List) {
          throw BackupFailure(
            BackupFailureKind.validationFailed,
            detail: 'table "$table" contains a nested value',
          );
        }
        decodedRow.add(cell);
      }
      decodedRows.add(decodedRow);
    }
    return BackupTableData(
      table: table,
      columns: decodedColumns,
      rows: decodedRows,
    );
  }
}

final class BackupTableCodec {
  const BackupTableCodec(this.database);

  final AppDatabase database;

  static final RegExp _identifier = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

  /// Rows per INSERT statement. Bounds statement size for large domains.
  static const int insertChunkSize = 100;

  static void validateIdentifier(String value) {
    if (!_identifier.hasMatch(value)) {
      throw BackupFailure(
        BackupFailureKind.validationFailed,
        detail: 'unsafe SQL identifier "$value"',
      );
    }
  }

  Future<List<String>> columnsOf(String table) async {
    validateIdentifier(table);
    final rows =
        await database.customSelect('PRAGMA table_info("$table")').get();
    return rows.map((row) => row.read<String>('name')).toList(growable: false);
  }

  Future<List<String>> primaryKeyOf(String table) async {
    validateIdentifier(table);
    final rows =
        await database.customSelect('PRAGMA table_info("$table")').get();
    final keyed = <({int order, String name})>[];
    for (final row in rows) {
      final order = row.read<int>('pk');
      if (order > 0) {
        keyed.add((order: order, name: row.read<String>('name')));
      }
    }
    keyed.sort((a, b) => a.order.compareTo(b.order));
    return keyed.map((entry) => entry.name).toList(growable: false);
  }

  Future<BackupTableData> exportTable(BackupTableSpec spec) async {
    final columns = await columnsOf(spec.table);
    final sql = StringBuffer('SELECT * FROM "${spec.table}"');
    final predicate = spec.exportPredicate;
    if (predicate != null && predicate.trim().isNotEmpty) {
      sql.write(' WHERE $predicate');
    }
    final result = await database.customSelect(sql.toString()).get();
    final rows = <List<Object?>>[];
    for (final row in result) {
      rows.add(<Object?>[
        for (final column in columns) row.data[column],
      ]);
    }
    return BackupTableData(
      table: spec.table,
      columns: columns,
      rows: rows,
    );
  }

  /// Rows removed by a Replace restore, per the registry's replace mode.
  Future<void> clearTableForReplace(BackupTableSpec spec) async {
    validateIdentifier(spec.table);
    switch (spec.replaceMode) {
      case BackupReplaceMode.upsertOnly:
        return;
      case BackupReplaceMode.deleteAll:
        await database.customStatement('DELETE FROM "${spec.table}"');
      case BackupReplaceMode.deleteWhere:
        final predicate = spec.replacePredicate;
        if (predicate == null || predicate.trim().isEmpty) {
          throw BackupFailure(
            BackupFailureKind.validationFailed,
            detail: 'table "${spec.table}" has no replace predicate',
          );
        }
        await database.customStatement(
          'DELETE FROM "${spec.table}" WHERE $predicate',
        );
    }
  }

  /// Binds one raw SQLite cell. Only the primitive types SQLite can produce
  /// are accepted, so an unexpected value can never reach SQL.
  static Variable<Object> variableFor(Object? cell) {
    if (cell == null ||
        cell is int ||
        cell is double ||
        cell is String ||
        cell is Uint8List) {
      return Variable<Object>(cell);
    }
    throw BackupFailure(
      BackupFailureKind.validationFailed,
      detail: 'unsupported value type ${cell.runtimeType}',
    );
  }

  /// Live column set for [table], used to intersect with a backup's columns.
  Future<Set<String>> liveColumns(String table) async =>
      (await columnsOf(table)).toSet();

  Future<void> insertRows({
    required String table,
    required List<String> columns,
    required List<List<Object?>> rows,
    BackupInsertMode mode = BackupInsertMode.insert,
  }) async {
    if (rows.isEmpty) {
      return;
    }
    validateIdentifier(table);
    for (final column in columns) {
      validateIdentifier(column);
    }
    final verb = mode == BackupInsertMode.insertOrReplace
        ? 'INSERT OR REPLACE'
        : 'INSERT';
    final rowPlaceholder =
        '(${List<String>.filled(columns.length, '?').join(',')})';
    for (var start = 0; start < rows.length; start += insertChunkSize) {
      final end = (start + insertChunkSize).clamp(0, rows.length);
      final chunk = rows.sublist(start, end);
      final values = <Variable<Object>>[];
      for (final row in chunk) {
        for (final cell in row) {
          values.add(variableFor(cell));
        }
      }
      final placeholders = List<String>.filled(
        chunk.length,
        rowPlaceholder,
      ).join(',');
      await database.customInsert(
        '$verb INTO "$table" (${columns.map((c) => '"$c"').join(',')}) '
        'VALUES $placeholders',
        variables: values,
      );
    }
  }

  /// Local primary-key values, used to detect Merge conflicts truthfully.
  Future<Set<String>> localPrimaryKeyValues(BackupTableSpec spec) async {
    final keyColumns = await primaryKeyOf(spec.table);
    if (keyColumns.isEmpty) {
      throw BackupFailure(
        BackupFailureKind.validationFailed,
        detail: 'table "${spec.table}" has no primary key',
      );
    }
    final result = await database
        .customSelect(
          'SELECT ${keyColumns.map((c) => '"$c"').join(',')} '
          'FROM "${spec.table}"',
        )
        .get();
    return <String>{
      for (final row in result)
        keyColumns.map((column) => '${row.data[column]}').join('\u0000'),
    };
  }

  /// Maps a row to its primary-key token using [keyColumns] positions.
  static String primaryKeyToken(
    List<String> columns,
    List<Object?> row,
    List<String> keyColumns,
  ) {
    final positions = keyColumns.map(columns.indexOf).toList(growable: false);
    return positions.map((position) => '${row[position]}').join('\u0000');
  }

  /// Columns present in both the backup and the live table, in live order.
  Future<List<String>> restorableColumns(
    String table,
    List<String> backupColumns,
  ) async {
    final live = await liveColumns(table);
    final restorable = <String>[];
    for (final column in backupColumns) {
      if (live.contains(column)) {
        restorable.add(column);
      }
    }
    return restorable;
  }

  /// Projects [row] onto [targetColumns] (both given in backup order).
  static List<Object?> projectRow(
    List<String> backupColumns,
    List<Object?> row,
    List<String> targetColumns,
  ) =>
      <Object?>[
        for (final column in targetColumns)
          row[backupColumns.indexOf(column)],
      ];

  /// Turns a duplicated primary key into a truthful validation failure.
  static BackupFailure duplicateRow(String table, String token) =>
      BackupFailure(
        BackupFailureKind.validationFailed,
        detail: 'table "$table" contains duplicate identity "$token"',
      );

  /// Convenience for the app profile id, used by capture/preview code.
  Future<String?> singleProfileId() async {
    final result = await database.customSelect(
      'SELECT id FROM local_profiles ORDER BY slot LIMIT 1',
    ).get();
    if (result.isEmpty) {
      return null;
    }
    return result.first.data['id'] as String?;
  }

  Future<void> quickCheck() async {
    final result = await database.customSelect('PRAGMA quick_check').getSingle();
    if (result.data.values.single != 'ok') {
      throw const BackupFailure(BackupFailureKind.postRestoreFailed);
    }
  }

  /// Referential check run alongside [quickCheck] after a commit.
  ///
  /// `quick_check` proves page integrity but says nothing about relationships,
  /// so a restore that adopted a profile identity also verifies that no row was
  /// left pointing at a parent that is gone.
  Future<int> foreignKeyViolationCount() async {
    final rows = await database.customSelect('PRAGMA foreign_key_check').get();
    return rows.length;
  }

  /// True when [table] carries the canonical `profile_id` foreign key.
  Future<bool> hasProfileIdColumn(String table) async =>
      (await columnsOf(table)).contains('profile_id');

  /// Retires every row the receiving install owns, so a backup made on a
  /// different profile identity can be adopted.
  ///
  /// A restore preserves [BackupManifest.profileId] exactly — that id is the
  /// foreign-key anchor for nearly every table — so on a fresh install the
  /// locally seeded and device-bound rows belong to a profile that is about to
  /// stop existing. Left in place they trip the deferred foreign-key check at
  /// COMMIT and roll the entire restore back, which is why a backup could only
  /// ever be restored onto the install it came from. Every row removed here is
  /// either restored from the backup itself or rebuilt by the current app, per
  /// the registry's classification.
  Future<void> detachLocalProfileIdentity({required String liveProfileId}) async {
    for (final spec in BackupDomainRegistry.tables) {
      if (spec.table == 'local_profiles') {
        // The profile row goes with the exported-table pass, after its children
        // are gone.
        continue;
      }
      if (!await hasProfileIdColumn(spec.table)) {
        continue;
      }
      validateIdentifier(spec.table);
      await database.customStatement(
        'DELETE FROM "${spec.table}" WHERE profile_id = ?',
        <Object?>[liveProfileId],
      );
    }
  }

  Future<int> countRows(String table) async {
    validateIdentifier(table);
    final result =
        await database.customSelect('SELECT COUNT(*) AS c FROM "$table"').get();
    return result.first.read<int>('c');
  }

  Future<int> countRowsWhere(String table, String predicate) async {
    validateIdentifier(table);
    final result = await database
        .customSelect('SELECT COUNT(*) AS c FROM "$table" WHERE $predicate')
        .get();
    return result.first.read<int>('c');
  }

  /// Every exported table in registry order.
  static List<BackupTableSpec> get orderedTables =>
      BackupDomainRegistry.exportedTables;
}
