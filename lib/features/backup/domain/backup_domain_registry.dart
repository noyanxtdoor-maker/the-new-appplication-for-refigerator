/// The central VS-18 backup domain registry.
///
/// Owner product law (2026-09-17): every persistent Next Transfer state owner
/// is classified here as exactly one of `BACKUP_AND_RESTORE`, `REGENERATE` or
/// `EXCLUDE`. Future features register with this contract instead of editing a
/// monolithic backup file format.
///
/// The classification baseline matches the controlling Astra audit
/// (`NEXT_TRANSFER_ASTRA_VS18_BACKUP_EXPORT_RESTORE_FORENSIC_AUDIT_20260917.md`
/// §G2.7), including its corrections for `life_indicator_definitions` and
/// `activity_types`.
library;

import 'package:rmplanner/features/backup/domain/backup_domain_contract.dart';

abstract final class BackupDomainRegistry {
  /// Schema-47 baseline: 45 tables, 0 unclassified.
  static const int baselineTableCount = 45;
  static const int baselineBackupAndRestoreCount = 40;
  static const int baselineRegenerateCount = 2;
  static const int baselineExcludeCount = 3;

  /// Every persistent Drift table in schema 47, with its classification.
  static const List<BackupTableSpec> tables = <BackupTableSpec>[
    // ---------------------------------------------------------------- identity
    BackupTableSpec(
      table: 'local_profiles',
      domain: BackupDomain.identity,
    ),

    // ------------------------------------------------------------- preferences
    BackupTableSpec(
      table: 'planner_preferences',
      domain: BackupDomain.preferences,
    ),
    BackupTableSpec(
      table: 'appearance_preferences',
      domain: BackupDomain.preferences,
    ),
    BackupTableSpec(
      table: 'maps_preferences',
      domain: BackupDomain.preferences,
    ),

    // ----------------------------------------------------------------- privacy
    // AG-7: the user's Privacy Lock *intent* is user configuration and is
    // backed up. No OS credential, biometric template or keystore material
    // exists in this table, and none is ever exported.
    BackupTableSpec(
      table: 'privacy_preferences',
      domain: BackupDomain.privacy,
    ),

    // ----------------------------------------------------------- notifications
    // AG / §T: canonical reminder policies are restored; the device-bound
    // scheduling artifacts live only in `background_work_requests` (EXCLUDE)
    // and are rebuilt by the existing reconciliation pass.
    BackupTableSpec(
      table: 'notification_preferences',
      domain: BackupDomain.notifications,
    ),
    BackupTableSpec(
      table: 'reminder_policies',
      domain: BackupDomain.notifications,
    ),

    // ------------------------------------------------------------- definitions
    // Audit correction: the six canonical ids are deterministic and
    // regenerated, but `label`/`unit`/`position` are user-mutated when a Goal
    // is renamed. Upsert-by-id keeps canonical identity AND user edits, which
    // is the same table the Colors screen goal-slot labels read.
    BackupTableSpec(
      table: 'life_indicator_definitions',
      domain: BackupDomain.definitions,
      replaceMode: BackupReplaceMode.upsertOnly,
      insertMode: BackupInsertMode.insertOrReplace,
    ),

    // ---------------------------------------------------------------- taxonomy
    // Audit correction: `is_system` rows are regenerated, but user rows,
    // labels, archive flags and `color_value` (the V2 custom-colour law) are
    // user data. System identity rows are upserted in place rather than
    // deleted, so their customizations survive without duplication.
    // All rows are exported (system rows carry user colour/label edits); the
    // surviving system rows are then updated in place by primary key.
    BackupTableSpec(
      table: 'activity_types',
      domain: BackupDomain.taxonomy,
      replaceMode: BackupReplaceMode.deleteWhere,
      replacePredicate: 'is_system = 0',
      insertMode: BackupInsertMode.insertOrReplace,
    ),
    BackupTableSpec(
      table: 'activity_type_indicator_mappings',
      domain: BackupDomain.taxonomy,
    ),

    // ------------------------------------------------------------------- goals
    BackupTableSpec(table: 'goals', domain: BackupDomain.goals),
    BackupTableSpec(table: 'goal_activities', domain: BackupDomain.goals),
    BackupTableSpec(
      table: 'goal_achievement_events',
      domain: BackupDomain.goals,
    ),

    // ---------------------------------------------------------------- planning
    BackupTableSpec(table: 'weekly_plans', domain: BackupDomain.planning),
    BackupTableSpec(
      table: 'weekly_plan_goal_memberships',
      domain: BackupDomain.planning,
    ),
    BackupTableSpec(
      table: 'weekly_indicator_target_revisions',
      domain: BackupDomain.planning,
    ),
    BackupTableSpec(
      table: 'indicator_goal_revisions',
      domain: BackupDomain.planning,
    ),

    // ----------------------------------------------------------------- planner
    BackupTableSpec(table: 'planner_tasks', domain: BackupDomain.planner),
    BackupTableSpec(
      table: 'task_status_changes',
      domain: BackupDomain.planner,
    ),
    BackupTableSpec(table: 'calendar_events', domain: BackupDomain.planner),
    BackupTableSpec(
      table: 'calendar_event_exceptions',
      domain: BackupDomain.planner,
    ),
    BackupTableSpec(table: 'task_event_links', domain: BackupDomain.planner),
    BackupTableSpec(
      table: 'task_event_link_history',
      domain: BackupDomain.planner,
    ),
    BackupTableSpec(
      table: 'task_goal_contributions',
      domain: BackupDomain.planner,
    ),

    // ---------------------------------------------------------------- outcomes
    BackupTableSpec(table: 'outcome_reports', domain: BackupDomain.outcomes),
    BackupTableSpec(
      table: 'outcome_report_contribution_drafts',
      domain: BackupDomain.outcomes,
    ),
    BackupTableSpec(
      table: 'activity_ledger_entries',
      domain: BackupDomain.outcomes,
    ),

    // ---------------------------------------------------------------- contacts
    BackupTableSpec(table: 'contacts', domain: BackupDomain.contacts),
    BackupTableSpec(table: 'contact_methods', domain: BackupDomain.contacts),
    // Built-in groups carry deterministic per-profile ids
    // (`ContactBuiltInGroupIdentity.idForProfile`) and are upserted by id so
    // they are never duplicated and never deleted.
    BackupTableSpec(
      table: 'contact_groups',
      domain: BackupDomain.contacts,
      replaceMode: BackupReplaceMode.upsertOnly,
      insertMode: BackupInsertMode.insertOrReplace,
    ),
    BackupTableSpec(
      table: 'contact_group_memberships',
      domain: BackupDomain.contacts,
    ),
    BackupTableSpec(table: 'contact_tags', domain: BackupDomain.contacts),
    BackupTableSpec(
      table: 'contact_tag_memberships',
      domain: BackupDomain.contacts,
    ),
    BackupTableSpec(table: 'contact_notes', domain: BackupDomain.contacts),
    BackupTableSpec(
      table: 'contact_availabilities',
      domain: BackupDomain.contacts,
    ),
    BackupTableSpec(
      table: 'event_contact_links',
      domain: BackupDomain.contacts,
    ),
    BackupTableSpec(
      table: 'event_occurrence_participants',
      domain: BackupDomain.contacts,
    ),
    BackupTableSpec(
      table: 'task_contact_links',
      domain: BackupDomain.contacts,
    ),
    BackupTableSpec(
      table: 'saved_contact_filters',
      domain: BackupDomain.contacts,
      exportPredicate: 'is_system = 0',
      replaceMode: BackupReplaceMode.deleteWhere,
      replacePredicate: 'is_system = 0',
    ),

    // -------------------------------------------------------------------- maps
    BackupTableSpec(table: 'saved_places', domain: BackupDomain.maps),

    // ------------------------------------------------- REGENERATE (not exported)
    // Local idempotency/command ledgers with no cloud counterpart in this
    // beta. They are rebuilt by normal app operation, never imported.
    BackupTableSpec(
      table: 'goal_outbox_operations',
      stateClass: PersistentStateClass.regenerate,
      exported: false,
    ),
    BackupTableSpec(
      table: 'calendar_event_operations',
      stateClass: PersistentStateClass.regenerate,
      exported: false,
    ),

    // --------------------------------------------------- EXCLUDE (never leaves)
    // Device-bound first-run progress: re-running onboarding on a fresh
    // install is safe and desirable.
    BackupTableSpec(
      table: 'onboarding_checkpoints',
      stateClass: PersistentStateClass.exclude,
      exported: false,
    ),
    // Reflects *this* device's OS permission grants; meaninglessness after a
    // reinstall (permissions must be re-requested by Android).
    BackupTableSpec(
      table: 'permission_audits',
      stateClass: PersistentStateClass.exclude,
      exported: false,
    ),
    // Android scheduling artifacts, including `platform_notification_id` and
    // attempt/eligibility timestamps. Rebuilt by reminder reconciliation.
    BackupTableSpec(
      table: 'background_work_requests',
      stateClass: PersistentStateClass.exclude,
      exported: false,
    ),
  ];

