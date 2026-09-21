// P1 owner-review correction A (2026-09-21) — Quick edit is standard Planner
// behavior, not a setting.
//
// Owner decision: the "Quick edit on timeline" toggle was removed from Planner
// settings while long-press move, edge-drag resize, commit-on-release and Undo
// were KEPT. Direct manipulation must therefore be independent of any stored
// preference: a legacy persisted `false` must not strand quick edit disabled
// now that no control can turn it back on.
//
// These tests prove BOTH halves:
//   * the effective normalization law at the repository/domain boundary
//     (legacy false reads as effective true, raw column preserved, converges on
//     the next ordinary save, no migration); and
//   * the capability itself on the real widget tree — with a legacy stored
//     false, long-press still exposes the resize endpoint handles and a drag
//     still commits the new end minute to the database.

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/planner/data/calendar_event_time_zones.dart';
import 'package:rmplanner/features/planner/data/drift_calendar_event_repository.dart';
import 'package:rmplanner/features/planner/data/drift_event_type_repository.dart';
import 'package:rmplanner/features/planner/data/drift_outcome_reporting_repository.dart';
import 'package:rmplanner/features/planner/data/drift_planner_repository.dart';
import 'package:rmplanner/features/planner/data/drift_task_event_link_repository.dart';
import 'package:rmplanner/features/planner/domain/calendar_event.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_settings.dart';

import '../../../support/test_dependencies.dart';

