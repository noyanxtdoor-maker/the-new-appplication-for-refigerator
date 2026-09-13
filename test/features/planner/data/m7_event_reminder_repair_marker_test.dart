import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/background/background_work_request.dart';
import 'package:rmplanner/core/background/reminder_recovery_request.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/ids/identifier_source.dart';
import 'package:rmplanner/features/notifications/data/drift_notification_foundation_repository.dart';
import 'package:rmplanner/features/planner/data/calendar_event_time_zones.dart';
import 'package:rmplanner/features/planner/data/drift_calendar_event_repository.dart';
import 'package:rmplanner/features/planner/data/drift_event_type_repository.dart';
import 'package:rmplanner/features/planner/domain/calendar_event.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';

import '../../../support/test_dependencies.dart';

/// M7 section 27 — the repair intent is a property of the MUTATION, not of a
/// dashboard.  These tests pin the two behaviours that are easy to get wrong:
///
/// * an Event mutation that changes a reminder's timing or eligibility commits
///   exactly one profile-scoped marker inside its own transaction;
/// * a settings save that does NOT change the global reminder default must not
///   mark anything, because the marker means "reminders need a fresh look" and
///   an unrelated save creates no such need.
void main() {
  late AppDatabase database;
  late ReminderRecoveryRequest marker;
  late DriftNotificationFoundationRepository notifications;
  late String profileId;

  final clock = FixedClock(DateTime.utc(2026, 9, 11, 10));

  setUp(() async {
    database = openMemoryDatabase();
    marker = ReminderRecoveryRequest(
      database: database,
      clock: clock,
      identifiers: const UuidIdentifierSource(),
    );
    notifications = DriftNotificationFoundationRepository(
      database: database,
      clock: clock,
    );
    profileId = (await buildTestRepository(
      database: database,
    ).completeOnboarding()).id;
  });

  tearDown(() => database.close());

  Future<BackgroundWorkRequest?> readMarker() =>
      notifications.readWorkRequest(ReminderRecoveryRequest.stableKeyFor(profileId));

  Future<int> markerCount() async {
    final rows = await database.select(database.backgroundWorkRequests).get();
    return rows
        .where((row) => row.stableKey.startsWith('reconcile:reminders:'))
        .length;
  }

  DriftCalendarEventRepository buildEvents() => DriftCalendarEventRepository(
    database: database,
    clock: clock,
    timeZones: IanaCalendarEventTimeZones(displayTimeZoneId: 'Etc/UTC'),
    reminderRepair: marker,
  );

  test('P29 saving an Event commits the repair intent in its own transaction', () async {
    final events = buildEvents();
    await events.saveEvent(
      profileId: profileId,
      draft: CalendarEventDraft(
        id: const UuidIdentifierSource().nextUuid(),
        title: 'Standup',
        timing: CalendarEventTiming.timed,
        startDate: PlannerDate(year: 2026, month: 9, day: 14),
        startMinute: 9 * 60,
        endMinute: 10 * 60,
        timeZoneId: 'Etc/UTC',
        requiresReport: false,
      ),
    );

    final row = await readMarker();
    expect(row, isNotNull);
    expect(row!.category, BackgroundWorkCategory.reminderRecovery);
    expect(row.ownerKind, BackgroundWorkOwnerKind.profile);
    expect(row.profileId, profileId);
    expect(await markerCount(), 1);
  });

  test('P29 a rolled-back Event save leaves no durable repair intent', () async {
    final events = buildEvents();
    await expectLater(
      database.transaction(() async {
        await events.saveEvent(
          profileId: profileId,
          draft: CalendarEventDraft(
            id: const UuidIdentifierSource().nextUuid(),
            title: 'Standup',
            timing: CalendarEventTiming.timed,
            startDate: PlannerDate(year: 2026, month: 9, day: 14),
            startMinute: 9 * 60,
            endMinute: 10 * 60,
            timeZoneId: 'Etc/UTC',
            requiresReport: false,
          ),
        );
        throw StateError('abort');
      }),
      throwsA(isA<StateError>()),
    );

    expect(
      await readMarker(),
      isNull,
      reason: 'the marker is part of the mutation it accompanies',
    );
    expect(
      await database.select(database.calendarEvents).get(),
      isEmpty,
      reason: 'the Event itself also rolled back',
    );
  });

  test('P33 a settings save that does NOT change the reminder default marks nothing', () async {
    final types = DriftEventTypeRepository(
      database: database,
      clock: clock,
      reminderRepair: marker,
    );
    final current = await types.readPlannerSettings(profileId: profileId);
    expect(
      await readMarker(),
      isNull,
      reason: 'precondition: reading settings is not a mutation',
    );

    // A save that carries the SAME reminder default forward (for example a
    // display toggle) creates no new reminder need.
    await types.savePlannerSettings(
      profileId: profileId,
      settings: current.copyWith(defaultReminderMinutes: current.defaultReminderMinutes),
    );

    expect(
      await readMarker(),
      isNull,
      reason: 'an unrelated settings save must not schedule a reconciliation',
    );
  });

  test('P33 changing the global reminder default DOES mark repair', () async {
    final types = DriftEventTypeRepository(
      database: database,
      clock: clock,
      reminderRepair: marker,
    );
    final current = await types.readPlannerSettings(profileId: profileId);
    final changed = current.defaultReminderMinutes == 30 ? 45 : 30;

    await types.savePlannerSettings(
      profileId: profileId,
      settings: current.copyWith(defaultReminderMinutes: changed),
    );

    final row = await readMarker();
    expect(row, isNotNull);
    expect(
      row!.profileId,
      profileId,
      reason: 'the inherited default governs this profile\'s reminders',
    );
  });
}
