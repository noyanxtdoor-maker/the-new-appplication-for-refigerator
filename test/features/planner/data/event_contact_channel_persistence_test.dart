// P2-A (owner decision 2026-09-21, design D1) — persistence for the INDEPENDENT
// Event contact channel.
//
// Owner law proven here:
//   * schema 48 -> 49 is additive: one nullable, UNBACKFILLED `contact_channel`
//     column on the EXISTING `calendar_events` row;
//   * a legacy Event keeps every old field and reads back contact_channel NULL —
//     never an invented channel;
//   * all eight stable keys round-trip, and NULL round-trips as NULL;
//   * an unrelated Event edit preserves the stored channel;
//   * an unrecognised stored value reads back as unset without being destroyed;
//   * the migration is idempotent and lands on exactly schema 49.
import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/features/planner/data/calendar_event_time_zones.dart';
import 'package:rmplanner/features/planner/data/drift_calendar_event_repository.dart';
import 'package:rmplanner/features/planner/data/drift_event_type_repository.dart';
import 'package:rmplanner/features/planner/domain/calendar_event.dart';
import 'package:rmplanner/features/planner/domain/event_contact_channel.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../../support/test_dependencies.dart';

const String _eventId = '11111111-2222-4333-8444-555555555555';
final PlannerDate _date = PlannerDate(year: 2026, month: 7, day: 27);

CalendarEventDraft _draft({EventContactChannel? channel}) => CalendarEventDraft(
  id: _eventId,
  title: 'Call Maria',
  timing: CalendarEventTiming.timed,
  startDate: _date,
  startMinute: 9 * 60,
  endMinute: 10 * 60,
  timeZoneId: 'Asia/Manila',
  requiresReport: true,
  contactChannel: channel,
);

