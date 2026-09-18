import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/notifications/domain/reminder_policy.dart';
import 'package:rmplanner/features/planner/application/calendar_event_providers.dart';
import 'package:rmplanner/features/planner/domain/calendar_event.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';

import '../../../support/test_dependencies.dart';

/// False-failure truthfulness regression (2026-09-18 Planner audit).
///
/// The canonical database commit is the truth boundary: once the Event row is
/// durable, post-commit auxiliary work (reminder reconciliation, Planner
/// refresh) must never rewrite the outcome to "not saved" / "not deleted".
/// These tests run against real Drift transaction boundaries; the reminder
/// horizon is the only double, via the production
/// [eventReminderHorizonOverrideProvider] seam.
void main() {
  group('save truth boundary', () {
    testWidgets(
      'post-commit reconcile failure still reports saved (never not-saved)',
      (tester) async {
        final harness = await _pumpTruthfulness(tester);
        final controller = harness.controller;
        harness.failReconcile = true;

        final result = await controller.saveEvent(
          _draft(id: _saveId, date: _start, title: 'Personal Study'),
          reminderMode: ReminderPolicyMode.inherit,
        );

        expect(result, CalendarEventSaveResult.savedAwaitingAuxiliary);
        expect(
          harness.controllerState,
          'Event saved, but its reminder needs attention.',
        );
        // Durable without any restart dance.
        expect(
          await controller.readEventDraft(_saveId),
          isNotNull,
        );
        expect(await _rowCount(harness.database, _saveId), 1);
      },
    );

    testWidgets('pre-commit validation failure stays not-saved with no row', (
      tester,
    ) async {
      final harness = await _pumpTruthfulness(tester);

      // A REAL forced pre-commit failure on the production validation path:
      // `saveEvent` opens with `_validateDraft`, which rejects an unknown IANA
      // time zone before the transaction. (A whitespace-only title does NOT
      // fail here — it is committed — so the pre-review version of this test
      // asserted an invented message and failed.)
      final result = await harness.controller.saveEvent(
        _draft(
          id: _invalidId,
          date: _start,
          title: 'Personal Study',
          timeZoneId: 'Not/AReal_Zone',
        ),
        reminderMode: ReminderPolicyMode.inherit,
      );

      expect(result, CalendarEventSaveResult.notSaved);
      expect(
        harness.controllerState,
        'Unknown IANA time zone: Not/AReal_Zone',
      );
      // Nothing is durable: not through the repository read-back, and not as a
      // raw row in the canonical Event table.
      expect(await harness.controller.readEventDraft(_invalidId), isNull);
      expect(await _rowCount(harness.database, _invalidId), 0);
    });

    testWidgets('success with inherit reminder returns saved', (tester) async {
      final harness = await _pumpTruthfulness(tester);

      final result = await harness.controller.saveEvent(
        _draft(id: _saveId, date: _start, title: 'Personal Study'),
        reminderMode: ReminderPolicyMode.inherit,
      );

      expect(result, CalendarEventSaveResult.saved);
      expect(harness.controllerState, isNull);
      expect(
        await harness.controller.readEventDraft(_saveId),
        isNotNull,
      );
    });

    testWidgets('same-draft retry after auxiliary failure keeps one row', (
      tester,
    ) async {
      final harness = await _pumpTruthfulness(tester);
      final draft = _draft(id: _saveId, date: _start, title: 'Lunch Prep');

      harness.failReconcile = true;
      expect(
        await harness.controller.saveEvent(
          draft,
          reminderMode: ReminderPolicyMode.inherit,
        ),
        CalendarEventSaveResult.savedAwaitingAuxiliary,
      );

      harness.failReconcile = false;
      expect(
        await harness.controller.saveEvent(
          draft,
          reminderMode: ReminderPolicyMode.inherit,
        ),
        CalendarEventSaveResult.saved,
      );
      expect(await _rowCount(harness.database, _saveId), 1);
    });

    testWidgets('committed event reads back as scheduled without restart', (
      tester,
    ) async {
      final harness = await _pumpTruthfulness(tester);
      harness.failReconcile = true;

      await harness.controller.saveEvent(
        _draft(id: _saveId, date: _start, title: 'Personal Study'),
        reminderMode: ReminderPolicyMode.inherit,
      );

      final occurrence = await harness.controller.readOccurrence(
        eventId: _saveId,
        originalDate: _start,
      );
      expect(occurrence, isNotNull);
      expect(occurrence!.status, CalendarEventStatus.scheduled);
    });

    testWidgets('distinct drafts share identical save semantics', (
      tester,
    ) async {
      final harness = await _pumpTruthfulness(tester);

      expect(
        await harness.controller.saveEvent(
          _draft(id: _saveId, date: _start, title: 'Personal Study'),
          reminderMode: ReminderPolicyMode.inherit,
        ),
        CalendarEventSaveResult.saved,
      );
      expect(
        await harness.controller.saveEvent(
          _draft(
            id: _otherId,
            date: _start.addDays(1),
            title: 'Ysa Mini Gathering',
          ),
          reminderMode: ReminderPolicyMode.inherit,
        ),
        CalendarEventSaveResult.saved,
      );
    });
  });

  group('delete truth boundary', () {
    testWidgets('cancel active occurrence reports deleted', (tester) async {
      final harness = await _pumpTruthfulness(tester);
      await harness.controller.saveEvent(
        _draft(id: _saveId, date: _start, title: 'Ysa Mini Gathering'),
      );

      final result = await harness.controller.cancelEvent(
        eventId: _saveId,
        originalDate: _start,
        scope: CalendarEventEditScope.occurrence,
        operationId: _operation(11),
      );

      expect(result, CalendarEventCancellationResult.deleted);
      expect(
        (await harness.controller.readOccurrence(
          eventId: _saveId,
          originalDate: _start,
        ))!
            .status,
        CalendarEventStatus.cancelled,
      );
    });

    testWidgets(
      'cancel with post-commit reconcile failure still reports deleted '
      '(never not-deleted)',
      (tester) async {
        final harness = await _pumpTruthfulness(tester);
        await harness.controller.saveEvent(
          _draft(id: _saveId, date: _start, title: 'Ysa Mini Gathering'),
        );
        harness.failReconcile = true;

        final result = await harness.controller.cancelEvent(
          eventId: _saveId,
          originalDate: _start,
          scope: CalendarEventEditScope.occurrence,
          operationId: _operation(12),
        );

        expect(result, isNot(CalendarEventCancellationResult.notDeleted));
        expect(result.closesDetail, isTrue);
        // Canonical state is cancelled despite the auxiliary failure.
        expect(
          (await harness.controller.readOccurrence(
            eventId: _saveId,
            originalDate: _start,
          ))!
              .status,
          CalendarEventStatus.cancelled,
        );
      },
    );

    testWidgets('cancel unknown event stays not-deleted', (tester) async {
      final harness = await _pumpTruthfulness(tester);

      final result = await harness.controller.cancelEvent(
        eventId: _missingId,
        originalDate: _start,
        scope: CalendarEventEditScope.occurrence,
        operationId: _operation(13),
      );

      expect(result, CalendarEventCancellationResult.notDeleted);
    });

    testWidgets('cancel with stable operation identity is idempotent', (
      tester,
    ) async {
      final harness = await _pumpTruthfulness(tester);
      await harness.controller.saveEvent(
        _draft(id: _saveId, date: _start, title: 'Ysa Mini Gathering'),
      );
      final operationId = _operation(14);

      final first = await harness.controller.cancelEvent(
        eventId: _saveId,
        originalDate: _start,
        scope: CalendarEventEditScope.occurrence,
        operationId: operationId,
      );
      final second = await harness.controller.cancelEvent(
        eventId: _saveId,
        originalDate: _start,
        scope: CalendarEventEditScope.occurrence,
        operationId: operationId,
      );

      expect(first.closesDetail, isTrue);
      expect(second.closesDetail, isTrue);
      expect(
        (await harness.controller.readOccurrence(
          eventId: _saveId,
          originalDate: _start,
        ))!
            .status,
        CalendarEventStatus.cancelled,
      );
      final operations =
          await (harness.database.select(
                harness.database.calendarEventOperations,
              )..where((table) => table.operationId.equals(operationId)))
              .get();
      expect(operations, hasLength(1));
    });
  });
}

