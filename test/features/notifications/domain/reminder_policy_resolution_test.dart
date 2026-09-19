import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/features/notifications/domain/reminder_policy.dart';

/// OWNER HOTFIX (2026-09-19) — the reminder resolution law.
///
/// The Event form used to read the occurrence key ALONE, while the scheduler
/// resolved occurrence-then-series. A reminder stored at series scope (what the
/// create path and an "All events" edit write) was therefore invisible to the form,
/// which rendered the global default instead of the user's own offset, and the next
/// save wrote an occurrence `inherit` row that shadowed the real override.
///
/// Both callers now share [ReminderPolicyResolution.resolveForOccurrence], so the
/// form can never display a different policy than the one that will actually fire.
void main() {
  ReminderPolicy policy({
    required String occurrenceId,
    required ReminderPolicyMode mode,
    int? offsetMinutes,
  }) => ReminderPolicy(
    id: 'policy-$occurrenceId',
    profileId: 'profile-1',
    sourceKind: ReminderSourceKind.calendarEvent,
    sourceId: 'event-1',
    occurrenceId: occurrenceId,
    mode: mode,
    offsetMinutes: offsetMinutes,
    createdAtUtc: DateTime.utc(2026, 9, 19),
    updatedAtUtc: DateTime.utc(2026, 9, 19),
  );

  group('reminder policy resolution', () {
    test('a series-only override is visible to an occurrence lookup', () {
      final policies = <ReminderPolicy>[
        policy(
          occurrenceId: ReminderPolicy.seriesOccurrenceId,
          mode: ReminderPolicyMode.offset,
          offsetMinutes: 4,
        ),
      ];

      final resolved = policies.resolveForOccurrence('event-1:2026-09-19');

      expect(resolved, isNotNull);
      expect(resolved!.mode, ReminderPolicyMode.offset);
      expect(
        resolved.offsetMinutes,
        4,
        reason: 'the user-set 4-minute override must survive the form lookup',
      );
    });

    test("an occurrence's own row outranks the series row", () {
      final policies = <ReminderPolicy>[
        policy(
          occurrenceId: ReminderPolicy.seriesOccurrenceId,
          mode: ReminderPolicyMode.offset,
          offsetMinutes: 4,
        ),
        policy(
          occurrenceId: 'event-1:2026-09-19',
          mode: ReminderPolicyMode.offset,
          offsetMinutes: 30,
        ),
      ];

      final resolved = policies.resolveForOccurrence('event-1:2026-09-19');

      expect(resolved!.offsetMinutes, 30);
      expect(resolved.occurrenceId, 'event-1:2026-09-19');
    });

    test('an unrelated occurrence still inherits the series row', () {
      final policies = <ReminderPolicy>[
        policy(
          occurrenceId: 'event-1:2026-09-19',
          mode: ReminderPolicyMode.offset,
          offsetMinutes: 30,
        ),
        policy(
          occurrenceId: ReminderPolicy.seriesOccurrenceId,
          mode: ReminderPolicyMode.offset,
          offsetMinutes: 4,
        ),
      ];

      final resolved = policies.resolveForOccurrence('event-1:2026-09-20');

      expect(
        resolved!.offsetMinutes,
        4,
        reason: 'a different occurrence must not read the sibling override',
      );
    });

    test('off at series scope resolves to off for an occurrence', () {
      final policies = <ReminderPolicy>[
        policy(
          occurrenceId: ReminderPolicy.seriesOccurrenceId,
          mode: ReminderPolicyMode.off,
        ),
      ];

      expect(
        policies.resolveForOccurrence('event-1:2026-09-19')!.mode,
        ReminderPolicyMode.off,
      );
    });

    test('no policy resolves to null, so the global default governs', () {
      expect(
        const <ReminderPolicy>[].resolveForOccurrence('event-1:2026-09-19'),
        isNull,
      );
    });

    test('asking for the series occurrence returns the series row', () {
      final policies = <ReminderPolicy>[
        policy(
          occurrenceId: 'event-1:2026-09-19',
          mode: ReminderPolicyMode.offset,
          offsetMinutes: 30,
        ),
        policy(
          occurrenceId: ReminderPolicy.seriesOccurrenceId,
          mode: ReminderPolicyMode.offset,
          offsetMinutes: 4,
        ),
      ];

      expect(
        policies
            .resolveForOccurrence(ReminderPolicy.seriesOccurrenceId)!
            .offsetMinutes,
        4,
      );
    });
  });
}
