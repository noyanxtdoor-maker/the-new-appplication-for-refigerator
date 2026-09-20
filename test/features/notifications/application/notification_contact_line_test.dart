// NEXT TRANSFER — the notification CONTACT LINE law (owner pass 2026-09-19, D).
//
// THE DEFECT THIS PINS.  "Show contacts" is ON, the Event has a Contact
// attached through the normal People section, and the delivered notification
// never contains the name.  The content path resolved a Contact name ONLY from
// the reminder policy's explicit `contactFollowUp` purpose + `contactId`
// (`_followUpName`), which is written by the Contact-follow-up creator flow.
// Attaching a Contact writes `event_contact_links` / `task_contact_links` and
// no policy purpose at all, so the line short-circuited to null and the owner's
// own Event Contact never reached the notification.
//
// The law locked here:
//
//   * an EXPLICIT follow-up Contact still wins (the existing M7 behaviour is
//     preserved exactly, so the creator flow cannot regress);
//   * otherwise the source's LIVE attached Contacts are used — the same
//     effective-link semantics the enrichment source already implements, so a
//     removed/unlinked/archived Contact never resolves and a rename is always
//     current;
//   * deterministic ordering, each name exactly once, DISPLAY NAMES ONLY;
//   * no attached Contacts means no line at all — never an empty row;
//   * the privacy gate sits ABOVE all of it: when the saved preview preference
//     is private/generic, `showDetails` is false and the canonical renderer
//     returns the neutral Generic copy, so a Contact name cannot appear no
//     matter what "Show contacts" says.

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/features/notifications/application/detailed_content_providers.dart';
import 'package:rmplanner/features/notifications/application/reminder_delivery_service.dart';
import 'package:rmplanner/features/notifications/application/reminder_delivery_source_reader.dart';
import 'package:rmplanner/features/notifications/application/reminder_enrichment_resolver.dart';
import 'package:rmplanner/features/notifications/application/reminder_notification_renderer.dart';
import 'package:rmplanner/features/notifications/data/detailed_content_preferences_store.dart';
import 'package:rmplanner/features/notifications/data/drift_notification_foundation_repository.dart';
import 'package:rmplanner/features/notifications/data/drift_reminder_enrichment_source.dart';
import 'package:rmplanner/features/notifications/domain/reminder_policy.dart';
import 'package:rmplanner/features/planner/data/calendar_event_time_zones.dart';
import 'package:rmplanner/features/planner/data/drift_calendar_event_repository.dart';
import 'package:rmplanner/features/planner/data/drift_planner_repository.dart';
import 'package:rmplanner/features/planner/domain/calendar_event.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';

import '../../../support/test_dependencies.dart';

