import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/presentation/planner_notification_invitation.dart';
import 'package:rmplanner/features/privacy/domain/permission_summary.dart';

import '../../support/test_dependencies.dart';

/// OWNER RULING (2026-09-18): the notification education lives at the SHELL /
/// NAVIGATION boundary and is measured THERE.
///
/// Three mounting points inside `PlannerScreen` were built and measured, and
/// each broke a different accepted contract (canvas hit tests, the accepted
/// toolbar/header taps, the body height the canvas geometry is measured
/// against). These tests therefore assert the shell behaviour only — they never
/// assert an accepted Planner geometry or hit coordinate, and they prove the
/// Planner is not even mounted while the education is on screen.
void main() {
  const selected = PlannerDate(year: 2026, month: 7, day: 27);

  final education = find.byKey(const Key('planner-notification-education'));
  final notNow = find.byKey(const Key('planner-notification-not-now'));
  final enable = find.byKey(const Key('planner-notification-enable'));
  final openSettings = find.byKey(const Key('planner-notification-open-settings'));
  final plannerMounted = find.byKey(const Key('planner-create-button'));

  Future<FakePermissionGateway> pumpApp(
    WidgetTester tester, {
    required OperatingSystemPermissionState notifications,
    OperatingSystemPermissionState? requestResult,
  }) async {
    tester.view.physicalSize = const Size(393, 874);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final database = openMemoryDatabase();
    addTearDown(database.close);
    final gateway = FakePermissionGateway(
      states: <OptionalPermission, OperatingSystemPermissionState>{
        OptionalPermission.notifications: notifications,
      },
      requestResult: requestResult,
    );
    final privacy = TestPrivacyDependencies(
      database: database,
      permissionGateway: gateway,
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
        plannerDateSource: const FixedPlannerDateSource(selected),
        // The education only exists where Android owns POST_NOTIFICATIONS, and
        // this host is not Android, so the capability is granted explicitly
        // here to exercise the real flow.
        extraOverrides: [
          notificationEducationSupportedProvider.overrideWithValue(true),
        ],
      ),
    );
    await tester.pumpAndSettle();
    return gateway;
  }

  Future<void> selectPlanner(WidgetTester tester) async {
    await tester.tap(find.text('Planner'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'never-configured notifications: the education appears BEFORE the Planner '
    'is mounted',
    (tester) async {
      await pumpApp(
        tester,
        notifications: OperatingSystemPermissionState.denied,
      );
      expect(plannerMounted, findsNothing);
      await selectPlanner(tester);
      expect(education, findsOneWidget);
      expect(find.text('Turn on notifications?'), findsOneWidget);
      // The Planner has NOT been activated behind the education: this is the
      // property that keeps the Planner contract untouched.
      expect(plannerMounted, findsNothing);
    },
  );

  testWidgets(
    'Not now never asks Android, enters the Planner, and does not nag again in '
    'the same session',
    (tester) async {
      final gateway = await pumpApp(
        tester,
        notifications: OperatingSystemPermissionState.denied,
      );
      await selectPlanner(tester);
      await tester.tap(notNow);
      await tester.pumpAndSettle();
      expect(gateway.requestCount, 0);
      expect(education, findsNothing);
      expect(plannerMounted, findsOneWidget);
    },
  );

  testWidgets(
    'a later deliberate Planner entry offers the education again',
    (tester) async {
      await pumpApp(
        tester,
        notifications: OperatingSystemPermissionState.denied,
      );
      await selectPlanner(tester);
      await tester.tap(notNow);
      await tester.pumpAndSettle();
      // Leave the Planner, then deliberately enter it again.
      await tester.tap(find.text('Home'));
      await tester.pumpAndSettle();
      await selectPlanner(tester);
      expect(education, findsOneWidget);
    },
  );

  testWidgets(
    'Enable requests exactly once, seeds on a grant, and enters the Planner',
    (tester) async {
      final gateway = await pumpApp(
        tester,
        notifications: OperatingSystemPermissionState.denied,
        requestResult: OperatingSystemPermissionState.granted,
      );
      await selectPlanner(tester);
      await tester.tap(enable);
      await tester.pumpAndSettle();
      // Navigation is never blocked on the permission machinery: the Planner is
      // on screen first, and the request follows.
      expect(education, findsNothing);
      expect(plannerMounted, findsOneWidget);
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      // Exactly one request: the education never fires the dialog merely because
      // the Planner was opened, and it never fires it twice.
      expect(gateway.requestCount, 1);
    },
  );

  testWidgets(
    'permanently denied offers Open Settings instead of a dead request, and the '
    'Planner stays available',
    (tester) async {
      final gateway = await pumpApp(
        tester,
        notifications: OperatingSystemPermissionState.permanentlyDenied,
      );
      await selectPlanner(tester);
      expect(openSettings, findsOneWidget);
      expect(enable, findsNothing);
      await tester.tap(openSettings);
      await tester.pumpAndSettle();
      // No useless runtime request was issued, and the Settings door was used.
      expect(gateway.requestCount, 0);
      expect(gateway.settingsOpened, isTrue);
      expect(plannerMounted, findsOneWidget);
    },
  );
}
