// P3 OWNER-REVIEW CORRECTIONS (2026-09-22).
//
// The owner physically reviewed the first P3 build and reported five real
// regressions. These laws fail against that build and pass against the
// correction:
//
//   1. `Schedule from Planner` / `Reschedule from Planner` could show the Event
//      TWICE — a saved (or creation-draft) block AND a session block.
//      => exactly ONE target draft block, ever.
//   2. The "+" FAB floated above the scheduling session, and empty timeline
//      space could still start a new Event.
//      => a session is adjustment-only: no FAB, no tap-to-create.
//   3. Moving/resizing the draft block raised the SAVED-event Undo card and then
//      "Event move could not be undone."
//      => a draft session never offers a saved-event Undo; Cancel is the
//      rollback.
//   4. The two direct schedule actions sat in a filled button row at the wrong
//      place.
//      => `Set Time to Now` between Date and Time, left-aligned, small plain
//      action links; `Reschedule from Planner` below the Time row, right-aligned.
//   5. A CONTACT Event's successful outcome read `Completed`.
//      => it reads `Contacted`; an ordinary Event still reads `Completed`; the
//      canonical stored status is unchanged.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/planner/application/calendar_event_creation_draft_provider.dart';
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
import 'package:rmplanner/features/planner/domain/planner_schedule_session.dart';
import 'package:rmplanner/features/planner/presentation/calendar_event_form_screen.dart';
import 'package:rmplanner/features/planner/presentation/planner_schedule_session_screen.dart';
import 'package:rmplanner/features/planner/presentation/widgets/event_current_status_controls.dart';
import 'package:rmplanner/features/planner/presentation/widgets/planner_event_report_status.dart';

import '../../../support/test_dependencies.dart';

const String _eventId = 'cccccccc-4444-4444-8444-444444444401';
final PlannerDate _today = PlannerDate.fromDateTime(DateTime.now());

/// The owner's exact target: a saved Meeting the user reschedules.
const int _meetingStart = 9 * 60;
const int _meetingEnd = 10 * 60;

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

Future<List<CalendarEventRow>> _eventRows(AppDatabase database) =>
    database.select(database.calendarEvents).get();

/// Saves the Meeting the owner reschedules, and returns its stored row.
Future<CalendarEventRow> _saveMeeting(_Repos repos) async {
  await repos.calendar.saveEvent(
    profileId: repos.profileId,
    draft: CalendarEventDraft(
      id: _eventId,
      title: 'Meeting',
      timing: CalendarEventTiming.timed,
      startDate: _today,
      startMinute: _meetingStart,
      endMinute: _meetingEnd,
      timeZoneId: 'Etc/UTC',
      requiresReport: false,
    ),
  );
  return (await _eventRows(repos.database)).single;
}

/// Pumps the real app, then pushes [builder] onto the navigator — the same
/// screens the product opens.
Future<void> _pushOnApp(
  WidgetTester tester, {
  required _Repos repos,
  required Widget Function() builder,
}) async {
  tester.view.physicalSize = const Size(862, 1900);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
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
  _unawaitedPush(
    Navigator.of(
      anchor,
    ).push(MaterialPageRoute<void>(builder: (_) => builder())),
  );
  await tester.pumpAndSettle();
}

void _unawaitedPush(Future<void> future) {}

Future<void> _openEditForm(WidgetTester tester, _Repos repos) {
  return _pushOnApp(
    tester,
    repos: repos,
    builder: () => CalendarEventFormScreen.edit(
      eventId: _eventId,
      originalDate: _today,
      scope: CalendarEventEditScope.series,
    ),
  );
}

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

Finder _actionFinder() => find.byKey(const Key('event-schedule-from-planner'));

/// Pumps the real app and stays on the Planner tab — the canonical screen, with
/// no form pushed over it.
Future<void> _pumpApp(WidgetTester tester, _Repos repos) async {
  tester.view.physicalSize = const Size(862, 1900);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
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
}