void main() {
  const selected = PlannerDate(year: 2026, month: 7, day: 27);
  const displayTimeZoneId = 'Asia/Manila';
  const scheduledEventId = '11111111-1111-4111-8111-111111111111';

  CalendarEventDraft timedDraft({
    required String id,
    required String title,
    required int startMinute,
    required int endMinute,
  }) {
    return CalendarEventDraft(
      id: id,
      title: title,
      timing: CalendarEventTiming.timed,
      startDate: selected,
      startMinute: startMinute,
      endMinute: endMinute,
      timeZoneId: displayTimeZoneId,
      requiresReport: false,
    );
  }

  String occurrenceIdFor(String eventId) {
    return CalendarEventOccurrenceIdentity.forDate(
      eventId: eventId,
      originalDate: selected,
    );
  }

  DriftEventTypeRepository eventTypeRepository(AppDatabase database) {
    return DriftEventTypeRepository(
      database: database,
      clock: FixedClock(DateTime.utc(2026, 9, 21, 12)),
    );
  }

  Future<(DriftPlannerRepository, DriftCalendarEventRepository)>
  buildRepositories(AppDatabase database) async {
    final timeZones = IanaCalendarEventTimeZones(
      displayTimeZoneId: displayTimeZoneId,
    );
    final linkRepository = DriftTaskEventLinkRepository(
      database: database,
      clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
    );
    final outcomeReportingRepository = DriftOutcomeReportingRepository(
      database: database,
      clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
    );
    final calendarRepository = DriftCalendarEventRepository(
      database: database,
      clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
      timeZones: timeZones,
      taskContextSource: linkRepository,
      linkContextTransfer: linkRepository,
      reportSource: outcomeReportingRepository,
    );
    final plannerRepository = DriftPlannerRepository(
      database: database,
      clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
      calendarSource: calendarRepository,
      taskContextSource: linkRepository,
      historicalEffectReader: outcomeReportingRepository,
    );
    return (plannerRepository, calendarRepository);
  }

  Future<void> writeLegacyQuickEditRow(
    AppDatabase database,
    String profileId, {
    required bool enabled,
  }) {
    return (database.update(
      database.plannerPreferences,
    )..where((table) => table.profileId.equals(profileId))).write(
      PlannerPreferencesCompanion(quickEditEnabled: Value<bool>(enabled)),
    );
  }

  Future<PlannerPreferenceRow> readRawPreferences(
    AppDatabase database,
    String profileId,
  ) {
    return (database.select(
      database.plannerPreferences,
    )..where((table) => table.profileId.equals(profileId))).getSingle();
  }

  group('Quick edit is standard behavior, not a stored preference', () {
    late AppDatabase database;
    late String profileId;

    setUp(() async {
      database = openMemoryDatabase();
      profileId = (await buildTestRepository(
        database: database,
      ).completeOnboarding()).id;
      await seedLegacyCanonicalGoals(database, profileId);
    });

    tearDown(() => database.close());

    test('a legacy stored false reads as effective true', () async {
      final repository = eventTypeRepository(database);
      await repository.savePlannerSettings(
        profileId: profileId,
        settings: const PlannerSettings.defaults(),
      );
      await writeLegacyQuickEditRow(database, profileId, enabled: false);

      // The raw column keeps the legacy value...
      expect(
        (await readRawPreferences(database, profileId)).quickEditEnabled,
        isFalse,
      );

      // ...but the app never consumes it, so direct manipulation stays on.
      final restored = await repository.readPlannerSettings(
        profileId: profileId,
      );
      expect(restored.quickEditEnabled, isTrue);
      expect(restored.effectiveQuickEditEnabled, isTrue);
    });

    test(
      'an ordinary settings save converges the legacy column to true',
      () async {
        final repository = eventTypeRepository(database);
        await repository.savePlannerSettings(
          profileId: profileId,
          settings: const PlannerSettings.defaults(),
        );
        await writeLegacyQuickEditRow(database, profileId, enabled: false);

        // A save carrying the stale false still persists the EFFECTIVE value, so
        // the legacy value converges without a migration or a schema change.
        await repository.savePlannerSettings(
          profileId: profileId,
          settings: (await repository.readPlannerSettings(
            profileId: profileId,
          )).copyWith(quickEditEnabled: false),
        );

        expect(
          (await readRawPreferences(database, profileId)).quickEditEnabled,
          isTrue,
        );
      },
    );
  });

  testWidgets('direct manipulation still works when a legacy false is stored', (
    tester,
  ) async {
    final database = openMemoryDatabase();
    addTearDown(database.close);
    final privacy = TestPrivacyDependencies(database: database);
    final startup = buildTestRepository(
      database: database,
      privacyGate: privacy.gate,
    );
    final profile = await startup.completeOnboarding();
    final (plannerRepository, calendarRepository) = await buildRepositories(
      database,
    );
    await calendarRepository.saveEvent(
      profileId: profile.id,
      draft: timedDraft(
        id: scheduledEventId,
        title: 'Legacy False Quick Edit',
        startMinute: 9 * 60,
        endMinute: 10 * 60,
      ),
    );
    // A settings row exists, then the legacy value is forced to false.
    await eventTypeRepository(database).savePlannerSettings(
      profileId: profile.id,
      settings: const PlannerSettings.defaults(),
    );
    await writeLegacyQuickEditRow(database, profile.id, enabled: false);

    final identifiers = SequenceIdentifierSource(<String>[
      'a1111111-1111-4111-8111-111111111111',
    ]);

    await tester.pumpWidget(
      privacy.buildApp(
        environment: const AppEnvironment(
          name: AppEnvironmentName.production,
          label: 'PRODUCTION',
        ),
        diagnostics: SanitizedDiagnostics(),
        startupRepository: startup,
        plannerRepository: plannerRepository,
        plannerDateSource: const FixedPlannerDateSource(selected),
        plannerIdentifierSource: identifiers,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Planner'));
    await tester.pumpAndSettle();

    final occurrenceId = occurrenceIdFor(scheduledEventId);
    final block = find.byKey(Key('planner-timed-event-$occurrenceId'));
    final endHit = find.byKey(Key('planner-resize-hit-$occurrenceId'));
    expect(endHit, findsNothing, reason: 'no handles before selection');

    await tester.ensureVisible(block);
    await tester.pumpAndSettle();

    // Long-press selects the Event. The endpoint handles only render when
    // direct manipulation is effectively enabled, so their presence is the
    // proof that the legacy stored false did not disable quick edit.
    await tester.longPress(block);
    await tester.pumpAndSettle();
    expect(
      endHit,
      findsOneWidget,
      reason: 'a legacy stored false must not disable direct manipulation',
    );

    // Drag the END handle down 60 px (one hour at the 60 px/hour default).
    final hitCenter = tester.getCenter(endHit);
    final gesture = await tester.startGesture(hitCenter);
    await tester.pump(const Duration(milliseconds: 20));
    await gesture.moveBy(const Offset(0, 24));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 36));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    // Commit-on-release persists the resize on the canonical master row.
    final events = await database.select(database.calendarEvents).get();
    expect(events, hasLength(1));
    expect(events.single.id, scheduledEventId);
    expect(events.single.startMinute, 9 * 60);
    expect(events.single.endMinute, 11 * 60);
    expect(
      await database.select(database.calendarEventOperations).get(),
      hasLength(1),
    );
    expect(identifiers.nextUuid, throwsStateError);
  });
}
