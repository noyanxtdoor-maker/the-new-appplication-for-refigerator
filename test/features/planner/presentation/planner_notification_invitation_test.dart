// OWNER REVIEW #4 — fail-first coverage for the first-Planner notification
// invitation.
//
// The audit proved no first-Planner notification education existed anywhere in
// the app, so a beta user who never discovered Android's notification settings
// received nothing and had no way to find out why.
//
// These tests pin the owner's required behaviour exactly:
//   * the invitation appears on the first Planner visit;
//   * NOTHING requests the Android permission until the user taps Enable;
//   * "Not now" leaves the Planner usable and does not request anything;
//   * a later Planner visit offers another chance (a permanent "already shown"
//     flag could never do that);
//   * Enable goes through the ONE existing serialized permission path;
//   * a permanent denial offers App Settings instead of a dead dialog;
//   * a successful grant leaves no stale invitation behind.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/background/background_work_gateway.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/notifications/notification_gateway.dart';
import 'package:rmplanner/core/notifications/notification_payload.dart';
import 'package:rmplanner/features/notifications/application/notification_foundation_repository.dart';
import 'package:rmplanner/features/notifications/application/notification_providers.dart';
import 'package:rmplanner/features/notifications/data/drift_notification_foundation_repository.dart';
import 'package:rmplanner/features/planner/presentation/planner_notification_invitation.dart';
import 'package:rmplanner/features/privacy/application/privacy_providers.dart';
import 'package:rmplanner/features/privacy/domain/permission_summary.dart';
import 'package:rmplanner/features/startup/application/startup_providers.dart';

import '../../../support/test_dependencies.dart';

