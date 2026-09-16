import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/contacts/domain/contact.dart';
import 'package:rmplanner/features/contacts/presentation/contact_filter_controls.dart';
import 'package:rmplanner/features/contacts/presentation/notes_editor.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';

import '../../support/test_dependencies.dart';
import '../../support/view_size.dart';

/// PRE-BETA RESPONSIVE (2026-09-16) — compact-height SURFACE reachability.
///
/// The destination sweep (`compact_height_test.dart`) proves the root surfaces
/// fill a 393 dp tall window. This file proves the *overlay* surfaces do: the
/// sheets, editors, and contextual-create forms a user reaches from those
/// roots. Overlays are where a compact height breaks first, because they are
/// commonly built as an unbounded `Column` inside a bottom sheet.
///
/// Only surfaces whose test FAILS may be corrected, and only with bounded
/// height / scroll / inset accommodation (AG-4). A passing surface is left
/// alone.
void main() {
  const PlannerDate monday = PlannerDate(year: 2026, month: 7, day: 27);

  /// A synthetic Group. Fixtures are never owner data.
  ContactGroup buildGroup(int index) => ContactGroup(
    id: 'grp-$index',
    profileId: 'p1',
    name: 'Group $index',
    colorValue: 0xFF175A8F,
    isArchived: false,
    sortOrder: index,
    createdAtUtc: DateTime.utc(2026, 7, 1),
    updatedAtUtc: DateTime.utc(2026, 7, 1),
  );

  Future<void> pumpShell(
    WidgetTester tester,
    Size size, {
    double textScale = 1.0,
  }) async {
    if (textScale != 1.0) {
      tester.platformDispatcher.textScaleFactorTestValue = textScale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    }
    setLogicalViewSize(tester, size);
    final database = openMemoryDatabase();
    addTearDown(database.close);
    final startup = buildTestRepository(database: database);
    await startup.completeOnboarding();
    final privacy = TestPrivacyDependencies(database: database);
    await tester.pumpWidget(
      privacy.buildApp(
        environment: const AppEnvironment(
          name: AppEnvironmentName.production,
          label: 'PRODUCTION',
        ),
        diagnostics: SanitizedDiagnostics(),
        startupRepository: startup,
        plannerDateSource: const FixedPlannerDateSource(monday),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Planner must NEVER be settled with `pumpAndSettle`: it schedules a
  /// recurring minute ticker by design (frozen M6 law), so a settle waits
  /// forever. Bounded pumps are the deterministic equivalent.
  Future<void> goToPlanner(WidgetTester tester) async {
    await tester.tap(navigationLabelFinder('Planner'));
    for (int i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> boundedPump(WidgetTester tester, {int frames = 30}) async {
    for (int i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  group('compact-height contact filter sheet', () {
    /// The sheet is built from a `Column` inside a `ConstrainedBox`, so it is
    /// the canonical compact-height risk shape. The longest option list
    /// (Groups) is used deliberately.
    Future<void> pumpSheet(WidgetTester tester, Size size, int options) async {
      setLogicalViewSize(tester, size);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  key: const Key('open-filter-sheet'),
                  onPressed: () => showContactFilterCategorySheet(
                    context: context,
                    category: ContactFilterCategory.groups,
                    criteria: const ContactFilterCriteria(),
                    groups: <ContactGroup>[
                      for (int i = 0; i < options; i++) buildGroup(i),
                    ],
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('open-filter-sheet')));
      await tester.pumpAndSettle();
    }

    for (final Size size in <Size>[
      TestWindowSizes.phoneLandscape,
      TestWindowSizes.compactHeightBoundary,
      TestWindowSizes.phonePortrait,
    ]) {
      testWidgets('renders 20 options without overflow at $size', (
        WidgetTester tester,
      ) async {
        await pumpSheet(tester, size, 20);
        expect(
          find.byKey(const Key('filter-sheet-groups')),
          findsOneWidget,
          reason: 'filter sheet must mount at $size',
        );
        expect(
          tester.takeException(),
          isNull,
          reason: 'filter sheet overflowed at $size',
        );
        // The master toggle and the first option must remain hit-testable.
        expect(
          find
              .byKey(const Key('filter-sheet-master-checkbox'))
              .hitTestable()
              .evaluate(),
          isNotEmpty,
          reason: 'master toggle unreachable at $size',
        );
        expect(
          find
              .byKey(const Key('filter-sheet-option-groups-grp-0'))
              .hitTestable()
              .evaluate(),
          isNotEmpty,
          reason: 'first option unreachable at $size',
        );
      });
    }
  });

  group('compact-height notes editor', () {
    Future<void> pumpNotes(WidgetTester tester, Size size) async {
      setLogicalViewSize(tester, size);
      await tester.pumpWidget(
        MaterialApp(
          home: NotesEditor(
            initialNotes: <ContactNote>[
              for (int i = 0; i < 6; i++)
                ContactNote(
                  id: 'note-$i',
                  contactId: 'c1',
                  noteText: 'Synthetic note $i',
                  createdAtUtc: DateTime.utc(2026, 7, 1),
                  updatedAtUtc: DateTime.utc(2026, 7, 1),
                ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('add + save reachable at a 393 dp tall window', (
      WidgetTester tester,
    ) async {
      await pumpNotes(tester, TestWindowSizes.phoneLandscape);
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const Key('notes-editor-add')).hitTestable().evaluate(),
        isNotEmpty,
        reason: 'Add Note must stay reachable on a short window',
      );
      expect(
        find.byKey(const Key('notes-editor-save')).hitTestable().evaluate(),
        isNotEmpty,
        reason: 'Save must stay reachable on a short window',
      );
    });

    testWidgets('add + save reachable at 393 dp with textScale 1.5', (
      WidgetTester tester,
    ) async {
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await pumpNotes(tester, TestWindowSizes.phoneLandscape);
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const Key('notes-editor-save')).hitTestable().evaluate(),
        isNotEmpty,
        reason: 'Save must stay reachable at textScale 1.5',
      );
    });
  });

  group('compact-height planner event creation', () {
    /// `compact_height_test.dart` already covers the create overlay and the
    /// TASK creation screen on this window. The EVENT path and the shared
    /// event/task form screens are the remaining authorised candidates, so
    /// they are driven here -- bounded pumps only, because the Planner's
    /// frozen minute ticker defeats `pumpAndSettle`.
    testWidgets('the Event creation screen opens at compact height', (
      WidgetTester tester,
    ) async {
      await pumpShell(tester, TestWindowSizes.phoneLandscape);
      await goToPlanner(tester);
      await boundedPump(tester);

      await tester.tap(find.byKey(const Key('planner-create-button')));
      await boundedPump(tester);
      expect(
        find.byKey(const Key('create-calendar-event-action')),
        findsOneWidget,
        reason: 'the Event action must stay reachable on a short window',
      );

      await tester.tap(find.byKey(const Key('create-calendar-event-action')));
      await boundedPump(tester);
      expect(
        tester.takeException(),
        isNull,
        reason: 'the Event creation flow must not overflow at 874x393',
      );
      // The flow must still present a way forward rather than clipping its CTA.
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is TextButton ||
              widget is ElevatedButton ||
              widget is FilledButton,
        ),
        findsWidgets,
        reason: 'the Event creation flow must keep an actionable CTA',
      );
    });

    testWidgets('the Event creation screen opens at 800x479', (
      WidgetTester tester,
    ) async {
      await pumpShell(tester, TestWindowSizes.compactHeightBoundary);
      await goToPlanner(tester);
      await boundedPump(tester);
      await tester.tap(find.byKey(const Key('planner-create-button')));
      await boundedPump(tester);
      await tester.tap(find.byKey(const Key('create-calendar-event-action')));
      await boundedPump(tester);
      expect(tester.takeException(), isNull);
    });
  });
}
