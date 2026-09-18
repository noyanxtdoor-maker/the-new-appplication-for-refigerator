import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/background/background_work_gateway.dart';
import 'package:rmplanner/core/notifications/notification_gateway.dart';
import 'package:rmplanner/core/notifications/notification_payload.dart';
import 'package:rmplanner/features/notifications/application/reminder_background_runtime.dart';

import '../../../support/test_dependencies.dart';

final class _RuntimeNotificationGateway implements NotificationGateway {
  @override
  Stream<NotificationResponseIntent> get responses => const Stream.empty();

  @override
  Future<void> cancel(int platformId) async {}

  @override
  Future<void> initialize() async {}

  @override
  Future<List<PendingLocalNotification>> pending() async =>
      const <PendingLocalNotification>[];

  @override
  Future<void> schedule(LocalNotificationRequest request) async {}

  @override
  NotificationResponseIntent? takeInitialResponse() => null;
}

final class _RuntimeBackgroundGateway implements BackgroundWorkGateway {
  final List<BackgroundWorkSpec> enqueued = <BackgroundWorkSpec>[];

  @override
  Future<void> cancelUnique(String uniqueName) async {}

  @override
  Future<void> enqueueUnique(BackgroundWorkSpec work) async {
    enqueued.add(work);
  }

  @override
  Future<void> initialize() async {}

  @override
  Future<BackgroundGatewayWorkState> inspect(String uniqueName) async =>
      BackgroundGatewayWorkState.absent;
}

void main() {
  test(
    'T65/T66/T67 headless recovery uses an existing primary profile without domain writes',
    () async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      final profile = await buildTestRepository(
        database: database,
      ).completeOnboarding();
      final background = _RuntimeBackgroundGateway();

      final handled = await runReminderRuntime(
        databaseOverride: database,
        gatewayOverride: _RuntimeNotificationGateway(),
        backgroundGatewayOverride: background,
        reconcileOverride: () async {},
      );

      expect(handled, isTrue);
      expect(
        await database.select(database.localProfiles).get(),
        hasLength(1),
        reason: 'headless runtime resolves the existing primary profile only',
      );
      expect((await database.select(database.plannerTasks).get()), isEmpty);
      expect((await database.select(database.calendarEvents).get()), isEmpty);
      expect((await database.select(database.weeklyPlans).get()), isEmpty);
      expect((await database.select(database.contacts).get()), isEmpty);
      expect(background.enqueued.single.uniqueName, 'nt.reminder.refill');
      expect(profile.id, isNotEmpty);
    },
  );
}
