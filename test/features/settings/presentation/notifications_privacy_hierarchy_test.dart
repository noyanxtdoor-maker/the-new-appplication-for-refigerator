// OWNER HIERARCHY LAW (2026-09-19) — the Notifications screen's frozen ladder:
//
//   SYSTEM NOTIFICATIONS
//          |
//   PRIVACY NOTIFICATION PREVIEW      <- the privacy gate
//          |
//   DETAILED CONTENT                  <- the master for the five fields
//          |
//   Show title / description / time / contacts / location
//
// Two defects are pinned here:
//
//   1. The Detailed content card gated its five switches on the SYSTEM master
//      alone, so with a PRIVATE preview the screen still presented them as live
//      choices even though the delivered copy is the neutral Generic one.  The
//      owner physically saw "Detailed Content looks ON while the preview is
//      private".  => `a private preview makes every Detailed row read off and
//         non-interactive` fails against the pre-fix code.
//
//   2. The privacy section shipped BELOW Detailed content, which presents the
//      gate as a lower layer than the content it gates.  => `the screen orders
//         Planning, then the privacy preview, then Detailed content` fails.
//
// Both tests assert the STORED values are preserved: the privacy layer
// suppresses EFFECT, it never destroys configuration, and re-enabling the
// preview returns the owner's own choices without navigation or restart.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/background/background_work_gateway.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/notifications/notification_gateway.dart';
import 'package:rmplanner/core/notifications/notification_payload.dart';
import 'package:rmplanner/features/notifications/application/detailed_content_providers.dart';
import 'package:rmplanner/features/notifications/application/notification_foundation_repository.dart';
import 'package:rmplanner/features/notifications/application/notification_providers.dart';
import 'package:rmplanner/features/notifications/data/detailed_content_preferences_store.dart';
import 'package:rmplanner/features/notifications/data/drift_notification_foundation_repository.dart';
import 'package:rmplanner/features/planner/application/event_type_providers.dart';
import 'package:rmplanner/features/planner/data/drift_event_type_repository.dart';
import 'package:rmplanner/features/privacy/application/privacy_providers.dart';
import 'package:rmplanner/features/privacy/domain/permission_summary.dart';
import 'package:rmplanner/features/privacy/domain/privacy_settings.dart';
import 'package:rmplanner/features/settings/presentation/notifications_settings_screen.dart';
import 'package:rmplanner/features/startup/application/startup_providers.dart';

import '../../../support/test_dependencies.dart';

/// The five Detailed rows, in the order the screen renders them.
const List<Key> _detailedKeys = <Key>[
  Key('notifications-detailed-title'),
  Key('notifications-detailed-description'),
  Key('notifications-detailed-time'),
  Key('notifications-detailed-contacts'),
  Key('notifications-detailed-location'),
];

