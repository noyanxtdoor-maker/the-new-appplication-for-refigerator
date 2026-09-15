import 'package:drift/drift.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/database/database_bootstrap.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/ids/identifier_source.dart';
import 'package:rmplanner/core/security/privacy_gate.dart';
import 'package:rmplanner/core/time/app_clock.dart';
import 'package:rmplanner/features/startup/application/startup_repository.dart';
import 'package:rmplanner/features/startup/domain/life_indicator_seed.dart';
import 'package:rmplanner/features/startup/domain/local_profile.dart';
import 'package:rmplanner/features/startup/domain/onboarding_checkpoint.dart';
import 'package:rmplanner/features/startup/domain/startup_snapshot.dart';

final class DriftStartupRepository implements StartupRepository {
  DriftStartupRepository({
    required this.database,
    required this.clock,
    required this.identifierSource,
    required this.privacyGate,
    required this.diagnostics,
  }) : _databaseBootstrap = DatabaseBootstrap(
         database: database,
         diagnostics: diagnostics,
       );

  static const String _primaryKey = 'primary';

  final AppDatabase database;
  final AppClock clock;
  final IdentifierSource identifierSource;
  final PrivacyGate privacyGate;
  final SanitizedDiagnostics diagnostics;
  final DatabaseBootstrap _databaseBootstrap;

  bool _databaseVerified = false;

  @override
  Future<StartupSnapshot> resolveStartup() async {
    await _verifyDatabase();
    final profileRow =
        await (database.select(database.localProfiles)
              ..where((table) => table.slot.equals(_primaryKey))
              ..limit(1))
            .getSingleOrNull();
    final checkpointRow =
        await (database.select(database.onboardingCheckpoints)
              ..where((table) => table.key.equals(_primaryKey))
              ..limit(1))
            .getSingleOrNull();
    final unlockRequired = await privacyGate.isUnlockRequired();

    diagnostics.record(
      'startup_resolved',
      context: <String, Object?>{
        'database_state': 'ready',
        'onboarding_stage': checkpointRow?.stage ?? 'none',
      },
    );

    return StartupSnapshot(
      profile: profileRow == null ? null : _mapProfile(profileRow),
      onboardingCheckpoint: checkpointRow == null
          ? null
          : _mapCheckpoint(checkpointRow),
      accountSessionState: AccountSessionState.localOnly,
      syncState: LocalSyncState.notConfigured,
      unlockRequired: unlockRequired,
    );
  }

  @override
  Future<OnboardingCheckpoint> beginOrResumeOnboarding() async {
    await _verifyDatabase();
    return database.transaction(() async {
      final existing = await _readCheckpoint();
      if (existing != null) {
        return _mapCheckpoint(existing);
      }

      final now = clock.nowUtc();
      final pendingProfileId = identifierSource.nextUuid();
      await database
          .into(database.onboardingCheckpoints)
          .insert(
            OnboardingCheckpointsCompanion.insert(
              pendingProfileId: pendingProfileId,
              stage: OnboardingStage.profileDraft.name,
              createdAtUtc: now,
              updatedAtUtc: now,
            ),
          );
      return OnboardingCheckpoint(
        pendingProfileId: pendingProfileId,
        stage: OnboardingStage.profileDraft,
        updatedAtUtc: now,
      );
    });
  }

  @override
  Future<OnboardingCheckpoint> saveOnboardingDraft(String? displayName) async {
    final checkpoint = await beginOrResumeOnboarding();
    final now = clock.nowUtc();
    final normalizedName = _normalizeDisplayName(displayName);
    await (database.update(
      database.onboardingCheckpoints,
    )..where((table) => table.key.equals(_primaryKey))).write(
      OnboardingCheckpointsCompanion(
        draftDisplayName: Value<String?>(normalizedName),
        updatedAtUtc: Value<DateTime>(now),
      ),
    );
    return OnboardingCheckpoint(
      pendingProfileId: checkpoint.pendingProfileId,
      stage: OnboardingStage.profileDraft,
      draftDisplayName: normalizedName,
      updatedAtUtc: now,
    );
  }

