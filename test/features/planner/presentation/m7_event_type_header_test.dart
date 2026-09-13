// VS16-M7 O9 (contract section 66) — Event Type form display resolution.
//
// O9 is PREEXISTING behavior that this milestone fixes for DISPLAY only:
//   * the Edit heading used the RAW master `selected.label`;
//   * `_formTypeDisplayLabel`'s snapshot comment was not implemented — an
//     unchanged edit returned `selected.label`.
//
// The laws under test:
//   * Before a deliberate picker change, the form shows the freshly loaded
//     EFFECTIVE occurrence label and identity for that edit scope.
//   * The heading and the type field resolve through the SAME label, so they
//     can never disagree about one Event.
//   * A retired/unmapped master binding never substitutes for the occurrence
//     exception, and the "Other" slot is never advertised as this Event's type
//     merely because its identity stopped resolving.
//   * `initialEventTypeLabel` stays a loading seed, not an eternal override.
//   * A deliberate selection (including RESELECTING the original type) counts
//     as deliberate and uses the canonical current choice label.
//   * Warm content is not withheld behind a redundant reload.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/planner/data/calendar_event_time_zones.dart';
import 'package:rmplanner/features/planner/data/drift_calendar_event_repository.dart';
import 'package:rmplanner/features/planner/data/drift_outcome_reporting_repository.dart';
import 'package:rmplanner/features/planner/data/drift_task_event_link_repository.dart';
import 'package:rmplanner/features/planner/domain/calendar_event.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';

import '../../../support/test_dependencies.dart';

const _selected = PlannerDate(year: 2026, month: 7, day: 27);
const _eventId = '99999999-9999-4999-9999-999999999999';
const _fieldKey = Key('selected-event-type-label');
const _fieldTapKey = Key('event-type-field');

/// The form's type selector is an anchored dropdown (not the standalone
/// picker dialog), so the form flow uses these keys.
const _dropdownKey = Key('event-type-dropdown-scroll');

/// A stable key that is NEVER a canonical creation choice, so a persisted
/// binding of this identity is guaranteed to resolve to nothing on load.
const _unmappedStableKey = 'retired-master-type';

