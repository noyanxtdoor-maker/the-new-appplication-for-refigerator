// OWNER REVIEW #4 STRAIGHTFIX — fail-first coverage for the Notifications
// screen's master/child gating and for its ENTRY read.
//
// Two defects are pinned here:
//
//   1. The DETAILED CONTENT card was the only card in the screen that ignored
//      the master. Its five switches kept rendering their stored ON values and
//      stayed tappable while notifications could not be delivered, which is what
//      the owner physically saw ("Detailed Content looks ON while notifications
//      are OFF"). => `master off makes every Detailed row read off and
//         non-interactive` fails against the pre-straightfix code.
//
//   2. The screen never loaded on entry, so it rendered whatever snapshot the
//      controller last published — from Home, from the Planner gate, or from an
//      earlier visit. That is how a stale "denied" snapshot could show System
//      notifications OFF while SQLite and Android both said ON.
//      => `opening the screen reconciles a stale snapshot` fails against the
//         pre-straightfix code.
//
// Both tests assert the STORED values are preserved, because the owner's law is
// reversible gating: the child reads off and is disabled, and turning the master
// back on restores the user's own choices.

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
import 'package:rmplanner/features/notifications/data/detailed_content_preferences_store.dart';
import 'package:rmplanner/features/notifications/data/drift_notification_foundation_repository.dart';
import 'package:rmplanner/features/notifications/domain/notification_preferences.dart';
import 'package:rmplanner/features/planner/application/event_type_providers.dart';
import 'package:rmplanner/features/planner/data/drift_event_type_repository.dart';
import 'package:rmplanner/features/privacy/application/privacy_providers.dart';
import 'package:rmplanner/features/privacy/domain/permission_summary.dart';
import 'package:rmplanner/features/settings/presentation/notifications_settings_screen.dart';
import 'package:rmplanner/features/startup/application/startup_providers.dart';

import '../../../support/test_dependencies.dart';

/// The five Detailed Content rows, in the order the screen renders them.
const List<Key> _detailedKeys = <Key>[
  Key('notifications-detailed-title'),
  Key('notifications-detailed-description'),
  Key('notifications-detailed-time'),
  Key('notifications-detailed-contacts'),
  Key('notifications-detailed-location'),
];

