// NEXT TRANSFER — the ONE notification content law across BOTH transports
// (owner pass 2026-09-19, defects N1 and N2).
//
// THE DEFECTS THIS PINS.
//
// N1.  The ordinary (native) transport PRE-RENDERS the notification body when
//      it schedules the alarm, and both controllers rendered that body with
//      `ReminderDetailOptions.all` — the owner's saved Show title / Show
//      description / Show time / Show contacts / Show location choices were
//      never consulted.  The targeted worker transport, by contrast, reads the
//      saved options at delivery.  So the SAME reminder showed different content
//      depending on which transport happened to own it, and changing a Show
//      toggle could not refresh a reminder that was already scheduled.
//
// N2.  Task reconciliation never passed `requiresEnrichment`, so every Task
//      stayed on the pre-rendered native transport.  A Task's live attached
//      People could be resolved by the reader but could never be DELIVERED.
//
// THE LAW LOCKED HERE: the effective options — System Notifications, then the
// Privacy preview gate, then the Detailed Content master, then the five per-field
// toggles — produce the same result on EVERY transport, and a Task with attached
// People is handed to the live-read transport.

import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/ids/identifier_source.dart';
import 'package:rmplanner/core/notifications/notification_gateway.dart';
import 'package:rmplanner/core/notifications/notification_payload.dart';
import 'package:rmplanner/features/contacts/application/contact_providers.dart';
import 'package:rmplanner/features/contacts/data/drift_contact_repository.dart';
import 'package:rmplanner/features/notifications/application/notification_providers.dart';
import 'package:rmplanner/features/notifications/application/reminder_notification_renderer.dart';
import 'package:rmplanner/features/notifications/data/detailed_content_preferences_store.dart';
import 'package:rmplanner/features/notifications/data/drift_notification_foundation_repository.dart';
// Prefixed: `app_database.dart` also declares a `NotificationPreferences`
// table class, and this suite needs both.
import 'package:rmplanner/features/notifications/domain/notification_preferences.dart'
    as notification_domain;
import 'package:rmplanner/features/notifications/domain/reminder_policy.dart';
import 'package:rmplanner/features/planner/application/calendar_event_providers.dart';
import 'package:rmplanner/features/planner/application/event_type_providers.dart';
import 'package:rmplanner/features/planner/application/planner_providers.dart';
import 'package:rmplanner/features/planner/data/calendar_event_time_zones.dart';
import 'package:rmplanner/features/planner/data/drift_calendar_event_repository.dart';
import 'package:rmplanner/features/planner/data/drift_event_type_repository.dart';
import 'package:rmplanner/features/planner/data/drift_planner_repository.dart';
import 'package:rmplanner/features/planner/domain/calendar_event.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_task.dart';
import 'package:rmplanner/features/privacy/application/privacy_providers.dart';
import 'package:rmplanner/features/privacy/data/drift_privacy_repository.dart';
import 'package:rmplanner/features/privacy/domain/permission_summary.dart';
import 'package:rmplanner/features/privacy/domain/privacy_settings.dart';

import '../../../support/test_dependencies.dart';

/// Captures what the native scheduler would have posted.
final class _RecordingGateway implements NotificationGateway {
  final List<LocalNotificationRequest> scheduled = <LocalNotificationRequest>[];

  @override
  Stream<NotificationResponseIntent> get responses => const Stream.empty();

  @override
  Future<void> initialize() async {}

  @override
  Future<void> schedule(LocalNotificationRequest request) async {
    scheduled.add(request);
  }

  @override
  Future<void> cancel(int platformId) async {}

  @override
  Future<List<PendingLocalNotification>> pending() async =>
      const <PendingLocalNotification>[];

  @override
  NotificationResponseIntent? takeInitialResponse() => null;
}

