// OWNER REVIEW #4 — fail-first coverage for the post-restore checkpoint repair.
//
// The audit reproduced this defect on the owner's device:
//
//   * the owner cleared app storage, so a fresh install minted profile
//     `34cd33bf-…` and wrote a COMPLETED onboarding checkpoint naming it;
//   * a whole-profile restore then adopted the backup's identity
//     `65771775-…` and retired the fresh profile;
//   * `onboarding_checkpoints` is deliberately NOT an exported backup domain
//     (it is replay/repair-class state), so the surviving row still named the
//     profile the restore had just removed.
//
// `_stateFromSnapshot` already fails closed for the mirror-image case (a
// completed checkpoint with no profile). This file pins the other half: a
// completed checkpoint that names a different profile than the live one is
// reconciled to the live profile, idempotently, and a checkpoint that is still
// mid-onboarding is never disturbed.

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/features/startup/domain/onboarding_checkpoint.dart';

import '../../../support/test_dependencies.dart';

void main() {
  /// Leaves the device in exactly the audited post-restore shape: a live
  /// profile, and a COMPLETED checkpoint that names a different — and no longer
  /// existing — profile, because the restore adopted the backup's identity and
  /// `onboarding_checkpoints` is not an exported backup domain.
  Future<void> stageStaleCheckpoint(
    AppDatabase database,
    String retiredProfileId,
  ) async {
    await (database.update(database.onboardingCheckpoints)..where(
          (table) => table.key.equals('primary'),
        ))
        .write(
          OnboardingCheckpointsCompanion(
            pendingProfileId: Value<String>(retiredProfileId),
          ),
        );
  }

  test('a completed checkpoint naming a retired profile is reconciled', () async {
    final database = openMemoryDatabase();
    addTearDown(database.close);
    final repository = buildTestRepository(database: database);

    final live = (await repository.completeOnboarding()).id;
    // The fresh install's own profile id, which the restore retired.
    const retired = '34cd33bf-23a8-4ad7-b286-b58f8f257e0e';
    expect(retired, isNot(live));
    await stageStaleCheckpoint(database, retired);

    // The defect, asserted directly: the raw row names a profile that does not
    // exist while the live profile is a different one.
    final staleRow = await (database.select(
      database.onboardingCheckpoints,
    )).getSingle();
    expect(
      staleRow.pendingProfileId,
      retired,
      reason: 'the fixture must reproduce the audited inconsistency',
    );
    expect(staleRow.stage, OnboardingStage.completed.name);

    final resolved = await repository.resolveStartup();
    expect(resolved.profile!.id, live);
    expect(
      resolved.onboardingCheckpoint!.pendingProfileId,
      live,
      reason: 'the checkpoint must follow the profile that actually exists',
    );
    expect(resolved.onboardingCheckpoint!.stage, OnboardingStage.completed);
  });

  test('the repair is idempotent', () async {
    final database = openMemoryDatabase();
    addTearDown(database.close);
    final repository = buildTestRepository(database: database);
    final live = (await repository.completeOnboarding()).id;
    await stageStaleCheckpoint(database, 'ffffffff-1111-4222-8333-444444444444');

    final first = await repository.resolveStartup();
    final second = await repository.resolveStartup();
    final third = await repository.resolveStartup();
    expect(first.onboardingCheckpoint!.pendingProfileId, live);
    expect(second.onboardingCheckpoint!.pendingProfileId, live);
    expect(third.onboardingCheckpoint!.pendingProfileId, live);
    expect(
      third.onboardingCheckpoint!.updatedAtUtc,
      second.onboardingCheckpoint!.updatedAtUtc,
      reason: 'an already-consistent row must not be rewritten again',
    );
  });

  test('a consistent checkpoint is never rewritten', () async {
    final database = openMemoryDatabase();
    addTearDown(database.close);
    final repository = buildTestRepository(database: database);
    final profileId = (await repository.completeOnboarding()).id;

    final first = await repository.resolveStartup();
    final second = await repository.resolveStartup();
    expect(first.onboardingCheckpoint!.pendingProfileId, profileId);
    expect(
      second.onboardingCheckpoint!.updatedAtUtc,
      first.onboardingCheckpoint!.updatedAtUtc,
      reason: 'an already-consistent row must not be touched at all',
    );
  });

  test('a checkpoint mid-onboarding is left alone', () async {
    final database = openMemoryDatabase();
    addTearDown(database.close);
    final repository = buildTestRepository(database: database);
    final pending = (await repository.beginOrResumeOnboarding()).pendingProfileId;

    final snapshot = await repository.resolveStartup();
    expect(snapshot.profile, isNull);
    expect(
      snapshot.onboardingCheckpoint!.pendingProfileId,
      pending,
      reason: 'a draft must never be rewritten into a completed checkpoint',
    );
    expect(snapshot.onboardingCheckpoint!.stage, OnboardingStage.profileDraft);
  });
}
