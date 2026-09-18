// VS16 M8 — background diagnostics privacy and read-only law
// (Appendix T, T-E).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/background/background_work_request.dart';
import 'package:rmplanner/core/database/app_database.dart'
    hide NotificationPreferences;
import 'package:rmplanner/features/notifications/application/background_diagnostics_provider.dart';
import 'package:rmplanner/features/notifications/application/notification_providers.dart';
import 'package:rmplanner/features/notifications/data/drift_notification_foundation_repository.dart';

import '../../../support/test_dependencies.dart';

void main() {
  late AppDatabase database;
  late DriftNotificationFoundationRepository repository;
  late FixedClock clock;
  late FakeNotificationGateway notifications;
  late FakeBackgroundWorkGateway background;
  late String profileId;

  setUp(() async {
    database = openMemoryDatabase();
    addTearDown(database.close);
    clock = FixedClock(DateTime.utc(2026, 9, 10, 9));
    repository = DriftNotificationFoundationRepository(
      database: database,
      clock: clock,
    );
    notifications = FakeNotificationGateway();
    background = FakeBackgroundWorkGateway();
    profileId = (await buildTestRepository(
      database: database,
    ).completeOnboarding()).id;
  });

  ProviderContainer createContainer() {
    final container = ProviderContainer(
      overrides: [
        reminderRuntimeProfileIdProvider.overrideWithValue(profileId),
        notificationFoundationRepositoryProvider.overrideWithValue(repository),
        notificationGatewayProvider.overrideWithValue(notifications),
        backgroundWorkGatewayProvider.overrideWithValue(background),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('T68/T70 snapshot is typed, factual, and read-only', () async {
    await repository.upsertWorkRequest(
      BackgroundWorkRequest(
        stableKey: 'reminder:calendarEvent:p:o:base',
        profileId: profileId,
        category: BackgroundWorkCategory.reminderRecovery,
        ownerKind: BackgroundWorkOwnerKind.occurrence,
        ownerId: 'event-1',
        occurrenceId: 'o',
        sourceRevision: 'rev.m7n_',
        scheduledForUtc: DateTime.utc(2026, 9, 10, 11),
        state: BackgroundWorkState.scheduled,
        attemptCount: 0,
        snoozeCount: 0,
        createdAtUtc: clock.nowUtc(),
        updatedAtUtc: clock.nowUtc(),
      ),
    );
    final container = createContainer();
    final snapshot = await container.read(backgroundDiagnosticsProvider.future);
    expect(snapshot.countsByState, <String, int>{'scheduled': 1});
    expect(snapshot.recoveryState, 'Not recorded');
    expect(snapshot.recoveryAttempts, isNull);
    expect(snapshot.pendingNativeReminderCount, 0);
    expect(snapshot.workerState, isNotEmpty);
    // No reconcile/enqueue/permission side effects during the snapshot.
    expect(background.enqueueCount, 0);
    expect(notifications.scheduleCount, 0);
    // Only state names and technical categories are exposed.
    expect(
      snapshot.countsByState.keys.every(
        (key) => BackgroundWorkState.values.any((state) => state.name == key),
      ),
      isTrue,
    );
  });

  test('snapshot reports a queued repair marker factually', () async {
    await repository.beginReminderRepair(profileId: profileId);
    await repository.upsertWorkRequest(
      BackgroundWorkRequest(
        stableKey: 'reconcile:reminders:$profileId',
        profileId: profileId,
        category: BackgroundWorkCategory.reminderRecovery,
        ownerKind: BackgroundWorkOwnerKind.profile,
        ownerId: profileId,
        sourceRevision: 'reconcile_1',
        state: BackgroundWorkState.running,
        attemptCount: 2,
        snoozeCount: 0,
        lastAttemptAtUtc: clock.nowUtc(),
        createdAtUtc: clock.nowUtc(),
        updatedAtUtc: clock.nowUtc(),
      ),
    );
    final container = createContainer();
    final snapshot = await container.read(backgroundDiagnosticsProvider.future);
    expect(snapshot.recoveryState, 'running');
    expect(snapshot.recoveryAttempts, 2);
    expect(snapshot.lastAttemptAtUtc, isNotNull);
  });
}