/// The app's own container — used to begin a session and a creation draft the
/// way the product's providers do.
ProviderContainer _appContainer(WidgetTester tester) =>
    ProviderScope.containerOf(
      tester.element(find.byKey(const Key('planner-date-picker-trigger'))),
      listen: false,
    );

/// Pushes the session host straight onto the app navigator.
Future<void> _pushSessionRoute(WidgetTester tester) async {
  final anchor = tester.element(
    find.byKey(const Key('planner-date-picker-trigger')),
  );
  _unawaitedPush(
    Navigator.of(anchor).push(
      MaterialPageRoute<PlannerScheduleResult>(
        builder: (_) => const PlannerScheduleSessionScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The form's canonical Save control — the circular check button every real
/// save path uses.
Finder _formSaveButton() => find.byKey(const Key('save-event-button'));

Future<void> _tapSave(WidgetTester tester) async {
  await tester.ensureVisible(_formSaveButton());
  await tester.tap(_formSaveButton());
  await tester.pumpAndSettle();
}

/// Opens the scheduling session from the still-open edit form.
Future<void> _openSession(WidgetTester tester) async {
  await tester.ensureVisible(_actionFinder());
  await tester.tap(_actionFinder());
  await tester.pumpAndSettle();
  expect(
    find.byKey(PlannerScheduleSessionScreen.screenKey),
    findsOneWidget,
    reason: 'the session is hosted by the canonical Planner',
  );
}

/// Anything inside the scheduling session's own screen.
Finder _inSession(Finder matching) => find.descendant(
  of: find.byKey(PlannerScheduleSessionScreen.screenKey),
  matching: matching,
);

/// The session's ONE draft block (a provisional surface, never a saved card).
Finder _sessionDraftBlocks() =>
    _inSession(find.byKey(const Key('planner-provisional-event-block')));

/// Any SAVED-style Event card inside the session. A reschedule must paint none:
/// the occurrence it stands in for is suppressed, so the Event is never doubled.
Finder _sessionSavedBlocks() => _inSession(
  find.byWidgetPredicate(
    (widget) =>
        widget.key is ValueKey<String> &&
        (widget.key! as ValueKey<String>).value.startsWith(
          'planner-timed-event-',
        ) &&
        !(widget.key! as ValueKey<String>).value.startsWith(
          'planner-timed-event-visible-',
        ),
  ),
);

/// EVERY Event block inside the session — the draft and any saved card. The
/// owner's regression was seeing this count at two, so the laws count it
/// directly rather than inferring from one kind of block.
Finder _sessionAllBlocks() => _inSession(
  find.byWidgetPredicate((widget) {
    final key = widget.key;
    if (key is! ValueKey<String>) {
      return false;
    }
    final value = key.value;
    return value == 'planner-provisional-event-block' ||
        (value.startsWith('planner-timed-event-') &&
            !value.startsWith('planner-timed-event-visible-'));
  }),
);

ProviderContainer _sessionContainer(WidgetTester tester) =>
    ProviderScope.containerOf(
      tester.element(find.byKey(PlannerScheduleSessionScreen.screenKey)),
      listen: false,
    );

PlannerScheduleSession? _session(WidgetTester tester) =>
    _sessionContainer(tester).read(plannerScheduleSessionProvider);

/// Drags the session's draft block by [delta] and returns its new start minute.
///
/// The block is scrolled into view first: the Planner focuses the current time,
/// so a 9 AM draft can sit outside the viewport and a drag aimed at its raw
/// centre would land on nothing. The move is ASSERTED here so a test can never
/// pass vacuously on a drag that did nothing.
Future<int> _dragDraftBlock(WidgetTester tester, Offset delta) async {
  final block = _sessionDraftBlocks();
  expect(block, findsOneWidget);
  await tester.ensureVisible(block);
  await tester.pumpAndSettle();
  final before = _session(tester)!.startMinute;
  final gesture = await tester.startGesture(tester.getCenter(block));
  await tester.pump(const Duration(milliseconds: 20));
  await gesture.moveBy(Offset(0, delta.dy / 2));
  await tester.pump();
  await gesture.moveBy(Offset(0, delta.dy / 2));
  await tester.pump();
  await gesture.up();
  for (var frame = 0; frame < 20; frame += 1) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  final after = _session(tester)!.startMinute;
  expect(
    after,
    isNot(before),
    reason: 'the session block must be draggable in adjustment mode',
  );
  return after;
}

void main() {
  group('owner correction — the scheduling action belongs to an existing Event', () {
    testWidgets('an existing Event offers Reschedule and never Schedule', (
      tester,
    ) async {
      final repos = await _buildRepositories();
      await _saveMeeting(repos);
      await _openEditForm(tester, repos);

      expect(find.text('Reschedule from Planner'), findsOneWidget);
      expect(
        find.text('Schedule from Planner'),
        findsNothing,
        reason: 'only an existing Event can be rescheduled',
      );
    });

    testWidgets('a brand-new Event is not offered the Planner action at all', (
      tester,
    ) async {
      final repos = await _buildRepositories();
      await _openCreateForm(tester, repos, await _plainEventType(repos));

      expect(
        _actionFinder(),
        findsNothing,
        reason:
            'the Planner provisional-draft creation flow already owns new-Event '
            'scheduling, so a second entry point is what produced the duplicate '
            'draft block',
      );
      expect(find.text('Schedule from Planner'), findsNothing);
    });
  });

  group('owner correction — exactly ONE target draft block', () {
    testWidgets(
      'reschedule mode suppresses the saved occurrence and paints one block',
      (tester) async {
        final repos = await _buildRepositories();
        await _saveMeeting(repos);
        await _openEditForm(tester, repos);
        await _openSession(tester);

        expect(
          _sessionSavedBlocks(),
          findsNothing,
          reason:
              'the saved Meeting must be suppressed while its draft stands in '
              'for it — never painted twice',
        );
        expect(
          _sessionDraftBlocks(),
          findsOneWidget,
          reason: 'exactly one target block',
        );
        expect(
          _sessionAllBlocks(),
          findsOneWidget,
          reason: 'ONE block total: never the saved occurrence beside a draft',
        );

        // And the session carries the saved schedule, not a fabricated one.
        expect(_session(tester)!.startMinute, _meetingStart);
        expect(_session(tester)!.endMinute, _meetingEnd);
      },
    );

    testWidgets('re-entering the scheduler still paints exactly one block', (
      tester,
    ) async {
      final repos = await _buildRepositories();
      await _saveMeeting(repos);
      await _openEditForm(tester, repos);

      await _openSession(tester);
      expect(_sessionDraftBlocks(), findsOneWidget);
      await tester.tap(find.byKey(PlannerScheduleSessionScreen.cancelKey));
      await tester.pumpAndSettle();

      // Cancel returns to the SAME form, draft untouched: the stored Meeting is
      // byte-identical (a draft session is not a transaction).
      expect(
        find.byKey(PlannerScheduleSessionScreen.screenKey),
        findsNothing,
        reason: 'Cancel closes the session and returns to the form',
      );
      final cancelled = await _eventRows(repos.database);
      expect(cancelled, hasLength(1));
      expect(cancelled.single.startMinute, _meetingStart);
      expect(cancelled.single.endMinute, _meetingEnd);

      await _openSession(tester);
      expect(
        _sessionDraftBlocks(),
        findsOneWidget,
        reason: 'no stale prior session and no second provisional block',
      );
      expect(_sessionSavedBlocks(), findsNothing);
      expect(
        _sessionAllBlocks(),
        findsOneWidget,
        reason: 're-entry still paints exactly one block',
      );
      expect(_session(tester)!.startMinute, _meetingStart);
    });
  });

  group('owner correction — a creation draft cannot double the target', () {
    testWidgets(
      'an unsaved creation draft is withheld while a session is active',
      (tester) async {
        final repos = await _buildRepositories();
        final type = await _plainEventType(repos);
        await _pumpApp(tester, repos);
        final container = _appContainer(tester);
        // The Planner's own provisional-draft creation flow, still live on its
        // date, plus the session that stands in for the same Event.
        container
            .read(plannerEventCreationDraftProvider.notifier)
            .begin(
              id: 'draft-1',
              date: _today,
              startMinute: 600,
              eventType: type,
            );
        container
            .read(plannerScheduleSessionProvider.notifier)
            .begin(
              PlannerScheduleSession(
                id: 'd1',
                date: _today,
                startMinute: _meetingStart,
                endMinute: _meetingEnd,
                title: 'Meeting',
              ),
            );
        await _pushSessionRoute(tester);

        expect(
          _sessionAllBlocks(),
          findsOneWidget,
          reason:
              'the session is the ONE representation of its Event — a creation '
              'draft must never paint a second block beside it',
        );
      },
    );
  });

  group('owner correction — a session is adjustment-only', () {
    testWidgets('no FAB, and empty timeline space cannot start a new Event', (
      tester,
    ) async {
      final repos = await _buildRepositories();
      await _saveMeeting(repos);
      await _openEditForm(tester, repos);
      await _openSession(tester);

      expect(
        find.byKey(const Key('planner-create-button')),
        findsNothing,
        reason: 'the owner saw the FAB floating above the session',
      );

      // Tap well below the 9-10 AM block: nothing may be created.
      final timeline = tester.getRect(
        find.byKey(const Key('timed-events-section')),
      );
      await tester.tapAt(Offset(timeline.left + 120, timeline.bottom - 24));
      await tester.pumpAndSettle();

      expect(
        find.byKey(PlannerScheduleSessionScreen.screenKey),
        findsOneWidget,
        reason: 'no creation route may replace the session',
      );
      expect(
        _sessionAllBlocks(),
        findsOneWidget,
        reason: 'empty-space tap must not start a second Event',
      );
    });

    testWidgets('dragging the draft never offers a saved-event Undo card', (
      tester,
    ) async {
      final repos = await _buildRepositories();
      final before = await _saveMeeting(repos);
      await _openEditForm(tester, repos);
      await _openSession(tester);

      await _dragDraftBlock(tester, const Offset(0, 72));

      expect(
        find.byKey(const Key('planner-move-undo-card')),
        findsNothing,
        reason: 'a draft session has no saved-event transaction to undo',
      );
      expect(
        find.text('Event move could not be undone.'),
        findsNothing,
        reason: 'Cancel is the session rollback, not an Undo token',
      );

      final after = await _eventRows(repos.database);
      expect(after, hasLength(1));
      expect(after.single.startMinute, before.startMinute);
      expect(after.single.endMinute, before.endMinute);
      expect(after.single.updatedAtUtc, before.updatedAtUtc);
    });
  });

  group('owner correction — Confirm and Cancel', () {
    testWidgets('Confirm returns the new schedule to the form only', (
      tester,
    ) async {
      final repos = await _buildRepositories();
      await _saveMeeting(repos);
      await _openEditForm(tester, repos);
      await _openSession(tester);

      final moved = await _dragDraftBlock(tester, const Offset(0, 72));
      expect(
        moved,
        isNot(_meetingStart),
        reason: 'the drag must actually move the session schedule',
      );

      await tester.tap(find.byKey(PlannerScheduleSessionScreen.confirmKey));
      await tester.pumpAndSettle();

      expect(
        find.byKey(PlannerScheduleSessionScreen.screenKey),
        findsNothing,
        reason: 'Confirm returns to the still-open Event form',
      );
      expect(
        (await _eventRows(repos.database)).single.startMinute,
        _meetingStart,
        reason: 'Confirm is draft-only: nothing is stored before form Save',
      );

      // The still-open form adopted the returned schedule, kept the rest of the
      // draft, and its Save is still the ONE persistence boundary: exactly one
      // row, with the moved start and the duration preserved.
      await _tapSave(tester);
      final saved = await _eventRows(repos.database);
      expect(saved, hasLength(1), reason: 'no duplicate Event');
      expect(saved.single.startMinute, moved);
      expect(saved.single.endMinute, moved + (_meetingEnd - _meetingStart));
    });
  });

  group('owner correction — action placement and typography', () {
    testWidgets(
      'Set Time to Now sits between Date and Time; Reschedule sits below Time',
      (tester) async {
        final repos = await _buildRepositories();
        await _saveMeeting(repos);
        await _openEditForm(tester, repos);

        final width =
            tester.view.physicalSize.width / tester.view.devicePixelRatio;
        // The scheduling tiles carry their key on both the tile and its InkWell,
        // so every geometry read targets the outermost match.
        final dateRect = tester.getRect(
          find.byKey(const Key('event-date-field')).first,
        );
        final nowRect = tester.getRect(
          find.byKey(const Key('event-set-time-to-now')).first,
        );
        final timeRect = tester.getRect(
          find.byKey(const Key('event-start-time')).first,
        );
        final rescheduleRect = tester.getRect(_actionFinder().first);

        expect(
          nowRect.top,
          greaterThan(dateRect.top),
          reason: 'Set Time to Now is below the Date field',
        );
        expect(
          nowRect.bottom,
          lessThanOrEqualTo(timeRect.top),
          reason: 'and above the Time row',
        );
        expect(
          tester
              .getCenter(find.byKey(const Key('event-set-time-to-now')).first)
              .dx,
          lessThan(width / 2),
          reason: 'left aligned',
        );
        expect(
          rescheduleRect.top,
          greaterThan(timeRect.bottom),
          reason: 'Reschedule from Planner sits below the Time row',
        );
        expect(
          tester.getCenter(_actionFinder().first).dx,
          greaterThan(width / 2),
          reason: 'right aligned',
        );
      },
    );

    testWidgets('both actions are plain text links, never filled buttons', (
      tester,
    ) async {
      final repos = await _buildRepositories();
      await _saveMeeting(repos);
      await _openEditForm(tester, repos);

      for (final finder in <Finder>[
        find.byKey(const Key('event-set-time-to-now')).first,
        _actionFinder().first,
      ]) {
        final button = tester.widget<TextButton>(finder);
        expect(
          button.style?.backgroundColor?.resolve(const <WidgetState>{}),
          isNull,
          reason: 'no filled surface behind the action link',
        );
        expect(
          button.style?.side?.resolve(const <WidgetState>{}),
          isNull,
          reason: 'and no pill outline',
        );
      }
    });
  });

  group('owner correction — a Contact Event reads Contacted', () {
    test('the canonical completed status is still `completedHappened`', () {
      expect(
        CalendarEventStatus.values.map((status) => status.name),
        isNot(contains('contacted')),
        reason: 'no new canonical status may be introduced',
      );
      expect(CalendarEventStatus.completedHappened.name, 'completedHappened');
    });

    test('the label mappers differ only by the Contact Event flag', () {
      expect(
        calendarEventStatusLabel(
          CalendarEventStatus.completedHappened,
          isContactEvent: true,
        ),
        'Contacted',
      );
      expect(
        calendarEventStatusLabel(CalendarEventStatus.completedHappened),
        'Completed',
      );
      expect(
        calendarEventOutcomeLabel(
          status: CalendarEventStatus.completedHappened,
          isContactEvent: true,
        ),
        'Contacted',
      );
      expect(
        calendarEventOutcomeLabel(
          status: CalendarEventStatus.completedHappened,
          isContactEvent: false,
        ),
        'Completed',
      );
      expect(
        PlannerEventReportStatus.labelFor(
          PlannerReportStatusKind.completed,
          isContactEvent: true,
        ),
        'Contacted',
      );
      expect(
        PlannerEventReportStatus.labelFor(PlannerReportStatusKind.completed),
        'Completed',
      );
    });

    testWidgets('the Event form Current Status row reads Contacted', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EventCurrentStatusControlRow(
              currentStatus: CalendarEventStatus.completedHappened,
              isContactEvent: true,
              saving: false,
              onSelect: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Text>(find.byKey(const Key('event-status-current-label')))
            .data,
        'Contacted',
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EventCurrentStatusControlRow(
              currentStatus: CalendarEventStatus.completedHappened,
              isContactEvent: false,
              saving: false,
              onSelect: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Text>(find.byKey(const Key('event-status-current-label')))
            .data,
        'Completed',
      );
    });
  });
}
