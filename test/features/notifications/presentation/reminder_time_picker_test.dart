import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/features/notifications/domain/reminder_policy.dart';
import 'package:rmplanner/features/notifications/presentation/reminder_time_picker.dart';

/// OWNER PASS 2026-09-19 — defect N3.
///
/// The picker used to return `int?`, where BOTH "Use default" and a plain
/// dismissal produced `null`.  Every caller therefore read "I opened the picker,
/// changed my mind and tapped outside" as "Use default", which silently rewrote
/// a deliberate custom offset back to the inherited default — and on the Event
/// form also authored an occurrence-level `inherit` row that shadowed the series
/// override.
///
/// These tests pin the four outcomes apart, at the picker AND at the single
/// call-site law both forms share.
void main() {
  group('one typed outcome per user intent', () {
    testWidgets('Use default is an explicit inherit, never a dismissal', (
      tester,
    ) async {
      await tester.pumpWidget(const MaterialApp(home: _Launcher()));
      await tester.tap(find.byKey(const Key('open-reminder-picker')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Use default'));
      await tester.pumpAndSettle();
      expect(_Launcher.last, isA<ReminderPickerUseDefault>());
    });

    testWidgets('Off is its own outcome', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: _Launcher()));
      await tester.tap(find.byKey(const Key('open-reminder-picker')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Off'));
      await tester.pumpAndSettle();
      expect(_Launcher.last, isA<ReminderPickerOff>());
    });

    testWidgets('a preset carries its minutes', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: _Launcher()));
      await tester.tap(find.byKey(const Key('open-reminder-picker')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('10 minutes before'));
      await tester.pumpAndSettle();
      expect(_Launcher.last, const ReminderPickerOffset(10));
    });

    testWidgets('Custom saves its exact minutes', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: _Launcher()));
      await tester.tap(find.byKey(const Key('open-reminder-picker')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Custom...'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '4');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(_Launcher.last, const ReminderPickerOffset(4));
    });

    testWidgets('tapping outside reports a DISMISSED outcome', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: _Launcher()));
      await tester.tap(find.byKey(const Key('open-reminder-picker')));
      await tester.pumpAndSettle();
      // Barrier tap, not a list item.
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(
        _Launcher.last,
        isA<ReminderPickerDismissed>(),
        reason: 'a barrier tap must never be reported as Use default',
      );
    });

    testWidgets('cancelling the Custom dialog is also a DISMISSAL', (
      tester,
    ) async {
      await tester.pumpWidget(const MaterialApp(home: _Launcher()));
      await tester.tap(find.byKey(const Key('open-reminder-picker')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Custom...'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(_Launcher.last, isA<ReminderPickerDismissed>());
    });
  });

  group('the shared call-site law', () {
    test('dismissal selects NOTHING, so the current value survives', () {
      expect(reminderSelectionIntent(const ReminderPickerDismissed()), isNull);
    });

    test('Use default selects inherit', () {
      expect(
        reminderSelectionIntent(const ReminderPickerUseDefault()),
        const ReminderSelectionIntent(ReminderPolicyMode.inherit),
      );
    });

    test('Off selects off', () {
      expect(
        reminderSelectionIntent(const ReminderPickerOff()),
        const ReminderSelectionIntent(ReminderPolicyMode.off),
      );
    });

    test('an offset selects its exact minutes', () {
      expect(
        reminderSelectionIntent(const ReminderPickerOffset(4)),
        const ReminderSelectionIntent(ReminderPolicyMode.offset, 4),
      );
    });

    testWidgets('repeated open -> dismiss stays lifecycle-safe', (
      tester,
    ) async {
      await tester.pumpWidget(const MaterialApp(home: _Launcher()));
      for (var cycle = 0; cycle < 3; cycle++) {
        await tester.tap(find.byKey(const Key('open-reminder-picker')));
        await tester.pumpAndSettle();
        await tester.tapAt(const Offset(10, 10));
        await tester.pumpAndSettle();
        expect(_Launcher.last, isA<ReminderPickerDismissed>());
      }
      expect(tester.takeException(), isNull);
      expect(find.byType(ErrorWidget), findsNothing);
    });

    testWidgets('Custom validation remains visible and retryable', (
      tester,
    ) async {
      await tester.pumpWidget(const MaterialApp(home: _Launcher()));
      await tester.tap(find.byKey(const Key('open-reminder-picker')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Custom...'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '10081');
      await tester.tap(find.text('Save'));
      await tester.pump();
      expect(find.text('Enter 0 to 10080 minutes.'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '27');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(_Launcher.last, const ReminderPickerOffset(27));
      expect(tester.takeException(), isNull);
    });
  });
}

final class _Launcher extends StatefulWidget {
  const _Launcher();

  static ReminderPickerResult? last;

  @override
  State<_Launcher> createState() => _LauncherState();
}

final class _LauncherState extends State<_Launcher> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: FilledButton(
          key: const Key('open-reminder-picker'),
          onPressed: () async {
            final result = await showReminderTimePicker(context);
            _Launcher.last = result;
          },
          child: const Text('Open reminder'),
        ),
      ),
    );
  }
}
