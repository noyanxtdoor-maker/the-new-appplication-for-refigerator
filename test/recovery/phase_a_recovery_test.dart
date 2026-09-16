import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/ids/identifier_source.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/goals/application/goal_providers.dart';
import 'package:rmplanner/features/goals/data/drift_goal_repository.dart';
import 'package:rmplanner/features/notifications/application/notification_privacy_refresh_provider.dart';
import 'package:rmplanner/features/notifications/application/notification_providers.dart';
import 'package:rmplanner/features/notifications/application/planning_reminder_reconciler.dart';
import 'package:rmplanner/features/notifications/application/reconcile_reminders.dart';
import 'package:rmplanner/features/notifications/application/reminder_reconciler.dart';
import 'package:rmplanner/features/notifications/domain/notification_preferences.dart'
    as prefs;
import 'package:rmplanner/features/planner/application/calendar_event_providers.dart';
import 'package:rmplanner/features/planner/application/event_type_providers.dart';
import 'package:rmplanner/features/planner/domain/event_color_preferences.dart';
import 'package:rmplanner/features/planner/domain/event_type.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/presentation/event_type_picker_dialog.dart';
import 'package:rmplanner/features/privacy/domain/permission_summary.dart';
import 'package:rmplanner/features/privacy/domain/privacy_settings.dart';
import 'package:rmplanner/features/startup/application/startup_providers.dart';
import 'package:rmplanner/features/startup/domain/startup_state.dart';
import 'package:rmplanner/features/weekly_planning/application/weekly_planning_providers.dart';
import 'package:rmplanner/features/weekly_planning/application/weekly_planning_repository.dart';
import 'package:rmplanner/features/weekly_planning/domain/weekly_plan.dart';

import '../support/test_dependencies.dart';
import '../support/view_size.dart';

