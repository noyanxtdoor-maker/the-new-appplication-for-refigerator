// OWNER HIERARCHY LAW (2026-09-19) — the Notifications screen's frozen ladder:
//
//   SYSTEM NOTIFICATIONS
//          |
//   PRIVACY NOTIFICATION PREVIEW      <- the ONE master (post-P2, 2026-09-22)
//          |
//   Show title / description / time / contacts / location
//
// The intermediate "Detailed content" master was REMOVED by owner decision on
// 2026-09-22: two masters for one question (generic vs detailed) produced a
// confusing ladder, and the privacy gate is the real outer master.  Its stored
// column is kept and read as the EFFECTIVE value TRUE, following the same
// normalization P1 used for showCurrentTime / quickEditEnabled, so an owner who
// had detail switched off does not silently lose every field choice.
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
import 'package:rmplanner/core/notifications/notification_preview_policy.dart';
import 'package:rmplanner/features/notifications/application/detailed_content_providers.dart';
import 'package:rmplanner/features/notifications/application/notification_foundation_repository.dart';
import 'package:rmplanner/features/notifications/application/notification_providers.dart';
import 'package:rmplanner/features/notifications/application/reminder_notification_renderer.dart';
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
    'S4 — the retired Detailed master is gone and cannot strand a legacy OFF',
    (tester) async {
      await buildContainer(privacyPreview: true);
      // A profile that had the retired master switched OFF.
      await repository.saveDetailedContent(
        profileId: profileId,
        preferences: const DetailedContentPreferences(enabled: false),
      );
      await pumpScreen(tester);
      await enableSystemMaster(tester);
      await scrollTo(tester, _detailedKeys.first);

      // Post-P2 owner decision (2026-09-22): Notification preview is the single
      // master, so the second one must not be rendered at all.
      expect(
        find.byKey(const Key('notifications-detailed-master')),
        findsNothing,
        reason: 'there is exactly one generic-vs-detailed master',
      );
      // The owner's field choices are the live ones again: a legacy stored OFF
      // must not keep the card inert now that no control can turn it back on.
      for (final key in _detailedKeys) {
        expect(detailed(tester, key).value, isTrue);
        expect(detailed(tester, key).onChanged, isNotNull);
      }
    },
  );

  testWidgets(
    'S7 — a legacy stored master OFF converges to effective ON without erasing '
    'the field choices',
    (tester) async {
      await buildContainer(privacyPreview: true);
      await repository.saveDetailedContent(
        profileId: profileId,
        preferences: const DetailedContentPreferences(
          enabled: false,
          showLocation: false,
        ),
      );

      final reread = await repository.readDetailedContent(profileId: profileId);
      expect(
        reread.enabled,
        isTrue,
        reason: 'the retired master reads as the effective value TRUE',
      );
      expect(
        reread.showLocation,
        isFalse,
        reason: "the owner's own field choices are preserved untouched",
      );

      await pumpScreen(tester);
      await enableSystemMaster(tester);
      await scrollTo(tester, _detailedKeys.last);
      expect(
        detailed(tester, _detailedKeys.last).value,
        isFalse,
        reason: 'the saved location choice still governs the row',
      );
      expect(
        detailed(tester, _detailedKeys.last).onChanged,
        isNotNull,
        reason: 'the retired master can no longer disable the field rows',
      );
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

  // POST-P2 OWNER FINDING (2026-09-22) — the defect this group pins:
  //
  //   The Settings preview was built by `buildDetailedPreview`, whose signature
  //   takes NO privacy input at all. With "Notification preview" OFF the
  //   DELIVERED notification was the neutral generic copy while the card still
  //   printed the full detailed sample underneath the sentence "This is the
  //   exact text a notification will show."
  //
  //   The existing 45 notification/privacy tests stayed green through this,
  //   because they assert the SWITCHES' effective state and never assert the
  //   PREVIEW TEXT against the canonical renderer. That is the gap closed here.
  group('POST-P2 — the preview card cannot contradict the shade', () {
    testWidgets(
      'a private Notification preview renders the EXACT generic copy the shade '
      'would deliver',
      (tester) async {
        await buildContainer(privacyPreview: false);
        await pumpScreen(tester);
        await enableSystemMaster(tester);
        await scrollTo(tester, _detailedKeys.first);

        expect(
          find.text(ReminderNotificationRenderer.genericTitle),
          findsOneWidget,
          reason: 'a closed gate must show the canonical generic title',
        );
        expect(
          find.text(ReminderNotificationRenderer.genericBody),
          findsOneWidget,
          reason: 'a closed gate must show the canonical generic body',
        );

        // Not one field of the sample may survive: the card sits directly under
        // "This is the exact text a notification will show."
        expect(
          find.textContaining('Dentist'),
          findsNothing,
          reason: 'the sample title is private content',
        );
        expect(
          find.textContaining('Riverside Clinic'),
          findsNothing,
          reason: 'the sample location is private content',
        );
        expect(
          find.textContaining('insurance card'),
          findsNothing,
          reason: 'the sample description is private content',
        );
        expect(
          find.textContaining('Follow up with'),
          findsNothing,
          reason: 'the sample contact line is private content',
        );
      },
    );

    testWidgets(
      'a permitted Notification preview renders the detailed sample',
      (tester) async {
        await buildContainer(privacyPreview: true);
        await pumpScreen(tester);
        await enableSystemMaster(tester);
        await scrollTo(tester, _detailedKeys.first);

        expect(
          find.text(ReminderNotificationRenderer.genericTitle),
          findsNothing,
          reason: 'the open gate must not be forced back to the generic copy',
        );
        expect(find.textContaining('Dentist'), findsOneWidget);
      },
    );

    test(
      'the preview entry point is a pure pass-through when the gate is open and '
      'cannot leak a field when it is closed',
      () {
        // Every granular field ON, and a sample that exercises all of them: this
        // is the worst case for a leak.
        const options = DetailedContentPreferences.defaults;
        const sampleTitle = '🦷 Dentist appointment';
        const sampleNotes = 'Bring the insurance card.';
        const sampleFollowUp = 'Bea';
        const sampleLocation = 'Riverside Clinic';

        final generic = buildNotificationPreview(
          mode: EffectiveNotificationPreviewMode.generic,
          isEvent: true,
          options: options,
          sourceTitle: sampleTitle,
          startDisplay: DateTime(2026, 1, 1, 9, 30),
          endDisplay: DateTime(2026, 1, 1, 10, 30),
          notes: sampleNotes,
          followUpName: sampleFollowUp,
          locationText: sampleLocation,
        );
        expect(
          generic,
          ReminderNotificationRenderer.generic,
          reason:
              'the canonical generic constant is the only thing a closed gate '
              'may render',
        );

        final detailed = buildNotificationPreview(
          mode: EffectiveNotificationPreviewMode.detailed,
          isEvent: true,
          options: options,
          sourceTitle: sampleTitle,
          startDisplay: DateTime(2026, 1, 1, 9, 30),
          endDisplay: DateTime(2026, 1, 1, 10, 30),
          notes: sampleNotes,
          followUpName: sampleFollowUp,
          locationText: sampleLocation,
        );
        expect(
          detailed,
          buildDetailedPreview(
            isEvent: true,
            options: options,
            sourceTitle: sampleTitle,
            startDisplay: DateTime(2026, 1, 1, 9, 30),
            endDisplay: DateTime(2026, 1, 1, 10, 30),
            notes: sampleNotes,
            followUpName: sampleFollowUp,
            locationText: sampleLocation,
          ),
          reason:
              'an open gate must resolve through the existing detailed builder '
              'byte for byte — the wrapper adds no second rendering law',
        );
        expect(detailed.title, contains('Dentist'));
      },
    );

    test("the card's mode is the canonical resolver's own answer", () {
      // The card no longer re-derives the privacy condition: it is handed
      // `resolveNotificationPreviewMode`, so this equality is what keeps the
      // card and the delivery path on one law.
      for (final mode in NotificationPreviewMode.values) {
        final settings = PrivacySettings(
          lockEnabled: false,
          notificationPreviewMode: mode,
        );
        expect(
          resolveNotificationPreviewMode(settings: settings),
          mode == NotificationPreviewMode.showContent
              ? EffectiveNotificationPreviewMode.detailed
              : EffectiveNotificationPreviewMode.generic,
        );
      }
    });
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
