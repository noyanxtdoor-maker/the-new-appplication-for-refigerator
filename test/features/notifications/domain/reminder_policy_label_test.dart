import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/features/notifications/domain/reminder_policy_label.dart';

void main() {
  group('OAT3/OAT4 shared reminder offset formatter', () {
    test('OAT4 zero renders "At event time", never "0 minutes before"', () {
      expect(ReminderPolicyLabel.offsetMinutes(0), 'At event time');
      expect(
        ReminderPolicyLabel.offsetMinutes(0),
        isNot(contains('0 minutes')),
      );
    });

    test('OAT3 one minute is singular', () {
      expect(ReminderPolicyLabel.offsetMinutes(1), '1 minute before');
    });

    test('OAT4 two and larger supported offsets stay plural', () {
      expect(ReminderPolicyLabel.offsetMinutes(2), '2 minutes before');
      expect(ReminderPolicyLabel.offsetMinutes(5), '5 minutes before');
      expect(ReminderPolicyLabel.offsetMinutes(10), '10 minutes before');
      expect(ReminderPolicyLabel.offsetMinutes(15), '15 minutes before');
      expect(ReminderPolicyLabel.offsetMinutes(30), '30 minutes before');
      expect(ReminderPolicyLabel.offsetMinutes(45), '45 minutes before');
      expect(ReminderPolicyLabel.offsetMinutes(60), '60 minutes before');
    });

    test('Off sentinel and null never reach the numeric formatter', () {
      expect(
        () => ReminderPolicyLabel.offsetMinutes(-1),
        throwsArgumentError,
        reason: 'the Off sentinel is owned by the call site, not the formatter',
      );
    });

    test('inherited summary keeps the abbreviated "min before" suffix', () {
      expect(
        ReminderPolicyLabel.inheritedOffsetMinutes(0),
        'At event time',
      );
      expect(ReminderPolicyLabel.inheritedOffsetMinutes(1), '1 min before');
      expect(ReminderPolicyLabel.inheritedOffsetMinutes(15), '15 min before');
      expect(
        () => ReminderPolicyLabel.inheritedOffsetMinutes(-1),
        throwsArgumentError,
      );
    });

    test('Task wording preserves its existing zero label', () {
      expect(
        ReminderPolicyLabel.offsetMinutes(0, zeroLabel: 'At due time'),
        'At due time',
      );
      expect(
        ReminderPolicyLabel.offsetMinutes(1, zeroLabel: 'At due time'),
        '1 minute before',
      );
      expect(
        ReminderPolicyLabel.inheritedOffsetMinutes(0, zeroLabel: 'At due time'),
        'At due time',
      );
      expect(
        ReminderPolicyLabel.inheritedOffsetMinutes(15, zeroLabel: 'At due time'),
        '15 min before',
      );
    });
  });
}
