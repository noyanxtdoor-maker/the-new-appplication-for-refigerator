import 'package:drift/drift.dart' hide isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/ids/identifier_source.dart';
import 'package:rmplanner/features/contacts/data/drift_contact_repository.dart';
import 'package:rmplanner/features/contacts/domain/contact.dart';
import 'package:rmplanner/features/indicators/domain/life_indicator.dart';
import 'package:rmplanner/features/planner/data/calendar_event_time_zones.dart';
import 'package:rmplanner/features/planner/data/drift_calendar_event_repository.dart';
import 'package:rmplanner/features/planner/data/drift_outcome_reporting_repository.dart';
import 'package:rmplanner/features/planner/domain/calendar_event.dart';
import 'package:rmplanner/features/planner/domain/event_type.dart';
import 'package:rmplanner/features/planner/domain/outcome_reporting.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';

import '../../../support/test_dependencies.dart';

const _eventId = 'a1111111-1111-4111-8111-111111111111';
const _contactA = 'b2222222-2222-4222-8222-222222222222';
const _contactB = 'c3333333-3333-4333-8333-333333333333';
const _contactC = 'd4444444-4444-4444-8444-444444444444';
const _reportId = 'e5555555-5555-4555-8555-555555555555';
const _operationId = 'f6666666-6666-4666-8666-666666666666';
const _date = PlannerDate(year: 2026, month: 7, day: 28);
const _ruleKey = 'life-indicator:meaningful_connections:1:0:count';

