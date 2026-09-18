// VS16 M8 — recovery ownership: marker lifecycle, KEEP policy, refill arm,
// reserved-ID sweep boundaries (Appendix T, T-D: T42–T46).
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/background/background_work_gateway.dart';
import 'package:rmplanner/core/background/background_work_request.dart';
import 'package:rmplanner/core/background/reminder_recovery_request.dart';
import 'package:rmplanner/core/database/app_database.dart'
    hide NotificationPreferences;
import 'package:rmplanner/core/notifications/flutter_local_notifications_launcher_badge_gateway.dart';
import 'package:rmplanner/core/notifications/notification_gateway.dart';
import 'package:rmplanner/core/notifications/notification_payload.dart';
import 'package:rmplanner/features/notifications/application/reminder_background_runtime.dart';
import 'package:rmplanner/features/notifications/data/drift_notification_foundation_repository.dart';

import '../../../support/test_dependencies.dart';

final class _InspectingNotificationGateway implements NotificationGateway {
  _InspectingNotificationGateway(this.pendingItems);

  final List<PendingLocalNotification> pendingItems;
  final List<int> cancelledIds = <int>[];

  @override
  Future<List<PendingLocalNotification>> pending() async => pendingItems;

  @override
  Stream<NotificationResponseIntent> get responses => const Stream.empty();

  @override
  Future<void> initialize() async {}

  @override
  Future<void> schedule(LocalNotificationRequest request) async {}

  @override
  Future<void> cancel(int platformId) async {
    cancelledIds.add(platformId);
  }

  @override
  NotificationResponseIntent? takeInitialResponse() => null;
}

final class _DeferredRecoveryGateway implements BackgroundWorkGateway {
  final enqueued = <BackgroundWorkSpec>[];

  @override
  Future<void> enqueueUnique(BackgroundWorkSpec work) async {
    work.validate();
    enqueued.add(work);
  }

  @override
  Future<void> initialize() async {}

  @override
  Future<void> cancelUnique(String uniqueName) async {}

  @override
  Future<BackgroundGatewayWorkState> inspect(String uniqueName) async =>
      BackgroundGatewayWorkState.absent;
}

BackgroundWorkRequest _reminderRow({
  required String profileId,
  required String key,
  required int platformId,
  BackgroundWorkState state = BackgroundWorkState.scheduled,
}) => BackgroundWorkRequest(
  stableKey: key,
  profileId: profileId,
  category: BackgroundWorkCategory.reminderRecovery,
  ownerKind: BackgroundWorkOwnerKind.occurrence,
  ownerId: 'event-1',
  occurrenceId: 'occurrence-1',
  sourceRevision: 'rev.m7n_',
  scheduledForUtc: DateTime.utc(2026, 9, 10, 11),
  state: state,
  attemptCount: 0,
  snoozeCount: 0,
  platformNotificationId: platformId,
  createdAtUtc: DateTime.utc(2026, 9, 1),
  updatedAtUtc: DateTime.utc(2026, 9, 1),
);

PendingLocalNotification _pendingItem({
  required int platformId,
  required String profileId,
}) => PendingLocalNotification(
  platformId: platformId,
  payload: NotificationPayloadCodec.encode(
    NotificationResponseIntent(
      profileId: profileId,
      sourceKind: NotificationSourceKind.calendarEvent,
      sourceId: 'event-1',
      occurrenceId: 'occurrence-1',
      action: NotificationResponseAction.open,
      generation: 0,
    ),
  ),
);

