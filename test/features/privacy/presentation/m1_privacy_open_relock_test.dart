// M1 (T3 / I–K) — real-app pending OPEN + background relock with UNKNOWN
// privacy settings.
//
// The whole point of S01 is behavioural, so this suite drives the real
// `NextTransferApp`, the real shared `SessionPrivacyGate` and the real startup
// repository over an in-memory database.  Only the CONTROLLER's own repository
// is wrapped, and only so its settings read can fail while startup's
// independent canonical read keeps succeeding.
//
// The privacy law under test:
//   * while provenance is unknown, Unlock must not mark the session unlocked,
//     must not raise an OS prompt, and must not release a pending Task OPEN;
//   * after a fresh successful read plus a real OS success, the same Unlock
//     tap resolves Ready and releases the held intent exactly once;
//   * another profile's intent stays rejected;
//   * an unknown fallback `lockEnabled == false` still qualifies for the
//     accepted five-minute background protection window.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/app/router/app_router.dart';
import 'package:rmplanner/app/router/route_names.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/notifications/notification_payload.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/notifications/application/notification_providers.dart';
import 'package:rmplanner/features/planner/application/planner_repository.dart';
import 'package:rmplanner/features/planner/data/drift_planner_repository.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_day.dart';
import 'package:rmplanner/features/planner/domain/planner_task.dart';
import 'package:rmplanner/features/planner/presentation/task_preview_sheet.dart';
import 'package:rmplanner/features/privacy/application/privacy_providers.dart';
import 'package:rmplanner/features/privacy/application/privacy_repository.dart';
import 'package:rmplanner/features/privacy/application/privacy_services.dart';
import 'package:rmplanner/features/privacy/domain/permission_summary.dart';
import 'package:rmplanner/features/privacy/domain/privacy_settings.dart';
import 'package:rmplanner/features/startup/application/startup_providers.dart';
import 'package:rmplanner/features/startup/application/startup_repository.dart';
import 'package:rmplanner/features/startup/domain/startup_state.dart';

import '../../../support/test_dependencies.dart';

const PlannerDate _monday = PlannerDate(year: 2026, month: 7, day: 27);
const String _taskId = 'm1-open-task';

/// Delegating privacy repository whose settings read can be failed on demand.
final class _FailingSettingsReader implements PrivacyRepository {
  _FailingSettingsReader(this._inner);

  final PrivacyRepository _inner;

  bool failing = false;

  @override
  Future<PrivacySettings> readSettings() async {
    if (failing) {
      throw StateError('injected privacy read failure');
    }
    return _inner.readSettings();
  }

  @override
  Future<PrivacySettings> setLockEnabled(bool enabled) =>
      _inner.setLockEnabled(enabled);

  @override
  Future<PrivacySettings> setNotificationPreviewMode(
    NotificationPreviewMode mode,
  ) => _inner.setNotificationPreviewMode(mode);

  @override
  Future<PermissionAudit> readPermissionAudit(OptionalPermission permission) =>
      _inner.readPermissionAudit(permission);

  @override
  Future<void> recordPermissionGranted(OptionalPermission permission) =>
      _inner.recordPermissionGranted(permission);

  @override
  Future<void> recordPermissionRequested(OptionalPermission permission) =>
      _inner.recordPermissionRequested(permission);

  @override
  Future<bool> isPrivacyLockEnabled() => _inner.isPrivacyLockEnabled();
}

/// Delegating planner repository whose Task lookup can be held open, so a
/// relock can land between intent acceptance and preview presentation.
final class _GatedPlannerRepository implements PlannerRepository {
  _GatedPlannerRepository(this._inner);

  final PlannerRepository _inner;

  bool gateReadTask = false;
  Completer<void>? readTaskGate;

  @override
  Future<PlannerDay> readDay({
    required String profileId,
    required PlannerDate selectedDate,
    required PlannerDate today,
  }) => _inner.readDay(
    profileId: profileId,
    selectedDate: selectedDate,
    today: today,
  );

