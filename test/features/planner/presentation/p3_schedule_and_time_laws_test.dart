// P3 (2026-09-22) — SCHEDULE / RESCHEDULE FROM PLANNER, SET TIME TO NOW / UNDO,
// MINUTE PRECISION, OVERNIGHT DURATION AND DATE-ONLY CONVERSION.
//
// The owner approved three time laws for this pack:
//
//   * MINUTE precision, exactly as the rest of Event scheduling.
//   * OVERNIGHT duration is preserved even across midnight (23:30 + 90 min ends
//     at 01:00 the NEXT day) — never clipped, shortened, split or faked to
//     11:59 PM.
//   * DATE-ONLY `Set Time to Now` becomes a timed Event using the canonical
//     default Event duration, and Undo restores the date-only state exactly.
//
// The graphical scheduling session is DRAFT-ONLY: the Event form stays open
// beneath it, the Planner receives the draft schedule, and the ordinary form
// Save remains the sole persistence boundary.  These tests prove that no row is
// written by a session, by `Set Time to Now`, or by Undo.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/planner/application/planner_schedule_session_provider.dart';
import 'package:rmplanner/features/planner/data/calendar_event_time_zones.dart';
import 'package:rmplanner/features/planner/data/drift_calendar_event_repository.dart';
import 'package:rmplanner/features/planner/data/drift_event_type_repository.dart';
import 'package:rmplanner/features/planner/data/drift_outcome_reporting_repository.dart';
import 'package:rmplanner/features/planner/data/drift_planner_repository.dart';
import 'package:rmplanner/features/planner/data/drift_task_event_link_repository.dart';
import 'package:rmplanner/features/planner/domain/calendar_event.dart';
import 'package:rmplanner/features/planner/domain/event_type.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_day.dart';
import 'package:rmplanner/features/planner/domain/planner_schedule_session.dart';
import 'package:rmplanner/features/planner/domain/planner_timeline_layout.dart';
import 'package:rmplanner/features/planner/presentation/calendar_event_form_screen.dart';
import 'package:rmplanner/features/planner/presentation/planner_schedule_session_screen.dart';

import '../../../support/test_dependencies.dart';

const String _eventId = 'bbbbbbbb-3333-4333-8333-333333333301';
final PlannerDate _today = PlannerDate.fromDateTime(DateTime.now());

typedef _Repos = ({
  AppDatabase database,
  DriftPlannerRepository planner,
  DriftCalendarEventRepository calendar,
  DriftEventTypeRepository eventTypes,
  String profileId,
});

Future<_Repos> _buildRepositories() async {
  final database = openMemoryDatabase();
  addTearDown(database.close);
  final clock = FixedClock(DateTime.utc(2026, 7, 27, 12));
  // Etc/UTC on both sides keeps the wall-clock assertions exact.
  final timeZones = IanaCalendarEventTimeZones(displayTimeZoneId: 'Etc/UTC');
  final linkRepository = DriftTaskEventLinkRepository(
    database: database,
    clock: clock,
  );
  final reportingRepository = DriftOutcomeReportingRepository(
    database: database,
    clock: clock,
  );
  final calendarRepository = DriftCalendarEventRepository(
    database: database,
    clock: clock,
    timeZones: timeZones,
    taskContextSource: linkRepository,
    linkContextTransfer: linkRepository,
    reportSource: reportingRepository,
  );
  final plannerRepository = DriftPlannerRepository(
    database: database,
    clock: clock,
    calendarSource: calendarRepository,
    taskContextSource: linkRepository,
    historicalEffectReader: reportingRepository,
  );
  final eventTypes = DriftEventTypeRepository(database: database, clock: clock);
  final profile = await buildTestRepository(
    database: database,
  ).completeOnboarding();
  await eventTypes.readEventTypes(profileId: profile.id);
  return (
    database: database,
    planner: plannerRepository,
    calendar: calendarRepository,
    eventTypes: eventTypes,
    profileId: profile.id,
  );
}

