// POST-P2 OWNER DECISION (2026-09-22) — the Permissions screen becomes
// actionable and honest.
//
// The audit proved two things about this screen:
//   * its four rows had NO onTap at all, so permission state was readable but
//     never actionable in-app — even for permissions Android can still prompt
//     for; the only control was the footer "Open Android app settings" button;
//   * `PermissionSummary.purpose` was populated by the domain and rendered
//     NOWHERE, and the Device calendar row presented a runtime state for a
//     permission this build does not even declare (no READ_CALENDAR /
//     WRITE_CALENDAR in the manifest), so it can never be granted.
//
// The owner's law:
//   requestable (not requested / denied) -> request through the canonical
//       gateway, exactly once, then refresh;
//   revoked (Android will not prompt again) -> open Android app settings and
//       NEVER call request;
//   granted / unavailable -> informational, no redundant request;
//   Device calendar -> informational placeholder, never a request.
//
// These tests fail against the pre-change tree: there was no row action to
// trigger, no purpose copy, and the calendar row claimed a runtime state.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/features/privacy/application/privacy_providers.dart';
import 'package:rmplanner/features/privacy/application/privacy_services.dart';
import 'package:rmplanner/features/privacy/data/drift_privacy_repository.dart';
import 'package:rmplanner/features/privacy/domain/permission_summary.dart';
import 'package:rmplanner/features/privacy/presentation/permissions_screen.dart';

import '../../../support/test_dependencies.dart';

/// A counting gateway: the assertions are about WHICH call is made, so both
/// counters must be observable.
final class _CountingGateway implements PermissionGateway {
  _CountingGateway({
    Map<OptionalPermission, OperatingSystemPermissionState>? states,
  }) : states =
           states ?? <OptionalPermission, OperatingSystemPermissionState>{};

  final Map<OptionalPermission, OperatingSystemPermissionState> states;
  int requestCount = 0;
  int settingsCount = 0;

  @override
  Future<bool> openSystemSettings() async {
    settingsCount += 1;
    return true;
  }

  @override
  Future<OperatingSystemPermissionState> status(
    OptionalPermission permission,
  ) async => states[permission] ?? OperatingSystemPermissionState.denied;

  @override
  Future<OperatingSystemPermissionState> request(
    OptionalPermission permission,
  ) async {
    requestCount += 1;
    return states[permission] ?? OperatingSystemPermissionState.denied;
  }
}

void main() {
  late DriftPrivacyRepository repository;
  late _CountingGateway gateway;
  late ProviderContainer container;

  Future<void> build({
    Map<OptionalPermission, OperatingSystemPermissionState>? states,
    bool seedGrantedAudit = false,
  }) async {
    final database = openMemoryDatabase();
    addTearDown(database.close);
    repository = DriftPrivacyRepository(
      database: database,
      clock: FixedClock(DateTime.utc(2026, 9, 22, 12)),
    );
    gateway = _CountingGateway(states: states);
    if (seedGrantedAudit) {
      // "Was granted, is now denied in system settings": the audit flags are
      // what turn a platform permanentlyDenied into the Revoked state.
      for (final permission in OptionalPermissionCatalog.values) {
        await repository.recordPermissionRequested(permission);
        await repository.recordPermissionGranted(permission);
      }
    }
    container = ProviderContainer(
      overrides: <Override>[
        privacyRepositoryProvider.overrideWithValue(repository),
        permissionGatewayProvider.overrideWithValue(gateway),
      ],
    );
    addTearDown(container.dispose);
  }

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: PermissionsScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tapRow(
    WidgetTester tester,
    OptionalPermission permission,
  ) async {
    await tester.tap(find.byKey(Key('permission-row-${permission.name}')));
    await tester.pumpAndSettle();
  }

  testWidgets('every row renders its canonical purpose copy', (tester) async {
    await build();
    await pump(tester);

    // The domain has always carried these sentences; the screen simply never
    // showed them, which is why the page read as a list of cryptic chips.
    for (final permission in <OptionalPermission>[
      OptionalPermission.contacts,
      OptionalPermission.notifications,
      OptionalPermission.foregroundLocation,
    ]) {
      expect(
        find.text(OptionalPermissionCatalog.purpose(permission)),
        findsOneWidget,
        reason: '${permission.name} purpose must be rendered',
      );
    }
    expect(find.text('Not available in this build.'), findsOneWidget);
    expect(find.text('Device calendar'), findsOneWidget);
  });

  testWidgets('the rows are grouped and vertically ordered without overlap', (
    tester,
  ) async {
    await build();
    await pump(tester);

    final rects = <Rect>[
      for (final permission in OptionalPermissionCatalog.values)
        tester.getRect(find.byKey(Key('permission-row-${permission.name}'))),
    ];
    for (var index = 1; index < rects.length; index++) {
      expect(
        rects[index].top,
        greaterThanOrEqualTo(rects[index - 1].bottom),
        reason: 'rows must not overlap or touch the previous row',
      );
    }
    // One grouped card holds all four rows (the accepted settings pattern).
    expect(
      find.ancestor(
        of: find.byKey(const Key('permission-row-contacts')),
        matching: find.byType(Card),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a requestable row requests exactly once through the gateway', (
    tester,
  ) async {
    // Default state: denied on the platform and never asked -> "Not requested",
    // which Android can still prompt for.
    await build();
    await pump(tester);
    expect(find.text('Not requested'), findsNWidgets(3));

    await tapRow(tester, OptionalPermission.contacts);
    expect(gateway.requestCount, 1);
    expect(gateway.settingsCount, 0);
  });

  testWidgets('a revoked row opens Android settings and NEVER requests', (
    tester,
  ) async {
    await build(
      states: <OptionalPermission, OperatingSystemPermissionState>{
        OptionalPermission.contacts:
            OperatingSystemPermissionState.permanentlyDenied,
      },
      seedGrantedAudit: true,
    );
    await pump(tester);
    await tapRow(tester, OptionalPermission.contacts);

    expect(
      gateway.settingsCount,
      1,
      reason: 'only the system settings screen can change a permanently denied',
    );
    expect(
      gateway.requestCount,
      0,
      reason: 'requesting again would show the user nothing',
    );
  });

  testWidgets('a granted row never re-requests', (tester) async {
    await build(
      states: <OptionalPermission, OperatingSystemPermissionState>{
        OptionalPermission.notifications:
            OperatingSystemPermissionState.granted,
      },
    );
    await pump(tester);
    await tapRow(tester, OptionalPermission.notifications);

    expect(gateway.requestCount, 0);
    expect(gateway.settingsCount, 0);
  });

  testWidgets('the Device calendar row is informational and never requests', (
    tester,
  ) async {
    await build(
      states: <OptionalPermission, OperatingSystemPermissionState>{
        OptionalPermission.calendar: OperatingSystemPermissionState.granted,
      },
    );
    await pump(tester);

    // Even a platform answer of "granted" cannot be shown as a running
    // capability: this build declares no calendar permission and ships no
    // calendar integration.
    expect(
      find.descendant(
        of: find.byKey(const Key('permission-row-calendar')),
        matching: find.text('Unavailable'),
      ),
      findsOneWidget,
    );
    await tapRow(tester, OptionalPermission.calendar);
    expect(gateway.requestCount, 0);
    expect(gateway.settingsCount, 0);
  });
}
