// Pack 3 — centralized Settings home.
//
// Only real sections/rows appear; every row reads real state and performs
// real behavior; unsupported settings (Accessibility, Country and Language,
// Contacts, Account/Sync) are absent.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/planner/presentation/planner_settings_screen.dart';
import 'package:rmplanner/features/privacy/domain/permission_summary.dart';
import 'package:rmplanner/features/privacy/presentation/permissions_screen.dart';
import 'package:rmplanner/features/privacy/presentation/privacy_center_screen.dart';
import 'package:rmplanner/features/settings/presentation/appearance_screen.dart';
import 'package:rmplanner/features/settings/presentation/colors_screen.dart';
import 'package:rmplanner/features/settings/presentation/notifications_settings_screen.dart';
import 'package:rmplanner/features/settings/presentation/settings_screen.dart';
import 'package:rmplanner/features/settings/presentation/start_of_week_screen.dart';

import '../../../support/test_dependencies.dart';

void main() {
  Future<void> pumpApp(
    WidgetTester tester, {
    bool notificationsGranted = false,
  }) async {
    tester.view.physicalSize = const Size(431, 912);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final database = openMemoryDatabase();
    addTearDown(database.close);
    final privacy = TestPrivacyDependencies(
      database: database,
      permissionGateway: FakePermissionGateway(
        states: {
          OptionalPermission.notifications: notificationsGranted
              ? OperatingSystemPermissionState.granted
              : OperatingSystemPermissionState.denied,
        },
      ),
    );
    final startup = buildTestRepository(
      database: database,
      privacyGate: privacy.gate,
    );
    await startup.completeOnboarding();
    await tester.pumpWidget(
      privacy.buildApp(
        environment: const AppEnvironment(
          name: AppEnvironmentName.production,
          label: 'PRODUCTION',
        ),
        diagnostics: SanitizedDiagnostics(),
        startupRepository: startup,
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openSettings(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('home-hamburger')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('drawer-account-settings')),
      200,
      scrollable: find.descendant(
        of: find.byKey(const Key('global-app-drawer-list')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('drawer-account-settings')));
    await tester.pumpAndSettle();
  }

  testWidgets('Settings shows only the real canonical sections and rows', (
    tester,
  ) async {
    await pumpApp(tester);
    await openSettings(tester);
    expect(find.byType(SettingsScreen), findsOneWidget);

    expect(
      find.byKey(const Key('settings-section-privacy-and-device')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('settings-section-planner-and-calendar')),
      findsOneWidget,
    );
    await tester.scrollUntilVisible(
      find.byKey(const Key('settings-section-planning')),
      160,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byKey(const Key('settings-section-planning')), findsOneWidget);

    for (final key in <String>[
      'settings-appearance',
      'settings-privacy-data',
      'settings-permissions',
      'settings-notifications',
      'settings-planner-calendar',
      'settings-colors',
      'settings-start-of-week',
    ]) {
      await tester.scrollUntilVisible(
        find.byKey(Key(key)),
        160,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.byKey(Key(key)), findsOneWidget, reason: key);
      expect(
        tester.widget<ListTile>(find.byKey(Key(key))).subtitle,
        isNull,
        reason: '$key must remain label plus control',
      );
    }

    // Unsupported settings must not appear (locked policy 8 / 10; B2
    // activates Appearance, so it is canonical now).
    for (final key in <String>[
      'settings-section-accessibility',
      'settings-section-country-and-language',
      'settings-section-contacts',
      'settings-section-account-and-sync',
    ]) {
      expect(find.byKey(Key(key)), findsNothing, reason: key);
    }
    for (final text in <String>[
      'Theme',
      'Accent Color',
      'Accessibility',
      'Country and Language',
      'Sync preferences',
    ]) {
      expect(find.text(text), findsNothing, reason: 'unsupported: $text');
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('VS16 Appearance retains controls without teaching subtitles', (
    tester,
  ) async {
    await pumpApp(tester);
    await openSettings(tester);
    await tester.tap(find.byKey(const Key('settings-appearance')));
    await tester.pumpAndSettle();
    expect(find.byType(AppearanceScreen), findsOneWidget);
    for (final label in <String>['System', 'Light', 'Dark', 'Rose', 'Blue']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    for (final helper in <String>[
      'Follow device appearance',
      'Always use light appearance',
      'Always use dark appearance',
      'Warm soft-light accents',
      'Cool soft-light accents',
    ]) {
      expect(find.text(helper), findsNothing, reason: helper);
    }
  });

  // Post-P2 owner decision (2026-09-22): the permission rows now carry their
  // own purpose text and the Device calendar row is an explicit, non-actionable
  // "Not available in this build" placeholder. This supersedes the earlier
  // "labels, status and action only" presentation: the domain purpose copy was
  // always lawful data (permission_summary.dart) that the screen simply never
  // rendered, which is a large part of why the page read as cryptic.
  testWidgets('Post-P2 Permissions renders purpose copy and honest calendar '
      'state', (tester) async {
    await pumpApp(tester);
    await openSettings(tester);
    await tester.tap(find.byKey(const Key('settings-permissions')));
    await tester.pumpAndSettle();
    expect(find.byType(PermissionsScreen), findsOneWidget);
    for (final label in <String>[
      'Contacts',
      'Notifications',
      'Location while using the app',
      'Device calendar',
    ]) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    // The three requestable permissions read "Not requested"; the calendar row
    // reports the truth for this build instead of a fabricated OS state.
    expect(find.text('Not requested'), findsNWidgets(3));
    expect(find.text('Unavailable'), findsOneWidget);
    // The reason subtitles added by owner decision made this page taller than
    // the old label/status/action-only list, so the footer button now sits
    // below the fold at this viewport: scroll it into view and then assert,
    // rather than assuming the whole page is one screenful.
    for (final helper in <String>[
      'Used only when you choose a contact-related feature. Core planning works without contact access.',
      'Used only when you enable reminders. Private content stays hidden unless you explicitly allow notification previews.',
      'Used only for a location feature you start while the app is open. Next Transfer does not request background location.',
    ]) {
      expect(find.text(helper), findsOneWidget, reason: helper);
    }
    expect(find.text('Not available in this build.'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const Key('open-system-settings-button')),
      200,
    );
    expect(
      find.byKey(const Key('open-system-settings-button')),
      findsOneWidget,
      reason: 'the Android app-settings escape hatch must survive the rewrite',
    );
  });

  testWidgets('VS16 Privacy removes ordinary copy but retains disclaimer', (
    tester,
  ) async {
    await pumpApp(tester);
    await openSettings(tester);
    await tester.tap(find.byKey(const Key('settings-privacy-data')));
    await tester.pumpAndSettle();
    expect(find.byType(PrivacyCenterScreen), findsOneWidget);
    expect(find.text('Privacy Lock'), findsOneWidget);
    expect(find.text('Show content in notification previews'), findsOneWidget);
    expect(find.text('Authentication secrets'), findsOneWidget);

    const disclaimer =
        'Next Transfer does not claim full-database encryption or '
        'end-to-end encryption. It states only protections implemented '
        'and verified.';
    await tester.scrollUntilVisible(
      find.text(disclaimer),
      180,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text(disclaimer), findsOneWidget);

    for (final helper in <String>[
      'Where data lives',
      'Your planner database is stored on this device and remains available offline.',
      'Optional account sync is not active. Future sync will identify exactly which eligible records leave the device.',
      'Raw BetterCalendar imports and private reflections do not enter sync, analytics, diagnostics, or the outbox.',
      'Review sanitized details before any future export.',
      'No data is deleted by opening this explanation.',
      'Attachments use scoped system pickers. Next Transfer does not request broad storage access or background location.',
    ]) {
      expect(find.text(helper), findsNothing, reason: helper);
    }
    await tester.scrollUntilVisible(
      find.byKey(const Key('diagnostic-preview-tile')),
      180,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      tester
          .widget<ListTile>(find.byKey(const Key('diagnostic-preview-tile')))
          .subtitle,
      isNull,
    );
    expect(
      tester
          .widget<ListTile>(find.byKey(const Key('deletion-impact-tile')))
          .subtitle,
      isNull,
    );
  });

  testWidgets('every visible row reads real state and performs real '
      'behavior', (tester) async {
    await pumpApp(tester);
    await openSettings(tester);

    // Permissions reads the real (denied) permission gateway state.
    await tester.tap(find.byKey(const Key('settings-permissions')));
    await tester.pumpAndSettle();
    expect(find.byType(PermissionsScreen), findsOneWidget);
    expect(find.text('Not requested'), findsWidgets);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);

    // Privacy and Data opens the canonical Privacy Center.
    await tester.tap(find.byKey(const Key('settings-privacy-data')));
    await tester.pumpAndSettle();
    expect(find.byType(PrivacyCenterScreen), findsOneWidget);
    expect(find.text('Privacy controls'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    // Planner and Calendar opens the real planner settings.
    await tester.scrollUntilVisible(
      find.byKey(const Key('settings-planner-calendar')),
      160,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const Key('settings-planner-calendar')));
    await tester.pumpAndSettle();
    expect(find.byType(PlannerSettingsScreen), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    // Colors opens the real colors screen.
    await tester.scrollUntilVisible(
      find.byKey(const Key('settings-colors')),
      160,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const Key('settings-colors')));
    await tester.pumpAndSettle();
    expect(find.byType(ColorsScreen), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    // Start of week opens the real selector.
    await tester.scrollUntilVisible(
      find.byKey(const Key('settings-start-of-week')),
      160,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const Key('settings-start-of-week')));
    await tester.pumpAndSettle();
    expect(find.byType(StartOfWeekScreen), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Notifications opens the canonical truthful M1 foundation', (
    tester,
  ) async {
    await pumpApp(tester);
    await openSettings(tester);
    await tester.scrollUntilVisible(
      find.byKey(const Key('settings-notifications')),
      160,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const Key('settings-notifications')));
    await tester.pumpAndSettle();
    expect(find.byType(NotificationsSettingsScreen), findsOneWidget);
    expect(
      find.byKey(const Key('notifications-reminders-readiness')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('notifications-recovery-readiness')),
      findsNothing,
    );
    expect(find.text('Reminders'), findsNothing);
    expect(find.text('Background recovery'), findsNothing);
    final eventToggle = tester.widget<SwitchListTile>(
      find.byKey(const Key('notifications-event-reminders')),
    );
    final taskToggle = tester.widget<SwitchListTile>(
      find.byKey(const Key('notifications-task-reminders')),
    );
    expect(eventToggle.onChanged, isNull);
    expect(taskToggle.onChanged, isNull);
    expect(
      find.byKey(const Key('notifications-system-status')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('notifications-event-reminders')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('notifications-task-reminders')),
      findsOneWidget,
    );
    // The screen legitimately grew past one viewport: the PLANNING, DETAILED
    // CONTENT and PRIVACY sections shipped after this M1 foundation test was
    // written, so the PRIVACY row must be scrolled into view before the finder
    // is a real assertion instead of an off-screen trivially-empty one.
    await tester.scrollUntilVisible(
      find.byKey(const Key('notifications-preview')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('notifications-preview')), findsOneWidget);
    expect(
      find.textContaining('delivery begins in later milestones'),
      findsNothing,
    );
    // Absence law reconciled to the current shipped product: the PLANNING
    // family (Weekly Review reminders / Awaiting Report reminders) is a live
    // accepted surface, so it legitimately appears and is no longer claimed
    // absent. Only the genuinely unshipped families stay absent.
    expect(find.text('Goal completed notifications'), findsNothing);
    expect(find.text('Follow-up reminders'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'Notifications master and category switches operate independently',
    (tester) async {
      await pumpApp(tester, notificationsGranted: true);
      await openSettings(tester);
      await tester.scrollUntilVisible(
        find.byKey(const Key('settings-notifications')),
        160,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byKey(const Key('settings-notifications')));
      await tester.pumpAndSettle();
      final master = find.byKey(const Key('notifications-system-toggle'));
      final event = find.byKey(const Key('notifications-event-reminders'));
      final task = find.byKey(const Key('notifications-task-reminders'));
      // OWNER REVIEW #4 STRAIGHTFIX: enabling notifications on a profile that
      // has never been configured now seeds the owner-approved defaults, so a
      // fresh enable legitimately arrives with every category already ON. The
      // independence law this test exists for is unchanged; it is asserted
      // RELATIVE to that seeded state, and it now also proves the reversible
      // gating that the master gate promises.
      await tester.tap(master);
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(master).value, isTrue);
      expect(tester.widget<SwitchListTile>(event).onChanged, isNotNull);
      expect(tester.widget<SwitchListTile>(task).onChanged, isNotNull);
      expect(tester.widget<SwitchListTile>(event).value, isTrue);
      expect(tester.widget<SwitchListTile>(task).value, isTrue);

      // One category off never moves its sibling.
      await tester.tap(event);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(event).value, isFalse);
      expect(tester.widget<SwitchListTile>(task).value, isTrue);
      await tester.tap(task);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(task).value, isFalse);
      expect(tester.widget<SwitchListTile>(event).value, isFalse);
      // ...and one back on never moves its sibling either.
      await tester.tap(event);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(event).value, isTrue);
      expect(tester.widget<SwitchListTile>(task).value, isFalse);

      // The master gates presentation only: it never rewrites child values, so
      // both children read OFF and non-interactive while it is off.
      await tester.tap(master);
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(master).value, isFalse);
      expect(tester.widget<SwitchListTile>(event).onChanged, isNull);
      expect(tester.widget<SwitchListTile>(task).onChanged, isNull);
      expect(tester.widget<SwitchListTile>(event).value, isFalse);
      expect(tester.widget<SwitchListTile>(task).value, isFalse);

      // Turning the master back on returns the user's own stored choices.
      await tester.tap(master);
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(master).value, isTrue);
      expect(tester.widget<SwitchListTile>(event).value, isTrue);
      expect(tester.widget<SwitchListTile>(task).value, isFalse);
      expect(tester.takeException(), isNull);
    },
  );
}