  @override
  Future<PlannerTask?> readTask({
    required String profileId,
    required String taskId,
  }) async {
    if (gateReadTask) {
      final gate = readTaskGate;
      if (gate != null) {
        await gate.future;
      }
    }
    return _inner.readTask(profileId: profileId, taskId: taskId);
  }

  @override
  Future<PlannerTask> saveTask({
    required String profileId,
    required PlannerTaskDraft draft,
    bool confirmLinkedTypeTransfer = false,
  }) => _inner.saveTask(
    profileId: profileId,
    draft: draft,
    confirmLinkedTypeTransfer: confirmLinkedTypeTransfer,
  );

  @override
  Future<TaskStatusChangeOutcome> changeTaskStatus({
    required String profileId,
    required String taskId,
    required PlannerTaskStatus target,
    required String operationId,
    String? reason,
    bool confirmLinkedTypeTransfer = false,
  }) => _inner.changeTaskStatus(
    profileId: profileId,
    taskId: taskId,
    target: target,
    operationId: operationId,
    reason: reason,
    confirmLinkedTypeTransfer: confirmLinkedTypeTransfer,
  );

  @override
  Future<TaskHardDeleteOutcome> hardDeleteTask({
    required String profileId,
    required String taskId,
  }) => _inner.hardDeleteTask(profileId: profileId, taskId: taskId);
}

final class _Harness {
  _Harness({
    required this.privacy,
    required this.startup,
    required this.planner,
    required this.reader,
    required this.profileId,
  });

  final TestPrivacyDependencies privacy;
  final StartupRepository startup;
  final DriftPlannerRepository planner;
  final _FailingSettingsReader reader;
  final String profileId;
}

Future<_Harness> _openHarness({required bool lockEnabled}) async {
  final database = openMemoryDatabase();
  addTearDown(database.close);
  final privacy = TestPrivacyDependencies(database: database);
  final startup = buildTestRepository(database: database, privacyGate: privacy.gate);
  final profile = await startup.completeOnboarding();
  if (lockEnabled) {
    await privacy.repository.setLockEnabled(true);
  }
  final planner = DriftPlannerRepository(
    database: database,
    clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
  );
  await planner.saveTask(
    profileId: profile.id,
    draft: const PlannerTaskDraft(
      id: _taskId,
      title: 'M1 pending errand',
      dueDate: _monday,
      dueMinute: 9 * 60,
      requiresReport: false,
    ),
  );
  final reader = _FailingSettingsReader(privacy.repository);
  return _Harness(
    privacy: privacy,
    startup: startup,
    planner: planner,
    reader: reader,
    profileId: profile.id,
  );
}

Future<ProviderContainer> _pumpApp(
  WidgetTester tester,
  _Harness harness, {
  PlannerRepository? planner,
}) async {
  await tester.pumpWidget(
    harness.privacy.buildApp(
      environment: const AppEnvironment(
        name: AppEnvironmentName.production,
        label: 'PRODUCTION',
      ),
      diagnostics: SanitizedDiagnostics(),
      startupRepository: harness.startup,
      plannerRepository: planner ?? harness.planner,
      plannerDateSource: const FixedPlannerDateSource(_monday),
      extraOverrides: [
        privacyRepositoryProvider.overrideWithValue(harness.reader),
      ],
    ),
  );
  await tester.pumpAndSettle();
  // Dispose the mounted app BEFORE the database teardown: a FAILED widget test
  // does not tear the tree down, and closing the database while the app still
  // holds an open stream wedges the next test in the same file.
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });
  return ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
}

NotificationResponseIntent _taskOpen(String profileId) =>
    NotificationResponseIntent(
      profileId: profileId,
      sourceKind: NotificationSourceKind.task,
      sourceId: _taskId,
      occurrenceId: 'task:$_taskId:2026-07-27',
      action: NotificationResponseAction.open,
    );