/// A plainly-scheduled, non-slot Event Type, so a create fixture never needs a
/// Goal occupant and never trips the Contact-report rules.
Future<EventType> _plainEventType(_Repos repos) async {
  final types = await repos.eventTypes.readEventTypes(
    profileId: repos.profileId,
  );
  return types.firstWhere(
    (type) =>
        !type.isLockedWliType &&
        type.stableKey != SystemEventTypeKeys.contact &&
        !type.reportRequiredDefault,
    orElse: () => types.first,
  );
}

CalendarEventDraft _timedDraft({
  required String id,
  required PlannerDate date,
  required int startMinute,
  required int endMinute,
  String title = 'Cross-midnight block',
}) {
  return CalendarEventDraft(
    id: id,
    title: title,
    timing: CalendarEventTiming.timed,
    startDate: date,
    startMinute: startMinute,
    endMinute: endMinute,
    timeZoneId: 'Etc/UTC',
    requiresReport: false,
  );
}

CalendarEventDraft _allDayDraft({
  required String id,
  required PlannerDate date,
}) {
  return CalendarEventDraft(
    id: id,
    title: 'Date-only block',
    timing: CalendarEventTiming.allDay,
    startDate: date,
    requiresReport: false,
  );
}

PlannerCalendarItem _item({
  required String id,
  required PlannerDate date,
  String? eventId,
}) {
  final midnight = DateTime(date.year, date.month, date.day);
  return PlannerCalendarItem(
    id: id,
    title: id,
    date: date,
    timing: PlannerEventTiming.timed,
    state: PlannerEventState.scheduled,
    requiresReport: false,
    hasOutcomeReport: false,
    startLocal: midnight.add(const Duration(hours: 9)),
    endLocal: midnight.add(const Duration(hours: 10)),
    eventId: eventId,
    originalDate: eventId == null ? null : date,
  );
}