void main() {
  test(
    'saved v46 disposable copy initializes without a schema downgrade',
    () async {
      final path = Platform.environment['PHASE_A_DISPOSABLE_DB'];
      expect(
        path,
        isNotNull,
        reason: 'Only run against the explicit disposable copy',
      );
      expect(path, contains('phase_a_disposable_v46.sqlite'));
      final database = AppDatabase.forTesting(NativeDatabase(File(path!)));
      try {
        expect(database.schemaVersion, 46);
        expect(
          (await database.customSelect('PRAGMA user_version').getSingle())
              .data
              .values
              .single,
          46,
        );
        expect(
          (await database.customSelect('PRAGMA integrity_check').getSingle())
              .data
              .values
              .single,
          'ok',
        );
        final tables = await database
            .customSelect("SELECT name FROM sqlite_master WHERE type='table'")
            .get();
        expect(tables.length, 45);
        expect(
          tables.map((row) => row.data['name']),
          containsAll([
            'goal_achievement_events',
            'weekly_plan_goal_memberships',
          ]),
        );
        await database.select(database.localProfiles).get();
        await database.select(database.goals).get();
        await database.select(database.goalAchievementEvents).get();
        await database.select(database.weeklyPlanGoalMemberships).get();
        final snapshot = await buildTestRepository(
          database: database,
        ).resolveStartup();
        expect(snapshot.profile, isNotNull);
        expect(snapshot.unlockRequired, isFalse);
      } finally {
        await database.close();
      }
    },
    skip: Platform.environment['PHASE_A_DISPOSABLE_DB'] == null
        ? 'Requires an explicit disposable v46 recovery fixture'
        : false,
  );

  testWidgets(
    'M5 startup reaches shell while planning reconciliation is pending, then completes',
    (tester) async {
      final database = openMemoryDatabase();
      addTearDown(database.close);
      final privacy = TestPrivacyDependencies(database: database);
      final startup = buildTestRepository(
        database: database,
        privacyGate: privacy.gate,
      );
      final profile = await startup.completeOnboarding();
      final release = Completer<void>();
      var planningCalls = 0;
      var planningFinished = false;
      final recovery = ReconcileReminders(
        reconcileEvents: () async {},
        reconcileTasks: () async {},
        reconcilePlanning: () async {
          planningCalls++;
          await release.future;
          planningFinished = true;
        },
      );
      await tester.pumpWidget(
        privacy.buildApp(
          environment: const AppEnvironment(
            name: AppEnvironmentName.production,
            label: 'PRODUCTION',
          ),
          diagnostics: SanitizedDiagnostics(),
          startupRepository: startup,
          extraOverrides: [
            reconcileRemindersProvider.overrideWithValue(recovery),
          ],
        ),
      );
      await tester.pumpAndSettle();
      // PRE-BETA RESPONSIVE (owner law, 2026-09-16): this finder is a handle on
      // the MOUNTED SHELL (used to reach the ProviderScope), not an assertion
      // about the bottom bar. It must therefore match whichever navigation
      // presentation the window width selects.
      final shell = navigationFinder();
      expect(shell, findsOneWidget);
      final container = ProviderScope.containerOf(tester.element(shell));
      expect(container.read(startupControllerProvider), isA<StartupReady>());
      expect(planningCalls, 1);
      expect(planningFinished, isFalse);
      release.complete();
      await tester.pumpAndSettle();
      expect(planningFinished, isTrue);
      expect(planningCalls, 1, reason: 'No startup reconciliation storm');

      final weekly = container.read(weeklyPlanningRepositoryProvider);
      final plan = await weekly.openOrCreate(
        profileId: profile.id,
        date: const PlannerDate(year: 2026, month: 7, day: 27),
      );
      final completion = weekly as WeeklyReviewCompletionSource;
      final reviewed = await completion.completeReview(
        profileId: profile.id,
        planId: plan.id,
      );
      expect(reviewed.storedState, WeeklyPlanState.reviewed);
      expect(reviewed.reviewCompletedAtUtc, isNotNull);
      final repeated = await completion.completeReview(
        profileId: profile.id,
        planId: plan.id,
      );
      expect(repeated.reviewCompletedAtUtc, reviewed.reviewCompletedAtUtc);
      expect(
        (await weekly.readHistory(
          profile.id,
        )).singleWhere((p) => p.id == plan.id).storedState,
        WeeklyPlanState.reviewed,
      );
      expect(
        await database.select(database.goalAchievementEvents).get(),
        isEmpty,
      );
      expect(
        await database.select(database.weeklyPlanGoalMemberships).get(),
        isEmpty,
      );

      // Exercise both M5 source readers through the real durable scheduler.
      final duePlan = await weekly.openOrCreate(
        profileId: profile.id,
        date: const PlannerDate(year: 2026, month: 7, day: 20),
      );
      final now = DateTime.utc(2026, 7, 27, 0, 30); // 08:30 Asia/Manila.
      await database
          .into(database.calendarEvents)
          .insert(
            CalendarEventsCompanion.insert(
              id: 'phase-a-report-event',
              profileId: profile.id,
              title: 'Report fixture',
              timing: 'timed',
              startDate: '2026-07-27',
              startMinute: const Value(480),
              endMinute: const Value(500),
              timeZoneId: const Value('Asia/Manila'),
              requiresReport: const Value(true),
              createdAtUtc: now,
              updatedAtUtc: now,
            ),
          );
      final foundation = container.read(
        notificationFoundationRepositoryProvider,
      );
      await foundation.savePreferences(
        profileId: profile.id,
        preferences: const prefs.NotificationPreferences.defaults().copyWith(
          systemNotificationsEnabled: true,
          weeklyReviewRemindersEnabled: true,
          awaitingReportRemindersEnabled: true,
        ),
      );
      final gateway = FakeNotificationGateway();
      final planning = PlanningReminderReconciler(
        weeklyPlans: weekly,
        events: container.read(calendarEventRepositoryProvider),
        repository: foundation,
        reminders: ReminderReconciler(
          repository: foundation,
          gateway: gateway,
          clock: FixedClock(now),
        ),
        permission: OperatingSystemPermissionState.granted,
        privacy: const PrivacySettings.defaults(),
      );
      await planning.reconcile(profileId: profile.id);
      expect(gateway.scheduledRequests.length, 2);
      expect(
        gateway.scheduledRequests.map((r) => r.scheduledAtUtc),
        containsAll([
          DateTime.utc(2026, 7, 27, 1),
          DateTime.utc(2026, 7, 27, 0, 35),
        ]),
      );
      await completion.completeReview(
        profileId: profile.id,
        planId: duePlan.id,
      );
      await planning.reconcile(profileId: profile.id);
      expect(
        gateway.cancelledIds,
        isNotEmpty,
        reason: 'Canonical review completion cancels its reminder',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'normal custom picker types remain before Task and use assigned colors',
    (tester) async {
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
        ),
      );
      await tester.pumpAndSettle();
      // PRE-BETA RESPONSIVE (owner law, 2026-09-16): this finder is a handle on
      // the MOUNTED SHELL (used to reach the ProviderScope), not an assertion
      // about the bottom bar. It must therefore match whichever navigation
      // presentation the window width selects.
      final shell = navigationFinder();
      final container = ProviderScope.containerOf(tester.element(shell));
      final repo = container.read(eventTypeRepositoryProvider);
      final customTypes = <EventType>[];
      for (var i = 0; i < 3; i++) {
        final type = await repo.saveCustomType(
          profileId: profile.id,
          draft: EventTypeDraft(
            id: 'f0000000-0000-4000-8000-00000000000${i + 1}',
            label: ['Daily Progress', 'Goal', 'Weekly Goal'][i],
            icon: EventTypeIcon.calendar,
            colorValue: 0xFF123456 + i,
            reportRequiredDefault: false,
            defaultDurationMinutes: 30,
            indicatorKeys: const {},
          ),
        );
        final saved = (await repo.readEventType(
          profileId: profile.id,
          eventTypeId: type.id,
        ))!;
        customTypes.add(saved);
        await repo.saveEventColorPreference(
          profileId: profile.id,
          eventTypeStableKey: saved.stableKey,
          preference: EventColorPreference(
            accentArgb: 0xFF1122AA + i,
            surfaceArgb: 0xFF334455,
          ),
        );
      }
      await tester.pumpWidget(
        ProviderScope(
          key: const ValueKey('isolated-picker-proof'),
          overrides: [
            eventTypeRepositoryProvider.overrideWithValue(repo),
            startupRepositoryProvider.overrideWithValue(startup),
            diagnosticsProvider.overrideWithValue(SanitizedDiagnostics()),
            goalRepositoryProvider.overrideWithValue(
              DriftGoalRepository(
                database: database,
                clock: FixedClock(DateTime.utc(2026, 9, 9, 2)),
                identifiers: const UuidIdentifierSource(),
              ),
            ),
          ],
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) {
                ref.watch(startupControllerProvider);
                return Scaffold(
                  body: TextButton(
                    onPressed: () =>
                        showEventTypePicker(context: context, ref: ref),
                    child: const Text('Choose'),
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Choose'));
      await tester.pumpAndSettle();
      final taskY = tester
          .getTopLeft(find.byKey(const Key('event-type-option-task')))
          .dy;
      var previousY = double.negativeInfinity;
      for (final key in SystemEventTypeKeys.approvedCreationOrder) {
        final finder = find.byKey(Key('event-type-option-$key'));
        if (finder.evaluate().isEmpty) continue;
        final y = tester.getTopLeft(finder).dy;
        expect(y, greaterThan(previousY));
        previousY = y;
      }
      for (var i = 0; i < customTypes.length; i++) {
        final type = customTypes[i];
        final y = tester
            .getTopLeft(find.byKey(Key('event-type-option-${type.stableKey}')))
            .dy;
        expect(y, greaterThan(previousY));
        expect(y, lessThan(taskY));
        previousY = y;
        final icon = tester.widget<Container>(
          find.byKey(Key('event-type-icon-${type.stableKey}')),
        );
        expect(
          (icon.decoration! as BoxDecoration).color,
          Color(0xFF1122AA + i),
        );
      }
      await tester.tap(find.byKey(const Key('event-type-picker-cancel')));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );
}