  /// Non-Drift durable stores.
  static const List<NonDriftStoreSpec> nonDriftStores = <NonDriftStoreSpec>[
    NonDriftStoreSpec(
      id: 'secure_storage_auth_token_bundle',
      stateClass: PersistentStateClass.exclude,
      mechanism: 'flutter_secure_storage',
      evidence: 'lib/core/security/auth_token_store.dart',
      // `auth_token_store.dart` owns the driver; `main.dart` is the
      // composition root that wires it. Any other file touching the mechanism
      // fails the gate until it is registered.
      allowedLocations: <String>{
        'lib/core/security/auth_token_store.dart',
        'lib/main.dart',
      },
    ),
    NonDriftStoreSpec(
      id: 'device_bound_recovery_checkpoint',
      stateClass: PersistentStateClass.exclude,
      mechanism: 'app_private_file',
      evidence: 'lib/features/backup/data/backup_recovery_checkpoint_store.dart',
      allowedLocations: <String>{
        'lib/features/backup/data/backup_recovery_checkpoint_store.dart',
        // The composition root asks path_provider for the app-private
        // directory the checkpoint lives in.
        'lib/main.dart',
      },
    ),
    NonDriftStoreSpec(
      id: 'secure_storage_backup_checkpoint_key',
      stateClass: PersistentStateClass.exclude,
      mechanism: 'flutter_secure_storage',
      evidence: 'lib/features/backup/data/secure_checkpoint_key_store.dart',
      allowedLocations: <String>{
        'lib/features/backup/data/secure_checkpoint_key_store.dart',
      },
    ),
  ];

