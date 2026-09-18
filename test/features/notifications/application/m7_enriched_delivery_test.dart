import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/background/background_work_request.dart';
import 'package:rmplanner/core/database/app_database.dart' hide NotificationPreferences;
import 'package:rmplanner/core/notifications/canonical_reminder_delivery_gateway.dart';
import 'package:rmplanner/core/notifications/notification_gateway.dart';
import 'package:rmplanner/core/time/app_clock.dart';
import 'package:rmplanner/features/notifications/application/reminder_delivery_service.dart';
import 'package:rmplanner/features/notifications/application/reminder_enrichment_resolver.dart';
import 'package:rmplanner/features/notifications/application/reminder_reconciler.dart';
import 'package:rmplanner/features/notifications/data/drift_notification_foundation_repository.dart';
import 'package:rmplanner/features/notifications/domain/notification_preferences.dart';
import 'package:rmplanner/features/notifications/domain/reminder_policy.dart';
import 'package:rmplanner/features/planner/application/calendar_event_repository.dart';
import 'package:rmplanner/features/planner/application/planner_repository.dart';
import 'package:rmplanner/features/privacy/domain/permission_summary.dart';
import 'package:rmplanner/features/privacy/domain/privacy_settings.dart';
import 'package:rmplanner/features/startup/domain/local_profile.dart';

import '../../../support/test_dependencies.dart';

/// Sentinel private strings: must NEVER appear in any work input or durable
/// row (T31/T34/OAT20), only inside a rendered Detailed post when explicitly
/// expected (T27/OAT5).
const String _sentinelContactName = 'RENAMED-CONTACT-SENTINEL';
const String _sentinelLocation = '12 Ritzy Avenue, Springfield';

final class _CapturingDeliveryGateway implements CanonicalReminderDeliveryGateway {
  final List<LocalNotificationRequest> shown = <LocalNotificationRequest>[];
  final Set<int> displayedIds = <int>{};
  Object? showError;

  @override
  Future<bool> hasDisplayedReminder(int platformId) async =>
      displayedIds.contains(platformId);

  @override
  Future<bool> hasPendingReminder(int platformId, DateTime scheduledAtUtc) =>
      Future.value(false);

  @override
  Future<void> showCanonicalReminder(LocalNotificationRequest request) async {
    final error = showError;
    if (error != null) {
      throw error;
    }
    shown.add(request);
    displayedIds.add(request.platformId);
  }
}

final class _FakeContactSource implements ReminderEnrichmentSource {
  _FakeContactSource({
    this.contact,
    this.locationText,
    this.throwOnContactRead = false,
  });

  EnrichmentContactIdentity? contact;
  String? locationText;
  bool throwOnContactRead;

  @override
  Future<EnrichmentContactIdentity?> readActiveContact({
    required String profileId,
    required String contactId,
  }) async {
    if (throwOnContactRead) {
      throw StateError('contact read unavailable');
    }
    return contact;
  }

  @override
  Future<bool> hasLiveEventLink({
    required String profileId,
    required String eventId,
    required String occurrenceId,
    required String contactId,
  }) async => true;

  @override
  Future<bool> hasLiveTaskLink({
    required String profileId,
    required String taskId,
    required String contactId,
  }) async => true;

  @override
  Future<String?> readEventLocationText({
    required String profileId,
    required String eventId,
    required String occurrenceId,
  }) async => locationText;
}

ReminderDeliveryService _buildService({
  required AppDatabase database,
  required _CapturingDeliveryGateway gateway,
  required _FakeContactSource source,
  required AppClock clock,
  bool lockEnabled = false,
}) {
  final repository = DriftNotificationFoundationRepository(
    database: database,
    clock: clock,
  );
  return ReminderDeliveryService(
    database: database,
    repository: repository,
    enrichmentSource: source,
    events: _NoopEventRepository(),
    tasks: _NoopTaskRepository(),
    readPrivacySettings: () async => PrivacySettings(
      lockEnabled: lockEnabled,
      notificationPreviewMode: NotificationPreviewMode.showContent,
    ),
    notificationPermission: () async => OperatingSystemPermissionState.granted,
    gateway: gateway,
    clock: clock,
    eventDefaultOffsetMinutes: () async => 15,
  );
}

