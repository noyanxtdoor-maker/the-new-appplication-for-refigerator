import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/features/planner/domain/event_contact_channel.dart';
import 'package:rmplanner/features/planner/domain/event_type.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_day.dart';
import 'package:rmplanner/features/planner/domain/planner_display_geometry.dart';
import 'package:rmplanner/features/planner/presentation/widgets/planner_event_block_content.dart';
import 'package:rmplanner/features/planner/presentation/widgets/planner_event_block_layout_policy.dart';

void main() {
  const day = PlannerDate(year: 2026, month: 9, day: 22);

  PlannerCalendarItem event({
    EventContactChannel? channel,
    String? stableKey = SystemEventTypeKeys.contact,
    String? label = 'Contact',
    bool backup = false,
  }) => PlannerCalendarItem(
    id: 'event',
    eventId: 'event',
    title: 'Alex',
    date: day,
    timing: PlannerEventTiming.timed,
    state: PlannerEventState.scheduled,
    requiresReport: false,
    hasOutcomeReport: false,
    startLocal: DateTime(2026, 9, 22, 10),
    endLocal: DateTime(2026, 9, 22, 11),
    activityTypeStableKey: stableKey,
    activityTypeLabel: label,
    contactChannel: channel,
    isBackupAppointment: backup,
  );

  Future<void> pump(
    WidgetTester tester,
    PlannerCalendarItem value, {
    double width = 180,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: width,
            height: 56,
            child: PlannerEventBlockContentView(
              event: value,
              use24HourTime: true,
              displayStartMinute: 600,
              displayEndMinute: 660,
              awaitingReport: false,
              content: const PlannerEventBlockContent(
                density: Density.tall,
                titleMaxLines: 1,
                showTitle: true,
                showTime: true,
                showTimeInline: false,
                showRecurrence: false,
                showStatusIcons: false,
                showResizeHandle: false,
                showTimeOnly: false,
                visibleHeight: 56,
              ),
              titleKey: const Key('title'),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets(
    'all canonical values and legacy null render one title-adjacent marker',
    (tester) async {
      for (final channel in <EventContactChannel?>[
        null,
        ...EventContactChannel.values,
      ]) {
        await pump(tester, event(channel: channel));
        expect(
          find.byKey(const Key('planner-event-contact-type-icon')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('title')), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets('ordinary, backup and synthetic-like events render no marker', (
    tester,
  ) async {
    await pump(
      tester,
      event(
        channel: EventContactChannel.email,
        stableKey: SystemEventTypeKeys.other,
        label: 'Other',
      ),
    );
    expect(
      find.byKey(const Key('planner-event-contact-type-icon')),
      findsNothing,
    );
    await pump(tester, event(channel: EventContactChannel.email, backup: true));
    expect(
      find.byKey(const Key('planner-event-contact-type-icon')),
      findsNothing,
    );
  });

  testWidgets(
    'meaningful connection follows form eligibility and narrow cards do not overflow',
    (tester) async {
      await pump(
        tester,
        event(
          channel: EventContactChannel.text,
          stableKey: SystemEventTypeKeys.meaningfulConnection,
          label: 'Meaningful Connection',
        ),
        width: 34,
      );
      expect(
        find.byKey(const Key('planner-event-contact-type-icon')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  test('display geometry clone retains Contact Type facts', () {
    final original = event(channel: EventContactChannel.videoCall);
    final placement = PlannerDisplayGeometry.resolve(
      events: <PlannerCalendarItem>[original],
      hourHeight: 36,
      viewportHeight: 700,
      configuredHours: 24,
    ).single;
    expect(placement.event.activityTypeStableKey, SystemEventTypeKeys.contact);
    expect(placement.event.contactChannel, EventContactChannel.videoCall);
  });
}
