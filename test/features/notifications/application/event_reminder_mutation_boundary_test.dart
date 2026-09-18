import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/notifications/application/launcher_badge_providers.dart';
import 'package:rmplanner/features/notifications/domain/reminder_policy.dart';
import 'package:rmplanner/features/planner/application/calendar_event_providers.dart';
import 'package:rmplanner/features/planner/domain/calendar_event.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';

import '../../../support/test_dependencies.dart';

void main() {
  testWidgets(
    'create and edit scopes invoke only their canonical Event sources',
    (tester) async {
      final calls = <String?>[];
      final controller = await _pumpController(tester, calls);
      final single = _draft(id: _singleId, date: _start);

      expect(await controller.saveEvent(single), CalendarEventSaveResult.saved);
      expect(calls, <String?>[_singleId]);

      calls.clear();
      expect(
        await controller.editEvent(
          eventId: _singleId,
          originalDate: _start,
          scope: CalendarEventEditScope.occurrence,
          draft: single.copyWith(title: 'Edited single'),
          operationId: _operation(1),
          reminderMode: ReminderPolicyMode.offset,
          reminderOffsetMinutes: 27,
        ),
        isTrue,
      );
      expect(calls, <String?>[_singleId]);

      final series = _draft(
        id: _seriesId,
        date: _start,
        recurrence: const CalendarRecurrenceRule(
          frequency: CalendarRecurrenceFrequency.daily,
        ),
      );
      calls.clear();
      expect(await controller.saveEvent(series), CalendarEventSaveResult.saved);
      expect(calls, <String?>[_seriesId]);

      calls.clear();
      expect(
        await controller.editEvent(
          eventId: _seriesId,
          originalDate: _start.addDays(1),
          scope: CalendarEventEditScope.occurrence,
          draft: series.copyWith(
            title: 'Occurrence exception',
            startDate: _start.addDays(1),
          ),
          operationId: _operation(2),
          reminderMode: ReminderPolicyMode.off,
        ),
        isTrue,
      );
      expect(calls, <String?>[_seriesId]);

      calls.clear();
      expect(
        await controller.editEvent(
          eventId: _seriesId,
          originalDate: _start,
          scope: CalendarEventEditScope.series,
          draft: series.copyWith(title: 'Edited series'),
          operationId: _operation(3),
          reminderMode: ReminderPolicyMode.offset,
          reminderOffsetMinutes: 6,
        ),
        isTrue,
      );
      expect(calls, <String?>[_seriesId]);

      calls.clear();
      expect(
        await controller.editEvent(
          eventId: _seriesId,
          originalDate: _start.addDays(2),
          scope: CalendarEventEditScope.thisAndFuture,
          draft: _draft(
            id: _splitId,
            date: _start.addDays(2),
            recurrence: const CalendarRecurrenceRule(
              frequency: CalendarRecurrenceFrequency.daily,
            ),
          ),
          operationId: _operation(4),
          reminderMode: ReminderPolicyMode.inherit,
        ),
        isTrue,
      );
      expect(calls, <String?>[_seriesId, _splitId]);
    },
  );

  testWidgets(
    'cancel, reschedule, replacement, and duplicate use exact scopes',
    (tester) async {
      final calls = <String?>[];
      final controller = await _pumpController(tester, calls);

      final single = _draft(id: _singleId, date: _start);
      await controller.saveEvent(single);
      calls.clear();
      expect(
        await controller.rescheduleEvent(
          eventId: _singleId,
          originalDate: _start,
          scope: CalendarEventEditScope.occurrence,
          replacement: _draft(id: _replacementId, date: _start.addDays(1)),
          operationId: _operation(5),
          refreshPlanner: false,
          reminderMode: ReminderPolicyMode.offset,
          reminderOffsetMinutes: 15,
        ),
        isTrue,
      );
      expect(calls, <String?>[_singleId, _replacementId]);

      final series = _draft(
        id: _seriesId,
        date: _start,
        recurrence: const CalendarRecurrenceRule(
          frequency: CalendarRecurrenceFrequency.daily,
        ),
      );
      calls.clear();
      await controller.saveEvent(series);
      calls.clear();
      expect(
        await controller.rescheduleEvent(
          eventId: _seriesId,
          originalDate: _start.addDays(1),
          scope: CalendarEventEditScope.occurrence,
          replacement: _draft(
            id: _unusedReplacementId,
            date: _start.addDays(2),
          ),
          operationId: _operation(6),
          refreshPlanner: false,
          reminderMode: ReminderPolicyMode.offset,
          reminderOffsetMinutes: 30,
        ),
        isTrue,
      );
      expect(calls, <String?>[_seriesId]);

      calls.clear();
      expect(
        await controller.cancelEvent(
          eventId: _seriesId,
          originalDate: _start.addDays(1),
          scope: CalendarEventEditScope.occurrence,
          operationId: _operation(7),
          refreshPlanner: false,
          managePendingDeletion: false,
        ),
        CalendarEventCancellationResult.deleted,
      );
      expect(calls, <String?>[_seriesId]);

      final duplicateSource = _draft(id: _duplicateSourceId, date: _start);
      calls.clear();
      await controller.saveEvent(duplicateSource);
      calls.clear();
      expect(
        await controller.duplicateEvent(
          eventId: _duplicateSourceId,
          originalDate: _start,
          duplicateId: _duplicateId,
          operationId: _operation(8),
        ),
        isTrue,
      );
      expect(calls, <String?>[_duplicateId]);
    },
  );

  testWidgets('direct occurrence and series policy changes reconcile once', (
    tester,
  ) async {
    final calls = <String?>[];
    final controller = await _pumpController(tester, calls);

    await controller.saveReminderPolicyAndReconcile(
      sourceId: _seriesId,
      occurrenceId: CalendarEventOccurrenceIdentity.forDate(
        eventId: _seriesId,
        originalDate: _start.addDays(1),
      ),
      mode: ReminderPolicyMode.offset,
      offsetMinutes: 6,
    );
    expect(calls, <String?>[_seriesId]);

    calls.clear();
    await controller.saveReminderPolicyAndReconcile(
      sourceId: _seriesId,
      occurrenceId: ReminderPolicy.seriesOccurrenceId,
      mode: ReminderPolicyMode.off,
    );
    expect(calls, <String?>[_seriesId]);
  });

  testWidgets('badge projection failure cannot roll back Event creation', (
    tester,
  ) async {
    final calls = <String?>[];
    final controller = await _pumpController(
      tester,
      calls,
      badgeRefresh: () async => throw StateError('OEM badge unavailable'),
    );

    expect(
      await controller.saveEvent(_draft(id: _singleId, date: _start)),
      CalendarEventSaveResult.saved,
    );
    expect(calls, <String?>[_singleId]);
    expect(await controller.readEventDraft(_singleId), isNotNull);
  });
}

