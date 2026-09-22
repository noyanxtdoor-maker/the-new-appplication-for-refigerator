import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rmplanner/features/planner/domain/calendar_event.dart';
import 'package:rmplanner/features/planner/presentation/widgets/planner_event_report_status.dart';
import 'package:rmplanner/features/planner/presentation/widgets/planner_report_status_icons.dart';

/// The four canonical report statuses in the locked app order:
/// Unreported, Did Not Attempt, Missed - Attempted, Completed.
const List<PlannerReportStatusKind> _canonicalKinds = <PlannerReportStatusKind>[
  PlannerReportStatusKind.unreported,
  PlannerReportStatusKind.didNotAttempt,
  PlannerReportStatusKind.missedAttempted,
  PlannerReportStatusKind.completed,
];

void main() {
  group('PlannerReportStatusIcon (authoritative icon sheet)', () {
    testWidgets(
      'every canonical status renders as an independent, semantic, vector '
      'icon at the requested size',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Row(
                children: <Widget>[
                  for (final kind in _canonicalKinds)
                    PlannerReportStatusIcon(
                      key: Key('icon-${kind.name}'),
                      kind: kind,
                      size: 22,
                    ),
                ],
              ),
            ),
          ),
        );

        for (final kind in _canonicalKinds) {
          final finder = find.byKey(Key('icon-${kind.name}'));
          expect(finder, findsOneWidget);
          // Vector geometry (CustomPaint), never a raster sheet or emoji.
          expect(
            find.descendant(of: finder, matching: find.byType(CustomPaint)),
            findsOneWidget,
          );
          expect(
            tester.getSize(finder),
            const Size(22, 22),
            reason: 'the icon must honor its explicit size',
          );
          // Every status carries its full semantic label.
          final semantics = tester.getSemantics(finder);
          expect(semantics.label, PlannerEventReportStatus.labelFor(kind));
        }
      },
    );

    testWidgets(
      'Contact events resolve the completed status to the same green-check '
      'completed kind, under the Contacted label',
      (tester) async {
        // OWNER LAW (2026-09-22), superseding the Delta 2 matrix: a Contact
        // Event's success state still resolves to the SAME canonical completed
        // KIND (the green check, unchanged), while its user-facing LABEL is now
        // 'Contacted'. The stored status remains `completedHappened` for both.
        final contactKind = PlannerEventReportStatus.kindForStatus(
          CalendarEventStatus.completedHappened,
          isContactEvent: true,
        );
        expect(contactKind, PlannerReportStatusKind.completed);
        expect(
          PlannerEventReportStatus.labelFor(contactKind, isContactEvent: true),
          'Contacted',
        );
        expect(
          PlannerEventReportStatus.labelFor(contactKind),
          'Completed',
          reason: 'an ordinary Event keeps the canonical Completed label',
        );
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: PlannerReportStatusIcon(
                key: Key('completed-contact-icon'),
                kind: PlannerReportStatusKind.completed,
              ),
            ),
          ),
        );
        expect(find.byKey(const Key('completed-contact-icon')), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(const Key('completed-contact-icon')),
            matching: find.byType(CustomPaint),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'canonical, selected, and unselected styles all render without layout '
      'exceptions',
      (tester) async {
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: Column(
                children: <Widget>[
                  PlannerReportStatusIcon(
                    kind: PlannerReportStatusKind.unreported,
                    style: PlannerReportStatusIconStyle.canonical,
                  ),
                  PlannerReportStatusIcon(
                    kind: PlannerReportStatusKind.didNotAttempt,
                    style: PlannerReportStatusIconStyle.canonical,
                  ),
                  PlannerReportStatusIcon(
                    kind: PlannerReportStatusKind.missedAttempted,
                    style: PlannerReportStatusIconStyle.selected,
                  ),
                  PlannerReportStatusIcon(
                    kind: PlannerReportStatusKind.completed,
                    style: PlannerReportStatusIconStyle.selected,
                  ),
                  PlannerReportStatusIcon(
                    kind: PlannerReportStatusKind.unreported,
                    style: PlannerReportStatusIconStyle.unselected,
                  ),
                  PlannerReportStatusIcon(
                    kind: PlannerReportStatusKind.completed,
                    style: PlannerReportStatusIconStyle.unselected,
                  ),
                ],
              ),
            ),
          ),
        );
        expect(find.byType(PlannerReportStatusIcon), findsNWidgets(6));
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'the Event-block badge delegates to the canonical icon component and '
      'keeps the status label',
      (tester) async {
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: PlannerEventStatusBadge(
                kind: PlannerReportStatusKind.completed,
              ),
            ),
          ),
        );
        expect(find.byType(PlannerEventStatusBadge), findsOneWidget);
        expect(find.byType(PlannerReportStatusIcon), findsOneWidget);
        final semantics = tester.getSemantics(
          find.byType(PlannerEventStatusBadge),
        );
        expect(semantics.label, 'Completed');
      },
    );
  });
}