void main() {
  late ProviderContainer container;
  late FakePermissionGateway permissionGateway;
  late NotificationFoundationRepository repository;
  late String profileId;

  Future<void> buildContainer({
    OperatingSystemPermissionState requestResult =
        OperatingSystemPermissionState.granted,
    Map<OptionalPermission, OperatingSystemPermissionState>? states,
  }) async {
    final database = openMemoryDatabase();
    addTearDown(database.close);
    final startupRepository = buildTestRepository(database: database);
    profileId = (await startupRepository.completeOnboarding()).id;
    repository = DriftNotificationFoundationRepository(
      database: database,
      clock: FixedClock(DateTime.utc(2026, 9, 18, 12)),
    );
    final privacy = TestPrivacyDependencies(
      database: database,
      permissionGateway: FakePermissionGateway(
        requestResult: requestResult,
        states: states,
      ),
    );
    permissionGateway = privacy.permissionGateway;
    container = ProviderContainer(
      overrides: <Override>[
        startupRepositoryProvider.overrideWithValue(startupRepository),
        diagnosticsProvider.overrideWithValue(SanitizedDiagnostics()),
        privacyRepositoryProvider.overrideWithValue(privacy.repository),
        permissionGatewayProvider.overrideWithValue(privacy.permissionGateway),
        notificationFoundationRepositoryProvider.overrideWithValue(repository),
        notificationGatewayProvider.overrideWithValue(_FakeNotificationGateway()),
        backgroundWorkGatewayProvider.overrideWithValue(_FakeBackgroundGateway()),
      ],
    );
    addTearDown(container.dispose);
    await container.read(startupControllerProvider.notifier).initialize();
    container.read(notificationSettingsControllerProvider);
    await container.read(notificationSettingsControllerProvider.notifier).load();
  }

  Future<void> pumpInvitation(WidgetTester tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: PlannerNotificationInvitation()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('first Planner visit invites without requesting anything',
      (tester) async {
    await buildContainer();
    await pumpInvitation(tester);

    expect(
      find.byKey(PlannerNotificationInvitation.enableKey),
      findsOneWidget,
    );
    expect(find.text('Turn on notifications?'), findsOneWidget);
    expect(find.text('Not now'), findsOneWidget);
    expect(
      permissionGateway.requestCount,
      0,
      reason: 'opening the Planner must never raise the Android dialog',
    );
  });

  testWidgets('Not now hides it, keeps the Planner usable, and requests nothing',
      (tester) async {
    await buildContainer();
    await pumpInvitation(tester);

    await tester.tap(find.byKey(PlannerNotificationInvitation.notNowKey));
    await tester.pumpAndSettle();

    expect(find.byKey(PlannerNotificationInvitation.cardKey), findsNothing);
    expect(permissionGateway.requestCount, 0);
  });

  testWidgets('a later Planner visit offers another chance', (tester) async {
    await buildContainer();
    await pumpInvitation(tester);
    await tester.tap(find.byKey(PlannerNotificationInvitation.notNowKey));
    await tester.pumpAndSettle();
    expect(find.byKey(PlannerNotificationInvitation.cardKey), findsNothing);

    // A later visit: the user who tapped "Don't allow" by accident gets another
    // chance. A permanent "already shown" flag could never provide this.
    container.read(plannerNotificationVisitsProvider.notifier).markVisit();
    await tester.pumpAndSettle();

    expect(find.byKey(PlannerNotificationInvitation.enableKey), findsOneWidget);
    expect(permissionGateway.requestCount, 0);
  });

  testWidgets('Enable requests once and leaves no stale invitation',
      (tester) async {
    await buildContainer();
    await pumpInvitation(tester);

    await tester.tap(find.byKey(PlannerNotificationInvitation.enableKey));
    await tester.pumpAndSettle();

    expect(permissionGateway.requestCount, 1);
    expect(
      container.read(notificationSettingsControllerProvider).permission,
      OperatingSystemPermissionState.granted,
    );
    expect(find.byKey(PlannerNotificationInvitation.cardKey), findsNothing);

    // The grant also performed first-ever setup, so the seeded defaults are
    // durable rather than merely displayed.
    final stored = await repository.readPreferences(profileId: profileId);
    expect(stored.systemNotificationsEnabled, isTrue);
    expect(stored.defaultTaskReminderMinutes, 10);
  });

  testWidgets('a permanent denial offers App Settings, not a dead dialog',
      (tester) async {
    await buildContainer(
      states: <OptionalPermission, OperatingSystemPermissionState>{
        OptionalPermission.notifications:
            OperatingSystemPermissionState.permanentlyDenied,
      },
    );
    await pumpInvitation(tester);

    expect(
      find.byKey(PlannerNotificationInvitation.openSettingsKey),
      findsOneWidget,
    );
    expect(
      find.text('Notifications are turned off for Next Transfer.'),
      findsOneWidget,
    );
    expect(
      find.byKey(PlannerNotificationInvitation.enableKey),
      findsNothing,
      reason: 'Android will not show its dialog again, so it must not be offered',
    );
    expect(permissionGateway.requestCount, 0);
  });

  testWidgets('an already-granted permission never shows the invitation',
      (tester) async {
    await buildContainer(
      states: <OptionalPermission, OperatingSystemPermissionState>{
        OptionalPermission.notifications: OperatingSystemPermissionState.granted,
      },
    );
    await pumpInvitation(tester);

    expect(find.byKey(PlannerNotificationInvitation.cardKey), findsNothing);
    expect(permissionGateway.requestCount, 0);
  });
}

final class _FakeNotificationGateway implements NotificationGateway {
  @override
  Stream<NotificationResponseIntent> get responses => const Stream.empty();

  @override
  Future<void> initialize() async {}

  @override
  Future<void> schedule(LocalNotificationRequest request) async {}

  @override
  Future<void> cancel(int platformId) async {}

  @override
  Future<List<PendingLocalNotification>> pending() async => const [];

  @override
  NotificationResponseIntent? takeInitialResponse() => null;
}

final class _FakeBackgroundGateway implements BackgroundWorkGateway {
  @override
  Future<void> initialize() async {}

  @override
  Future<void> enqueueUnique(BackgroundWorkSpec work) async {}

  @override
  Future<void> cancelUnique(String uniqueName) async {}

  @override
  Future<BackgroundGatewayWorkState> inspect(String uniqueName) async =>
      BackgroundGatewayWorkState.absent;
}