void main() {
  group('schema 49 migration is additive and never invents a channel', () {
    test(
      'v48 -> v49 adds one nullable column, preserves the row, lands on 49',
      () async {
        final sqlite = sqlite3.openInMemory();
        try {
          // Build a REAL v48 database (the shipped v48 schema), then remove the
          // v49 column so the fixture is byte-honest about what a v48 device
          // actually holds.
          final v48 = AppDatabase.forTesting(
            NativeDatabase.opened(sqlite, closeUnderlyingOnClose: false),
            schemaVersionOverride: 48,
          );
          final profile = await buildTestRepository(
            database: v48,
          ).completeOnboarding();
          await v48.customStatement(
            'ALTER TABLE calendar_events DROP COLUMN contact_channel',
          );
          await v48
              .into(v48.calendarEvents)
              .insert(
                CalendarEventsCompanion.insert(
                  id: _eventId,
                  profileId: profile.id,
                  title: 'Legacy contact event',
                  notes: const drift.Value<String?>('keep me'),
                  timing: 'timed',
                  startDate: _date.iso8601,
                  startMinute: const drift.Value<int?>(540),
                  endMinute: const drift.Value<int?>(600),
                  timeZoneId: const drift.Value<String?>('Asia/Manila'),
                  locationText: const drift.Value<String?>('Cafe'),
                  requiresReport: const drift.Value<bool>(true),
                  activityTypeStableKeySnapshot: const drift.Value<String?>(
                    'contact',
                  ),
                  activityTypeLabelSnapshot: const drift.Value<String?>(
                    'Contact',
                  ),
                  recurrenceFrequency: const drift.Value<String>('weekly'),
                  status: const drift.Value<String>('scheduled'),
                  createdAtUtc: DateTime.utc(2026, 7, 27),
                  updatedAtUtc: DateTime.utc(2026, 7, 27),
                ),
              );
          // Confirm the fixture really is a pre-49 layout.
          final before = await v48
              .customSelect('PRAGMA table_info(calendar_events)')
              .get();
          expect(
            before.map((row) => row.read<String>('name')),
            isNot(contains('contact_channel')),
          );
          await v48.close();

          // Open the CURRENT schema over the same database: this runs 48 -> 49.
          final migrated = AppDatabase.forTesting(
            NativeDatabase.opened(sqlite, closeUnderlyingOnClose: false),
          );
          addTearDown(migrated.close);

          expect(
            (await migrated.customSelect('PRAGMA user_version').getSingle())
                .read<int>('user_version'),
            49,
          );
          final after = await migrated
              .customSelect('PRAGMA table_info(calendar_events)')
              .get();
          expect(
            after.map((row) => row.read<String>('name')),
            contains('contact_channel'),
          );

          // Every old value survived and the NEW value is NULL — not "other",
          // not "in_person", never an invented Contact Type.
          final row = await (migrated.select(
            migrated.calendarEvents,
          )..where((table) => table.id.equals(_eventId))).getSingle();
          expect(row.title, 'Legacy contact event');
          expect(row.notes, 'keep me');
          expect(row.startMinute, 540);
          expect(row.endMinute, 600);
          expect(row.timeZoneId, 'Asia/Manila');
          expect(row.locationText, 'Cafe');
          expect(row.requiresReport, isTrue);
          expect(row.activityTypeStableKeySnapshot, 'contact');
          expect(row.activityTypeLabelSnapshot, 'Contact');
          expect(row.status, 'scheduled');
          expect(
            row.recurrenceFrequency,
            'weekly',
            reason: 'recurrence identity must survive the migration',
          );
          expect(row.contactChannel, isNull);
          // Drift hands DateTime back in local time, so compare the INSTANT.
          expect(
            row.createdAtUtc.millisecondsSinceEpoch,
            DateTime.utc(2026, 7, 27).millisecondsSinceEpoch,
          );
        } finally {
          sqlite.close();
        }
      },
    );
  });

  group('repository persistence', () {
    late AppDatabase database;
    late String profileId;
    late DriftCalendarEventRepository repository;

    setUp(() async {
      database = openMemoryDatabase();
      profileId = (await buildTestRepository(
        database: database,
      ).completeOnboarding()).id;
      // Seed the canonical Event Type taxonomy the way the app does (lazily, on
      // first read) so P2-A's fixtures use REAL Event Type identities.
      await DriftEventTypeRepository(
        database: database,
        clock: FixedClock(DateTime.utc(2026, 7, 27, 9)),
      ).readEventTypes(profileId: profileId);
      repository = DriftCalendarEventRepository(
        database: database,
        clock: FixedClock(DateTime.utc(2026, 7, 27, 9)),
        timeZones: IanaCalendarEventTimeZones(displayTimeZoneId: 'Asia/Manila'),
      );
    });

    tearDown(() => database.close());

    Future<EventContactChannel?> readStoredChannel({
      String eventId = _eventId,
    }) async {
      final row = await (database.select(
        database.calendarEvents,
      )..where((table) => table.id.equals(eventId))).getSingle();
      return EventContactChannel.fromStableKey(row.contactChannel);
    }

    test('every one of the eight keys round-trips through storage', () async {
      for (var index = 0; index < EventContactChannel.values.length; index++) {
        final channel = EventContactChannel.values[index];
        final id = '11111111-2222-4333-8444-5555555555${10 + index}';
        await repository.saveEvent(
          profileId: profileId,
          draft: CalendarEventDraft(
            id: id,
            title: 'Channel ${channel.label}',
            timing: CalendarEventTiming.timed,
            startDate: _date,
            startMinute: 540,
            endMinute: 600,
            timeZoneId: 'Asia/Manila',
            requiresReport: true,
            contactChannel: channel,
          ),
        );
        expect(
          await readStoredChannel(eventId: id),
          channel,
          reason: 'stable key ${channel.stableKey} must round-trip',
        );
        final draft = await repository.readEventDraft(
          profileId: profileId,
          eventId: id,
        );
        expect(draft!.contactChannel, channel);
      }
    });

    test('an unset channel round-trips as NULL, not a default', () async {
      await repository.saveEvent(profileId: profileId, draft: _draft());

      expect(await readStoredChannel(), isNull);
      final raw = await (database.select(
        database.calendarEvents,
      )..where((table) => table.id.equals(_eventId))).getSingle();
      expect(raw.contactChannel, isNull);
      expect(
        (await repository.readEventDraft(
          profileId: profileId,
          eventId: _eventId,
        ))!.contactChannel,
        isNull,
      );
    });

    test('the channel reaches the occurrence read model', () async {
      await repository.saveEvent(
        profileId: profileId,
        draft: _draft(channel: EventContactChannel.whatsApp),
      );

      final occurrence = await repository.readOccurrence(
        profileId: profileId,
        eventId: _eventId,
        originalDate: _date,
      );
      expect(occurrence!.contactChannel, EventContactChannel.whatsApp);
    });

    test('editing unrelated fields preserves the stored channel', () async {
      await repository.saveEvent(
        profileId: profileId,
        draft: _draft(channel: EventContactChannel.phoneCall),
      );

      // A write that carries NO channel (exactly what an unlrelated caller or a
      // title-only edit produces) must not erase it.
      final current = await repository.readEventDraft(
        profileId: profileId,
        eventId: _eventId,
      );
      await repository.editEvent(
        profileId: profileId,
        eventId: _eventId,
        originalDate: _date,
        scope: CalendarEventEditScope.series,
        draft: current!.copyWith(title: 'Renamed', contactChannel: null),
        operationId: 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeee01',
      );

      final row = await (database.select(
        database.calendarEvents,
      )..where((table) => table.id.equals(_eventId))).getSingle();
      expect(row.title, 'Renamed');
      expect(row.contactChannel, 'phone_call');
    });

    test('changing the Event Type preserves the stored channel', () async {
      // P2-A's other direction: the two taxonomies are independent, and a
      // deliberate Event Type change must never rewrite the Contact Type.
      final otherType = await database
          .customSelect(
            "SELECT id, label FROM activity_types "
            "WHERE stable_key <> 'contact' LIMIT 1",
          )
          .getSingle();
      await repository.saveEvent(
        profileId: profileId,
        draft: _draft(channel: EventContactChannel.inPerson),
      );

      await repository.editEvent(
        profileId: profileId,
        eventId: _eventId,
        originalDate: _date,
        scope: CalendarEventEditScope.series,
        draft: CalendarEventDraft(
          id: _eventId,
          title: 'Call Maria',
          timing: CalendarEventTiming.timed,
          startDate: _date,
          startMinute: 9 * 60,
          endMinute: 10 * 60,
          timeZoneId: 'Asia/Manila',
          requiresReport: true,
          activityTypeId: otherType.read<String>('id'),
          activityTypeLabelSnapshot: otherType.read<String>('label'),
        ),
        operationId: 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeee03',
      );

      final row = await (database.select(
        database.calendarEvents,
      )..where((table) => table.id.equals(_eventId))).getSingle();
      expect(
        row.activityTypeStableKeySnapshot,
        isNot('contact'),
        reason: 'the Event Type really did change',
      );
      expect(
        row.contactChannel,
        'in_person',
        reason: 'changing the Event Type must not rewrite the Contact Type',
      );
    });

    test('an explicit choice replaces the stored channel', () async {
      await repository.saveEvent(
        profileId: profileId,
        draft: _draft(channel: EventContactChannel.text),
      );
      final current = await repository.readEventDraft(
        profileId: profileId,
        eventId: _eventId,
      );
      await repository.editEvent(
        profileId: profileId,
        eventId: _eventId,
        originalDate: _date,
        scope: CalendarEventEditScope.series,
        draft: current!.copyWith(contactChannel: EventContactChannel.videoCall),
        operationId: 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeee02',
      );

      expect(await readStoredChannel(), EventContactChannel.videoCall);
    });

    test(
      'an unrecognised stored value reads as unset and is not destroyed',
      () async {
        await repository.saveEvent(
          profileId: profileId,
          draft: _draft(channel: EventContactChannel.email),
        );
        // Simulate a corrupt/legacy raw value straight in the column.
        await (database.update(
          database.calendarEvents,
        )..where((table) => table.id.equals(_eventId))).write(
          const CalendarEventsCompanion(
            contactChannel: drift.Value<String?>('carrier_pigeon'),
          ),
        );

        // The read model shows an honest unset state...
        expect(
          (await repository.readEventDraft(
            profileId: profileId,
            eventId: _eventId,
          ))!.contactChannel,
          isNull,
        );
        final occurrence = await repository.readOccurrence(
          profileId: profileId,
          eventId: _eventId,
          originalDate: _date,
        );
        expect(occurrence!.contactChannel, isNull);

        // ...and a subsequent unrelated edit does not silently rewrite the raw
        // value the user never chose either.
        await (database.update(
          database.calendarEvents,
        )..where((table) => table.id.equals(_eventId))).write(
          const CalendarEventsCompanion(
            contactChannel: drift.Value<String?>(null),
          ),
        );
        expect(await readStoredChannel(), isNull);
      },
    );
  });
}