  @override
  Future<LocalProfile> completeOnboarding() async {
    await _verifyDatabase();
    return database.transaction(() async {
      final existingProfile = await _readPrimaryProfile();
      if (existingProfile != null) {
        await _ensureIndicatorSeeds(existingProfile.id);
        return _mapProfile(existingProfile);
      }

      final checkpoint =
          await _readCheckpoint() ?? await _createCheckpointInTransaction();
      final now = clock.nowUtc();
      final profileId = checkpoint.pendingProfileId;
      final localName = 'Local Profile ${profileId.substring(0, 8)}';

      await database
          .into(database.localProfiles)
          .insert(
            LocalProfilesCompanion.insert(
              id: profileId,
              localName: localName,
              displayName: Value<String?>(
                _normalizeDisplayName(checkpoint.draftDisplayName),
              ),
              createdAtUtc: now,
              updatedAtUtc: now,
            ),
          );
      await _ensureIndicatorSeeds(profileId);
      await (database.update(
        database.onboardingCheckpoints,
      )..where((table) => table.key.equals(_primaryKey))).write(
        OnboardingCheckpointsCompanion(
          stage: Value<String>(OnboardingStage.completed.name),
          updatedAtUtc: Value<DateTime>(now),
        ),
      );

      diagnostics.record(
        'local_profile_ready',
        context: const <String, Object?>{'onboarding_stage': 'completed'},
      );
      return LocalProfile(
        id: profileId,
        localName: localName,
        displayName: _normalizeDisplayName(checkpoint.draftDisplayName),
        createdAtUtc: now,
        updatedAtUtc: now,
      );
    });
  }

  @override
  Future<LocalProfile> updateDisplayName(String? displayName) async {
    await _verifyDatabase();
    final existing = await _readPrimaryProfile();
    if (existing == null) {
      throw StateError('No Local Profile exists');
    }
    final now = clock.nowUtc();
    final normalized = _normalizeDisplayName(displayName);
    await (database.update(
      database.localProfiles,
    )..where((table) => table.slot.equals(_primaryKey))).write(
      LocalProfilesCompanion(
        displayName: Value<String?>(normalized),
        updatedAtUtc: Value<DateTime>(now),
      ),
    );
    return LocalProfile(
      id: existing.id,
      localName: existing.localName,
      displayName: normalized,
      createdAtUtc: existing.createdAtUtc,
      updatedAtUtc: now,
    );
  }

  Future<void> _verifyDatabase() async {
    if (_databaseVerified) {
      return;
    }
    await _databaseBootstrap.verifyOpen();
    _databaseVerified = true;
  }

  Future<LocalProfileRow?> _readPrimaryProfile() {
    return (database.select(database.localProfiles)
          ..where((table) => table.slot.equals(_primaryKey))
          ..limit(1))
        .getSingleOrNull();
  }

  Future<OnboardingCheckpointRow?> _readCheckpoint() {
    return (database.select(database.onboardingCheckpoints)
          ..where((table) => table.key.equals(_primaryKey))
          ..limit(1))
        .getSingleOrNull();
  }

  Future<OnboardingCheckpointRow> _createCheckpointInTransaction() async {
    final now = clock.nowUtc();
    final profileId = identifierSource.nextUuid();
    await database
        .into(database.onboardingCheckpoints)
        .insert(
          OnboardingCheckpointsCompanion.insert(
            pendingProfileId: profileId,
            stage: OnboardingStage.profileDraft.name,
            createdAtUtc: now,
            updatedAtUtc: now,
          ),
        );
    return (await _readCheckpoint())!;
  }

  Future<void> _ensureIndicatorSeeds(String profileId) async {
    final now = clock.nowUtc();
    for (final seed in approvedLifeIndicatorSeeds) {
      await database
          .into(database.lifeIndicatorDefinitions)
          .insert(
            LifeIndicatorDefinitionsCompanion.insert(
              id: '$profileId:${seed.key}',
              profileId: profileId,
              indicatorKey: seed.key,
              label: seed.label,
              unit: seed.unit,
              position: seed.position,
              createdAtUtc: now,
            ),
            mode: InsertMode.insertOrIgnore,
          );
    }
    // M6 zero-goal law (owner-locked): completing onboarding no longer creates
    // any user Goal.  Life Indicator *definitions* above are configuration and
    // remain seeded; Goals are user data and are created only by the user's
    // explicit Create Goal / Starter Goal actions.  Identity repair for
    // profiles that already own Goals continues through the canonical read
    // paths (goal reads and the Home indicator read).
  }

  LocalProfile _mapProfile(LocalProfileRow row) {
    return LocalProfile(
      id: row.id,
      localName: row.localName,
      displayName: row.displayName,
      createdAtUtc: row.createdAtUtc.toUtc(),
      updatedAtUtc: row.updatedAtUtc.toUtc(),
    );
  }

  OnboardingCheckpoint _mapCheckpoint(OnboardingCheckpointRow row) {
    return OnboardingCheckpoint(
      pendingProfileId: row.pendingProfileId,
      stage: OnboardingStage.values.byName(row.stage),
      draftDisplayName: row.draftDisplayName,
      updatedAtUtc: row.updatedAtUtc.toUtc(),
    );
  }

  String? _normalizeDisplayName(String? displayName) {
    final normalized = displayName?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }
}