const _start = PlannerDate(year: 2026, month: 9, day: 21);
const _saveId = '30000000-0000-4000-8000-000000000001';
const _otherId = '30000000-0000-4000-8000-000000000002';
const _invalidId = '30000000-0000-4000-8000-000000000003';
const _missingId = '30000000-0000-4000-8000-000000000009';

String _operation(int value) =>
    '40000000-0000-4000-8000-${value.toString().padLeft(12, '0')}';

CalendarEventDraft _draft({
  required String id,
  required PlannerDate date,
  required String title,
  String timeZoneId = 'Asia/Manila',
}) => CalendarEventDraft(
  id: id,
  title: title,
  timing: CalendarEventTiming.timed,
  startDate: date,
  startMinute: 14 * 60,
  endMinute: 21 * 60,
  timeZoneId: timeZoneId,
  requiresReport: false,
);

Future<int> _rowCount(AppDatabase database, String eventId) async {
  final rows =
      await (database.select(
            database.calendarEvents,
          )..where((table) => table.id.equals(eventId)))
          .get();
  return rows.length;
}

final class _TruthfulnessHarness {
  // Positional initializing formals: a private named parameter is not legal in
  // Dart, and the analyzer's prefer_initializing_formals lint is correct here.
  const _TruthfulnessHarness(
    this.controller,
    this.database,
    this.container,
    this._failReconcileSetter,
    this._stateReader,
  );

  final CalendarEventController controller;
  final AppDatabase database;
  final ProviderContainer container;
  final void Function(bool value) _failReconcileSetter;
  final String? Function() _stateReader;

  set failReconcile(bool value) => _failReconcileSetter(value);

  String? get controllerState => _stateReader();
}

Future<_TruthfulnessHarness> _pumpTruthfulness(WidgetTester tester) async {
  final database = openMemoryDatabase();
  addTearDown(database.close);
  final privacy = TestPrivacyDependencies(database: database);
  final startup = buildTestRepository(
    database: database,
    privacyGate: privacy.gate,
  );
  await startup.completeOnboarding();
  var failReconcile = false;
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
          if (failReconcile) {
            throw StateError('reminder reconcile unavailable');
          }
        }),
      ],
    ),
  );
  await tester.pumpAndSettle();
  final container = ProviderScope.containerOf(
    tester.element(find.byType(MaterialApp).first),
  );
  return _TruthfulnessHarness(
    container.read(calendarEventControllerProvider.notifier),
    database,
    container,
    (value) => failReconcile = value,
    () => container.read(calendarEventControllerProvider),
  );
}
