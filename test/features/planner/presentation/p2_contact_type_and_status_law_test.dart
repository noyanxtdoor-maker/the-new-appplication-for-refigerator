// P2 (owner decisions 2026-09-21) — Event contact channel + ordinary-edit
// Current Status + partial-save truth.
//
// P2-A: "Contact Type" is INDEPENDENT of Event Type. The form's own control
//       writes its own persisted value and never routes through the Event Type
//       picker; a legacy Event with no stored channel shows an honest unset
//       state; the Event Type picker keeps working.
// P2-B: ordinary edit exposes Current Status only under the owner's END-based
//       rule, and VISIBILITY is separated from SUBMISSION ARMING — opening,
//       viewing, or saving an eligible past Event submits nothing.
// P2-C: when the Event field write succeeds and report submission then fails,
//       the result is truthful, the Event edit stays persisted, and a retry is
//       safe with a fresh operationId.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/planner/application/outcome_reporting_providers.dart';
import 'package:rmplanner/features/planner/application/outcome_reporting_repository.dart';
import 'package:rmplanner/features/planner/data/calendar_event_time_zones.dart';
import 'package:rmplanner/features/planner/data/drift_calendar_event_repository.dart';
import 'package:rmplanner/features/planner/data/drift_event_type_repository.dart';
import 'package:rmplanner/features/planner/data/drift_outcome_reporting_repository.dart';
import 'package:rmplanner/features/planner/data/drift_planner_repository.dart';
import 'package:rmplanner/features/planner/data/drift_task_event_link_repository.dart';
import 'package:rmplanner/features/planner/domain/calendar_event.dart';
import 'package:rmplanner/features/planner/domain/event_contact_channel.dart';
import 'package:rmplanner/features/planner/domain/outcome_reporting.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/presentation/calendar_event_form_screen.dart';

import '../../../support/test_dependencies.dart';

const String _eventId = 'aaaaaaaa-1111-4111-8111-111111111101';

/// The instant the test suite reasons about. The form's ordinary-edit
/// eligibility deliberately measures against the real wall clock (matching the
/// file's existing `_isFutureOccurrence` convention), so the fixtures are
/// placed relative to today rather than to the fixed repository clock.
final PlannerDate _utcToday = PlannerDate.fromDateTime(DateTime.now().toUtc());
final PlannerDate _localToday = PlannerDate.fromDateTime(DateTime.now());

/// The REAL seeded system Contact type. A fixture must never invent an Event
/// Type identity: an unresolvable snapshot is re-resolved on save, which would
/// make an unrelated edit look like an Event Type change.
Future<({String id, String label})> _contactType(AppDatabase database) async {
  final row = await database
      .customSelect(
        "SELECT id, label FROM activity_types WHERE stable_key = 'contact' "
        'LIMIT 1',
      )
      .getSingle();
  return (id: row.read<String>('id'), label: row.read<String>('label'));
}

/// A Contact Event: the only surface where the owner's Contact Type control is
/// exposed, and a type that always requires a report.
CalendarEventDraft _contactDraft({
  required PlannerDate date,
  required ({String id, String label}) contactType,
  CalendarEventTiming timing = CalendarEventTiming.timed,
  int? startMinute,
  int? endMinute,
  // The canonical UTC identity this codebase's zone database recognises.
  String timeZoneId = 'Etc/UTC',
  EventContactChannel? channel,
}) {
  return CalendarEventDraft(
    id: _eventId,
    title: 'Call Maria',
    timing: timing,
    startDate: date,
    startMinute: timing == CalendarEventTiming.allDay ? null : startMinute,
    endMinute: timing == CalendarEventTiming.allDay ? null : endMinute,
    timeZoneId: timing == CalendarEventTiming.allDay ? null : timeZoneId,
    requiresReport: true,
    activityTypeId: contactType.id,
    activityTypeStableKeySnapshot: 'contact',
    activityTypeLabelSnapshot: contactType.label,
    contactChannel: channel,
  );
}

/// A reporting repository whose FIRST [submit] fails, so the Event-field-write
/// -then-report-submit order can be observed honestly. Everything else is a
/// straight delegate to the real canonical implementation.
final class _FailFirstSubmitReporting implements OutcomeReportingRepository {
  _FailFirstSubmitReporting(this._inner);