void main() {
  late ProviderContainer container;
  late NotificationFoundationRepository repository;
  late String profileId;

  Future<void> buildContainer({bool privacyPreview = false}) async {
    final database = openMemoryDatabase();
    addTearDown(database.close);
    final startupRepository = buildTestRepository(database: database);
    profileId = (await startupRepository.completeOnboarding()).id;
    repository = DriftNotificationFoundationRepository(
      database: database,
      clock: FixedClock(DateTime.utc(2026, 9, 19, 12)),
    );
    final privacy = TestPrivacyDependencies(
      database: database,
      permissionGateway: FakePermissionGateway(
        states: <OptionalPermission, OperatingSystemPermissionState>{
          OptionalPermission.notifications:
              OperatingSystemPermissionState.granted,
        },
      ),
    );
    if (privacyPreview) {
      await privacy.repository.setNotificationPreviewMode(
        NotificationPreviewMode.showContent,
      );
    }
    container = ProviderContainer(
      overrides: <Override>[
        startupRepositoryProvider.overrideWithValue(startupRepository),
        diagnosticsProvider.overrideWithValue(SanitizedDiagnostics()),
        privacyRepositoryProvider.overrideWithValue(privacy.repository),
        privacyGateProvider.overrideWithValue(privacy.gate),
        deviceAuthenticatorProvider.overrideWithValue(privacy.authenticator),
        permissionGatewayProvider.overrideWithValue(privacy.permissionGateway),
        notificationFoundationRepositoryProvider.overrideWithValue(repository),
        notificationGatewayProvider.overrideWithValue(
          _FakeNotificationGateway(),
        ),
        backgroundWorkGatewayProvider.overrideWithValue(
          _FakeBackgroundGateway(),
        ),
        eventTypeRepositoryProvider.overrideWithValue(
          DriftEventTypeRepository(
            database: database,
            clock: FixedClock(DateTime.utc(2026, 9, 19, 12)),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(startupControllerProvider.notifier).initialize();
  }

  /// The System notifications master is ON for every test here, so nothing but
  /// the privacy gate is being measured.
  Future<void> enableSystemMaster(WidgetTester tester) async {
    final master = find.byKey(const Key('notifications-system-toggle'));
    await tester.tap(master);
    await tester.pumpAndSettle();
  }

  Future<void> pumpScreen(WidgetTester tester) async {
    tester.view.physicalSize = const Size(431, 1600);
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

  SwitchListTile detailed(WidgetTester tester, Key key) =>
      tester.widget<SwitchListTile>(
        find.descendant(
          of: find.byKey(key),
          matching: find.byType(SwitchListTile),
        ),
      );

  /// Scrolls a row into view with BOUNDED pumps.
  ///
  /// `pumpAndSettle` is deliberately avoided here: this screen legitimately
  /// shows an indeterminate progress indicator while a notification-content
  /// repair is running, and that animation never settles.  A fixed number of
  /// frames is enough to lay the row out, and it cannot hang.
  Future<void> scrollTo(WidgetTester tester, Key key) async {
    await tester.scrollUntilVisible(
      find.byKey(key),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    for (var frame = 0; frame < 6; frame++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets(
    'the screen orders Planning, then the privacy preview, then Detailed '
    'content',
    (tester) async {
      await buildContainer();
      await pumpScreen(tester);

      double topOf(Finder finder) => tester.getTopLeft(finder).dy;

      await scrollTo(
        tester,
        const Key('notifications-weekly-review-reminders'),
      );
      final planning = topOf(
        find.byKey(const Key('notifications-weekly-review-reminders')),
      );
      final privacy = topOf(find.byKey(const Key('notifications-preview')));

      await scrollTo(tester, _detailedKeys.first);
      final detailedContent = topOf(find.byKey(_detailedKeys.first));

      // The privacy gate is listed ABOVE the content it gates, and after the
      // Planning family: the visual order must state the hierarchy.
      expect(
        planning,
        lessThan(privacy),
        reason: 'the privacy preview belongs after Planning',
      );
      expect(
        privacy,
        lessThan(detailedContent),
        reason:
            'the privacy preview belongs BEFORE Detailed content: it is the '
            'gate the Detailed options operate under',
      );
    },
  );

  testWidgets(
    'a private preview makes every Detailed row read off and non-interactive',
    (tester) async {
      await buildContainer(privacyPreview: false);
      await pumpScreen(tester);
      await enableSystemMaster(tester);
      await scrollTo(tester, _detailedKeys.first);

      for (final key in _detailedKeys) {
        expect(
          detailed(tester, key).value,
          isFalse,
          reason:
              'with a private preview no detailed field can be delivered, so '
              'the row must not read as an active ON choice',
        );
        expect(
          detailed(tester, key).onChanged,
          isNull,
          reason: 'the row must not be changeable while privacy forbids detail',
        );
      }

      // ...and the stored choices were never touched.
      expect(
        await repository.readDetailedContent(profileId: profileId),
        DetailedContentPreferences.defaults,
      );
    },
  );

  testWidgets(
    'the preview becomes interactive and the owner choices return when privacy '
    'permits detail',
    (tester) async {
      await buildContainer(privacyPreview: true);
      await pumpScreen(tester);
      await enableSystemMaster(tester);
      await scrollTo(tester, _detailedKeys.first);

      for (final key in _detailedKeys) {
        expect(detailed(tester, key).value, isTrue);
        expect(detailed(tester, key).onChanged, isNotNull);
      }
    },
  );

  testWidgets(
    'S4 — the master OFF makes every field row read off and non-interactive',
    (tester) async {
      await buildContainer(privacyPreview: true);
      await repository.saveDetailedContent(
        profileId: profileId,
        preferences: const DetailedContentPreferences(enabled: false),
      );
      await pumpScreen(tester);
      await enableSystemMaster(tester);
      await scrollTo(tester, const Key('notifications-detailed-master'));

      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const Key('notifications-detailed-master')),
            )
            .value,
        isFalse,
      );
      for (final key in _detailedKeys) {
        expect(detailed(tester, key).value, isFalse);
        expect(detailed(tester, key).onChanged, isNull);
      }
    },
  );

  testWidgets(
    'S7 — the master off/on round trip restores the field rows untouched',
    (tester) async {
      await buildContainer(privacyPreview: true);
      await repository.saveDetailedContent(
        profileId: profileId,
        preferences: const DetailedContentPreferences(showLocation: false),
      );
      await pumpScreen(tester);
      await enableSystemMaster(tester);

      // The master is above the five fields; turning it off must disable them
      // without erasing the saved location choice.
      await scrollTo(tester, const Key('notifications-detailed-master'));
      await tester.tap(find.byKey(const Key('notifications-detailed-master')));
      await tester.pumpAndSettle();
      expect(detailed(tester, _detailedKeys.first).onChanged, isNull);
      expect(
        await repository.readDetailedContent(profileId: profileId),
        const DetailedContentPreferences(showLocation: false, enabled: false),
        reason: 'turning the master off must not rewrite any field',
      );

      await tester.tap(find.byKey(const Key('notifications-detailed-master')));
      await tester.pumpAndSettle();
      await scrollTo(tester, _detailedKeys.last);
      expect(
        detailed(tester, _detailedKeys.last).value,
        isFalse,
        reason: "the owner's own location choice returns",
      );
      expect(
        detailed(tester, _detailedKeys.first).value,
        isTrue,
        reason: 'a field that was never touched stays on',
      );
      expect(detailed(tester, _detailedKeys.first).onChanged, isNotNull);
    },
  );

  testWidgets(
    'a private preview then a permitted preview returns the saved choices '
    'without restarting',
    (tester) async {
      await buildContainer(privacyPreview: false);
      await pumpScreen(tester);
      await enableSystemMaster(tester);

      // The owner's Details were configured before any of this — a durable
      // choice that predates the privacy change, which is exactly the case the
      // owner cares about.
      await repository.saveDetailedContent(
        profileId: profileId,
        preferences: const DetailedContentPreferences(showLocation: false),
      );
      container.invalidate(detailedContentPreferencesProvider);

      await scrollTo(tester, _detailedKeys.first);
      expect(
        detailed(tester, _detailedKeys.first).onChanged,
        isNull,
        reason: 'a private preview must not offer the Detailed choices',
      );

      // Privacy opens, through the screen's OWN switch: the same screen must
      // become usable on the spot, with the stored configuration intact — no
      // navigation, no restart.
      await scrollTo(tester, const Key('notifications-preview'));
      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('notifications-preview')),
          matching: find.byType(Switch),
        ),
      );
      // Bounded pumps rather than pumpAndSettle: opening the gate queues a
      // notification-content repair whose indicator animates indefinitely.
      for (var frame = 0; frame < 12; frame++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      await scrollTo(tester, _detailedKeys.first);
      expect(
        detailed(tester, _detailedKeys.last).value,
        isFalse,
        reason:
            'the stored location choice must survive the privacy round trip',
      );
      expect(detailed(tester, _detailedKeys.first).value, isTrue);
      expect(detailed(tester, _detailedKeys.first).onChanged, isNotNull);
    },
  );
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