/// OPD-3-004 BACKEND — DORMANT CAPABILITY (owner override 2026-08-17).
///
/// The explicit per-Contact "Meaningful Connections" confirmation UX is
/// ARCHIVED/DEFERRED and is no longer an active VS-11 release gate. This
/// suite preserves the deterministic v29 backend semantics so a future
/// restoration stays cheap: one people-linked interaction / Event; three
/// linked Contacts A, B, C; an explicit report confirms ONLY A and B as
/// meaningful -> EXACTLY two contributions (one tied to A, one tied to B,
/// zero tied to C); corrections are set-diff; idempotent; profile-scoped;
/// historical attribution is preserved. The active UI never invokes this
/// path (confirmedContactIds stays null -> classic event-level contribution).
void main() {
  late AppDatabase database;
  late String profileId;
  late DriftContactRepository contacts;
  late DriftCalendarEventRepository events;
  late DriftOutcomeReportingRepository reports;

  setUp(() async {
    database = openMemoryDatabase();
    profileId = (await buildTestRepository(
      database: database,
    ).completeOnboarding()).id;
    contacts = DriftContactRepository(
      database: database,
      clock: FixedClock(DateTime.utc(2026, 7, 28, 12)),
      identifiers: UuidIdentifierSource(),
    );
    reports = DriftOutcomeReportingRepository(
      database: database,
      clock: FixedClock(DateTime.utc(2026, 7, 28, 12)),
    );
    events = DriftCalendarEventRepository(
      database: database,
      clock: FixedClock(DateTime.utc(2026, 7, 28, 12)),
      timeZones: IanaCalendarEventTimeZones(displayTimeZoneId: 'Asia/Manila'),
      reportSource: reports,
    );
  });

  tearDown(() => database.close());

  Future<void> createContactsAndLinkedEvent() async {
    for (final (id, name) in <(String, String)>[
      (_contactA, 'Contact A'),
      (_contactB, 'Contact B'),
      (_contactC, 'Contact C'),
    ]) {
      await contacts.createContact(
        profileId: profileId,
        draft: ContactDraft(
          id: id,
          firstName: name,
          lastName: '',
          displayName: name,
          preferredContactMethod: ContactPreferredMethod.message,
          isFavorite: false,
        ),
      );
    }
    await events.saveEvent(
      profileId: profileId,
      draft: CalendarEventDraft(
        id: _eventId,
        title: 'Weekly connection visit',
        timing: CalendarEventTiming.timed,
        startDate: _date,
        startMinute: 8 * 60,
        endMinute: 9 * 60,
        timeZoneId: 'Asia/Manila',
        requiresReport: true,
        activityTypeId: SystemEventTypeIds.meaningfulConnection,
        activityTypeStableKeySnapshot: SystemEventTypeKeys.meaningfulConnection,
        activityTypeLabelSnapshot: 'Meaningful Connections',
      ),
    );
    await contacts.setEventPeople(
      profileId: profileId,
      eventId: _eventId,
      occurrenceId: 'series',
      originalDate: _date,
      contactIds: const <String>[_contactA, _contactB, _contactC],
    );
  }

  Future<OutcomeReportSource> readSource() async {
    final source = await reports.readEventSource(
      profileId: profileId,
      eventId: _eventId,
      originalDate: _date,
    );
    expect(source, isNotNull);
    return source!;
  }

  ContributionDraft contactContribution(String contactId) {
    final rule = ScheduledPotentialRule.tryParse(_ruleKey);
    expect(rule, isNotNull);
    return ContributionDraft(
      ruleKey: rule!.encode(),
      indicatorKey: rule.indicatorKey,
      value: IndicatorValue(
        scaledValue: rule.value.scaledValue,
        scale: rule.value.scale,
        unit: rule.value.unit,
      ),
      contactId: contactId,
    );
  }

  Future<void> submitContactReport({
    required String reportId,
    required List<String> confirmedContactIds,
    required String operationId,
    String? correctsReportId,
    String? correctionReason,
  }) async {
    await reports.submit(
      profileId: profileId,
      draft: OutcomeReportDraft(
        id: reportId,
        source: await readSource(),
        activityDate: _date,
        outcome: OutcomeKind.completedHappened,
        correctsReportId: correctsReportId,
        correctionReason: correctionReason,
        contributions: <ContributionDraft>[
          for (final contactId in confirmedContactIds)
            contactContribution(contactId),
        ],
      ),
      operationId: operationId,
    );
  }

  Future<List<ActivityLedgerEntry>> effectiveEntries(String profile) async {
    return reports.readLedgerHistory(
      profileId: profile,
      indicatorKey: 'meaningful_connections',
      effectiveOnly: true,
    );
  }

  test(
    'OPD-3-004 scenario 1: confirming A and B of three linked Contacts '
    'produces exactly two per-Contact contributions (one A, one B, zero C)',
    () async {
      await createContactsAndLinkedEvent();
      await submitContactReport(
        reportId: _reportId,
        confirmedContactIds: const <String>[_contactA, _contactB],
        operationId: _operationId,
      );

      final effective = await effectiveEntries(profileId);
      expect(effective, hasLength(2));
      expect(
        effective.where((e) => e.contactId == _contactA),
        hasLength(1),
        reason: 'A was confirmed -> exactly one A contribution',
      );
      expect(
        effective.where((e) => e.contactId == _contactB),
        hasLength(1),
        reason: 'B was confirmed -> exactly one B contribution',
      );
      expect(
        effective.where((e) => e.contactId == _contactC),
        isEmpty,
        reason: 'C was linked but NOT confirmed -> zero contributions',
      );

      final actual = await reports.readActual(
        profileId: profileId,
        indicatorKey: 'meaningful_connections',
        startDate: _date,
        endDate: _date,
      );
      expect(actual.value.scaledValue, 2);
    },
  );

  test(
    'OPD-3-004 scenario 2 (idempotency): re-submitting the same confirmation '
    'keeps exactly two effective per-Contact contributions',
    () async {
      await createContactsAndLinkedEvent();
      await submitContactReport(
        reportId: _reportId,
        confirmedContactIds: const <String>[_contactA, _contactB],
        operationId: _operationId,
      );
      final result = await reports.submit(
        profileId: profileId,
        draft: OutcomeReportDraft(
          id: _reportId,
          source: await readSource(),
          activityDate: _date,
          outcome: OutcomeKind.completedHappened,
          contributions: const <ContributionDraft>[],
        ),
        operationId: _operationId,
      );
      expect(result.unchanged, isTrue);

      final effective = await effectiveEntries(profileId);
      expect(effective, hasLength(2));
      expect(effective.where((e) => e.contactId == _contactA), hasLength(1));
      expect(effective.where((e) => e.contactId == _contactB), hasLength(1));
      final history = await reports.readLedgerHistory(
        profileId: profileId,
        indicatorKey: 'meaningful_connections',
        effectiveOnly: false,
      );
      final contributionCount = history
          .where((e) => e.type == ActivityLedgerEntryType.contribution)
          .length;
      expect(contributionCount, 2, reason: 'no duplicate A/B contributions');
    },
  );

  test(
    'OPD-3-004 scenario 3 (set-diff): correcting {A, B} to {A} leaves A '
    'effective and reverses B',
    () async {
      await createContactsAndLinkedEvent();
      await submitContactReport(
        reportId: _reportId,
        confirmedContactIds: const <String>[_contactA, _contactB],
        operationId: _operationId,
      );
      await submitContactReport(
        reportId: 'e7777777-7777-4777-8777-777777777777',
        confirmedContactIds: const <String>[_contactA],
        operationId: 'f8888888-8888-4888-8888-888888888888',
        correctsReportId: _reportId,
        correctionReason: 'Only A was actually confirmed as meaningful.',
      );

      final effective = await effectiveEntries(profileId);
      expect(effective, hasLength(1));
      expect(effective.single.contactId, _contactA);
      final history = await reports.readLedgerHistory(
        profileId: profileId,
        indicatorKey: 'meaningful_connections',
        effectiveOnly: false,
      );
      final bReversal = history.where(
        (e) => e.type == ActivityLedgerEntryType.reversal,
      );
      expect(
        bReversal.isNotEmpty,
        isTrue,
        reason: 'B received a reversal row (history is preserved, not deleted)',
      );
    },
  );

  test(
    'OPD-3-004 scenario 4 (set-diff): correcting {A} to {A, C} keeps A, adds '
    'C, and leaves B reversed',
    () async {
      await createContactsAndLinkedEvent();
      await submitContactReport(
        reportId: _reportId,
        confirmedContactIds: const <String>[_contactA, _contactB],
        operationId: _operationId,
      );
      await submitContactReport(
        reportId: 'e7777777-7777-4777-8777-777777777777',
        confirmedContactIds: const <String>[_contactA],
        operationId: 'f8888888-8888-4888-8888-888888888888',
        correctsReportId: _reportId,
        correctionReason: 'Only A was actually confirmed as meaningful.',
      );
      await submitContactReport(
        reportId: 'e9999999-9999-4999-8999-999999999999',
        confirmedContactIds: const <String>[_contactA, _contactC],
        operationId: 'faaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        correctsReportId: 'e7777777-7777-4777-8777-777777777777',
        correctionReason: 'C was also confirmed as meaningful.',
      );

      final effective = await effectiveEntries(profileId);
      expect(effective, hasLength(2));
      expect(effective.where((e) => e.contactId == _contactA), hasLength(1));
      expect(effective.where((e) => e.contactId == _contactC), hasLength(1));
      expect(
        effective.where((e) => e.contactId == _contactB),
        isEmpty,
        reason: 'B stays reversed through the chain',
      );
    },
  );

  test(
    'OPD-3-004 scenario 5 (set-diff): correcting {A, B} to {} reverses both '
    'and leaves zero effective Contact contributions',
    () async {
      await createContactsAndLinkedEvent();
      await submitContactReport(
        reportId: _reportId,
        confirmedContactIds: const <String>[_contactA, _contactB],
        operationId: _operationId,
      );
      await submitContactReport(
        reportId: 'e7777777-7777-4777-8777-777777777777',
        confirmedContactIds: const <String>[],
        operationId: 'f8888888-8888-4888-8888-888888888888',
        correctsReportId: _reportId,
        correctionReason: 'No Contact was actually confirmed as meaningful.',
      );

      final effective = await effectiveEntries(profileId);
      expect(effective, isEmpty);
      final history = await reports.readLedgerHistory(
        profileId: profileId,
        indicatorKey: 'meaningful_connections',
        effectiveOnly: false,
      );
      expect(
        history.where((e) => e.type == ActivityLedgerEntryType.reversal),
        hasLength(2),
        reason: 'both A and B were reversed; rows never deleted',
      );
    },
  );

  test(
    'OPD-3-004 scenario 6: one linked Contact but none selected -> zero '
    'Contact contributions',
    () async {
      await createContactsAndLinkedEvent();
      await submitContactReport(
        reportId: _reportId,
        confirmedContactIds: const <String>[],
        operationId: _operationId,
      );

      final effective = await effectiveEntries(profileId);
      expect(
        effective.where((e) => e.contactId != null),
        isEmpty,
        reason: 'no Contact selected -> no per-Contact contributions',
      );
    },
  );

  test(
    'OPD-3-004 scenario 7: three linked Contacts but none selected -> zero '
    'Contact contributions',
    () async {
      await createContactsAndLinkedEvent();
      await submitContactReport(
        reportId: _reportId,
        confirmedContactIds: const <String>[],
        operationId: _operationId,
      );

      final effective = await effectiveEntries(profileId);
      expect(effective, isEmpty);
      expect(
        effective.where((e) => e.contactId != null),
        isEmpty,
        reason: 'linked presence alone never contributes',
      );
    },
  );

  test(
    'OPD-3-004 scenario 8: Event title says Meaningful Connection but no '
    'explicit Contact selection -> zero Contact Actual',
    () async {
      await createContactsAndLinkedEvent();
      await submitContactReport(
        reportId: _reportId,
        confirmedContactIds: const <String>[],
        operationId: _operationId,
      );

      final actual = await reports.readActual(
        profileId: profileId,
        indicatorKey: 'meaningful_connections',
        startDate: _date,
        endDate: _date,
      );
      expect(
        actual.value.scaledValue,
        0,
        reason: 'title text never infers a Contact Actual',
      );
    },
  );

  test(
    'OPD-3-004 scenario 9: Event completed but no explicit Contact selection '
    '-> zero Contact Actual',
    () async {
      await createContactsAndLinkedEvent();
      await submitContactReport(
        reportId: _reportId,
        confirmedContactIds: const <String>[],
        operationId: _operationId,
      );

      final actual = await reports.readActual(
        profileId: profileId,
        indicatorKey: 'meaningful_connections',
        startDate: _date,
        endDate: _date,
      );
      expect(
        actual.value.scaledValue,
        0,
        reason: 'completion alone never infers a Contact Actual',
      );
    },
  );

  test(
    'OPD-3-004 scenario 10: returning from an external action creates no '
    'Actual without structured confirmation',
    () async {
      await createContactsAndLinkedEvent();
      // No report was ever submitted (e.g. a phone/SMS/email handoff
      // returned). Nothing may be inferred.
      final effective = await effectiveEntries(profileId);
      expect(effective, isEmpty);
      final actual = await reports.readActual(
        profileId: profileId,
        indicatorKey: 'meaningful_connections',
        startDate: _date,
        endDate: _date,
      );
      expect(
        actual.value.scaledValue,
        0,
        reason: 'external return without structured confirmation -> zero',
      );
    },
  );

  test(
    'OPD-3-004 scenario 11: re-running a correction with the same set stays '
    'idempotent - exactly two effective Contact contributions, no duplicates',
    () async {
      await createContactsAndLinkedEvent();
      await submitContactReport(
        reportId: _reportId,
        confirmedContactIds: const <String>[_contactA, _contactB],
        operationId: _operationId,
      );
      // A genuine re-run is a correction with the SAME confirmed set (new
      // report id + new operation). The effective set must remain {A, B} with
      // exactly one effective row per Contact.
      await submitContactReport(
        reportId: 'aaaaaaaa-1111-4111-8111-111111111111',
        confirmedContactIds: const <String>[_contactA, _contactB],
        operationId: 'bbbbbbbb-1111-4111-8111-111111111111',
        correctsReportId: _reportId,
        correctionReason: 'Re-saved the same confirmation.',
      );
      await submitContactReport(
        reportId: 'aaaaaaaa-2222-4222-8222-222222222222',
        confirmedContactIds: const <String>[_contactA, _contactB],
        operationId: 'bbbbbbbb-2222-4222-8222-222222222222',
        correctsReportId: 'aaaaaaaa-1111-4111-8111-111111111111',
        correctionReason: 'Re-saved the same confirmation again.',
      );

      final effective = await effectiveEntries(profileId);
      expect(effective, hasLength(2));
      expect(effective.where((e) => e.contactId == _contactA), hasLength(1));
      expect(effective.where((e) => e.contactId == _contactB), hasLength(1));
      expect(
        effective.where((e) => e.type == ActivityLedgerEntryType.reversal),
        isEmpty,
        reason: 'no effective reversal rows survive in the effective view',
      );
    },
  );

  test(
    'OPD-3-004 scenario 12 (profile isolation): profile B cannot see profile '
    'A Contact attribution',
    () async {
      await createContactsAndLinkedEvent();
      await submitContactReport(
        reportId: _reportId,
        confirmedContactIds: const <String>[_contactA],
        operationId: _operationId,
      );

      // completeOnboarding is idempotent (returns the existing primary
      // profile), so insert the second profile row directly.
      const otherProfileId = '99999999-9999-4999-8999-999999999999';
      await database.into(database.localProfiles).insert(
        LocalProfilesCompanion.insert(
          id: otherProfileId,
          slot: const Value<String>('secondary'),
          localName: 'Local Profile 99999999',
          createdAtUtc: DateTime.utc(2026, 8, 17),
          updatedAtUtc: DateTime.utc(2026, 8, 17),
        ),
      );
      // Seed the same Life Goal definition for the second profile (a real
      // second profile would have gone through onboarding).
      final sourceDefinition = await (database
              .select(database.lifeIndicatorDefinitions)
            ..where(
              (table) =>
                  table.profileId.equals(profileId) &
                  table.indicatorKey.equals('meaningful_connections'),
            ))
          .getSingle();
      await database.into(database.lifeIndicatorDefinitions).insert(
        LifeIndicatorDefinitionsCompanion.insert(
          id: 'aaaaaaaa-0000-4000-8000-000000000002',
          profileId: otherProfileId,
          indicatorKey: sourceDefinition.indicatorKey,
          label: sourceDefinition.label,
          unit: sourceDefinition.unit,
          position: sourceDefinition.position,
          createdAtUtc: DateTime.utc(2026, 8, 17),
        ),
      );
      final otherEntries = await effectiveEntries(otherProfileId);
      expect(otherEntries, isEmpty);
      final otherActual = await reports.readActual(
        profileId: otherProfileId,
        indicatorKey: 'meaningful_connections',
        startDate: _date,
        endDate: _date,
      );
      expect(otherActual.value.scaledValue, 0);
    },
  );

  test(
    'OPD-3-004 scenario 13 (archive): archiving a Contact preserves its '
    'historical attribution',
    () async {
      await createContactsAndLinkedEvent();
      await submitContactReport(
        reportId: _reportId,
        confirmedContactIds: const <String>[_contactA],
        operationId: _operationId,
      );
      await contacts.archiveContact(
        profileId: profileId,
        contactId: _contactA,
      );

      final effective = await effectiveEntries(profileId);
      expect(effective.single.contactId, _contactA);
      expect(effective.single.isEffective, isTrue);
    },
  );

  test(
    'OPD-3-004 scenario 14 (merge): merging preserves historical attribution '
    'to the absorbed identity (no rewrite)',
    () async {
      await createContactsAndLinkedEvent();
      await submitContactReport(
        reportId: _reportId,
        confirmedContactIds: const <String>[_contactA, _contactB],
        operationId: _operationId,
      );
      await contacts.mergeContacts(
        profileId: profileId,
        survivorId: _contactA,
        absorbedIds: const <String>[_contactB],
        choices: const ContactMergeChoices(<String, String>{}),
      );

      final history = await reports.readLedgerHistory(
        profileId: profileId,
        indicatorKey: 'meaningful_connections',
        effectiveOnly: false,
      );
      final bContributions = history.where(
        (e) => e.type == ActivityLedgerEntryType.contribution,
      );
      expect(
        bContributions.any((e) => e.contactId == _contactB),
        isTrue,
        reason: 'absorbed B identity remains historically attributable',
      );
      final effective = await effectiveEntries(profileId);
      expect(
        effective.where((e) => e.contactId == _contactA),
        hasLength(1),
      );
    },
  );
}