  final OutcomeReportingRepository _inner;
  int failuresRemaining = 1;
  int submitCalls = 0;
  final List<String> operationIds = <String>[];

  @override
  Future<ReportSubmissionResult> submit({
    required String profileId,
    required OutcomeReportDraft draft,
    required String operationId,
  }) {
    submitCalls++;
    operationIds.add(operationId);
    if (failuresRemaining > 0) {
      failuresRemaining--;
      throw StateError('synthetic report failure');
    }
    return _inner.submit(
      profileId: profileId,
      draft: draft,
      operationId: operationId,
    );
  }

  @override
  Future<OutcomeReportSource?> readTaskSource({
    required String profileId,
    required String taskId,
  }) => _inner.readTaskSource(profileId: profileId, taskId: taskId);

  @override
  Future<OutcomeReportSource?> readEventSource({
    required String profileId,
    required String eventId,
    required PlannerDate originalDate,
  }) => _inner.readEventSource(
    profileId: profileId,
    eventId: eventId,
    originalDate: originalDate,
  );

  @override
  Future<List<IndicatorOption>> readIndicatorOptions(String profileId) =>
      _inner.readIndicatorOptions(profileId);

  @override
  Future<OutcomeReport?> readDraftForSlot({
    required String profileId,
    required String sourceSlotKey,
  }) => _inner.readDraftForSlot(
    profileId: profileId,
    sourceSlotKey: sourceSlotKey,
  );

  @override
  Future<OutcomeReport?> readReport({
    required String profileId,
    required String reportId,
  }) => _inner.readReport(profileId: profileId, reportId: reportId);

  @override
  Future<List<OutcomeReport>> readReportHistory(String profileId) =>
      _inner.readReportHistory(profileId);

  @override
  Future<List<ActivityLedgerEntry>> readLedgerHistory({
    required String profileId,
    String? indicatorKey,
    PlannerDate? startDate,
    PlannerDate? endDate,
    bool effectiveOnly = true,
  }) => _inner.readLedgerHistory(
    profileId: profileId,
    indicatorKey: indicatorKey,
    startDate: startDate,
    endDate: endDate,
    effectiveOnly: effectiveOnly,
  );

  @override
  Future<OutcomeReport> saveDraft({
    required String profileId,
    required OutcomeReportDraft draft,
  }) => _inner.saveDraft(profileId: profileId, draft: draft);

  @override
  Future<bool> clearSubmittedStatus({
    required String profileId,
    required OutcomeReportSource source,
    required String operationId,
    required String correctionReason,
  }) => _inner.clearSubmittedStatus(
    profileId: profileId,
    source: source,
    operationId: operationId,
    correctionReason: correctionReason,
  );

  @override
  Future<IndicatorActual> readActual({
    required String profileId,
    required String indicatorKey,
    required PlannerDate startDate,
    required PlannerDate endDate,
  }) => _inner.readActual(
    profileId: profileId,
    indicatorKey: indicatorKey,
    startDate: startDate,
    endDate: endDate,
  );

  @override
  Future<List<IndicatorActual>> rebuildActuals({
    required String profileId,
    required PlannerDate startDate,
    required PlannerDate endDate,
  }) => _inner.rebuildActuals(
    profileId: profileId,
    startDate: startDate,
    endDate: endDate,
  );

  @override
  Future<LedgerProjectionAudit> auditProjection(String profileId) =>
      _inner.auditProjection(profileId);
}

typedef _Repos = ({
  AppDatabase database,
  DriftPlannerRepository planner,
  DriftCalendarEventRepository calendar,
  DriftOutcomeReportingRepository reporting,
  String profileId,
});

Future<_Repos> _buildRepositories() async {
  final database = openMemoryDatabase();
  addTearDown(database.close);
  final clock = FixedClock(DateTime.utc(2026, 7, 27, 12));
  final timeZones = IanaCalendarEventTimeZones(
    displayTimeZoneId: 'Asia/Manila',
  );
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
  final profile = await buildTestRepository(
    database: database,
  ).completeOnboarding();
  // Seed the canonical Event Type taxonomy the way the app does (lazily, on
  // first read) so the Contact Event Type is a REAL persisted identity rather
  // than an invented one.
  await DriftEventTypeRepository(
    database: database,
    clock: clock,
  ).readEventTypes(profileId: profile.id);
  return (
    database: database,
    planner: plannerRepository,
    calendar: calendarRepository,
    reporting: reportingRepository,
    profileId: profile.id,
  );
}