void main() {
  group('M8 recovery ownership', () {
    late AppDatabase database;
    late DriftNotificationFoundationRepository repository;
    late String profileId;

    setUp(() async {
      database = openMemoryDatabase();
      addTearDown(database.close);
      repository = DriftNotificationFoundationRepository(
        database: database,
        clock: FixedClock(DateTime.utc(2026, 9, 10, 9)),
      );
      profileId = (await buildTestRepository(
        database: database,
      ).completeOnboarding()).id;
    });

    test(
      'T42 marker lifecycle: completed revision survives; newer queued wins',
      () async {
        final markerKey = ReminderRecoveryRequest.stableKeyFor(profileId);
        expect(
          await ReminderRecoveryRequest.markRunning(
            database: database,
            profileId: profileId,
            nowUtc: DateTime.utc(2026, 9, 10, 9),
          ),
          isFalse,
          reason: 'no marker exists yet; reads never create repairs',
        );
        await ReminderRecoveryRequest.markDirty(
          database: database,
          profileId: profileId,
          nowUtc: DateTime.utc(2026, 9, 10, 9),
        );
        final revision = (await repository.readWorkRequest(
          markerKey,
        ))!.sourceRevision!;
        expect(
          await ReminderRecoveryRequest.markRunning(
            database: database,
            profileId: profileId,
            nowUtc: DateTime.utc(2026, 9, 10, 9, 1),
          ),
          isTrue,
        );
        // A mutation during the pass re-queues the marker for a trailing pass.
        await ReminderRecoveryRequest.markDirty(
          database: database,
          profileId: profileId,
          nowUtc: DateTime.utc(2026, 9, 10, 9, 2),
        );
        await ReminderRecoveryRequest.markCompleted(
          database: database,
          profileId: profileId,
          nowUtc: DateTime.utc(2026, 9, 10, 9, 3),
        );
        final afterPass = await repository.readWorkRequest(markerKey);
        expect(afterPass!.state, BackgroundWorkState.queued);
        expect(afterPass.sourceRevision, isNot(revision));
        // Completing the trailing pass closes the episode.
        expect(
          await ReminderRecoveryRequest.markRunning(
            database: database,
            profileId: profileId,
            nowUtc: DateTime.utc(2026, 9, 10, 9, 4),
          ),
          isTrue,
        );
        await ReminderRecoveryRequest.markCompleted(
          database: database,
          profileId: profileId,
          nowUtc: DateTime.utc(2026, 9, 10, 9, 5),
        );
        final settled = await repository.readWorkRequest(markerKey);
        expect(settled!.state, BackgroundWorkState.completed);
        expect(settled.completedAtUtc, isNotNull);
        // An older result can never complete a newer revision.
        await ReminderRecoveryRequest.markDirty(
          database: database,
          profileId: profileId,
          nowUtc: DateTime.utc(2026, 9, 10, 9, 6),
        );
        await ReminderRecoveryRequest.markRunning(
          database: database,
          profileId: profileId,
          nowUtc: DateTime.utc(2026, 9, 10, 9, 7),
        );
        await database
            .into(database.backgroundWorkRequests)
            .insertOnConflictUpdate(
              BackgroundWorkRequestsCompanion.insert(
                stableKey: markerKey,
                profileId: Value(profileId),
                category: BackgroundWorkCategory.reminderRecovery.name,
                ownerKind: BackgroundWorkOwnerKind.profile.name,
                ownerId: Value(profileId),
                sourceRevision: Value('reconcile_newer'),
                state: BackgroundWorkState.queued.name,
                attemptCount: const Value(0),
                snoozeCount: const Value(0),
                createdAtUtc: DateTime.utc(2026, 9, 10, 9, 8),
                updatedAtUtc: DateTime.utc(2026, 9, 10, 9, 8),
              ),
            );
        await ReminderRecoveryRequest.markCompleted(
          database: database,
          profileId: profileId,
          nowUtc: DateTime.utc(2026, 9, 10, 9, 9),
        );
        final newest = await repository.readWorkRequest(markerKey);
        expect(newest!.state, BackgroundWorkState.queued);
        expect(newest.sourceRevision, 'reconcile_newer');
      },
    );

    test(
      'T43/T44 successful recovery re-arms exactly one KEEP refill; failure arms nothing',
      () async {
        final background = _DeferredRecoveryGateway();
        // A failing pass must not arm any refill and keeps the marker retrying.
        await ReminderRecoveryRequest.markDirty(
          database: database,
          profileId: profileId,
          nowUtc: DateTime.utc(2026, 9, 10, 9),
        );
        final failed = await runReminderRuntime(
          backgroundGatewayOverride: background,
          databaseOverride: database,
          gatewayOverride: _InspectingNotificationGateway(
            const <PendingLocalNotification>[],
          ),
          reconcileOverride: () async => throw StateError('injected failure'),
        );
        expect(failed, isFalse);
        expect(background.enqueued, isEmpty);
        final failedMarker = await repository.readWorkRequest(
          ReminderRecoveryRequest.stableKeyFor(profileId),
        );
        expect(failedMarker, isNotNull);
        expect(
          failedMarker!.state,
          anyOf(
            BackgroundWorkState.retryScheduled,
            BackgroundWorkState.failedActionRequired,
          ),
        );
        expect(failedMarker.lastFailureCategory, 'runtime_unavailable');
        expect(failedMarker.lastFailureCategory, isNot(contains('StateError')));

        background.enqueued.clear();
        await ReminderRecoveryRequest.markDirty(
          database: database,
          profileId: profileId,
          nowUtc: DateTime.utc(2026, 9, 10, 10),
        );
        final recovered = await runReminderRuntime(
          backgroundGatewayOverride: background,
          databaseOverride: database,
          gatewayOverride: _InspectingNotificationGateway(
            const <PendingLocalNotification>[],
          ),
          reconcileOverride: () async {},
        );
        expect(recovered, isTrue);
        expect(background.enqueued, hasLength(1));
        final refill = background.enqueued.single;
        expect(refill.uniqueName, 'nt.reminder.refill');
        expect(refill.taskName, 'nt.reminder.recovery');
        expect(refill.inputData, isEmpty);
        expect(refill.initialDelay, const Duration(hours: 24));
        expect(refill.existingPolicy, BackgroundExistingWorkPolicy.keep);
        final marker = await repository.readWorkRequest(
          ReminderRecoveryRequest.stableKeyFor(profileId),
        );
        expect(marker!.state, BackgroundWorkState.completed);
      },
    );

    test(
      'T46 sweep cancels only owned stale items; badge ID and unknown payloads untouched',
      () async {
        await repository.upsertWorkRequest(
          _reminderRow(
            profileId: profileId,
            key: 'reminder:calendarEvent:$profileId:stale:base',
            platformId: 101,
            state: BackgroundWorkState.cancelledObsolete,
          ),
        );
        await repository.upsertWorkRequest(
          _reminderRow(
            profileId: profileId,
            key: 'reminder:calendarEvent:$profileId:live:base',
            platformId: 102,
          ),
        );
        final gateway = _InspectingNotificationGateway(
          <PendingLocalNotification>[
            // Owned stale: cancelled durable row -> cancelled.
            _pendingItem(platformId: 101, profileId: profileId),
            // Owned live: scheduled durable row -> kept.
            _pendingItem(platformId: 102, profileId: profileId),
            // Badge reservation is never touched.
            PendingLocalNotification(
              platformId:
                  FlutterLocalNotificationsLauncherBadgeGateway.notificationId,
              payload: 'badge',
            ),
            // Unknown/foreign payload: diagnostic unknown, never cancelled.
            PendingLocalNotification(
              platformId: 103,
              payload: 'not-a-v1-payload',
            ),
            // Valid payload but different profile: no ownership proof -> kept.
            _pendingItem(platformId: 104, profileId: 'other-profile'),
            // No durable row at all but owned payload: orphan -> cancelled.
            _pendingItem(platformId: 105, profileId: profileId),
          ],
        );
        await runReminderRuntime(
          backgroundGatewayOverride: _DeferredRecoveryGateway(),
          databaseOverride: database,
          gatewayOverride: gateway,
          reconcileOverride: () async {},
        );
        expect(gateway.cancelledIds, <int>[101, 105]);
      },
    );
  });
}