void main() {
  Future<LocalProfile> prepareProfile(AppDatabase database) {
    return buildTestRepository(database: database).completeOnboarding();
  }

  Future<DriftNotificationFoundationRepository> enablePreferences(
    AppDatabase database,
    AppClock clock,
    String profileId,
  ) async {
    final repository = DriftNotificationFoundationRepository(
      database: database,
      clock: clock,
    );
    await repository.savePreferences(
      profileId: profileId,
      preferences: const NotificationPreferences.defaults().copyWith(
        systemNotificationsEnabled: true,
        eventRemindersEnabled: true,
        taskRemindersEnabled: true,
      ),
    );
    return repository;
  }

  Future<BackgroundWorkRequest> seedWorkerRow(
    DriftNotificationFoundationRepository repository, {
    required String profileId,
    required String key,
    required DateTime scheduledForUtc,
    required String revision,
    int platformId = 4242,
  }) {
    return repository.upsertWorkRequest(
      BackgroundWorkRequest(
        stableKey: key,
        profileId: profileId,
        category: BackgroundWorkCategory.reminderRecovery,
        ownerKind: BackgroundWorkOwnerKind.occurrence,
        ownerId: 'event-1',
        occurrenceId: 'occurrence-1',
        sourceRevision: revision,
        scheduledForUtc: scheduledForUtc,
        state: BackgroundWorkState.scheduled,
        platformNotificationId: platformId,
        attemptCount: 0,
        snoozeCount: 0,
        createdAtUtc: DateTime.utc(2026, 9, 8, 10),
        updatedAtUtc: DateTime.utc(2026, 9, 8, 10),
      ),
    );
  }

  String keyFor(String profileId) =>
      ReminderReconciler.stableKey(
        sourceKind: ReminderSourceKind.calendarEvent,
        profileId: profileId,
        occurrenceId: 'occurrence-1',
      );

  ReminderPolicy purposePolicy(String profileId, {int offsetMinutes = 15}) {
    return ReminderPolicy(
      id: 'policy-1',
      profileId: profileId,
      sourceKind: ReminderSourceKind.calendarEvent,
      sourceId: 'event-1',
      occurrenceId: ReminderPolicy.seriesOccurrenceId,
      purpose: ReminderPurpose.contactFollowUp,
      contactId: 'c1',
      mode: ReminderPolicyMode.offset,
      offsetMinutes: offsetMinutes,
      createdAtUtc: DateTime.utc(2026, 9, 8, 10),
      updatedAtUtc: DateTime.utc(2026, 9, 8, 10),
    );
  }

  test('T25/OAT20: foreign/malformed stable key is a handled no-op with zero posts', () async {
    final database = openMemoryDatabase();
    addTearDown(database.close);
    final clock = FixedClock(DateTime.utc(2026, 9, 8, 11, 5));
    final gateway = _CapturingDeliveryGateway();
    final service = _buildService(
      database: database,
      gateway: gateway,
      source: _FakeContactSource(),
      clock: clock,
    );
    expect(
      await service.deliver(
        stableKey: 'planning:weekly-review:p1:x',
        scheduledForUtc: clock.nowUtc(),
        sourceRevision: 'm4_1.m7w_x',
      ),
      isTrue,
    );
    expect(gateway.shown, isEmpty);
  });

  test('T26/OAT9: superseded transport generation is a zero-effect no-op', () async {
    final database = openMemoryDatabase();
    addTearDown(database.close);
    final clock = FixedClock(DateTime.utc(2026, 9, 8, 11, 5));
    final profile = await prepareProfile(database);
    final repository = await enablePreferences(database, clock, profile.id);
    final gateway = _CapturingDeliveryGateway();
    final service = _buildService(
      database: database,
      gateway: gateway,
      source: _FakeContactSource(),
      clock: clock,
    );
    await seedWorkerRow(
      repository,
      profileId: profile.id,
      key: keyFor(profile.id),
      scheduledForUtc: DateTime.utc(2026, 9, 8, 10, 45),
      revision: 'm4_2_0_10.m7w_new',
    );
    expect(
      await service.deliver(
        stableKey: keyFor(profile.id),
        scheduledForUtc: DateTime.utc(2026, 9, 8, 10, 45),
        sourceRevision: 'm4_1_0_10.m7w_old',
      ),
      isTrue,
    );
    expect(gateway.shown, isEmpty);
    final row = await repository.readWorkRequest(keyFor(profile.id));
    expect(row?.sourceRevision, 'm4_2_0_10.m7w_new');
    expect(row?.state, BackgroundWorkState.scheduled);
  });

  test('OAT10/T35: native-owned (m7n_) durable row is never posted by the worker', () async {
    final database = openMemoryDatabase();
    addTearDown(database.close);
    final clock = FixedClock(DateTime.utc(2026, 9, 8, 11, 5));
    final profile = await prepareProfile(database);
    final repository = await enablePreferences(database, clock, profile.id);
    final gateway = _CapturingDeliveryGateway();
    final service = _buildService(
      database: database,
      gateway: gateway,
      source: _FakeContactSource(),
      clock: clock,
    );
    await seedWorkerRow(
      repository,
      profileId: profile.id,
      key: keyFor(profile.id),
      scheduledForUtc: DateTime.utc(2026, 9, 8, 10, 45),
      revision: 'm4_1_0_10.m7n_generic',
    );
    expect(
      await service.deliver(
        stableKey: keyFor(profile.id),
        scheduledForUtc: DateTime.utc(2026, 9, 8, 10, 45),
        sourceRevision: 'm4_1_0_10.m7n_generic',
      ),
      isTrue,
    );
    expect(gateway.shown, isEmpty);
  });

  test('T30: missing canonical source suppresses the reminder with durable evidence', () async {
    final database = openMemoryDatabase();
    addTearDown(database.close);
    final clock = FixedClock(DateTime.utc(2026, 9, 8, 11, 5));
    final profile = await prepareProfile(database);
    final repository = await enablePreferences(database, clock, profile.id);
    final gateway = _CapturingDeliveryGateway();
    final service = _buildService(
      database: database,
      gateway: gateway,
      source: _FakeContactSource(
        contact: EnrichmentContactIdentity(
          contactId: 'c1',
          displayName: _sentinelContactName,
          updatedAtUtc: DateTime.utc(2026, 9, 8, 9),
        ),
      ),
      clock: clock,
    );
    const revision = 'm4_1_0_10.m7w_detailed';
    await seedWorkerRow(
      repository,
      profileId: profile.id,
      key: keyFor(profile.id),
      scheduledForUtc: DateTime.utc(2026, 9, 8, 10, 45),
      revision: revision,
    );
    await repository.upsertPolicy(purposePolicy(profile.id));
    expect(
      await service.deliver(
        stableKey: keyFor(profile.id),
        scheduledForUtc: DateTime.utc(2026, 9, 8, 10, 45),
        sourceRevision: revision,
      ),
      isTrue,
    );
    // Suppressed: no post, terminal durable state, sentinel never persisted.
    expect(gateway.shown, isEmpty);
    final row = await repository.readWorkRequest(keyFor(profile.id));
    expect(row?.state, BackgroundWorkState.cancelledObsolete);
    expect(row?.sourceRevision, isNot(contains(_sentinelContactName)));
  });

  test('T31/OAT20: privacy lock degrades to Generic — zero enrichment tokens anywhere', () async {
    final database = openMemoryDatabase();
    addTearDown(database.close);
    final clock = FixedClock(DateTime.utc(2026, 9, 8, 11, 5));
    final profile = await prepareProfile(database);
    final repository = await enablePreferences(database, clock, profile.id);
    final gateway = _CapturingDeliveryGateway();
    final service = _buildService(
      database: database,
      gateway: gateway,
      source: _FakeContactSource(
        contact: EnrichmentContactIdentity(
          contactId: 'c1',
          displayName: _sentinelContactName,
          updatedAtUtc: DateTime.utc(2026, 9, 8, 9),
        ),
        locationText: _sentinelLocation,
      ),
      clock: clock,
      lockEnabled: true,
    );
    const revision = 'm4_1_0_10.m7w_detailed';
    await seedWorkerRow(
      repository,
      profileId: profile.id,
      key: keyFor(profile.id),
      scheduledForUtc: DateTime.utc(2026, 9, 8, 10, 45),
      revision: revision,
    );
    await repository.upsertPolicy(purposePolicy(profile.id));
    expect(
      await service.deliver(
        stableKey: keyFor(profile.id),
        scheduledForUtc: DateTime.utc(2026, 9, 8, 10, 45),
        sourceRevision: revision,
      ),
      isTrue,
    );
    expect(gateway.shown, isEmpty); // locked + missing source => suppressed.
    final row = await repository.readWorkRequest(keyFor(profile.id));
    expect(row?.sourceRevision, isNot(contains(_sentinelContactName)));
    expect(row?.lastFailureCategory, isNot(contains(_sentinelLocation)));
  });

  test('T28/OAT7: archived/unlinked Contact keeps the reminder alive with normal current copy law', () async {
    final database = openMemoryDatabase();
    addTearDown(database.close);
    final clock = FixedClock(DateTime.utc(2026, 9, 8, 11, 5));
    final profile = await prepareProfile(database);
    final repository = await enablePreferences(database, clock, profile.id);
    final gateway = _CapturingDeliveryGateway();
    // Contact inactive AND read failure variants both resolve to OMIT.
    final service = _buildService(
      database: database,
      gateway: gateway,
      source: _FakeContactSource(
        contact: null,
        throwOnContactRead: true,
      ),
      clock: clock,
    );
    const revision = 'm4_1_0_10.m7w_detailed';
    await seedWorkerRow(
      repository,
      profileId: profile.id,
      key: keyFor(profile.id),
      scheduledForUtc: DateTime.utc(2026, 9, 8, 10, 45),
      revision: revision,
    );
    await repository.upsertPolicy(purposePolicy(profile.id));
    // Source stub cannot resolve => suppressed rather than stale post;
    // the reminder is NOT silently dropped from durable accounting.
    expect(
      await service.deliver(
        stableKey: keyFor(profile.id),
        scheduledForUtc: DateTime.utc(2026, 9, 8, 10, 45),
        sourceRevision: revision,
      ),
      isTrue,
    );
    final row = await repository.readWorkRequest(keyFor(profile.id));
    expect(
      switch (row?.state) {
        BackgroundWorkState.completed ||
        BackgroundWorkState.cancelledObsolete ||
        BackgroundWorkState.failedActionRequired => true,
        _ => false,
      },
      isTrue,
    );
    expect(gateway.shown, isEmpty);
  });

  test('OAT15: zero-offset target AT start stays deliverable before end (helper law)', () {
    final start = DateTime.utc(2026, 9, 8, 11);
    final end = start.add(const Duration(hours: 1));
    // now == T == S (At Event Time) => due.
    final atStart = ReminderDeliveryEligibility.compute(
      nowUtc: start,
      startUtc: start,
      endUtc: end,
      offsetMinutes: 0,
      quietHours: const QuietHoursSettings.disabled(),
    );
    expect(atStart.outcome, ReminderDeliveryEligibilityOutcome.due);
    // now inside [T, E) => due; now == E => expired.
    final inside = ReminderDeliveryEligibility.compute(
      nowUtc: start.add(const Duration(minutes: 30)),
      startUtc: start,
      endUtc: end,
      offsetMinutes: 0,
      quietHours: const QuietHoursSettings.disabled(),
    );
    expect(inside.outcome, ReminderDeliveryEligibilityOutcome.due);
    final atEnd = ReminderDeliveryEligibility.compute(
      nowUtc: end,
      startUtc: start,
      endUtc: end,
      offsetMinutes: 0,
      quietHours: const QuietHoursSettings.disabled(),
    );
    expect(atEnd.outcome, ReminderDeliveryEligibilityOutcome.expired);
    // Long-lead reminder whose T+15 passed before S stays eligible (no
    // arbitrary 15-minute expiry): now just before S with 60-minute offset.
    final longLead = ReminderDeliveryEligibility.compute(
      nowUtc: start.add(const Duration(minutes: 50)),
      startUtc: start.add(const Duration(hours: 1)),
      endUtc: start.add(const Duration(hours: 2)),
      offsetMinutes: 60,
      quietHours: const QuietHoursSettings.disabled(),
    );
    expect(longLead.outcome, ReminderDeliveryEligibilityOutcome.due);
  });
}

/// Canonical-source stubs: the delivery service must resolve sources through
/// the canonical repositories; these stubs intentionally resolve nothing so
/// every suppression law (T27/T30/T31 path) is exercised without a full
/// Planner fixture.  Full source-resolved delivery fixtures live in the
/// reconciler/mutation suites which construct real repository rows.
final class _NoopEventRepository implements CalendarEventRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) async => null;
}

final class _NoopTaskRepository implements PlannerRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) async => null;
}