/// Pumps the real app so every provider the form needs exists, then pushes the
/// real Event edit form onto the navigator. This is the same screen the pencil
/// opens; pushing it directly keeps the test about the FORM's law rather than
/// about navigating the timeline.
Future<void> _openEditForm(
  WidgetTester tester, {
  required _Repos repos,
  required PlannerDate originalDate,
  List<Override> extraOverrides = const <Override>[],
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
      plannerDateSource: FixedPlannerDateSource(originalDate),
      extraOverrides: extraOverrides,
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('Planner'));
  await tester.pumpAndSettle();

  final anchor = tester.element(
    find.byKey(const Key('planner-date-picker-trigger')),
  );
  unawaitedPush(
    Navigator.of(anchor).push(
      MaterialPageRoute<void>(
        builder: (_) => CalendarEventFormScreen.edit(
          eventId: _eventId,
          originalDate: originalDate,
          scope: CalendarEventEditScope.series,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The push future is intentionally not awaited: the route completes when the
/// form closes, which is the behaviour under test.
void unawaitedPush(Future<void> future) {}

Future<CalendarEventRow> _storedRow(AppDatabase database, String eventId) =>
    (database.select(
      database.calendarEvents,
    )..where((table) => table.id.equals(eventId))).getSingle();

void _sizeView(WidgetTester tester) {
  tester.view.physicalSize = const Size(862, 1824);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  group('P2-A: Contact Type is independent of Event Type', () {
    testWidgets(
      'a Contact Event shows its own control, an honest unset state, and the '
      'Event Type field keeps its own identity and label',
      (tester) async {
        _sizeView(tester);
        final repos = await _buildRepositories();
        await repos.calendar.saveEvent(
          profileId: repos.profileId,
          draft: _contactDraft(
            contactType: await _contactType(repos.database),
            date: _utcToday.addDays(-3),
            startMinute: 9 * 60,
            endMinute: 10 * 60,
          ),
        );

        await _openEditForm(
          tester,
          repos: repos,
          originalDate: _utcToday.addDays(-3),
        );

        // The Event Type control is ALWAYS the Event Type, even for a Contact
        // Event — the old mis-wiring relabelled this very widget "Contact Type".
        expect(find.byKey(const Key('event-type-field')), findsOneWidget);
        expect(find.text('Event Type'), findsWidgets);

        // ...and Contact Type is its own separately persisted control.
        expect(find.byKey(const Key('contact-type-field')), findsOneWidget);
        expect(find.text('Contact Type'), findsOneWidget);
        expect(
          tester
              .widget<Text>(
                find.byKey(const Key('selected-contact-type-label')),
              )
              .data,
          'In Person',
          reason:
              'owner revision (2026-09-22): "Not set" was removed completely, '
              'so a legacy Event that never stored a channel presents as the '
              'standard default, In Person',
        );

        // The picker offers exactly the eight owner-fixed channels.
        await tester.tap(find.byKey(const Key('contact-type-field')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('contact-type-options')), findsOneWidget);
        for (final channel in EventContactChannel.values) {
          final option = find.byKey(
            Key('contact-type-option-${channel.stableKey}'),
          );
          expect(option, findsOneWidget, reason: channel.stableKey);
          expect(
            find.descendant(of: option, matching: find.text(channel.label)),
            findsOneWidget,
            reason: 'label ${channel.label} maps to ${channel.stableKey}',
          );
        }
        expect(
          tester
              .widget<ListView>(find.byKey(const Key('contact-type-options')))
              .childrenDelegate
              .estimatedChildCount,
          EventContactChannel.values.length,
        );
      },
    );

    testWidgets(
      'choosing a Contact Type persists it and never touches Event Type',
      (tester) async {
        _sizeView(tester);
        final repos = await _buildRepositories();
        final date = _utcToday.addDays(-3);
        await repos.calendar.saveEvent(
          profileId: repos.profileId,
          draft: _contactDraft(
            contactType: await _contactType(repos.database),
            date: date,
            startMinute: 9 * 60,
            endMinute: 10 * 60,
          ),
        );

        await _openEditForm(tester, repos: repos, originalDate: date);

        await tester.tap(find.byKey(const Key('contact-type-field')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('contact-type-option-whatsapp')));
        await tester.pumpAndSettle();

        // The form reflects the choice immediately...
        expect(
          tester
              .widget<Text>(
                find.byKey(const Key('selected-contact-type-label')),
              )
              .data,
          'WhatsApp',
        );
        // ...and the Event Type control is untouched by it.
        expect(find.byKey(const Key('event-type-field')), findsOneWidget);

        final save = find.byKey(const Key('save-event-button'));
        await tester.ensureVisible(save);
        await tester.tap(save);
        await tester.pumpAndSettle();

        final row = await _storedRow(repos.database, _eventId);
        expect(row.contactChannel, 'whatsapp');
        expect(
          row.activityTypeStableKeySnapshot,
          'contact',
          reason: 'choosing a Contact Type must not rewrite the Event Type',
        );
        expect(row.activityTypeLabelSnapshot, 'Contact');
      },
    );

    // The reverse direction — a deliberate EVENT TYPE change leaving the stored
    // Contact Type alone — is proven at the layer that owns the write, in
    // `event_contact_channel_persistence_test.dart` ("changing the Event Type
    // preserves the stored channel"). The form's own Event Type picker is a
    // full-screen transition with a non-settling entrance animation, so driving
    // it here would trade a deterministic claim for a timing artifact.
  });

  group('P2-B: ordinary edit Current Status uses the END-based rule', () {
    testWidgets('an ENDED timed Event exposes Current Status', (tester) async {
      _sizeView(tester);
      final repos = await _buildRepositories();
      final date = _utcToday.addDays(-3);
      await repos.calendar.saveEvent(
        profileId: repos.profileId,
        draft: _contactDraft(
          contactType: await _contactType(repos.database),
          date: date,
          startMinute: 9 * 60,
          endMinute: 10 * 60,
        ),
      );

      await _openEditForm(tester, repos: repos, originalDate: date);
      expect(
        find.byKey(const Key('calendar-event-form-scroll')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('event-status-section')), findsOneWidget);
      // Visibility is not a reporting session.
      expect(
        await repos.database.select(repos.database.outcomeReports).get(),
        isEmpty,
      );
    });

    testWidgets('an ONGOING timed Event exposes no Current Status', (
      tester,
    ) async {
      _sizeView(tester);
      final repos = await _buildRepositories();
      // Spans the whole current UTC day, so it is genuinely in progress
      // regardless of when the suite runs.
      await repos.calendar.saveEvent(
        profileId: repos.profileId,
        draft: _contactDraft(
          contactType: await _contactType(repos.database),
          date: _utcToday,
          startMinute: 0,
          endMinute: 1440,
        ),
      );

      await _openEditForm(tester, repos: repos, originalDate: _utcToday);
      expect(
        find.byKey(const Key('calendar-event-form-scroll')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('event-status-section')),
        findsNothing,
        reason: 'time passing never fabricates an outcome',
      );
    });

    testWidgets('a FUTURE timed Event exposes no Current Status', (
      tester,
    ) async {
      _sizeView(tester);
      final repos = await _buildRepositories();
      final date = _utcToday.addDays(3);
      await repos.calendar.saveEvent(
        profileId: repos.profileId,
        draft: _contactDraft(
          contactType: await _contactType(repos.database),
          date: date,
          startMinute: 9 * 60,
          endMinute: 10 * 60,
        ),
      );

      await _openEditForm(tester, repos: repos, originalDate: date);
      expect(
        find.byKey(const Key('calendar-event-form-scroll')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('event-status-section')), findsNothing);
    });

    testWidgets(
      'a PAST all-day Event exposes Current Status; today\'s does not',
      (tester) async {
        _sizeView(tester);
        final repos = await _buildRepositories();
        final pastDate = _localToday.addDays(-3);
        await repos.calendar.saveEvent(
          profileId: repos.profileId,
          draft: _contactDraft(
            contactType: await _contactType(repos.database),
            date: pastDate,
            timing: CalendarEventTiming.allDay,
          ),
        );

        await _openEditForm(tester, repos: repos, originalDate: pastDate);
        expect(
          find.byKey(const Key('calendar-event-form-scroll')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('event-status-section')),
          findsOneWidget,
          reason:
              'a date before today is END-based eligible for all-day Events',
        );

        // A second Event, dated today, is deliberately NOT eligible.
        const todayId = 'aaaaaaaa-1111-4111-8111-111111111102';
        await repos.calendar.saveEvent(
          profileId: repos.profileId,
          draft: CalendarEventDraft(
            id: todayId,
            title: 'Today all-day',
            timing: CalendarEventTiming.allDay,
            startDate: _localToday,
            requiresReport: true,
            activityTypeId: 'contact-type-id',
            activityTypeStableKeySnapshot: 'contact',
            activityTypeLabelSnapshot: 'Contact',
          ),
        );
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        final anchor = tester.element(
          find.byKey(const Key('planner-date-picker-trigger')),
        );
        unawaitedPush(
          Navigator.of(anchor).push(
            MaterialPageRoute<void>(
              builder: (_) => CalendarEventFormScreen.edit(
                eventId: todayId,
                originalDate: _localToday,
                scope: CalendarEventEditScope.series,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('calendar-event-form-scroll')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('event-status-section')),
          findsNothing,
          reason: 'an all-day Event dated today has not ended',
        );
      },
    );

    testWidgets(
      'opening and SAVING an eligible past Event without touching Current '
      'Status submits no report and overwrites no status',
      (tester) async {
        _sizeView(tester);
        final repos = await _buildRepositories();
        final date = _utcToday.addDays(-3);
        await repos.calendar.saveEvent(
          profileId: repos.profileId,
          draft: _contactDraft(
            contactType: await _contactType(repos.database),
            date: date,
            startMinute: 9 * 60,
            endMinute: 10 * 60,
          ),
        );

        await _openEditForm(tester, repos: repos, originalDate: date);
        expect(find.byKey(const Key('event-status-section')), findsOneWidget);

        // An ordinary, unrelated edit.
        await tester.enterText(
          find.byKey(const Key('event-title-field')),
          'Call Maria (renamed)',
        );
        await tester.pump();
        final save = find.byKey(const Key('save-event-button'));
        await tester.ensureVisible(save);
        await tester.tap(save);
        await tester.pumpAndSettle();

        final row = await _storedRow(repos.database, _eventId);
        expect(row.title, 'Call Maria (renamed)');
        expect(
          row.status,
          'scheduled',
          reason: 'merely rendering Current Status must not set status',
        );
        expect(
          await repos.database.select(repos.database.outcomeReports).get(),
          isEmpty,
          reason: 'an ordinary edit must not arm a report submission',
        );
        expect(
          await repos.database
              .select(repos.database.activityLedgerEntries)
              .get(),
          isEmpty,
        );
      },
    );

    testWidgets(
      'a DELIBERATE Current Status choice submits exactly one canonical report '
      'with the occurrence identity preserved',
      (tester) async {
        _sizeView(tester);
        final repos = await _buildRepositories();
        final date = _utcToday.addDays(-3);
        await repos.calendar.saveEvent(
          profileId: repos.profileId,
          draft: _contactDraft(
            contactType: await _contactType(repos.database),
            date: date,
            startMinute: 9 * 60,
            endMinute: 10 * 60,
          ),
        );

        await _openEditForm(tester, repos: repos, originalDate: date);
        final option = find.byKey(
          const Key('event-status-option-completedHappened'),
        );
        await tester.ensureVisible(option);
        await tester.tap(option);
        await tester.pumpAndSettle();

        final save = find.byKey(const Key('save-event-button'));
        await tester.ensureVisible(save);
        await tester.tap(save);
        await tester.pumpAndSettle();

        // The deliberate choice went through the canonical pipeline, ONCE.
        final reports = await repos.database
            .select(repos.database.outcomeReports)
            .get();
        expect(reports, hasLength(1));
        expect(reports.single.outcome, OutcomeKind.completedHappened.name);
        expect(
          reports.single.originalDate,
          date.iso8601,
          reason: 'the canonical occurrence identity must survive',
        );
        expect(
          reports.single.occurrenceId,
          CalendarEventOccurrenceIdentity.forDate(
            eventId: _eventId,
            originalDate: date,
          ),
        );
        expect(
          await repos.database
              .select(repos.database.activityLedgerEntries)
              .get(),
          isEmpty,
          reason:
              'this Event carries no Goal contribution rule, so the '
              'combined outcome report writes no factual Activity History '
              'row — the canonical engine invents nothing',
        );
      },
    );
  });

  group('P2-C: a failed report submission is truthful and retry is safe', () {
    testWidgets(
      'Event field write persists, the user is told the STATUS was not saved, '
      'nothing is recorded twice, and a retry commits one canonical report',
      (tester) async {
        _sizeView(tester);
        final repos = await _buildRepositories();
        final date = _utcToday.addDays(-3);
        await repos.calendar.saveEvent(
          profileId: repos.profileId,
          draft: _contactDraft(
            contactType: await _contactType(repos.database),
            date: date,
            startMinute: 9 * 60,
            endMinute: 10 * 60,
          ),
        );

        final reporting = _FailFirstSubmitReporting(repos.reporting);
        await _openEditForm(
          tester,
          repos: repos,
          originalDate: date,
          extraOverrides: <Override>[
            outcomeReportingRepositoryProvider.overrideWithValue(reporting),
          ],
        );

        await tester.enterText(
          find.byKey(const Key('event-title-field')),
          'Call Maria (edited before the report failed)',
        );
        await tester.pump();
        await tester.tap(
          find.byKey(const Key('event-status-option-completedHappened')),
        );
        await tester.pumpAndSettle();

        final save = find.byKey(const Key('save-event-button'));
        await tester.ensureVisible(save);
        await tester.tap(save);
        // Bounded pumps: a SnackBar is transient by design, and
        // `pumpAndSettle` would advance past its dismissal.
        await tester.pump();
        for (
          var attempt = 0;
          attempt < 12 &&
              find.textContaining('Status was not saved').evaluate().isEmpty;
          attempt++
        ) {
          await tester.pump(const Duration(milliseconds: 100));
        }

        // The failed submission is reported as a REPORT failure — the honest
        // description of what happened — and never as a blanket "the Save
        // failed", because the Event edit really did persist.
        expect(
          find.textContaining('Report was not submitted'),
          findsOneWidget,
          reason: 'the message must name what actually failed',
        );
        expect(find.textContaining('could not be saved'), findsNothing);
        expect(find.textContaining('Save failed'), findsNothing);
        expect(
          find.byKey(const Key('calendar-event-form-scroll')),
          findsOneWidget,
          reason: 'the form stays open so the retry is possible',
        );
        expect(reporting.submitCalls, 1);

        final row = await _storedRow(repos.database, _eventId);
        expect(row.title, 'Call Maria (edited before the report failed)');
        expect(
          await repos.database.select(repos.database.outcomeReports).get(),
          isEmpty,
        );
        expect(
          await repos.database
              .select(repos.database.activityLedgerEntries)
              .get(),
          isEmpty,
        );

        // Retry: the report commits, once. Wait for the form to close (the
        // success path pops) rather than assuming a fixed number of frames.
        await tester.tap(save);
        for (
          var attempt = 0;
          attempt < 40 &&
              find
                  .byKey(const Key('calendar-event-form-scroll'))
                  .evaluate()
                  .isNotEmpty;
          attempt++
        ) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('calendar-event-form-scroll')),
          findsNothing,
          reason: 'a successful retry closes the form',
        );
        expect(reporting.submitCalls, 2);
        expect(
          reporting.operationIds.toSet(),
          hasLength(2),
          reason: 'a retry must use a fresh operationId',
        );

        final reports = await repos.database
            .select(repos.database.outcomeReports)
            .get();
        expect(reports, hasLength(1));
        expect(reports.single.outcome, OutcomeKind.completedHappened.name);
        expect(
          reports.single.originalDate,
          date.iso8601,
          reason: 'the retry still targets the canonical occurrence',
        );
        expect(
          await repos.database
              .select(repos.database.activityLedgerEntries)
              .get(),
          isEmpty,
          reason:
              'a non-contributing Event records no factual ledger row, '
              'before or after a retry',
        );
        // The Event edit was persisted exactly once by the first save and is
        // not duplicated by the retry.
        expect(
          await repos.database.select(repos.database.calendarEvents).get(),
          hasLength(1),
        );
      },
    );
  });
}
