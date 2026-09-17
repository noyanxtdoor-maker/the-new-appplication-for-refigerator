/// Persistent-state coverage evaluation for the VS-18 backup contract.
///
/// Pure functions so the coverage gate can be proven to *fail* on deliberately
/// unclassified state, not merely to pass today.
library;

import 'package:rmplanner/features/backup/domain/backup_domain_contract.dart';
import 'package:rmplanner/features/backup/domain/backup_domain_registry.dart';

final class BackupCoverageReport {
  const BackupCoverageReport({
    required this.violations,
    required this.tableCount,
    required this.backupAndRestoreCount,
    required this.regenerateCount,
    required this.excludeCount,
  });

  final List<String> violations;
  final int tableCount;
  final int backupAndRestoreCount;
  final int regenerateCount;
  final int excludeCount;

  bool get isClean => violations.isEmpty;
}

abstract final class BackupCoverage {
  /// Compares the live schema's table names against the registry.
  ///
  /// Fails when a table exists in the schema but is unclassified, when a
  /// registry entry names a table that no longer exists, or when an exported
  /// table is not classified `BACKUP_AND_RESTORE` with a domain package.
  static BackupCoverageReport evaluateSchema(Iterable<String> schemaTables) {
    final violations = <String>[];
    final live = schemaTables.toSet();

    var backupAndRestore = 0;
    var regenerate = 0;
    var exclude = 0;

    for (final spec in BackupDomainRegistry.tables) {
      switch (spec.stateClass) {
        case PersistentStateClass.backupAndRestore:
          backupAndRestore++;
        case PersistentStateClass.regenerate:
          regenerate++;
        case PersistentStateClass.exclude:
          exclude++;
      }
      if (!live.contains(spec.table)) {
        violations.add(
          'registered table "${spec.table}" is not in the live schema',
        );
      }
      if (spec.exported) {
        if (spec.stateClass != PersistentStateClass.backupAndRestore) {
          violations.add(
            'exported table "${spec.table}" must be classified '
            'BACKUP_AND_RESTORE (was ${spec.stateClass.wireName})',
          );
        }
        if (spec.domain == null) {
          violations.add(
            'exported table "${spec.table}" has no domain package',
          );
        }
      } else if (spec.stateClass == PersistentStateClass.backupAndRestore) {
        violations.add(
          'table "${spec.table}" is classified BACKUP_AND_RESTORE but is not '
          'exported by any domain package',
        );
      }
      if (spec.replaceMode == BackupReplaceMode.deleteWhere &&
          (spec.replacePredicate == null ||
              spec.replacePredicate!.trim().isEmpty)) {
        violations.add(
          'table "${spec.table}" uses deleteWhere without a predicate',
        );
      }
      if (spec.replaceMode != BackupReplaceMode.deleteWhere &&
          spec.replacePredicate != null) {
        violations.add(
          'table "${spec.table}" declares a replace predicate that its '
          'replace mode never uses',
        );
      }
    }

    for (final table in live) {
      if (BackupDomainRegistry.forTable(table) == null) {
        violations.add(
          'UNCLASSIFIED persistent table "$table" — classify it as '
          'BACKUP_AND_RESTORE, REGENERATE or EXCLUDE',
        );
      }
    }

    for (final domain in BackupDomain.restoreOrder) {
      for (final dependency in domain.dependencies) {
        final dependencyIndex = BackupDomain.restoreOrder.indexOf(dependency);
        final domainIndex = BackupDomain.restoreOrder.indexOf(domain);
        if (dependencyIndex >= domainIndex) {
          violations.add(
            'domain "${domain.manifestKey}" depends on '
            '"${dependency.manifestKey}" but does not follow it in restore '
            'order',
          );
        }
      }
      if (BackupDomainRegistry.tablesOf(domain).isEmpty) {
        violations.add('domain "${domain.manifestKey}" owns no tables');
      }
    }

    return BackupCoverageReport(
      violations: violations,
      tableCount: live.length,
      backupAndRestoreCount: backupAndRestore,
      regenerateCount: regenerate,
      excludeCount: exclude,
    );
  }

  /// Verifies non-Drift persistence: every mechanism actually used in `lib/`
  /// must be registered, and every file touching it must be an allowed
  /// location of a registered store.
  static List<String> evaluateNonDrift(
    Map<String, Set<String>> usageByMechanism,
  ) {
    final violations = <String>[];

    for (final entry in usageByMechanism.entries) {
      final stores = BackupDomainRegistry.nonDriftStores
          .where((store) => store.mechanism == entry.key)
          .toList(growable: false);
      if (stores.isEmpty) {
        violations.add(
          'UNCLASSIFIED durable persistence mechanism "${entry.key}" is used '
          'in ${entry.value.join(', ')} — register a non-Drift store for it',
        );
        continue;
      }
      final allowed = <String>{
        for (final store in stores) ...store.allowedLocations,
      };
      for (final file in entry.value) {
        if (!allowed.contains(file)) {
          violations.add(
            '$file uses "${entry.key}" but is not an allowed location of any '
            'registered store',
          );
        }
      }
    }

    for (final store in BackupDomainRegistry.nonDriftStores) {
      if (store.allowedLocations.isEmpty && store.mechanism != 'none') {
        violations.add(
          'non-Drift store "${store.id}" has no allowed locations, so it '
          'cannot be enforced',
        );
      }
    }

    return violations;
  }
}