const _start = PlannerDate(year: 2026, month: 9, day: 7);
const _singleId = '10000000-0000-4000-8000-000000000001';
const _seriesId = '10000000-0000-4000-8000-000000000002';
const _splitId = '10000000-0000-4000-8000-000000000003';
const _replacementId = '10000000-0000-4000-8000-000000000004';
const _unusedReplacementId = '10000000-0000-4000-8000-000000000005';
const _duplicateSourceId = '10000000-0000-4000-8000-000000000006';
const _duplicateId = '10000000-0000-4000-8000-000000000007';

String _operation(int value) =>
    '20000000-0000-4000-8000-${value.toString().padLeft(12, '0')}';

CalendarEventDraft _draft({
  required String id,
  required PlannerDate date,
  CalendarRecurrenceRule recurrence = const CalendarRecurrenceRule(),
}) => CalendarEventDraft(
  id: id,
  title: 'Event $id',
  timing: CalendarEventTiming.timed,
  startDate: date,
  startMinute: 10 * 60,
  endMinute: 11 * 60,
  timeZoneId: 'Asia/Manila',
  requiresReport: false,
  recurrence: recurrence,
);

Future<CalendarEventController> _pumpController(
  WidgetTester tester,
  List<String?> calls, {
  LauncherBadgeRefresh? badgeRefresh,
}) async {
  final database = openMemoryDatabase();
  addTearDown(database.close);
  final privacy = TestPrivacyDependencies(database: database);
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
      plannerDateSource: const FixedPlannerDateSource(_start),
      extraOverrides: <Override>[
        eventReminderHorizonOverrideProvider.overrideWithValue((
          eventId,
          refreshContent,
        ) async {
          calls.add(eventId);
        }),
        if (badgeRefresh != null)
          launcherBadgeRefreshProvider.overrideWithValue(badgeRefresh),
      ],
    ),
  );
  await tester.pumpAndSettle();
  // M4 startup recovery is independent of the source-mutation scope under test.
  expect(calls, <String?>[null]);
  calls.clear();
  final container = ProviderScope.containerOf(
    tester.element(find.byType(MaterialApp).first),
  );
  return container.read(calendarEventControllerProvider.notifier);
}