void main() {
  late ProviderContainer container;
  late FakePermissionGateway permissionGateway;
  late NotificationFoundationRepository repository;
  late String profileId;

  Future<void> buildContainer({
    OperatingSystemPermissionState notifications =
        OperatingSystemPermissionState.denied,
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
        states: <OptionalPermission, OperatingSystemPermissionState>{
          OptionalPermission.notifications: notifications,
        },
      ),
    );
    permissionGateway = privacy.permissionGateway;
    container = ProviderContainer(
      overrides: <Override>[
        startupRepositoryProvider.overrideWithValue(startupRepository),
        diagnosticsProvider.overrideWithValue(SanitizedDiagnostics()),
        privacyRepositoryProvider.overrideWithValue(privacy.repository),
        privacyGateProvider.overrideWithValue(privacy.gate),
        deviceAuthenticatorProvider.overrideWithValue(privacy.authenticator),
        permissionGatewayProvider.overrideWithValue(privacy.permissionGateway),
        notificationFoundationRepositoryProvider.overrideWithValue(repository),
        notificationGatewayProvider.overrideWithValue(_FakeNotificationGateway()),
        backgroundWorkGatewayProvider.overrideWithValue(
          _FakeBackgroundGateway(),
        ),
        eventTypeRepositoryProvider.overrideWithValue(
          DriftEventTypeRepository(
            database: database,
            clock: FixedClock(DateTime.utc(2026, 9, 18, 12)),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(startupControllerProvider.notifier).initialize();
  }

  Future<void> pumpScreen(WidgetTester tester) async {
    tester.view.physicalSize = const Size(431, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: NotificationsSettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// The key sits on the row widget, so the switch is its descendant.
  SwitchListTile detailed(WidgetTester tester, Key key) =>
      tester.widget<SwitchListTile>(
        find.descendant(
          of: find.byKey(key),
          matching: find.byType(SwitchListTile),
        ),
      );

  Future<void> scrollToDetailed(WidgetTester tester) async {
    await tester.scrollUntilVisible(
      find.byKey(_detailedKeys.first),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'master off makes every Detailed row read off and non-interactive',
    (tester) async {
      await buildContainer();
      await pumpScreen(tester);
      await scrollToDetailed(tester);

      // The stored values are the all-TRUE Detailed defaults, so a switch that
      // reported the STORED value here is exactly the defect the owner saw.
      for (final key in _detailedKeys) {
        expect(
          detailed(tester, key).value,
          isFalse,
          reason: 'the child must READ off while notifications are off',
        );
        expect(
          detailed(tester, key).onChanged,
          isNull,
          reason: 'the child must not be changeable while notifications are off',
        );
      }
    },
  );

  testWidgets(
    'master on restores the stored Detailed choices, and they survive a '
    'master off/on round trip',
    (tester) async {
      await buildContainer(
        notifications: OperatingSystemPermissionState.granted,
      );
      await pumpScreen(tester);
      final master = find.byKey(const Key('notifications-system-toggle'));

      await tester.tap(master);
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(master).value, isTrue);

      await scrollToDetailed(tester);
      for (final key in _detailedKeys) {
        expect(detailed(tester, key).value, isTrue);
        expect(detailed(tester, key).onChanged, isNotNull);
      }

      // The user deliberately turns ONE detailed option off.
      await tester.tap(find.byKey(_detailedKeys.first));
      await tester.pumpAndSettle();
      expect(detailed(tester, _detailedKeys.first).value, isFalse);
      expect(
        await repository.readDetailedContent(profileId: profileId),
        DetailedContentPreferences.defaults.copyWith(showTitle: false),
        reason: 'the tap must be durable, not merely painted',
      );

      // Turning the master off must not erase that choice...
      await tester.scrollUntilVisible(master, -200,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      await tester.tap(master);
      await tester.pumpAndSettle();
      await scrollToDetailed(tester);
      expect(detailed(tester, _detailedKeys.first).value, isFalse);
      expect(detailed(tester, _detailedKeys[1]).value, isFalse);
      expect(
        await repository.readDetailedContent(profileId: profileId),
        DetailedContentPreferences.defaults.copyWith(showTitle: false),
        reason: 'the stored choice is preserved while the master is off',
      );
      // ...and turning it back on returns the user's own configuration.
      await tester.scrollUntilVisible(master, -200,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      await tester.tap(master);
      await tester.pumpAndSettle();
      await scrollToDetailed(tester);
      expect(
        detailed(tester, _detailedKeys.first).value,
        isFalse,
        reason: "the user's own choice returns; it is not reset to true",
      );
      expect(detailed(tester, _detailedKeys[1]).value, isTrue);
    },
  );

  testWidgets('opening the screen reconciles a stale snapshot', (tester) async {
    await buildContainer();
    // Publish a snapshot while the permission is still denied: this is the state
    // the shell leaves behind after a Planner visit.
    await container
        .read(notificationSettingsControllerProvider.notifier)
        .refreshWhenIdle();
    expect(
      container.read(notificationSettingsControllerProvider).permission,
      OperatingSystemPermissionState.denied,
    );

    // Now the permission is granted and a configuration lands out of band — the
    // Android-App-Settings route, or a restore.
    permissionGateway.states[OptionalPermission.notifications] =
        OperatingSystemPermissionState.granted;
    await repository.savePreferences(
      profileId: profileId,
      preferences: const NotificationPreferences.defaults().copyWith(
        systemNotificationsEnabled: true,
      ),
    );

    await pumpScreen(tester);

    final master = find.byKey(const Key('notifications-system-toggle'));
    expect(
      tester.widget<Switch>(master).value,
      isTrue,
      reason:
          'the screen must read current truth on entry instead of presenting a '
          'stale snapshot as authoritative',
    );
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