/// Pumps the real app, then pushes [builder] onto the navigator — the same
/// screens the product opens.
Future<void> _pushOnApp(
  WidgetTester tester, {
  required _Repos repos,
  required Widget Function() builder,
}) async {
  final privacy = TestPrivacyDependencies(database: repos.database);
  await tester.pumpWidget(
    privacy.buildApp(
      environment: const AppEnvironment(
        name: AppEnvironmentName.production,
        label: 'PRODUCTION',
      ),
      diagnostics: SanitizedDiagnostics(),
      startupRepository: buildTestRepository(
        database: repos.database,
        privacyGate: privacy.gate,
      ),
      plannerRepository: repos.planner,
      calendarEventRepository: repos.calendar,
      plannerDateSource: FixedPlannerDateSource(_today),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('Planner'));
  await tester.pumpAndSettle();
  final anchor = tester.element(
    find.byKey(const Key('planner-date-picker-trigger')),
  );
  // The push future completes when the route closes, which is the behaviour
  // under test, so it is intentionally not awaited.
  _unawaitedPush(
    Navigator.of(
      anchor,
    ).push(MaterialPageRoute<void>(builder: (_) => builder())),
  );
  await tester.pumpAndSettle();
}

void _unawaitedPush(Future<void> future) {}

Future<void> _openCreateForm(
  WidgetTester tester,
  _Repos repos,
  EventType type,
) {
  return _pushOnApp(
    tester,
    repos: repos,
    builder: () => CalendarEventFormScreen.create(
      initialDate: _today,
      initialEventType: type,
    ),
  );
}

Future<void> _openEditForm(
  WidgetTester tester,
  _Repos repos, {
  String eventId = _eventId,
  PlannerDate? originalDate,
}) {
  return _pushOnApp(
    tester,
    repos: repos,
    builder: () => CalendarEventFormScreen.edit(
      eventId: eventId,
      originalDate: originalDate ?? _today,
      scope: CalendarEventEditScope.series,
    ),
  );
}

/// The form's canonical Save control — the circular check button every real
/// save path uses.
Finder _formSaveButton() => find.byKey(const Key('save-event-button'));

Future<void> _tapSave(WidgetTester tester) async {
  await tester.ensureVisible(_formSaveButton());
  await tester.tap(_formSaveButton());
  await tester.pumpAndSettle();
}

Future<List<CalendarEventRow>> _eventRows(AppDatabase database) =>
    database.select(database.calendarEvents).get();

void main() {
  group('P3 minute law — a cross-midnight end keeps its next-day offset', () {
    test('90 minutes from 11:30 PM reports 1500, not 60', () {
      final start = DateTime(2026, 9, 22, 23, 30);
      final end = DateTime(2026, 9, 23, 1);
      expect(end.difference(start).inMinutes, 90);
      expect(plannerEndMinuteOfDay(start, end), 1500);
    });

    test('the single-day canvas still paints only up to 24:00', () {
      final start = DateTime(2026, 9, 22, 23, 30);
      final end = DateTime(2026, 9, 23, 1);
      expect(plannerRenderEndMinuteOfDay(start, end), 1440);
    });

    test('same-day and the accepted 24:00 boundary are byte-identical', () {
      expect(
        plannerEndMinuteOfDay(
          DateTime(2026, 9, 22, 9),
          DateTime(2026, 9, 22, 10),
        ),
        600,
      );
      expect(
        plannerEndMinuteOfDay(DateTime(2026, 9, 22, 23), DateTime(2026, 9, 23)),
        1440,
      );
      expect(
        plannerRenderEndMinuteOfDay(
          DateTime(2026, 9, 22, 23),
          DateTime(2026, 9, 23),
        ),
        1440,
      );
    });
  });

  group('P3 overnight persistence round trip', () {
    testWidgets('a 90-minute cross-midnight Event survives save and read', (
      tester,
    ) async {
      final repos = await _buildRepositories();
      await repos.calendar.saveEvent(
        profileId: repos.profileId,
        draft: _timedDraft(
          id: _eventId,
          date: _today,
          startMinute: 23 * 60 + 30,
          endMinute: 24 * 60 + 60,
        ),
      );
      final row = (await _eventRows(repos.database)).single;
      expect(row.startMinute, 1410);
      expect(row.endMinute, 1500);

      final occurrence = await repos.calendar.readOccurrence(
        profileId: repos.profileId,
        eventId: _eventId,
        originalDate: _today,
      );
      expect(occurrence, isNotNull);
      final start = occurrence!.startDisplay!;
      final end = occurrence.endDisplay!;
      expect(
        end.difference(start).inMinutes,
        90,
        reason: 'the duration must be preserved, never clipped or shortened',
      );
      expect(start, DateTime(_today.year, _today.month, _today.day, 23, 30));
      expect(end.day, start.day + 1);
      expect(end.hour, 1);

      // And the form loads it back as a NEXT-DAY end rather than a same-day one.
      expect(plannerEndMinuteOfDay(start, end), 1500);
    });
  });

  group('P3 scheduling session projection', () {
    test('no session leaves the day exactly as it was', () {
      final events = <PlannerCalendarItem>[
        _item(id: 'a', date: _today, eventId: 'saved-a'),
      ];
      expect(
        identical(
          applyPlannerScheduleSessionProjection(events, null, _today),
          events,
        ),
        isTrue,
      );
    });

    test(
      'a new-Event session paints one provisional block on its own date',
      () {
        const session = PlannerScheduleSession(
          id: 's1',
          date: PlannerDate(year: 2026, month: 9, day: 22),
          startMinute: 600,
          endMinute: 690,
          title: 'New block',
        );
        final today = PlannerDate.fromDateTime(DateTime(2026, 9, 22));
        final projected = applyPlannerScheduleSessionProjection(
          const <PlannerCalendarItem>[],
          session,
          today,
        );
        expect(projected, hasLength(1));
        expect(projected.single.id, session.itemId);
        expect(projected.single.eventId, isNull);
        expect(
          projected.single.endLocal!
              .difference(projected.single.startLocal!)
              .inMinutes,
          90,
        );
        // A different day draws nothing.
        expect(
          applyPlannerScheduleSessionProjection(
            const <PlannerCalendarItem>[],
            session,
            today.addDays(1),
          ),
          isEmpty,
        );
      },
    );

    test('a reschedule session hides the occurrence it stands in for', () {
      final session = PlannerScheduleSession(
        id: 's2',
        date: _today,
        startMinute: 600,
        endMinute: 660,
        title: 'Moved',
        suppressedEventId: 'saved-a',
        suppressedOriginalDate: _today,
      );
      final projected = applyPlannerScheduleSessionProjection(
        <PlannerCalendarItem>[
          _item(id: 'occurrence-a', date: _today, eventId: 'saved-a'),
          _item(id: 'other', date: _today, eventId: 'saved-b'),
        ],
        session,
        _today,
      );
      expect(
        projected.where((item) => item.eventId == 'saved-a'),
        isEmpty,
        reason: 'the same Event must never be painted twice',
      );
      expect(
        projected.where((item) => item.id == session.itemId),
        hasLength(1),
      );
      expect(
        projected.where((item) => item.eventId == 'saved-b'),
        hasLength(1),
        reason: 'unrelated Events are untouched',
      );
    });
  });

  group('P3 scheduling session is draft-only', () {
    test('move, resize and confirm never touch the database', () async {
      final repos = await _buildRepositories();
      await repos.calendar.saveEvent(
        profileId: repos.profileId,
        draft: _timedDraft(
          id: _eventId,
          date: _today,
          startMinute: 9 * 60,
          endMinute: 10 * 60,
        ),
      );
      final before = await _eventRows(repos.database);

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(
        plannerScheduleSessionProvider.notifier,
      );
      controller.begin(
        PlannerScheduleSession(
          id: 's3',
          date: _today,
          startMinute: 9 * 60,
          endMinute: 10 * 60,
          title: 'Draft',
          suppressedEventId: _eventId,
          suppressedOriginalDate: _today,
        ),
      );

      // A MOVE preserves the duration, and a RESIZE sets both edges.
      controller.updateSchedule(
        date: _today,
        startMinute: 14 * 60,
        endMinute: 14 * 60 + 60,
      );
      expect(container.read(plannerScheduleSessionProvider)!.startMinute, 840);
      expect(
        container.read(plannerScheduleSessionProvider)!.durationMinutes,
        60,
      );
      controller.updateSchedule(
        date: _today,
        startMinute: 14 * 60,
        endMinute: 16 * 60,
      );
      expect(container.read(plannerScheduleSessionProvider)!.endMinute, 960);

      final result = controller.confirm();
      expect(result, isNotNull);
      expect(result!.startMinute, 840);
      expect(result.endMinute, 960);
      expect(
        container.read(plannerScheduleSessionProvider),
        isNull,
        reason: 'Confirm ends the session',
      );

      final after = await _eventRows(repos.database);
      expect(
        after.single.startMinute,
        before.single.startMinute,
        reason: 'a session must never write the stored Event',
      );
      expect(after.single.endMinute, before.single.endMinute);
      expect(after.single.updatedAtUtc, before.single.updatedAtUtc);
    });

    test('a resize can never produce an interval shorter than 15 minutes', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(
        plannerScheduleSessionProvider.notifier,
      );
      controller.begin(
        PlannerScheduleSession(
          id: 's4',
          date: _today,
          startMinute: 600,
          endMinute: 660,
          title: 'Draft',
        ),
      );
      controller.updateSchedule(date: _today, startMinute: 600, endMinute: 601);
      expect(
        container.read(plannerScheduleSessionProvider)!.durationMinutes,
        15,
      );
    });

    test('clear discards the session and Confirm then returns nothing', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(
        plannerScheduleSessionProvider.notifier,
      );
      controller.begin(
        PlannerScheduleSession(
          id: 's5',
          date: _today,
          startMinute: 600,
          endMinute: 660,
          title: 'Draft',
        ),
      );
      controller.clear();
      expect(container.read(plannerScheduleSessionProvider), isNull);
      expect(controller.confirm(), isNull);
    });
  });

  group('P3 form time laws', () {
    testWidgets('Set Time to Now keeps the duration, offers Undo, writes on Save '
        'only', (tester) async {
      tester.view.physicalSize = const Size(862, 1900);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repos = await _buildRepositories();
      await _openCreateForm(tester, repos, await _plainEventType(repos));

      expect(await _eventRows(repos.database), isEmpty);
      expect(find.text('Set Time to Now'), findsOneWidget);

      await tester.ensureVisible(
        find.byKey(const Key('event-set-time-to-now')),
      );
      await tester.tap(find.byKey(const Key('event-set-time-to-now')));
      await tester.pumpAndSettle();

      // Undo replaces the action, and nothing has been written yet.
      expect(find.text('Undo'), findsOneWidget);
      expect(find.text('Set Time to Now'), findsNothing);
      expect(
        await _eventRows(repos.database),
        isEmpty,
        reason: 'Set Time to Now is a draft action',
      );

      await _tapSave(tester);

      final row = (await _eventRows(repos.database)).single;
      expect(row.timing, CalendarEventTiming.timed.name);
      expect(
        row.endMinute! - row.startMinute!,
        // The create form's own draft is 9:00-10:00, and `Set Time to Now`
        // preserves the DURATION the draft already had rather than imposing the
        // default one — that conversion belongs to the date-only path.
        60,
        reason: 'the current duration is preserved across Now',
      );
      final nowMinute = DateTime.now().hour * 60 + DateTime.now().minute;
      expect(
        (row.startMinute! - nowMinute).abs() <= 1,
        isTrue,
        reason: 'Now uses the current local minute',
      );
    });

    testWidgets('Undo restores the exact pre-Now schedule', (tester) async {
      tester.view.physicalSize = const Size(862, 1900);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repos = await _buildRepositories();
      await _openCreateForm(tester, repos, await _plainEventType(repos));

      await tester.ensureVisible(
        find.byKey(const Key('event-set-time-to-now')),
      );
      await tester.tap(find.byKey(const Key('event-set-time-to-now')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const Key('event-set-time-to-now')),
      );
      await tester.tap(find.byKey(const Key('event-set-time-to-now')));
      await tester.pumpAndSettle();

      expect(find.text('Set Time to Now'), findsOneWidget);
      await _tapSave(tester);

      final row = (await _eventRows(repos.database)).single;
      expect(
        row.startMinute,
        9 * 60,
        reason: 'Undo restores the 9:00 AM the draft held before Now',
      );
      expect(
        row.endMinute,
        10 * 60,
        reason: 'and its 10:00 AM end, so the original draft is exact',
      );
    });

    testWidgets('a date-only Event converts to timed with the default duration '
        'and Undo restores date-only', (tester) async {
      tester.view.physicalSize = const Size(862, 1900);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repos = await _buildRepositories();
      await repos.calendar.saveEvent(
        profileId: repos.profileId,
        draft: _allDayDraft(id: _eventId, date: _today),
      );
      await _openEditForm(tester, repos);

      // A date-only Event shows no clock tiles at all.
      expect(find.byKey(const Key('event-start-time')), findsNothing);

      await tester.ensureVisible(
        find.byKey(const Key('event-set-time-to-now')),
      );
      await tester.tap(find.byKey(const Key('event-set-time-to-now')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('event-start-time')),
        // The tile and its InkWell both carry the key.
        findsWidgets,
        reason: 'Now converts the draft to a timed Event',
      );
      expect(find.text('Undo'), findsOneWidget);
      expect(
        (await _eventRows(repos.database)).single.timing,
        CalendarEventTiming.allDay.name,
        reason: 'nothing is persisted before Save',
      );

      await _tapSave(tester);
      final configured = await repos.eventTypes.readPlannerSettings(
        profileId: repos.profileId,
      );
      final converted = (await _eventRows(repos.database)).single;
      expect(converted.timing, CalendarEventTiming.timed.name);
      expect(
        converted.endMinute! - converted.startMinute!,
        configured.defaultDurationMinutes,
        reason: 'the canonical default Event duration, not an invented one',
      );
    });

    testWidgets('Undo from a date-only conversion restores the date-only state '
        'exactly', (tester) async {
      tester.view.physicalSize = const Size(862, 1900);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repos = await _buildRepositories();
      await repos.calendar.saveEvent(
        profileId: repos.profileId,
        draft: _allDayDraft(id: _eventId, date: _today),
      );
      await _openEditForm(tester, repos);

      await tester.ensureVisible(
        find.byKey(const Key('event-set-time-to-now')),
      );
      await tester.tap(find.byKey(const Key('event-set-time-to-now')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('event-start-time')), findsWidgets);

      await tester.ensureVisible(
        find.byKey(const Key('event-set-time-to-now')),
      );
      await tester.tap(find.byKey(const Key('event-set-time-to-now')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('event-start-time')),
        findsNothing,
        reason: 'Undo restores the exact prior date-only state',
      );

      await _tapSave(tester);
      final restored = (await _eventRows(repos.database)).single;
      expect(restored.timing, CalendarEventTiming.allDay.name);
      expect(restored.startMinute, isNull);
      expect(restored.endMinute, isNull);
    });

    testWidgets('an overnight Event is displayed honestly on load', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(862, 1900);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repos = await _buildRepositories();
      await repos.calendar.saveEvent(
        profileId: repos.profileId,
        draft: _timedDraft(
          id: _eventId,
          date: _today,
          startMinute: 23 * 60 + 30,
          endMinute: 24 * 60 + 60,
        ),
      );
      await _openEditForm(tester, repos);

      expect(
        find.byKey(const Key('event-ends-next-day')),
        findsOneWidget,
        reason: '11:30 PM - 1:00 AM must say that it ends the next day',
      );
      expect(tester.takeException(), isNull);
    });

    // OWNER-REVIEW CORRECTION (2026-09-22): the Planner scheduling action is
    // for EDITING an existing Event, so the session laws below are proven on the
    // edit path. A brand-new Event is never offered it — the Planner's own
    // provisional-draft creation flow already owns new-Event scheduling, and
    // offering a second one was exactly the duplicate-block regression.
    testWidgets(
      'Schedule from Planner opens the session, and Confirm returns a '
      'draft-only schedule while Cancel leaves the draft alone',
      (tester) async {
        tester.view.physicalSize = const Size(862, 1900);
        tester.view.devicePixelRatio = 2;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final repos = await _buildRepositories();
        await repos.calendar.saveEvent(
          profileId: repos.profileId,
          draft: _timedDraft(
            id: _eventId,
            date: _today,
            startMinute: 9 * 60,
            endMinute: 10 * 60,
            title: 'Meeting',
          ),
        );
        await _openEditForm(tester, repos);

        // The owner renamed the edit action to `Schedule from Planner`, so the
        // form carries exactly ONE scheduling action link.
        expect(find.text('Schedule from Planner'), findsOneWidget);
        expect(
          find.byKey(const Key('event-schedule-from-planner')),
          findsOneWidget,
          reason: 'an existing Event has ONE scheduling action, never two',
        );

        await tester.ensureVisible(
          find.byKey(const Key('event-schedule-from-planner')),
        );
        await tester.tap(find.byKey(const Key('event-schedule-from-planner')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(PlannerScheduleSessionScreen.screenKey),
          findsOneWidget,
          reason: 'the session is hosted by the existing Planner timeline',
        );

        // Cancel: the session is discarded and the stored row is untouched.
        await tester.tap(find.byKey(PlannerScheduleSessionScreen.cancelKey));
        await tester.pumpAndSettle();
        final cancelled = await _eventRows(repos.database);
        expect(cancelled, hasLength(1));
        expect(cancelled.single.startMinute, 9 * 60);
        expect(cancelled.single.endMinute, 10 * 60);

        // Confirm: the form keeps the draft; persistence still needs Save.  The
        // confirmed schedule is what Save then stores, so a stale one-level Undo
        // can never override it.
        await tester.ensureVisible(
          find.byKey(const Key('event-schedule-from-planner')),
        );
        await tester.tap(find.byKey(const Key('event-schedule-from-planner')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(PlannerScheduleSessionScreen.confirmKey));
        await tester.pumpAndSettle();

        expect(
          find.byKey(PlannerScheduleSessionScreen.screenKey),
          findsNothing,
          reason: 'Confirm returns to the still-open form',
        );
        expect(
          await _eventRows(repos.database),
          hasLength(1),
          reason: 'Confirm is draft-only',
        );

        await _tapSave(tester);
        expect((await _eventRows(repos.database)), hasLength(1));
      },
    );
  });
}
