import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/background/background_work_request.dart';
import 'package:rmplanner/core/background/reminder_recovery_request.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/ids/identifier_source.dart';
import 'package:rmplanner/features/notifications/data/drift_notification_foundation_repository.dart';
import 'package:rmplanner/features/privacy/data/drift_privacy_repository.dart';
import 'package:rmplanner/features/privacy/domain/privacy_settings.dart';

import '../../../support/test_dependencies.dart';

/// M7 section 27 / 53 P32 — Privacy Lock and preview mode are DEVICE-GLOBAL
/// settings that decide whether a deliverable reminder may show its source
/// copy.  Changing either therefore schedules a reconciliation of reminders
/// that are already registered.
///
/// The same law has a negative half that matters just as much: Privacy
/// preferences are stored once per device, so the marker needs a profile id,
/// and the contract explicitly forbids manufacturing one.  With no Local
/// Profile there is nothing registered to reconcile, and the write must be a
/// truthful no-op rather than a new profile.
void main() {
  late AppDatabase database;
  late ReminderRecoveryRequest marker;
  late DriftPrivacyRepository privacy;
  late DriftNotificationFoundationRepository notifications;
  late String profileId;

  setUp(() async {
    database = openMemoryDatabase();
    marker = ReminderRecoveryRequest(
      database: database,
      clock: FixedClock(DateTime.utc(2026, 9, 11, 10)),
      identifiers: const UuidIdentifierSource(),
    );
    privacy = DriftPrivacyRepository(
      database: database,
      clock: FixedClock(DateTime.utc(2026, 9, 11, 10)),
      reminderRepair: marker,
    );
    notifications = DriftNotificationFoundationRepository(
      database: database,
      clock: FixedClock(DateTime.utc(2026, 9, 11, 10)),
    );
  });

  tearDown(() => database.close());

  Future<BackgroundWorkRequest?> readMarkerFor(String id) =>
      notifications.readWorkRequest(ReminderRecoveryRequest.stableKeyFor(id));

  Future<int> profileCount() async =>
      (await database.select(database.localProfiles).get()).length;

  test('P32 enabling the Privacy Lock marks repair for the live profile', () async {
    profileId = (await buildTestRepository(
      database: database,
    ).completeOnboarding()).id;

    await privacy.setLockEnabled(true);

    final row = await readMarkerFor(profileId);
    expect(row, isNotNull);
    expect(row!.category, BackgroundWorkCategory.reminderRecovery);
    expect(row.ownerKind, BackgroundWorkOwnerKind.profile);
    expect(row.profileId, profileId);
    expect(
      await profileCount(),
      1,
      reason: 'a settings write never creates a profile',
    );
  });

  test('P32 a preview-mode change marks repair without touching profiles', () async {
    profileId = (await buildTestRepository(
      database: database,
    ).completeOnboarding()).id;

    await privacy.setNotificationPreviewMode(
      NotificationPreviewMode.showContent,
    );

    expect(await readMarkerFor(profileId), isNotNull);
    expect(await profileCount(), 1);
    final settings = await privacy.readSettings();
    expect(
      settings.notificationPreviewMode,
      NotificationPreviewMode.showContent,
      reason: 'the setting itself still persists exactly as before',
    );
  });

  test('P32 with no Local Profile the write is a no-op, never a new profile', () async {
    expect(
      await profileCount(),
      0,
      reason: 'precondition: this device has no Local Profile yet',
    );

    await privacy.setLockEnabled(true);
    await privacy.setNotificationPreviewMode(
      NotificationPreviewMode.showContent,
    );

    expect(
      await database.select(database.backgroundWorkRequests).get(),
      isEmpty,
      reason: 'there is nothing registered to reconcile, so no marker is due',
    );
    expect(
      await profileCount(),
      0,
      reason: 'section 53 P32 forbids creating a profile to satisfy the marker',
    );
    final settings = await privacy.readSettings();
    expect(
      settings.lockEnabled,
      isTrue,
      reason: 'the setting still persists; only the marker is skipped',
    );
  });

  test('P32 concurrent settings writes collapse into ONE pending marker', () async {
    profileId = (await buildTestRepository(
      database: database,
    ).completeOnboarding()).id;

    await privacy.setNotificationPreviewMode(
      NotificationPreviewMode.showContent,
    );
    final first = await readMarkerFor(profileId);
    await privacy.setNotificationPreviewMode(NotificationPreviewMode.hidden);
    final second = await readMarkerFor(profileId);

    expect(
      second!.createdAtUtc,
      first!.createdAtUtc,
      reason: 'a burst of setting changes is one repair episode, not many',
    );
    final rows = await database.select(database.backgroundWorkRequests).get();
    expect(
      rows
          .where((row) => row.stableKey.startsWith('reconcile:reminders:'))
          .length,
      1,
    );
  });
}
