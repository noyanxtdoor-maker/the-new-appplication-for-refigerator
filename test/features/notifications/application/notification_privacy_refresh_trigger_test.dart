import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/features/notifications/application/notification_privacy_refresh_provider.dart';
import 'package:rmplanner/features/notifications/application/notification_providers.dart';
import 'package:rmplanner/features/notifications/data/drift_notification_foundation_repository.dart';
import 'package:rmplanner/features/planner/application/calendar_event_providers.dart';
import 'package:rmplanner/features/planner/application/planner_providers.dart';
import 'package:rmplanner/features/privacy/application/privacy_providers.dart';
import 'package:rmplanner/features/privacy/domain/privacy_settings.dart';
import 'package:rmplanner/features/startup/application/startup_providers.dart';

import '../../../support/test_dependencies.dart';

void main() {
  test(
    'combined refresh dispatches one full Event and Task content pass',
    () async {
      final eventRefreshes = <bool>[];
      final taskRefreshes = <bool>[];
      // The pass composes the REAL reminder runtime (recovery coordinator,
      // orphan sweeper, registration repair), so it needs the same canonical
      // app-root overrides every other notification harness uses. A bare
      // container that only stubbed the two horizon passes tripped the
      // composition's own guard: 'NotificationFoundationRepository must be
      // overridden at the app root'.
      final database = openMemoryDatabase();
      addTearDown(database.close);
      final privacy = TestPrivacyDependencies(database: database);
      final container = ProviderContainer(
        overrides: <Override>[
          diagnosticsProvider.overrideWithValue(SanitizedDiagnostics()),
          startupRepositoryProvider.overrideWithValue(
            buildTestRepository(database: database),
          ),
          privacyRepositoryProvider.overrideWithValue(privacy.repository),
          permissionGatewayProvider.overrideWithValue(
            privacy.permissionGateway,
          ),
          notificationFoundationRepositoryProvider.overrideWithValue(
            DriftNotificationFoundationRepository(
              database: database,
              clock: FixedClock(DateTime.utc(2026, 9, 5)),
            ),
          ),
          notificationGatewayProvider.overrideWithValue(
            FakeNotificationGateway(),
          ),
          backgroundWorkGatewayProvider.overrideWithValue(
            FakeBackgroundWorkGateway(),
          ),
          eventReminderHorizonOverrideProvider.overrideWithValue((
            eventId,
            refreshContent,
          ) async {
            expect(eventId, isNull);
            eventRefreshes.add(refreshContent);
          }),
          taskReminderHorizonOverrideProvider.overrideWithValue((
            refreshContent,
          ) async {
            taskRefreshes.add(refreshContent);
          }),
        ],
      );
      addTearDown(container.dispose);

      await container.read(notificationPrivacyRefreshProvider)();

      expect(eventRefreshes, <bool>[true]);
      expect(taskRefreshes, <bool>[true]);
    },
  );

  test(
    'preview and lock writes dispatch once and preserve saved preview mode',
    () async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      final dependencies = TestPrivacyDependencies(database: database);
      var refreshCount = 0;
      final container = dependencies.createContainer(
        extraOverrides: <Override>[
          notificationPrivacyRefreshProvider.overrideWithValue(() async {
            refreshCount += 1;
          }),
        ],
      );
      addTearDown(container.dispose);
      final controller = container.read(privacyControllerProvider.notifier);
      await controller.initialize();

      await controller.setNotificationPreviewMode(
        NotificationPreviewMode.showContent,
      );
      expect(refreshCount, 1);
      await controller.setNotificationPreviewMode(
        NotificationPreviewMode.showContent,
      );
      expect(refreshCount, 1);

      expect(await controller.enableLock(), isTrue);
      expect(refreshCount, 2);
      expect(
        container
            .read(privacyControllerProvider)
            .settings
            .notificationPreviewMode,
        NotificationPreviewMode.showContent,
      );

      expect(await controller.disableLock(), isTrue);
      expect(refreshCount, 3);
      expect(
        container
            .read(privacyControllerProvider)
            .settings
            .notificationPreviewMode,
        NotificationPreviewMode.showContent,
      );

      await controller.setNotificationPreviewMode(
        NotificationPreviewMode.hidden,
      );
      expect(refreshCount, 4);
      expect(await controller.enableLock(), isTrue);
      expect(await controller.disableLock(), isTrue);
      expect(refreshCount, 6);
      expect(
        container
            .read(privacyControllerProvider)
            .settings
            .notificationPreviewMode,
        NotificationPreviewMode.hidden,
      );
    },
  );
}
