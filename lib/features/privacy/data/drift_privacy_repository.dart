import 'package:drift/drift.dart';
import 'package:rmplanner/core/background/reminder_recovery_request.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/time/app_clock.dart';
import 'package:rmplanner/features/privacy/application/privacy_repository.dart';
import 'package:rmplanner/features/privacy/domain/permission_summary.dart';
import 'package:rmplanner/features/privacy/domain/privacy_settings.dart';

final class DriftPrivacyRepository implements PrivacyRepository {
  const DriftPrivacyRepository({required this.database, required this.clock});

  static const String _primaryKey = 'primary';

  final AppDatabase database;
  final AppClock clock;

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
    await _markReminderRepairForPrimary();
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
    await _markReminderRepairForPrimary();
    return updated;
  }

  /// Device-scoped privacy truth belongs to the single primary profile; the
  /// repair marker is written there without creating any profile.
  Future<void> _markReminderRepairForPrimary() async {
    try {
      final profile =
          await (database.select(database.localProfiles)
                ..where((table) => table.slot.equals('primary'))
                ..limit(1))
              .getSingleOrNull();
      if (profile == null) return;
      await ReminderRecoveryRequest.markDirty(
        database: database,
        profileId: profile.id,
        nowUtc: clock.nowUtc(),
      );
    } on Object {
      // The privacy write is already durable; repair retries on next trigger.
    }
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
