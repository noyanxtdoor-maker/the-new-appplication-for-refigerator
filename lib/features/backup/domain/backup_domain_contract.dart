/// VS-18 permanent backup contract — domain and persistent-state vocabulary.
///
/// Owner product law (2026-09-17): VS-18 is the permanent local backup /
/// restore framework for Next Transfer, not a one-time snapshot. Every durable
/// state source must declare exactly one [PersistentStateClass], and every
/// backup-capable domain declares its own format version, dependencies and
/// restore behaviour here so that future features *register* rather than edit
/// a monolithic file format.
library;

/// Exactly one class per durable store. Unclassified durable state is a
/// release-blocking failure.
enum PersistentStateClass {
  /// Canonical user-owned or user-configured state.
  backupAndRestore('BACKUP_AND_RESTORE'),

  /// Safely recreated by the current app: canonical seeds, derived
  /// projections/caches, platform schedules rebuilt from canonical policies.
  regenerate('REGENERATE'),

  /// Must never leave the device: credentials, API keys, OS permission state,
  /// device identifiers, platform notification ids, ephemeral runtime state.
  exclude('EXCLUDE');

  const PersistentStateClass(this.wireName);

  final String wireName;
}

/// How a Replace restore treats an existing table before inserting the
/// backup's rows.
enum BackupReplaceMode {
  /// Every row is user data — the table is emptied first.
  deleteAll,

  /// The table mixes app-regenerable identity rows with user rows; only the
  /// user rows matched by [BackupTableSpec.replacePredicate] are removed.
  deleteWhere,

  /// Seeded/derived identity rows are upserted by primary key so canonical
  /// identities (and their user customizations) survive. Nothing is deleted.
  upsertOnly,
}

/// How rows are written during restore.
enum BackupInsertMode {
  /// Plain insert — used when the target rows were just deleted.
  insert,

  /// `INSERT OR REPLACE` — used by `upsertOnly` tables and `deleteWhere`
  /// tables whose surviving rows must be updated in place.
  insertOrReplace,
}

/// One persistent Drift table inside a backup domain.
final class BackupTableSpec {
  const BackupTableSpec({
    required this.table,
    this.domain,
    this.stateClass = PersistentStateClass.backupAndRestore,
    this.exported = true,
    this.exportPredicate,
    this.replaceMode = BackupReplaceMode.deleteAll,
    this.replacePredicate,
    this.insertMode = BackupInsertMode.insert,
  });

  /// Physical SQLite table name. Must match the Drift schema exactly; the
  /// coverage gate proves that.
  final String table;

  /// Owning domain package. Non-null exactly when [exported] is true.
  final BackupDomain? domain;

  final PersistentStateClass stateClass;

  /// Included in a native backup's payload.
  final bool exported;

  /// Optional SQL predicate selecting the rows to export. `null` exports every
  /// row of the table.
  final String? exportPredicate;

  final BackupReplaceMode replaceMode;

  /// SQL predicate selecting the rows removed by [BackupReplaceMode.deleteWhere].
  final String? replacePredicate;

  final BackupInsertMode insertMode;
}

/// A dependency-ordered, dependency-safe package of tables (OPD-4-017).
enum BackupDomain {
  identity('identity'),
  preferences('preferences'),
  privacy('privacy'),
  notifications('notifications'),
  definitions('definitions'),
  taxonomy('taxonomy'),
  goals('goals'),
  planning('planning'),
  planner('planner'),
  outcomes('outcomes'),
  contacts('contacts'),
  maps('maps');

  const BackupDomain(this.manifestKey);

  /// Stable wire name. Never rename once shipped — it is a compatibility key.
  final String manifestKey;

  /// Restore order: every dependency appears earlier in this list.
  static const List<BackupDomain> restoreOrder = <BackupDomain>[
    identity,
    preferences,
    privacy,
    notifications,
    definitions,
    taxonomy,
    goals,
    planning,
    planner,
    outcomes,
    contacts,
    maps,
  ];

  Set<BackupDomain> get dependencies => switch (this) {
        identity => const <BackupDomain>{},
        preferences => const <BackupDomain>{identity},
        privacy => const <BackupDomain>{identity},
        notifications => const <BackupDomain>{identity},
        definitions => const <BackupDomain>{identity},
        taxonomy => const <BackupDomain>{identity},
        goals => const <BackupDomain>{
            identity,
            definitions,
            taxonomy,
          },
        planning => const <BackupDomain>{identity, goals},
        planner => const <BackupDomain>{identity, taxonomy, goals},
        outcomes => const <BackupDomain>{
            identity,
            goals,
            planner,
          },
        contacts => const <BackupDomain>{identity, planner},
        maps => const <BackupDomain>{identity},
      };

  /// The backup-format version of this domain package. Bumped only when the
  /// domain's serialized shape changes in a way that needs migration.
  int get formatVersion => 1;

  /// Human-readable label for preview and result surfaces.
  String get label => switch (this) {
        identity => 'Local profile',
        preferences => 'Preferences',
        privacy => 'Privacy preferences',
        notifications => 'Notifications and reminders',
        definitions => 'Life indicator definitions',
        taxonomy => 'Event types',
        goals => 'Goals',
        planning => 'Weekly planning',
        planner => 'Planner events and tasks',
        outcomes => 'Reports and progress history',
        contacts => 'Contacts',
        maps => 'Saved places',
      };
}

/// A durable store that is *not* a Drift table. Registered so that the
/// coverage gate can prove the non-Drift arm is classified too.
final class NonDriftStoreSpec {
  const NonDriftStoreSpec({
    required this.id,
    required this.stateClass,
    required this.mechanism,
    required this.evidence,
    this.allowedLocations = const <String>{},
  });

  /// Stable identifier, never renamed once shipped.
  final String id;

  final PersistentStateClass stateClass;

  /// Detected persistence technology, e.g. `flutter_secure_storage`.
  final String mechanism;

  /// Where the store is grounded in source, for review.
  final String evidence;

  /// Source paths allowed to touch this mechanism. Any new path touching it
  /// fails the gate until the store (or the new caller) is registered.
  final Set<String> allowedLocations;
}
