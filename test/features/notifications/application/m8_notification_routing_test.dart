import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:rmplanner/app/router/route_names.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/notifications/notification_payload.dart';
import 'package:rmplanner/core/notifications/notification_response_controller.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/notifications/application/notification_providers.dart';

import '../../../support/test_dependencies.dart';

void main() {
  Future<({TestPrivacyDependencies privacy, String profileId})> pumpReadyApp(
    WidgetTester tester,
    NotificationResponseController responses,
  ) async {
    final database = openMemoryDatabase();
    addTearDown(database.close);
    final privacy = TestPrivacyDependencies(database: database);
    final startup = buildTestRepository(
      database: database,
      privacyGate: privacy.gate,
    );
    final profile = await startup.completeOnboarding();
    await tester.pumpWidget(
      privacy.buildApp(
        environment: const AppEnvironment(
          name: AppEnvironmentName.production,
          label: 'PRODUCTION',
        ),
        diagnostics: SanitizedDiagnostics(),
        startupRepository: startup,
        extraOverrides: <Override>[
          notificationResponseControllerProvider.overrideWithValue(responses),
        ],
      ),
    );
    await tester.pumpAndSettle();
    return (privacy: privacy, profileId: profile.id);
  }

  testWidgets('T62 Snooze response is terminally ignored at app routing', (
    tester,
  ) async {
    final responses = NotificationResponseController();
    final ready = await pumpReadyApp(tester, responses);
    addTearDown(responses.dispose);

    responses.capture(
      payload: NotificationPayloadCodec.encode(
        NotificationResponseIntent(
          profileId: ready.profileId,
          sourceKind: NotificationSourceKind.task,
          sourceId: 'missing-task',
          action: NotificationResponseAction.snooze,
          generation: 0,
        ),
      ),
      actionId: 'snooze',
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));

    expect(find.byKey(const Key('main-bottom-navigation')), findsOneWidget);
    expect(
      await ready.privacy.repository.database
          .select(ready.privacy.repository.database.backgroundWorkRequests)
          .get(),
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('T63 missing Event notification is a safe no-op', (tester) async {
    final responses = NotificationResponseController();
    final ready = await pumpReadyApp(tester, responses);
    addTearDown(responses.dispose);

    responses.capture(
      payload: NotificationPayloadCodec.encode(
        NotificationResponseIntent(
          profileId: ready.profileId,
          sourceKind: NotificationSourceKind.calendarEvent,
          sourceId: 'deleted-event',
          occurrenceId: 'deleted-occurrence',
          action: NotificationResponseAction.open,
          generation: 0,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));

    expect(find.byKey(const Key('main-bottom-navigation')), findsOneWidget);
    expect(
      GoRouter.of(tester.element(find.byType(Scaffold).first)).state.uri.path,
      RoutePaths.home,
    );
    expect(tester.takeException(), isNull);
  });
}
