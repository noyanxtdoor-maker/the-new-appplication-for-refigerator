/// Restore preview, mode and result models (AG-3 / FR-S-016).
library;

import 'package:rmplanner/features/backup/domain/backup_domain_contract.dart';

enum BackupRestoreMode {
  /// Incoming backup replaces the current local profile's data in the selected
  /// packages.
  replace('Replace local data'),

  /// Incoming rows are added alongside existing rows; an existing stable
  /// identity is kept and the conflicting incoming row is skipped (AG-4).
  merge('Merge with local data');

  const BackupRestoreMode(this.label);

  final String label;
}

/// Truthful pre-write summary. Nothing here is invented: counts come from the
/// parsed payload and conflicts from the live database.
final class RestorePreview {
  const RestorePreview({
    required this.createdAtUtc,
    required this.appVersion,
    required this.schemaVersion,
    required this.containerVersion,
    required this.mode,
    required this.selectedDomains,
    required this.addedDependencyDomains,
    required this.rowCounts,
    required this.conflictCounts,
    required this.domainsAbsentFromBackup,
  });

  final DateTime createdAtUtc;
  final String appVersion;
  final int schemaVersion;
  final int containerVersion;
  final BackupRestoreMode mode;
  final Set<BackupDomain> selectedDomains;

  /// Dependency packages the user did not select but that the restore requires
  /// (OPD-4-017). Surfaced truthfully rather than added silently.
  final Set<BackupDomain> addedDependencyDomains;

  final Map<BackupDomain, int> rowCounts;

  /// Only meaningful for [BackupRestoreMode.merge].
  final Map<BackupDomain, int> conflictCounts;

  /// Domains this app version owns that the backup does not carry. Expected for
  /// an older backup and explicitly *not* corruption.
  final Set<BackupDomain> domainsAbsentFromBackup;

  int get totalRows =>
      rowCounts.values.fold<int>(0, (total, count) => total + count);

  int get totalConflicts =>
      conflictCounts.values.fold<int>(0, (total, count) => total + count);
}

final class RestoredDomainOutcome {
  const RestoredDomainOutcome({
    required this.domain,
    required this.rowsWritten,
    required this.conflictsSkipped,
    required this.dependencySkips,
    required this.skippedTableCount,
  });

  final BackupDomain domain;
  final int rowsWritten;

  /// Incoming rows skipped because the same stable identity already exists
  /// locally (Merge law, AG-4).
  final int conflictsSkipped;

  /// Incoming rows skipped because a row they depend on was skipped, so they
  /// could not be restored without creating an orphan (dependency-safe partial
  /// restore).
  final int dependencySkips;

  /// Tables in this domain where dependency skips occurred.
  final int skippedTableCount;
}

final class BackupRestoreResult {
  const BackupRestoreResult({
    required this.mode,
    required this.outcomes,
    required this.postRestoreWarnings,
    required this.rolledBack,
    this.identityAdopted = false,
    this.restoredProfileId,
  });

  final BackupRestoreMode mode;
  final List<RestoredDomainOutcome> outcomes;

  /// True when the backup was made on a different local profile than the one
  /// this install had, so the restore adopted the backup's identity. The app
  /// must re-resolve its profile afterwards or it keeps reading a profile that
  /// no longer exists.
  final bool identityAdopted;

  /// The profile id the restored data belongs to.
  final String? restoredProfileId;

  /// Non-fatal, truthful post-commit warnings (e.g. reminder schedules could
  /// not be rebuilt). A successful data restore is never rolled back for these.
  final List<String> postRestoreWarnings;

  final bool rolledBack;

  int get rowsWritten =>
      outcomes.fold<int>(0, (total, outcome) => total + outcome.rowsWritten);

  int get conflictsSkipped => outcomes.fold<int>(
        0,
        (total, outcome) => total + outcome.conflictsSkipped,
      );

  int get dependencySkips => outcomes.fold<int>(
        0,
        (total, outcome) => total + outcome.dependencySkips,
      );

  int get skippedTableCount => outcomes.fold<int>(
        0,
        (total, outcome) => total + outcome.skippedTableCount,
      );
}

final class BackupCreationResult {
  const BackupCreationResult({
    required this.fileName,
    required this.location,
    required this.byteLength,
    required this.domains,
    required this.rowCounts,
    required this.createdAtUtc,
    this.savedToDownloads = false,
  });

  final String fileName;
  final String location;
  final int byteLength;
  final Set<BackupDomain> domains;
  final Map<BackupDomain, int> rowCounts;
  final DateTime createdAtUtc;

  /// True when the file went straight into the user-visible Downloads folder,
  /// so the confirmation can say where it actually is.
  final bool savedToDownloads;

  int get totalRows =>
      rowCounts.values.fold<int>(0, (total, count) => total + count);
}
