import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/features/contacts/domain/contact.dart';
import 'package:rmplanner/features/contacts/presentation/device_contact_import_screen.dart';
import 'package:rmplanner/features/privacy/domain/permission_summary.dart';

/// M6 FINAL CORRECTION — Contacts runtime-permission UX.
///
/// The import flow was already contextual (it asked only on an explicit tap),
/// but every non-granted outcome collapsed into one "Permission denied" screen:
/// a permanently-denied user was trapped in a retry that Android will never
/// answer, and returning from Android Settings did nothing.  These tests pin
/// the four required behaviours plus the contextual-request law.
void main() {
  final drafts = <DeviceContactDraft>[
    const DeviceContactDraft(
      displayName: 'Maria Santos',
      phones: <String>['+63 917 555 0101'],
      emails: <String>['maria@example.com'],
    ),
  ];

  Future<void> pumpScreen(
    WidgetTester tester, {
    required Future<OperatingSystemPermissionState> Function() requester,
    Future<OperatingSystemPermissionState> Function()? checker,
    Future<bool> Function()? opener,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: DeviceContactImportScreen(
            deviceReader: () async => drafts,
            permissionRequester: requester,
            permissionChecker: checker,
            settingsOpener: opener,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('no Contacts permission is requested before the user acts', (
    tester,
  ) async {
    var requests = 0;
    await pumpScreen(
      tester,
      requester: () async {
        requests += 1;
        return OperatingSystemPermissionState.granted;
      },
    );

    expect(requests, 0);
    expect(find.byKey(const Key('device-import-start')), findsOneWidget);
    expect(find.byKey(const Key('device-import-list')), findsNothing);
  });

  testWidgets('granting continues straight into the import list', (
    tester,
  ) async {
    await pumpScreen(
      tester,
      requester: () async => OperatingSystemPermissionState.granted,
    );

    await tester.tap(find.byKey(const Key('device-import-start')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('device-import-list')), findsOneWidget);
    expect(find.text('Maria Santos'), findsOneWidget);
  });

  testWidgets('a plain deny stays truthful and retryable', (tester) async {
    await pumpScreen(
      tester,
      requester: () async => OperatingSystemPermissionState.denied,
    );

    await tester.tap(find.byKey(const Key('device-import-start')));
    await tester.pumpAndSettle();

    expect(find.text('Permission denied'), findsOneWidget);
    expect(find.byKey(const Key('device-import-retry')), findsOneWidget);
    expect(
      find.byKey(const Key('device-import-denied-done')),
      findsOneWidget,
    );
    // A plain deny must NOT claim the user has to go to Settings.
    expect(
      find.byKey(const Key('device-import-open-settings')),
      findsNothing,
    );
  });

  testWidgets('a permanently denied request offers Android Settings', (
    tester,
  ) async {
    var openedSettings = false;
    await pumpScreen(
      tester,
      requester: () async =>
          OperatingSystemPermissionState.permanentlyDenied,
      opener: () async {
        openedSettings = true;
        return true;
      },
    );

    await tester.tap(find.byKey(const Key('device-import-start')));
    await tester.pumpAndSettle();

    expect(find.text('Contacts access is turned off'), findsOneWidget);
    expect(
      find.byKey(const Key('device-import-open-settings')),
      findsOneWidget,
    );
    // The dead-end retry must not be the only affordance here.
    expect(find.byKey(const Key('device-import-list')), findsNothing);

    await tester.tap(find.byKey(const Key('device-import-open-settings')));
    await tester.pumpAndSettle();
    expect(openedSettings, isTrue);
  });

  testWidgets(
    'returning from Settings continues the import without re-tapping',
    (tester) async {
      var requests = 0;
      var checks = 0;
      var accessEnabled = false;

      await pumpScreen(
        tester,
        requester: () async {
          requests += 1;
          return accessEnabled
              ? OperatingSystemPermissionState.granted
              : OperatingSystemPermissionState.permanentlyDenied;
        },
        checker: () async {
          checks += 1;
          return accessEnabled
              ? OperatingSystemPermissionState.granted
              : OperatingSystemPermissionState.permanentlyDenied;
        },
        opener: () async {
          // Simulates the owner enabling Contacts in Android Settings.
          accessEnabled = true;
          return true;
        },
      );

      await tester.tap(find.byKey(const Key('device-import-start')));
      await tester.pumpAndSettle();
      expect(find.text('Contacts access is turned off'), findsOneWidget);

      await tester.tap(find.byKey(const Key('device-import-open-settings')));
      await tester.pumpAndSettle();

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      // Recovery is PASSIVE: it never asked Android for permission again.
      expect(requests, 1);
      expect(checks, greaterThanOrEqualTo(1));
      expect(find.byKey(const Key('device-import-list')), findsOneWidget);
      expect(find.text('Maria Santos'), findsOneWidget);
    },
  );

  testWidgets('a resume without a pending import intent does nothing', (
    tester,
  ) async {
    var checks = 0;
    await pumpScreen(
      tester,
      requester: () async => OperatingSystemPermissionState.granted,
      checker: () async {
        checks += 1;
        return OperatingSystemPermissionState.granted;
      },
    );

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(checks, 0);
    expect(find.byKey(const Key('device-import-list')), findsNothing);
  });
}