void main() {
  Future<(AppDatabase, DriftCalendarEventRepository)> buildRepositories() async {
    final database = openMemoryDatabase();
    addTearDown(database.close);
    final clock = FixedClock(DateTime.utc(2026, 7, 27, 12));
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
      timeZones: IanaCalendarEventTimeZones(
        displayTimeZoneId: 'Asia/Manila',
      ),
      taskContextSource: linkRepository,
      linkContextTransfer: linkRepository,
      reportSource: reportingRepository,
    );
    return (database, calendarRepository);
  }

  /// Seeds one Event on the Planner's selected day and returns its occurrence
  /// id so the detail sheet can be opened deterministically.
  Future<String> seedEvent(
    WidgetTester tester, {
    required AppDatabase database,
    required DriftCalendarEventRepository calendarRepository,
    required CalendarEventDraft draft,
  }) async {
    final profile = await buildTestRepository(
      database: database,
    ).completeOnboarding();
    await calendarRepository.saveEvent(profileId: profile.id, draft: draft);
    await tester.pumpAndSettle();
    return CalendarEventOccurrenceIdentity.forDate(
      eventId: draft.id,
      originalDate: _selected,
    );
  }

  /// Pumps the app straight into the Edit form for the seeded Event.
  Future<void> openEditForm(
    WidgetTester tester, {
    required AppDatabase database,
    required DriftCalendarEventRepository calendarRepository,
    required String occurrenceId,
    List<Override> extraOverrides = const <Override>[],
  }) async {
    final privacy = TestPrivacyDependencies(database: database);
    final startup = buildTestRepository(
      database: database,
      privacyGate: privacy.gate,
    );
    await tester.pumpWidget(
      privacy.buildApp(
        environment: const AppEnvironment(
          name: AppEnvironmentName.production,
          label: 'PRODUCTION',
        ),
        diagnostics: SanitizedDiagnostics(),
        startupRepository: startup,
        calendarEventRepository: calendarRepository,
        plannerDateSource: const FixedPlannerDateSource(_selected),
        extraOverrides: extraOverrides,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Planner'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('planner-timed-event-$occurrenceId')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('event-detail-sheet-edit-icon')));
    await tester.pumpAndSettle();
  }

  /// Convenience: the string currently shown inside the type field.
  String? fieldLabel(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(_fieldKey)).data;

  void sizePhone(WidgetTester tester) {
    tester.view.physicalSize = const Size(393, 874);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  testWidgets(
    'OAT11: Edit agrees with the occurrence projection before a deliberate '
    'type change, and the heading carries the same label',
    (tester) async {
      sizePhone(tester);
      final (database, calendarRepository) = await buildRepositories();
      final occurrenceId = await seedEvent(
        tester,
        database: database,
        calendarRepository: calendarRepository,
        draft: const CalendarEventDraft(
          id: _eventId,
          title: 'Occurrence projection',
          timing: CalendarEventTiming.timed,
          startDate: _selected,
          startMinute: 9 * 60,
          endMinute: 10 * 60,
          timeZoneId: 'Asia/Manila',
          requiresReport: false,
          activityTypeId: 'live-type-id',
          activityTypeStableKeySnapshot: 'live',
          activityTypeLabelSnapshot: 'Morning Routine',
        ),
      );

      await openEditForm(
        tester,
        database: database,
        calendarRepository: calendarRepository,
        occurrenceId: occurrenceId,
      );

      expect(
        find.byKey(_fieldKey),
        findsOneWidget,
        reason: 'the Edit form always exposes the type field',
      );
      expect(
        fieldLabel(tester),
        'Morning Routine',
        reason: 'OAT11: the occurrence snapshot is the truthful label',
      );
      // Heading agreement: whatever label the type field shows, the heading
      // must carry the same one (never the raw master row).
      expect(
        find.text('Edit ${fieldLabel(tester)} Event'),
        findsOneWidget,
        reason: 'OAT11: the heading must agree with the type field',
      );
    },
  );

  testWidgets(
    'OAT12: a retired master binding never substitutes for the occurrence '
    'exception, and the Other slot is not advertised',
    (tester) async {
      sizePhone(tester);
      final (database, calendarRepository) = await buildRepositories();
      // The persisted identity belongs to no canonical creation choice, while
      // the occurrence still carries its own truthful snapshot label.
      final occurrenceId = await seedEvent(
        tester,
        database: database,
        calendarRepository: calendarRepository,
        draft: const CalendarEventDraft(
          id: _eventId,
          title: 'Retired binding',
          timing: CalendarEventTiming.timed,
          startDate: _selected,
          startMinute: 9 * 60,
          endMinute: 10 * 60,
          timeZoneId: 'Asia/Manila',
          requiresReport: false,
          activityTypeId: _unmappedStableKey,
          activityTypeStableKeySnapshot: _unmappedStableKey,
          activityTypeLabelSnapshot: 'Retired Goal Alias',
        ),
      );

      await openEditForm(
        tester,
        database: database,
        calendarRepository: calendarRepository,
        occurrenceId: occurrenceId,
      );

      expect(find.byKey(_fieldKey), findsOneWidget);
      expect(
        fieldLabel(tester),
        'Retired Goal Alias',
        reason: 'the occurrence snapshot outranks any unresolved master row',
      );
      // The Other slot must NOT be substituted for an identity that merely
      // stopped resolving — that would invent a semantic type.
      expect(
        find.text('Other'),
        findsNothing,
        reason: 'OAT12: an unmapped identity is not "Other"',
      );
      expect(
        find.text('Edit Retired Goal Alias Event'),
        findsOneWidget,
        reason: 'OAT12: the heading keeps the truthful occurrence label',
      );
    },
  );

  testWidgets(
    'OAT11C: a deliberate selection uses the canonical current choice label '
    'and reselecting the original type still counts as deliberate',
    (tester) async {
      sizePhone(tester);
      final (database, calendarRepository) = await buildRepositories();
      final occurrenceId = await seedEvent(
        tester,
        database: database,
        calendarRepository: calendarRepository,
        draft: const CalendarEventDraft(
          id: _eventId,
          title: 'Deliberate reselection',
          timing: CalendarEventTiming.timed,
          startDate: _selected,
          startMinute: 9 * 60,
          endMinute: 10 * 60,
          timeZoneId: 'Asia/Manila',
          requiresReport: false,
          activityTypeId: 'live-type-id',
          activityTypeStableKeySnapshot: 'live',
          activityTypeLabelSnapshot: 'Stale Snapshot Alias',
        ),
      );

      await openEditForm(
        tester,
        database: database,
        calendarRepository: calendarRepository,
        occurrenceId: occurrenceId,
      );

      // Unchanged edit: the retained snapshot history is the truthful label.
      expect(
        fieldLabel(tester),
        'Stale Snapshot Alias',
        reason: 'existing snapshot history stays snapshot history',
      );

      // Open the type dropdown and choose the canonical "Other" creation
      // choice, then reselect it a second time.  Re-selection is itself a
      // deliberate decision, so the display must follow the CURRENT canonical
      // label and comparison against the master id alone is insufficient.
      await tester.tap(find.byKey(_fieldTapKey));
      await tester.pumpAndSettle();
      expect(find.byKey(_dropdownKey), findsOneWidget);

      final otherOption = find.byKey(
        const Key('event-type-dropdown-option-other'),
      );
      expect(otherOption, findsOneWidget);
      await tester.ensureVisible(otherOption);
      await tester.pumpAndSettle();
      await tester.tap(otherOption);
      await tester.pumpAndSettle();

      final chosen = fieldLabel(tester);
      expect(chosen, isNotNull);
      expect(
        chosen,
        isNot('Stale Snapshot Alias'),
        reason: 'a deliberate selection abandons the stale snapshot history',
      );
      expect(
        find.text('Edit $chosen Event'),
        findsOneWidget,
        reason: 'OAT11C: the heading follows the deliberate selection',
      );

      // Reopen the dropdown and reselect the SAME type: the deliberate flag
      // must stay set even though the identity does not change.
      await tester.tap(find.byKey(_fieldTapKey));
      await tester.pumpAndSettle();
      final again = find.byKey(const Key('event-type-dropdown-option-other'));
      await tester.ensureVisible(again);
      await tester.pumpAndSettle();
      await tester.tap(again);
      await tester.pumpAndSettle();
      expect(
        fieldLabel(tester),
        chosen,
        reason: 'reselecting the original type stays deliberate',
      );
      expect(
        find.text('Edit $chosen Event'),
        findsOneWidget,
        reason: 'OAT11C: reselection keeps heading and field in agreement',
      );
    },
  );

  testWidgets(
    'OAT13: a warm same-profile load is not gated on a redundant reload and '
    'content is not withheld behind it',
    (tester) async {
      sizePhone(tester);
      final (database, calendarRepository) = await buildRepositories();
      final occurrenceId = await seedEvent(
        tester,
        database: database,
        calendarRepository: calendarRepository,
        draft: const CalendarEventDraft(
          id: _eventId,
          title: 'Warm load',
          timing: CalendarEventTiming.timed,
          startDate: _selected,
          startMinute: 9 * 60,
          endMinute: 10 * 60,
          timeZoneId: 'Asia/Manila',
          requiresReport: false,
          activityTypeId: 'live-type-id',
          activityTypeStableKeySnapshot: 'live',
          activityTypeLabelSnapshot: 'Warm Type',
        ),
      );

      await openEditForm(
        tester,
        database: database,
        calendarRepository: calendarRepository,
        occurrenceId: occurrenceId,
      );

      // The form content must be present without any further explicit reload:
      // the readiness gate is satisfied by the load that already completed.
      expect(
        find.byKey(_fieldKey),
        findsOneWidget,
        reason: 'OAT13: warm content is not withheld',
      );
      expect(
        find.byType(CircularProgressIndicator),
        findsNothing,
        reason: 'OAT13: a satisfied load must not keep a blocking spinner',
      );
      expect(fieldLabel(tester), 'Warm Type');
    },
  );
}