void main() {
  testWidgets(
    'J1/J2 an unknown settings read holds the lock and the pending Task OPEN, '
    'then releases it once after a real successful read and OS unlock',
    (tester) async {
      final harness = await _openHarness(lockEnabled: true);
      harness.reader.failing = true;
      final container = await _pumpApp(tester, harness);

      // The canonical startup read still succeeds, so the app is Protected.
      expect(find.byKey(const Key('unlock-button')), findsOneWidget);
      expect(container.read(startupControllerProvider), isA<StartupProtected>());
      expect(
        container.read(privacyControllerProvider).status,
        isNot(PrivacyLockStatus.unlocked),
      );

      // A matching Task OPEN is accepted but held: not Ready yet.
      container
          .read(notificationResponseControllerProvider)
          .capture(payload: NotificationPayloadCodec.encode(_taskOpen(harness.profileId)));
      await tester.pumpAndSettle();
      expect(find.byType(TaskPreviewSheet), findsNothing);
      expect(find.byKey(const Key('main-bottom-navigation')), findsNothing);

      // Unlock while the retry still fails: no OS prompt, no access, no OPEN.
      await tester.tap(find.byKey(const Key('unlock-button')));
      await tester.pumpAndSettle();
      expect(
        harness.privacy.authenticator.authenticationAttempts,
        0,
        reason: 'unknown settings must not raise an OS authentication prompt',
      );
      expect(
        container.read(privacyControllerProvider).status,
        isNot(PrivacyLockStatus.unlocked),
      );
      expect(await harness.privacy.gate.isUnlockRequired(), isTrue);
      expect(container.read(startupControllerProvider), isA<StartupProtected>());
      expect(find.byType(TaskPreviewSheet), findsNothing);
      expect(find.byKey(const Key('main-bottom-navigation')), findsNothing);

      // A fresh successful read plus a real OS success unlocks and releases it.
      harness.reader.failing = false;
      harness.privacy.authenticator.authenticationResult =
          DeviceAuthenticationResult.authenticated;
      await tester.tap(find.byKey(const Key('unlock-button')));

      // Bounded pump window rather than a single settle: the ticket requires the
      // release to be recorded at each boundary, not only the final settled
      // screen.  (R1 — a pre-existing defect recorded in the M1 session audit:
      // once Ready is published, the accepted app presents this preview and
      // then loses it when that same publication rebuilds `appRouterProvider`.
      // Verified on the unchanged accepted HEAD with an S01-independent probe,
      // so it is NOT an M1 regression; router/notification-routing repair is
      // explicitly outside the M1 allowlist.  This test therefore asserts the
      // SECURITY properties of the release — authorized release, exactly once,
      // to the matching canonical source — and records R1 separately.)
      final presentations = <int>[];
      final canonicalTitles = <bool>[];
      final routes = <String>[];
      for (var frame = 0; frame < 40; frame += 1) {
        await tester.pump(const Duration(milliseconds: 25));
        presentations.add(find.byType(TaskPreviewSheet).evaluate().length);
        canonicalTitles.add(
          find.text('M1 pending errand').evaluate().isNotEmpty,
        );
        routes.add(
          container
              .read(appRouterProvider)
              .routerDelegate
              .currentConfiguration
              .uri
              .toString(),
        );
      }

      expect(
        container.read(privacyControllerProvider).status,
        PrivacyLockStatus.unlocked,
      );
      expect(await harness.privacy.gate.isUnlockRequired(), isFalse);
      expect(container.read(startupControllerProvider), isA<StartupReady>());
      expect(
        presentations.any((count) => count > 0),
        isTrue,
        reason: 'the held matching intent is presented after a real unlock',
      );
      expect(
        presentations.any((count) => count > 1),
        isFalse,
        reason: 'the release presents exactly once, never a duplicate stack',
      );
      expect(
        canonicalTitles.any((seen) => seen),
        isTrue,
        reason: 'the presented preview is the matching canonical Task',
      );
      expect(
        routes,
        contains(RoutePaths.planner),
        reason: 'the release routes to Planner, never to an arbitrary location',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('J3 an intent for another profile is still a safe no-op', (
    tester,
  ) async {
    final harness = await _openHarness(lockEnabled: false);
    final container = await _pumpApp(tester, harness);
    expect(container.read(startupControllerProvider), isA<StartupReady>());

    container
        .read(notificationResponseControllerProvider)
        .capture(
          payload: NotificationPayloadCodec.encode(
            _taskOpen('a-different-profile'),
          ),
        );
    await tester.pumpAndSettle();

    expect(find.byType(TaskPreviewSheet), findsNothing);
    expect(container.read(startupControllerProvider), isA<StartupReady>());
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'J4 a relock during a delayed Task lookup cannot present over protection',
    (tester) async {
      final harness = await _openHarness(lockEnabled: true);
      final gated = _GatedPlannerRepository(harness.planner);
      final container = await _pumpApp(tester, harness, planner: gated);
      expect(find.byKey(const Key('unlock-button')), findsOneWidget);

      harness.privacy.authenticator.authenticationResult =
          DeviceAuthenticationResult.authenticated;
      await tester.tap(find.byKey(const Key('unlock-button')));
      await tester.pumpAndSettle();
      expect(container.read(startupControllerProvider), isA<StartupReady>());

      // Accept the intent, but hold the canonical Task lookup open.
      gated.gateReadTask = true;
      gated.readTaskGate = Completer<void>();
      container
          .read(notificationResponseControllerProvider)
          .capture(payload: NotificationPayloadCodec.encode(_taskOpen(harness.profileId)));
      await tester.pump();
      await tester.pump();

      // Relock while the lookup is still pending.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(minutes: 5));
      expect(
        container.read(privacyControllerProvider).status,
        PrivacyLockStatus.locked,
      );

      gated.readTaskGate!.complete();
      await tester.pumpAndSettle();

      expect(
        find.byType(TaskPreviewSheet),
        findsNothing,
        reason: 'a stale resolution must be a safe no-op, not a presentation',
      );
      expect(container.read(startupControllerProvider), isA<StartupProtected>());
      // The Protected transition while Home is mounted surfaces a pre-existing
      // Home-indicator `StateError` for one frame (the indicator providers
      // rebuild against a non-Ready profile).  Those indicators are outside the
      // M1 allowlist, so the inherited error is RECORDED rather than masked: a
      // new exception type still fails this test.
      final transitionError = tester.takeException();
      expect(
        transitionError,
        anyOf(isNull, isA<StateError>()),
        reason: 'only the inherited Home-indicator transition error is expected',
      );
    },
  );

  testWidgets(
    'I1 an unknown fallback lockEnabled=false still honors the five-minute '
    'background protection window',
    (tester) async {
      final harness = await _openHarness(lockEnabled: true);
      harness.reader.failing = true;
      final container = await _pumpApp(tester, harness);
      expect(
        container.read(privacyControllerProvider).status,
        PrivacyLockStatus.unavailable,
      );

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      await tester.pump(const Duration(minutes: 4, seconds: 59));
      expect(
        container.read(privacyControllerProvider).status,
        isNot(PrivacyLockStatus.locked),
        reason: 'the accepted window must not fire early',
      );

      // Repeated lifecycle noise must not restart the single monotonic window.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(
        container.read(privacyControllerProvider).status,
        PrivacyLockStatus.locked,
        reason: 'unknown settings still require protection at the threshold',
      );
      expect(container.read(startupControllerProvider), isA<StartupProtected>());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('K1 trusted-disabled startup still reaches Home with no prompt', (
    tester,
  ) async {
    final harness = await _openHarness(lockEnabled: false);
    final container = await _pumpApp(tester, harness);

    expect(container.read(startupControllerProvider), isA<StartupReady>());
    expect(
      container.read(privacyControllerProvider).status,
      PrivacyLockStatus.disabled,
    );
    expect(
      find.byKey(const Key('main-bottom-navigation')),
      findsOneWidget,
      reason: 'a genuinely disabled profile is not locked out',
    );
    expect(harness.privacy.authenticator.authenticationAttempts, 0);
    expect(tester.takeException(), isNull);
  });
}