void main() {
  const eventId = '11111111-1111-4111-8111-111111111111';
  const taskId = '22222222-2222-4222-8222-222222222222';
  const eventNotes = 'Weekly coordination with the district team';

  late AppDatabase database;
  late String profileId;
  late DriftCalendarEventRepository calendar;
  late DriftPlannerRepository planner;
  late DriftNotificationFoundationRepository foundation;
  late DriftPrivacyRepository privacyRepository;
  late _RecordingGateway gateway;
  late List<String> workerRegistrations;
  late PlannerDate targetDate;

  /// The two days of headroom keep the fixture unambiguously in the future for
  /// the real `SystemAppClock` the reconciler uses in production.
  PlannerDate twoDaysAhead() =>
      PlannerDate.fromDateTime(DateTime.now()).addDays(2);

  Future<ProviderContainer> buildContainer() async {
    final container = ProviderContainer(
      overrides: <Override>[
        notificationFoundationRepositoryProvider.overrideWithValue(foundation),
        notificationGatewayProvider.overrideWithValue(gateway),
        backgroundWorkGatewayProvider.overrideWithValue(
          FakeBackgroundWorkGateway(),
        ),
        calendarEventRepositoryProvider.overrideWithValue(calendar),
        plannerRepositoryProvider.overrideWithValue(planner),
        eventTypeRepositoryProvider.overrideWithValue(
          DriftEventTypeRepository(
            database: database,
            clock: FixedClock(DateTime.utc(2026, 9, 19, 4)),
          ),
        ),
        contactRepositoryProvider.overrideWithValue(
          DriftContactRepository(
            database: database,
            clock: FixedClock(DateTime.utc(2026, 9, 19, 4)),
            identifiers: const UuidIdentifierSource(),
          ),
        ),
        privacyRepositoryProvider.overrideWithValue(privacyRepository),
        permissionGatewayProvider.overrideWithValue(
          FakePermissionGateway(
            states: <OptionalPermission, OperatingSystemPermissionState>{
              OptionalPermission.notifications:
                  OperatingSystemPermissionState.granted,
            },
          ),
        ),
        // The runtime profile is the same seam the headless reminder runtime
        // uses, so no fake StartupReady is constructed.
        reminderRuntimeProfileIdProvider.overrideWithValue(profileId),
        reminderWorkerTransportProvider.overrideWithValue(({
          required String stableKey,
          required DateTime scheduledAtUtc,
          required String sourceRevision,
          required int platformNotificationId,
        }) async {
          workerRegistrations.add(sourceRevision);
        }),
        reminderWorkerReleaseProvider.overrideWithValue((_) async {}),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<void> setDetailed(DetailedContentPreferences preferences) => foundation
      .saveDetailedContent(profileId: profileId, preferences: preferences);

  Future<void> enableDelivery() async {
    await foundation.savePreferences(
      profileId: profileId,
      preferences: const notification_domain.NotificationPreferences.defaults()
          .copyWith(
            systemNotificationsEnabled: true,
            eventRemindersEnabled: true,
            taskRemindersEnabled: true,
          ),
    );
  }

  /// The saved privacy preview is the HIGHEST content gate, so the Detailed
  /// fixtures have to open it explicitly (its fresh default is private).
  Future<void> enableDetailedPreview() => privacyRepository
      .setNotificationPreviewMode(NotificationPreviewMode.showContent);

  Future<void> seedEvent() async {
    await calendar.saveEvent(
      profileId: profileId,
      draft: CalendarEventDraft(
        id: eventId,
        title: 'District Meeting',
        timing: CalendarEventTiming.timed,
        startDate: targetDate,
        startMinute: 14 * 60 + 10,
        endMinute: 15 * 60,
        timeZoneId: 'Asia/Manila',
        notes: eventNotes,
        requiresReport: false,
      ),
    );
    // An explicit 10-minute policy makes the fixture independent of whatever
    // the fresh Planner settings say the Event default is.
    await foundation.upsertPolicy(
      ReminderPolicyFixture.event(eventId: eventId, profileId: profileId),
    );
  }

  Future<void> seedTask() async {
    await planner.saveTask(
      profileId: profileId,
      draft: PlannerTaskDraft(
        id: taskId,
        title: 'Call the supplier',
        dueDate: targetDate,
        dueMinute: 14 * 60 + 10,
        requiresReport: false,
      ),
    );
    await foundation.upsertPolicy(
      ReminderPolicyFixture.task(taskId: taskId, profileId: profileId),
    );
  }

  Future<String?> lastNativeBody() async =>
      gateway.scheduled.isEmpty ? null : gateway.scheduled.last.body;

  Future<String?> lastNativeTitle() async =>
      gateway.scheduled.isEmpty ? null : gateway.scheduled.last.title;

  setUp(() async {
    database = openMemoryDatabase();
    profileId = (await buildTestRepository(
      database: database,
    ).completeOnboarding()).id;
    final clock = FixedClock(DateTime.utc(2026, 9, 19, 4));
    calendar = DriftCalendarEventRepository(
      database: database,
      clock: clock,
      timeZones: IanaCalendarEventTimeZones(displayTimeZoneId: 'Asia/Manila'),
    );
    planner = DriftPlannerRepository(database: database, clock: clock);
    foundation = DriftNotificationFoundationRepository(
      database: database,
      clock: clock,
    );
    privacyRepository = DriftPrivacyRepository(
      database: database,
      clock: clock,
    );
    gateway = _RecordingGateway();
    workerRegistrations = <String>[];
    targetDate = twoDaysAhead();
    await enableDelivery();
    await enableDetailedPreview();
  });

  tearDown(() => database.close());

  group('N1 — the native transport honours the saved field choices', () {
    test(
      'a field that is OFF never appears in the pre-rendered body',
      () async {
        await seedEvent();
        await setDetailed(
          const DetailedContentPreferences(
            showTitle: true,
            showDescription: false,
            showTime: false,
            showContacts: false,
            showLocation: false,
          ),
        );
        final container = await buildContainer();
        await container
            .read(calendarEventControllerProvider.notifier)
            .reconcileEventHorizon();

        expect(
          gateway.scheduled,
          hasLength(1),
          reason: 'a plain Event (no location, no People) stays on native',
        );
        expect(await lastNativeTitle(), 'District Meeting');
        expect(
          await lastNativeBody(),
          ReminderNotificationRenderer.genericBody,
          reason: 'every body field was switched off, so only the title shows',
        );
      },
    );

    test('the enabled fields appear and the disabled ones do not', () async {
      await seedEvent();
      await setDetailed(
        const DetailedContentPreferences(
          showTitle: true,
          showDescription: true,
          showTime: false,
          showContacts: false,
          showLocation: false,
        ),
      );
      final container = await buildContainer();
      await container
          .read(calendarEventControllerProvider.notifier)
          .reconcileEventHorizon();

      final body = await lastNativeBody();
      expect(body, contains(eventNotes));
      expect(
        body,
        isNot(matches(RegExp(r'\d{1,2}:\d{2} [AP]M'))),
        reason: 'Show time was OFF, so no time range may be rendered',
      );
    });

    test('Show time ON renders the range and Show description OFF hides '
        'the notes', () async {
      await seedEvent();
      await setDetailed(
        const DetailedContentPreferences(
          showDescription: false,
          showTime: true,
        ),
      );
      final container = await buildContainer();
      await container
          .read(calendarEventControllerProvider.notifier)
          .reconcileEventHorizon();

      final body = await lastNativeBody();
      expect(body, isNot(contains(eventNotes)));
      expect(body, contains('2:10 PM'));
    });

    // POST-P2 OWNER DECISION (2026-09-22): this case pinned the retired
    // "Detailed Content" master as the source of the neutral copy. That master
    // is gone — "Notification preview" is the one generic-vs-detailed authority
    // — and its column reads as the EFFECTIVE value TRUE, so a legacy stored
    // `false` must NOT strand a reminder on the neutral copy. The Generic copy
    // itself is still delivered from the privacy gate, covered by
    // 'a privacy-private preview produces the Generic copy whatever the field
    // toggles say' below.
    test(
      'a legacy Detailed Content master OFF still delivers its own copy',
      () async {
        await seedEvent();
        // The exact legacy row the owner is worried about.
        await setDetailed(const DetailedContentPreferences(enabled: false));
        final container = await buildContainer();
        await container
            .read(calendarEventControllerProvider.notifier)
            .reconcileEventHorizon();

        expect(gateway.scheduled, hasLength(1));
        expect(
          await lastNativeTitle(),
          'District Meeting',
          reason:
              'the retired master can no longer suppress the saved content; '
              'only the privacy gate can',
        );
      },
    );

    test('all five fields OFF is the neutral Generic copy', () async {
      await seedEvent();
      await setDetailed(
        const DetailedContentPreferences(
          showTitle: false,
          showDescription: false,
          showTime: false,
          showContacts: false,
          showLocation: false,
        ),
      );
      final container = await buildContainer();
      await container
          .read(calendarEventControllerProvider.notifier)
          .reconcileEventHorizon();

      expect(
        await lastNativeTitle(),
        ReminderNotificationRenderer.genericTitle,
      );
      expect(await lastNativeBody(), ReminderNotificationRenderer.genericBody);
    });

    test('a privacy-private preview produces the Generic copy whatever the '
        'field toggles say', () async {
      await seedEvent();
      await setDetailed(const DetailedContentPreferences());
      await privacyRepository.setNotificationPreviewMode(
        NotificationPreviewMode.hidden,
      );
      final container = await buildContainer();
      await container
          .read(calendarEventControllerProvider.notifier)
          .reconcileEventHorizon();

      expect(
        await lastNativeTitle(),
        ReminderNotificationRenderer.genericTitle,
      );
      expect(await lastNativeBody(), ReminderNotificationRenderer.genericBody);
    });

    test(
      'N1-G — changing a Show toggle refreshes the already-scheduled copy',
      () async {
        await seedEvent();
        await setDetailed(
          const DetailedContentPreferences(
            showDescription: false,
            showTime: false,
          ),
        );
        final container = await buildContainer();
        final controller = container.read(
          calendarEventControllerProvider.notifier,
        );
        await controller.reconcileEventHorizon();
        expect(gateway.scheduled, hasLength(1));
        expect(await lastNativeBody(), isNot(contains(eventNotes)));

        // The owner flips Show description ON.  The reminder is already
        // scheduled, so only a participating render revision can refresh it.
        await setDetailed(
          const DetailedContentPreferences(
            showDescription: true,
            showTime: false,
          ),
        );
        await controller.reconcileEventHorizon();

        expect(
          gateway.scheduled,
          hasLength(2),
          reason: 'the same notification identity must be re-rendered in place',
        );
        expect(await lastNativeBody(), contains(eventNotes));
      },
    );
  });

  group('N2 — a Task with attached People reaches the live-read transport', () {
    Future<void> attachTaskContact() => database
        .into(database.taskContactLinks)
        .insert(
          TaskContactLinksCompanion.insert(
            id: 'task-link-1',
            profileId: profileId,
            taskId: taskId,
            contactId: 'contact-juan',
            createdAtUtc: DateTime.utc(2026, 9, 1),
          ),
        );

    Future<void> seedContact() => database
        .into(database.contacts)
        .insert(
          ContactsCompanion.insert(
            id: 'contact-juan',
            profileId: profileId,
            displayName: 'Juan Dela Cruz',
            lifecycleState: const Value<String>('active'),
            createdAtUtc: DateTime.utc(2026, 9, 1),
            updatedAtUtc: DateTime.utc(2026, 9, 1),
          ),
        );

    test('a Task without People stays on the native transport and honours '
        'the field toggles', () async {
      await seedTask();
      await setDetailed(
        const DetailedContentPreferences(
          showTitle: true,
          showDescription: false,
          showTime: false,
          showContacts: true,
          showLocation: true,
        ),
      );
      final container = await buildContainer();
      await container
          .read(plannerControllerProvider.notifier)
          .reconcileTaskReminderHorizon();

      expect(workerRegistrations, isEmpty);
      expect(gateway.scheduled, hasLength(1));
      expect(await lastNativeTitle(), 'Call the supplier');
    });

    test(
      'attached People promote the Task to the live-read transport',
      () async {
        await seedTask();
        await seedContact();
        await attachTaskContact();
        await setDetailed(const DetailedContentPreferences());
        final container = await buildContainer();
        await container
            .read(plannerControllerProvider.notifier)
            .reconcileTaskReminderHorizon();

        expect(
          workerRegistrations,
          isNotEmpty,
          reason: 'a pre-rendered native body could never carry a live name',
        );
        expect(
          workerRegistrations.single,
          contains('m7w_'),
          reason: 'the durable revision must record the worker transport',
        );
        expect(
          gateway.scheduled,
          isEmpty,
          reason: 'one logical reminder keeps exactly one delivery owner',
        );
      },
    );

    // POST-P2 OWNER DECISION (2026-09-22): see the N1 note above — the retired
    // master is no longer an authority, so a legacy `false` must not strand a
    // Task on the neutral copy either.
    test('a legacy Master-OFF Task still schedules its own copy', () async {
      await seedTask();
      await setDetailed(const DetailedContentPreferences(enabled: false));
      final container = await buildContainer();
      await container
          .read(plannerControllerProvider.notifier)
          .reconcileTaskReminderHorizon();

      expect(await lastNativeTitle(), 'Call the supplier');
    });
  });

  group('the revision token is run-stable', () {
    test('equal options produce equal tokens and different options differ', () {
      const all = ReminderDetailOptions.all;
      expect(all.revisionToken, ReminderDetailOptions.all.revisionToken);
      expect(all.revisionToken, hasLength(5));
      expect(
        all.copyWith(showTitle: false).revisionToken,
        isNot(all.revisionToken),
      );
      expect(
        all.copyWith(showContacts: false).revisionToken,
        isNot(all.copyWith(showTime: false).revisionToken),
        reason: 'each field must occupy its own position in the token',
      );
    });
  });
}

/// A deterministic policy fixture so the fixtures do not depend on the fresh
/// global defaults.
abstract final class ReminderPolicyFixture {
  static ReminderPolicy event({
    required String eventId,
    required String profileId,
  }) => ReminderPolicy(
    id: 'policy-event',
    profileId: profileId,
    sourceKind: ReminderSourceKind.calendarEvent,
    sourceId: eventId,
    occurrenceId: ReminderPolicy.seriesOccurrenceId,
    purpose: ReminderPurpose.standard,
    mode: ReminderPolicyMode.offset,
    offsetMinutes: 10,
    createdAtUtc: DateTime.utc(2026, 9, 1),
    updatedAtUtc: DateTime.utc(2026, 9, 1),
  );

  static ReminderPolicy task({
    required String taskId,
    required String profileId,
  }) => ReminderPolicy(
    id: 'policy-task',
    profileId: profileId,
    sourceKind: ReminderSourceKind.task,
    sourceId: taskId,
    occurrenceId: ReminderPolicy.seriesOccurrenceId,
    purpose: ReminderPurpose.standard,
    mode: ReminderPolicyMode.offset,
    offsetMinutes: 10,
    createdAtUtc: DateTime.utc(2026, 9, 1),
    updatedAtUtc: DateTime.utc(2026, 9, 1),
  );
}