  /// Drift tables that are part of a native backup payload.
  static List<BackupTableSpec> get exportedTables =>
      tables.where((spec) => spec.exported).toList(growable: false);

  static BackupTableSpec? forTable(String table) {
    for (final spec in tables) {
      if (spec.table == table) {
        return spec;
      }
    }
    return null;
  }

  /// Tables belonging to [domain], in registry order.
  static List<BackupTableSpec> tablesOf(BackupDomain domain) =>
      tables.where((spec) => spec.domain == domain).toList(growable: false);

  static PersistentStateClass? classificationOf(String table) =>
      forTable(table)?.stateClass;

  /// Every domain that must appear in a current backup manifest.
  static const List<BackupDomain> domains = BackupDomain.restoreOrder;

  /// Domains required for [selection], including dependencies (OPD-4-017).
  /// Domain packages that carry at least one table.
  static Set<BackupDomain> get populatedDomains => <BackupDomain>{
        for (final spec in tables)
          if (spec.exported && spec.domain != null) spec.domain!,
      };

  static Set<BackupDomain> resolveDependencies(Iterable<BackupDomain> selection) {
    final resolved = <BackupDomain>{};
    void add(BackupDomain domain) {
      if (resolved.add(domain)) {
        for (final dependency in domain.dependencies) {
          add(dependency);
        }
      }
    }

    for (final domain in selection) {
      add(domain);
    }
    return resolved;
  }

  /// Dependency domains of [selection] that [available] does not provide.
  ///
  /// The selection itself is never reported here: a selected domain that is
  /// absent from the backup is a different, separately reported error.
  static Set<BackupDomain> missingDependencies(
    Iterable<BackupDomain> selection,
    Set<BackupDomain> available,
  ) {
    final selected = selection.toSet();
    final required = resolveDependencies(selected);
    return required.difference(selected).difference(available);
  }
}