void main() {
  const eventId = '11111111-1111-4111-8111-111111111111';
  final startDate = PlannerDate(year: 2026, month: 9, day: 20);

  late AppDatabase database;
  late String profileId;
  late DriftCalendarEventRepository calendar;
  late DriftNotificationFoundationRepository foundation;
  late DriftReminderDeliverySourceReader reader;
  late String occurrenceId;

  /// A reader with the given resolved privacy permission, so the privacy gate
  /// can be exercised without writing the privacy tables.
  DriftReminderDeliverySourceReader readerWith(
    NotificationDeliveryPrivacy privacy,
  ) => DriftReminderDeliverySourceReader(
    database: database,
    clock: FixedClock(DateTime.utc(2026, 9, 19, 4)),
    events: calendar,
    zones: IanaCalendarEventTimeZones(displayTimeZoneId: 'Asia/Manila'),
    enrichment: ReminderEnrichmentResolver(
      DriftReminderEnrichmentSource(database: database),
    ),
    tasks: DriftPlannerRepository(
      database: database,
      clock: FixedClock(DateTime.utc(2026, 9, 19, 4)),
    ),
    privacy: () async => privacy,
    detailedContent: (id) => foundation.readDetailedContent(profileId: id),
  );

  Future<void> seedContact({
    required String id,
    required String name,
    String lifecycle = 'active',
    String? mergedInto,
  }) => database
      .into(database.contacts)
      .insert(
        ContactsCompanion.insert(
          id: id,
          profileId: profileId,
          displayName: name,
          lifecycleState: Value(lifecycle),
          mergedIntoContactId: Value(mergedInto),
          createdAtUtc: DateTime.utc(2026, 9, 1),
          updatedAtUtc: DateTime.utc(2026, 9, 1),
        ),
      );

  Future<void> attachEventContact(
    String contactId, {
    String linkOccurrenceId = 'series',
    String status = 'active',
  }) => database
      .into(database.eventContactLinks)
      .insert(
        EventContactLinksCompanion.insert(
          id: 'link-$linkOccurrenceId-$contactId',
          profileId: profileId,
          eventId: eventId,
          occurrenceId: Value(linkOccurrenceId),
          contactId: contactId,
          status: Value(status),
          createdAtUtc: DateTime.utc(2026, 9, 1),
          updatedAtUtc: DateTime.utc(2026, 9, 1),
        ),
      );

  /// A plain reminder the user set.  Its purpose is `standard`: this is what an
  /// ordinary Save writes, and it is exactly the situation the owner reported.
  Future<void> seedStandardPolicy() => foundation.upsertPolicy(
    ReminderPolicy(
      id: 'policy-1',
      profileId: profileId,
      sourceKind: ReminderSourceKind.calendarEvent,
      sourceId: eventId,
      occurrenceId: ReminderPolicy.seriesOccurrenceId,
      purpose: ReminderPurpose.standard,
      mode: ReminderPolicyMode.offset,
      offsetMinutes: 10,
      createdAtUtc: DateTime.utc(2026, 9, 1),
      updatedAtUtc: DateTime.utc(2026, 9, 1),
    ),
  );

  Future<ReminderDeliverySnapshot> readEvent() async => (await reader.read(
    profileId: profileId,
    sourceKind: ReminderSourceKind.calendarEvent,
    sourceId: eventId,
    occurrenceId: occurrenceId,
  ))!;

  /// The canonical Detailed body for this snapshot, mirroring the delivery
  /// service's own render law: a non-detailed snapshot is the neutral Generic
  /// copy before any field is even considered.
  RenderedReminder render(ReminderDeliverySnapshot snapshot) =>
      snapshot.showDetails
      ? ReminderNotificationRenderer.eventDetailed(
          eventTitle: snapshot.sourceTitle,
          startDisplay: snapshot.startUtc,
          endDisplay: snapshot.endUtc,
          notes: snapshot.notes,
          followUpName: snapshot.followUpName,
          locationText: snapshot.locationText,
          options: snapshot.detailOptions,
        )
      : ReminderNotificationRenderer.generic;

  setUp(() async {
    database = openMemoryDatabase();
    final clock = FixedClock(DateTime.utc(2026, 9, 19, 4));
    profileId = (await buildTestRepository(
      database: database,
    ).completeOnboarding()).id;
    calendar = DriftCalendarEventRepository(
      database: database,
      clock: clock,
      timeZones: IanaCalendarEventTimeZones(displayTimeZoneId: 'Asia/Manila'),
    );
    foundation = DriftNotificationFoundationRepository(
      database: database,
      clock: clock,
    );
    reader = readerWith(NotificationDeliveryPrivacy.detailed);
    occurrenceId = CalendarEventOccurrenceIdentity.forDate(
      eventId: eventId,
      originalDate: startDate,
    );
    await calendar.saveEvent(
      profileId: profileId,
      draft: CalendarEventDraft(
        id: eventId,
        title: 'District Meeting',
        timing: CalendarEventTiming.timed,
        startDate: startDate,
        startMinute: 14 * 60 + 10,
        endMinute: 15 * 60,
        timeZoneId: 'Asia/Manila',
        notes: 'Weekly coordination',
        requiresReport: false,
      ),
    );
    await seedStandardPolicy();
  });

  tearDown(() => database.close());

  group('C — the attached Contact reaches the notification', () {
    test('C1 — one attached Contact appears for a plain reminder', () async {
      await seedContact(id: 'contact-juan', name: 'Juan Dela Cruz');
      await attachEventContact('contact-juan');

      final snapshot = await readEvent();
      expect(
        snapshot.followUpName,
        'Juan Dela Cruz',
        reason:
            'C1: attaching a Contact must be enough; the policy purpose is a '
            'separate follow-up flow and must not be the only source',
      );
      expect(
        render(snapshot).body,
        contains('Juan Dela Cruz'),
        reason: 'C1: the name must reach the notification body',
      );
    });

    test('C5 — two attached Contacts appear exactly once, in order', () async {
      await seedContact(id: 'contact-juan', name: 'Juan Dela Cruz');
      await seedContact(id: 'contact-maria', name: 'Maria Santos');
      await attachEventContact('contact-juan');
      await attachEventContact('contact-maria');

      final snapshot = await readEvent();
      expect(snapshot.followUpName, 'Juan Dela Cruz, Maria Santos');

      final body = render(snapshot).body;
      expect('Juan Dela Cruz'.allMatches(body), hasLength(1));
      expect('Maria Santos'.allMatches(body), hasLength(1));
    });

    test('C6 — no attached Contact means no line at all', () async {
      final snapshot = await readEvent();
      expect(snapshot.followUpName, isNull);
      expect(render(snapshot).body, isNot(contains('Follow up')));
      expect(render(snapshot).body, isNot(contains('Contacts')));
    });

    test(
      'C7 — a removed / archived / merged Contact resolves to nothing',
      () async {
        await seedContact(
          id: 'contact-gone',
          name: 'Ana',
          lifecycle: 'archived',
        );
        await attachEventContact('contact-gone');
        expect((await readEvent()).followUpName, isNull);

        await database.delete(database.eventContactLinks).go();
        await seedContact(
          id: 'contact-merged',
          name: 'Old Name',
          mergedInto: 'contact-new',
        );
        await seedContact(id: 'contact-new', name: 'New Name');
        await attachEventContact('contact-merged');

        expect(
          (await readEvent()).followUpName,
          isNull,
          reason: 'C7: no retarget to mergedIntoContactId may be invented',
        );
      },
    );

    test(
      'C8 — only the display name is carried, never other Contact data',
      () async {
        await seedContact(id: 'contact-juan', name: 'Juan Dela Cruz');
        await attachEventContact('contact-juan');
        await database
            .into(database.contactMethods)
            .insert(
              ContactMethodsCompanion.insert(
                id: 'method-1',
                contactId: 'contact-juan',
                type: 'phone',
                rawValue: '0917 123 4567',
                normalizedValue: '+639171234567',
              ),
            );

        final snapshot = await readEvent();
        expect(snapshot.followUpName, 'Juan Dela Cruz');
        final body = render(snapshot).body;
        expect(body, isNot(contains('0917')));
        expect(body, isNot(contains('+63917')));
      },
    );

    test(
      'an occurrence-level unlink removes the name for that date only',
      () async {
        await seedContact(id: 'contact-juan', name: 'Juan Dela Cruz');
        await attachEventContact('contact-juan');
        await attachEventContact(
          'contact-juan',
          linkOccurrenceId: occurrenceId,
          status: 'removed',
        );

        expect((await readEvent()).followUpName, isNull);
      },
    );

    test(
      'an explicit follow-up Contact still wins over the People list',
      () async {
        await seedContact(id: 'contact-juan', name: 'Juan Dela Cruz');
        await seedContact(id: 'contact-bea', name: 'Bea');
        await attachEventContact('contact-juan');
        await attachEventContact('contact-bea');
        await foundation.upsertPolicy(
          ReminderPolicy(
            id: 'policy-1',
            profileId: profileId,
            sourceKind: ReminderSourceKind.calendarEvent,
            sourceId: eventId,
            occurrenceId: ReminderPolicy.seriesOccurrenceId,
            purpose: ReminderPurpose.contactFollowUp,
            contactId: 'contact-bea',
            mode: ReminderPolicyMode.offset,
            offsetMinutes: 10,
            createdAtUtc: DateTime.utc(2026, 9, 1),
            updatedAtUtc: DateTime.utc(2026, 9, 1),
          ),
        );

        expect(
          (await readEvent()).followUpName,
          'Bea',
          reason:
              'the M7 creator flow is an EXPLICIT choice and must not be diluted '
              'by the People list',
        );
      },
    );

    test('a dangling explicit choice falls back to the People list', () async {
      await seedContact(id: 'contact-juan', name: 'Juan Dela Cruz');
      await seedContact(id: 'contact-gone', name: 'Ana', lifecycle: 'archived');
      await attachEventContact('contact-juan');
      await attachEventContact('contact-gone');
      await foundation.upsertPolicy(
        ReminderPolicy(
          id: 'policy-1',
          profileId: profileId,
          sourceKind: ReminderSourceKind.calendarEvent,
          sourceId: eventId,
          occurrenceId: ReminderPolicy.seriesOccurrenceId,
          purpose: ReminderPurpose.contactFollowUp,
          contactId: 'contact-gone',
          mode: ReminderPolicyMode.offset,
          offsetMinutes: 10,
          createdAtUtc: DateTime.utc(2026, 9, 1),
          updatedAtUtc: DateTime.utc(2026, 9, 1),
        ),
      );

      expect(
        (await readEvent()).followUpName,
        'Juan Dela Cruz',
        reason:
            'an explicit selection that no longer resolves must not blank the '
            'line while other People are still attached — and the archived '
            'Contact must never be revived',
      );
    });
  });

  group('P — the privacy gate sits above Show contacts', () {
    test(
      'C3/C4/P1 — a private preview yields the neutral Generic copy',
      () async {
        await seedContact(id: 'contact-juan', name: 'Juan Dela Cruz');
        await attachEventContact('contact-juan');
        final private = readerWith(NotificationDeliveryPrivacy.generic);

        final snapshot = (await private.read(
          profileId: profileId,
          sourceKind: ReminderSourceKind.calendarEvent,
          sourceId: eventId,
          occurrenceId: occurrenceId,
        ))!;

        expect(
          snapshot.showDetails,
          isFalse,
          reason:
              'C3: the privacy preview preference is the gate the delivery '
              'renderer consults before any detailed field',
        );
        expect(render(snapshot).body, ReminderNotificationRenderer.genericBody);
        expect(render(snapshot).body, isNot(contains('Juan Dela Cruz')));
      },
    );

    test(
      'P7 — the saved per-field choices survive a private-preview read',
      () async {
        await seedContact(id: 'contact-juan', name: 'Juan Dela Cruz');
        await attachEventContact('contact-juan');
        await foundation.saveDetailedContent(
          profileId: profileId,
          preferences: const DetailedContentPreferences(showLocation: false),
        );

        final private = readerWith(NotificationDeliveryPrivacy.generic);
        final hidden = (await private.read(
          profileId: profileId,
          sourceKind: ReminderSourceKind.calendarEvent,
          sourceId: eventId,
          occurrenceId: occurrenceId,
        ))!;
        expect(hidden.showDetails, isFalse);

        // The storage itself must still hold the owner's own configuration:
        // privacy suppresses EFFECT, never storage.
        expect(
          await foundation.readDetailedContent(profileId: profileId),
          const DetailedContentPreferences(showLocation: false),
        );

        final visible = await readEvent();
        expect(visible.showDetails, isTrue);
        expect(visible.detailOptions.showLocation, isFalse);
        expect(visible.detailOptions.showContacts, isTrue);
      },
    );
  });

  group(
    'the Detailed Content master suppresses detail, never configuration',
    () {
      test(
        'Case B / P2 — master OFF delivers the neutral Generic copy',
        () async {
          await seedContact(id: 'contact-juan', name: 'Juan Dela Cruz');
          await attachEventContact('contact-juan');
          await foundation.saveDetailedContent(
            profileId: profileId,
            preferences: const DetailedContentPreferences(enabled: false),
          );

          final snapshot = await readEvent();
          expect(
            snapshot.showDetails,
            isTrue,
            reason:
                'privacy still permits detail; the master is what forbids it',
          );
          expect(snapshot.detailOptions.isEmpty, isTrue);
          expect(render(snapshot), ReminderNotificationRenderer.generic);
          expect(render(snapshot).body, isNot(contains('Juan Dela Cruz')));
        },
      );

      test(
        'C4 — master OFF conceals contacts even with Show contacts ON',
        () async {
          await seedContact(id: 'contact-juan', name: 'Juan Dela Cruz');
          await attachEventContact('contact-juan');
          await foundation.saveDetailedContent(
            profileId: profileId,
            preferences: const DetailedContentPreferences(enabled: false),
          );

          final stored = await foundation.readDetailedContent(
            profileId: profileId,
          );
          expect(
            stored.showContacts,
            isTrue,
            reason: 'the owner never turned Show contacts off',
          );
          expect(
            render(await readEvent()).body,
            isNot(contains('Juan Dela Cruz')),
          );
        },
      );

      test(
        'P8 — a master off/on round trip returns the field choices',
        () async {
          await foundation.saveDetailedContent(
            profileId: profileId,
            preferences: const DetailedContentPreferences(showLocation: false),
          );
          final before = await foundation.readDetailedContent(
            profileId: profileId,
          );

          await foundation.saveDetailedContent(
            profileId: profileId,
            preferences: before.copyWith(enabled: false),
          );
          final off = await foundation.readDetailedContent(
            profileId: profileId,
          );
          expect(off.enabled, isFalse);
          expect(
            off.showLocation,
            isFalse,
            reason: 'the master must not rewrite the field switches',
          );

          final back = await foundation.saveDetailedContent(
            profileId: profileId,
            preferences: off.copyWith(enabled: true),
          );
          expect(back.enabled, isTrue);
          expect(
            back.showLocation,
            isFalse,
            reason: "the owner's own choice returns; it is not reset to true",
          );
          expect(back.showTitle, isTrue);
        },
      );
    },
  );

  group('the canonical renderer still gates each field independently', () {
    RenderedReminder preview(ReminderDetailOptions options) =>
        buildDetailedPreview(
          isEvent: true,
          options: DetailedContentPreferences(
            showTitle: options.showTitle,
            showDescription: options.showDescription,
            showTime: options.showTime,
            showContacts: options.showContacts,
            showLocation: options.showLocation,
          ),
          sourceTitle: 'District Meeting',
          startDisplay: DateTime.utc(2026, 9, 20, 6, 10),
          endDisplay: DateTime.utc(2026, 9, 20, 7),
          notes: 'Weekly coordination',
          followUpName: 'Juan Dela Cruz',
          locationText: 'Meetinghouse',
        );

    test('C2 — Show contacts OFF removes the name and nothing else', () {
      final rendered = preview(
        ReminderDetailOptions.all.copyWith(showContacts: false),
      );
      expect(rendered.title, 'District Meeting');
      expect(rendered.body, isNot(contains('Juan Dela Cruz')));
      expect(rendered.body, contains('Weekly coordination'));
      expect(rendered.body, contains('Meetinghouse'));
    });

    test('C9 — Show contacts ON survives every other field being OFF', () {
      final rendered = preview(
        const ReminderDetailOptions(
          showTitle: false,
          showDescription: false,
          showTime: false,
          showContacts: true,
          showLocation: false,
        ),
      );
      expect(rendered.body, 'Follow up with Juan Dela Cruz.');
    });

    test('C10 — Show contacts OFF leaves the other four intact', () {
      final rendered = preview(
        const ReminderDetailOptions(
          showTitle: true,
          showDescription: true,
          showTime: true,
          showContacts: false,
          showLocation: false,
        ),
      );
      expect(rendered.title, 'District Meeting');
      expect(rendered.body, contains('Weekly coordination'));
      expect(rendered.body, isNot(contains('Follow up')));
    });

    test('P2 — every field off falls back to the neutral Generic copy', () {
      expect(
        preview(
          const ReminderDetailOptions(
            showTitle: false,
            showDescription: false,
            showTime: false,
            showContacts: false,
            showLocation: false,
          ),
        ),
        ReminderNotificationRenderer.generic,
      );
    });
  });
}
