import 'package:drift/drift.dart';
import 'package:rmplanner/core/background/reminder_recovery_request.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/time/app_clock.dart';
import 'package:rmplanner/features/privacy/application/privacy_repository.dart';
import 'package:rmplanner/features/privacy/domain/permission_summary.dart';
import 'package:rmplanner/features/privacy/domain/privacy_settings.dart';

final class DriftPrivacyRepository implements PrivacyRepository {
  const DriftPrivacyRepository({
    required this.database,
    required this.clock,
    this.reminderRepair,
  });

  static const String _primaryKey = 'primary';

  final AppDatabase database;
  final AppClock clock;

  /// M7 section 27 repair-intent port.  Preview mode and Privacy Lock decide
  /// whether a deliverable reminder may show its source copy, so changing
  /// either must schedule a reconciliation of already-registered reminders.
  /// This writes only the repair marker; it never creates a profile and
  /// never touches reminder policy or source truth.
  final ReminderRecoveryRequest? reminderRepair;

  @override
  Future<bool> isPrivacyLockEnabled() async {
    return (await readSettings()).lockEnabled;
  }

  @override
  Future<PermissionAudit> readPermissionAudit(
    OptionalPermission permission,
  ) async {
    final row =
        await (database.select(database.permissionAudits)
              ..where((table) => table.permissionKey.equals(permission.name))
              ..limit(1))
            .getSingleOrNull();
    if (row == null) {
      return const PermissionAudit.neverRequested();
    }
    return PermissionAudit(
      requestedByApp: row.requestedByApp,
      everGranted: row.everGranted,
    );
  }

  @override
  Future<PrivacySettings> readSettings() async {
    final row =
        await (database.select(database.privacyPreferences)
              ..where((table) => table.key.equals(_primaryKey))
              ..limit(1))
            .getSingleOrNull();
    if (row == null) {
      return const PrivacySettings.defaults();
    }
    return PrivacySettings(
      lockEnabled: row.lockEnabled,
      notificationPreviewMode: NotificationPreviewMode.values.byName(
        row.notificationPreviewMode,
      ),
    );
  }

  @override
  Future<void> recordPermissionGranted(OptionalPermission permission) async {
    final current = await readPermissionAudit(permission);
    await _writePermissionAudit(
      permission,
      requestedByApp: current.requestedByApp,
      everGranted: true,
    );
  }

  @override
  Future<void> recordPermissionRequested(OptionalPermission permission) async {
    final current = await readPermissionAudit(permission);
    await _writePermissionAudit(
      permission,
      requestedByApp: true,
      everGranted: current.everGranted,
    );
  }

  @override
  Future<PrivacySettings> setLockEnabled(bool enabled) async {
    final current = await readSettings();
    final updated = PrivacySettings(
      lockEnabled: enabled,
      notificationPreviewMode: current.notificationPreviewMode,
    );
    await _writeSettings(updated);
    // Section 27: the lock governs whether reminders may render source copy.
    await _markRepair();
    return updated;
  }

  @override
  Future<PrivacySettings> setNotificationPreviewMode(
    NotificationPreviewMode mode,
  ) async {
    final current = await readSettings();
    final updated = PrivacySettings(
      lockEnabled: current.lockEnabled,
      notificationPreviewMode: mode,
    );
    await _writeSettings(updated);
    // Section 27: a preview-mode change alters the rendered notification.
    await _markRepair();
    return updated;
  }

  /// Resolves the ONLY profile this device-global setting can affect.
  ///
  /// Privacy preferences are stored once per device, so the marker needs a
  /// profile id.  This reads the existing Local Profile only and NEVER
  /// creates one (contract section 53 P32: "no new profile creation"); when
  /// no profile exists yet there is nothing registered to reconcile, so the
  /// mark is a truthful no-op.
  Future<void> _markRepair() async {
    final repair = reminderRepair;
    if (repair == null) return;
    final profile =
        await (database.select(database.localProfiles)
              ..orderBy(<OrderClauseGenerator<$LocalProfilesTable>>[
                (table) => OrderingTerm.asc(table.createdAtUtc),
              ])
              ..limit(1))
            .getSingleOrNull();
    if (profile == null) return;
    await repair.mark(database, profileId: profile.id);
  }

  Future<void> _writePermissionAudit(
    OptionalPermission permission, {
    required bool requestedByApp,
    required bool everGranted,
  }) async {
    await database
        .into(database.permissionAudits)
        .insertOnConflictUpdate(
          PermissionAuditsCompanion.insert(
            permissionKey: permission.name,
            requestedByApp: Value<bool>(requestedByApp),
            everGranted: Value<bool>(everGranted),
            updatedAtUtc: clock.nowUtc(),
          ),
        );
  }

  Future<void> _writeSettings(PrivacySettings settings) async {
    await database
        .into(database.privacyPreferences)
        .insertOnConflictUpdate(
          PrivacyPreferencesCompanion.insert(
            lockEnabled: Value<bool>(settings.lockEnabled),
            notificationPreviewMode: Value<String>(
              settings.notificationPreviewMode.name,
            ),
            updatedAtUtc: clock.nowUtc(),
          ),
        );
  }
}
