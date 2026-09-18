import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:rmplanner/app/next_transfer_app.dart';
import 'package:rmplanner/app/router/app_router.dart';
import 'package:rmplanner/app/router/route_names.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/ids/identifier_source.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/contacts/data/drift_contact_repository.dart';
import 'package:rmplanner/features/contacts/domain/contact.dart';
import 'package:rmplanner/features/notifications/data/drift_notification_foundation_repository.dart';
import 'package:rmplanner/features/notifications/domain/contact_follow_up_creation_intent.dart';
import 'package:rmplanner/features/notifications/domain/notification_preferences.dart'
    as domain_prefs;
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/presentation/calendar_event_form_screen.dart';
import 'package:rmplanner/features/planner/presentation/task_form_screen.dart';
import 'package:rmplanner/features/privacy/domain/permission_summary.dart';

import '../../../support/test_dependencies.dart';

/// Contract §24/T-B widget suite (T9/T10/T11/T12/T14-OAT14): the ONLY M7
/// provenance carrier is the typed [ContactFollowUpCreationIntent] extra built
/// by ContactDetailScreen._createFollowUp; ordinary contacts= creation stays
/// ordinary; unknown/malformed extras fail closed; unsaved cancel/back writes
/// nothing; finalize failure keeps the form open with the same stable source
/// ID and the exact SnackBar copy.
///
/// Each contract clause runs in its own app instance: the chooser sheet's
/// close transition overlaps badly with same-test re-navigation (duplicate
/// GlobalKeys), so per-test isolation is the house pattern.
const _contactId = 'e1000000-0000-4000-8000-000000000102';

class _Harness {
  _Harness({
    required this.database,
    required this.router,
    required this.profileId,
  });

  final AppDatabase database;
  final GoRouter router;
  final String profileId;
}

Future<_Harness> _pumpApp(
  WidgetTester tester, {
  String? existingContactId,
}) async {
  const today = PlannerDate(year: 2026, month: 8, day: 31);
  final database = openMemoryDatabase();
  addTearDown(database.close);
  final startup = buildTestRepository(database: database);
  final profile = await startup.completeOnboarding();
  final privacy = TestPrivacyDependencies(
    database: database,
    permissionGateway: FakePermissionGateway(
      states: <OptionalPermission, OperatingSystemPermissionState>{
        OptionalPermission.notifications: OperatingSystemPermissionState.granted,
      },
    ),
  );
  // The reconciler gates on master + Event category preferences; the fresh
  // profile starts with all of them disabled, so the follow-up save's
  // reconcile step would be a silent no-op without this.
  await DriftNotificationFoundationRepository(
    database: database,
    clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
  ).savePreferences(
    profileId: profile.id,
    preferences: domain_prefs.NotificationPreferences.defaults().copyWith(
      systemNotificationsEnabled: true,
      eventRemindersEnabled: true,
    ),
  );
  final contacts = DriftContactRepository(
    database: database,
    clock: FixedClock(DateTime.utc(2026, 8, 31, 2)),
    identifiers: UuidIdentifierSource(),
  );
  if (existingContactId != null) {
    await contacts.createContact(
      profileId: profile.id,
      draft: const ContactDraft(
        id: _contactId,
        firstName: 'Fiona',
        lastName: 'Followup',
        displayName: 'Fiona Followup',
        preferredContactMethod: ContactPreferredMethod.message,
        isFavorite: false,
      ),
    );
  }

  await tester.pumpWidget(
    privacy.buildApp(
      environment: const AppEnvironment(
        name: AppEnvironmentName.production,
        label: 'PRODUCTION',
      ),
      diagnostics: SanitizedDiagnostics(),
      startupRepository: startup,
      contactRepository: contacts,
      plannerDateSource: const FixedPlannerDateSource(today),
    ),
  );
  await tester.pumpAndSettle();
  final container = ProviderScope.containerOf(
    tester.element(find.byType(NextTransferApp)),
  );
  return _Harness(
    database: database,
    router: container.read(appRouterProvider),
    profileId: profile.id,
  );
}

Future<void> _pumpUntil(
  WidgetTester tester,
  Finder finder, {
  int attempts = 40,
}) async {
  for (var attempt = 0; attempt < attempts; attempt++) {
    await tester.pump(const Duration(milliseconds: 100));
    if (finder.evaluate().isNotEmpty) {
      return;
    }
  }
  fail('Timed out waiting for $finder');
}

Future<void> _pumpUntilGone(
  WidgetTester tester,
  Finder finder, {
  int attempts = 40,
}) async {
  for (var attempt = 0; attempt < attempts; attempt++) {
    await tester.pump(const Duration(milliseconds: 100));
    if (finder.evaluate().isEmpty) {
      return;
    }
  }
  fail('Timed out waiting for $finder to disappear');
}

/// Transition pumps interleaved with real-time drains: drift table-update
/// notifications (Goals watchChanges listens to calendarEvents) resume the
/// form's paused Riverpod subscriptions on real event-loop turns.  If a
/// notification lands while TickerMode transitions flush those subscriptions
/// mid-build, Riverpod raises markNeedsBuild-during-build.  Giving every
/// frame a real-time window keeps notifications between frames.
Future<void> _pumpTransition(WidgetTester tester, int frames) async {
  for (var i = 0; i < frames; i++) {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 16));
    });
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// Let every scheduled frame run to completion so provider invalidations
/// land between frames, never mid-build.  The settle is best-effort and
/// STRICTLY bounded: the shell can host perpetually-animating widgets, and
/// the default 10-minute pumpAndSettle timeout would stall the suite.
Future<void> _pumpFramesQuietly(WidgetTester tester) async {
  try {
    await tester.pumpAndSettle(
      const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 2),
    );
  } on Object {
    // Shell animation never idles; subsequent pumps handle the rest.
  }
}

/// Let the tapped save's full async chain (DB writes, policy persist,
/// People commit, finalize, reconcile) finish in REAL time before any
/// transition frame ticks.  Drift completions arrive on real event-loop
/// turns that fake-async pumps cannot flush; without this drain they land
/// mid-build during the close transition (markNeedsBuild-during-build).
Future<void> _drainSaveChain(WidgetTester tester) async {
  for (var slice = 0; slice < 24; slice++) {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
  }
}

/// Fixed pumps only: the app shell contains a perpetually-animating widget,
/// so pumpAndSettle never settles.  The save tests use the static
/// ProtectedContent screen as the pushed-route base: a live shell route
/// beneath a pushed page pauses its Riverpod subscriptions, and resuming
/// them mid-pop flushes provider notifications during build
/// (markNeedsBuild-during-build).  The static screen watches no drift
/// streams, so the pop stays quiet.
Future<void> _goToBaseThenPush(
  WidgetTester tester,
  GoRouter router,
  String location, {
  Object? extra,
  bool useProtectedBase = false,
}) async {
  router.go(useProtectedBase ? RoutePaths.protectedContent : RoutePaths.planner);
  await tester.pump(const Duration(milliseconds: 600));
  await tester.pump(const Duration(milliseconds: 200));
  unawaited(router.push(location, extra: extra));
  await tester.pump(const Duration(milliseconds: 600));
  await tester.pump(const Duration(milliseconds: 200));
}

/// The house close pattern: invoke the header IconButton's callback directly
/// (the sheet header sits under the status bar in tests), then pump past the
/// sheet's exit transition.  Every create route is pushed over the home base,
/// so the close pop always leaves a page on the stack.
Future<void> _closeEventSheet(WidgetTester tester) async {
  tester
      .widget<IconButton>(
        find.byKey(const Key('calendar-event-sheet-close')),
      )
      .onPressed
      ?.call();
  await tester.pump(const Duration(milliseconds: 600));
  await _pumpUntilGone(tester, find.byType(CalendarEventFormScreen));
}

/// The Task form's close button pops the navigator page; the create route is
/// always pushed over the home base, so the pop stays healthy.
Future<void> _closeTaskForm(WidgetTester tester) async {
  tester
      .widget<IconButton>(find.byKey(const Key('task-form-close')))
      .onPressed
      ?.call();
  await tester.pump(const Duration(milliseconds: 600));
  await _pumpUntilGone(tester, find.byType(TaskFormScreen));
}

/// Opens the Contact Detail chooser and picks Calendar Event; the picker
/// dialog opens before its option list resolves, so wait for the concrete
/// option tile.
Future<void> _openChooserAndPickEvent(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 400));
  await tester.scrollUntilVisible(
    find.byKey(const Key('create-follow-up')),
    400,
    scrollable: find.descendant(
      of: find.byKey(const Key('contact-profile-tab')),
      matching: find.byType(Scrollable),
    ),
  );
  await tester.tap(find.byKey(const Key('create-follow-up')));
  await _pumpUntil(tester, find.byKey(const Key('follow-up-event')));
  // Let the bottom sheet finish its slide-up before tapping a tile.
  await tester.pump(const Duration(milliseconds: 400));
  await tester.tap(find.byKey(const Key('follow-up-event')));
  await tester.pump();
  await _pumpUntil(
    tester,
    find.byKey(const Key('event-type-option-job_application')),
  );
  await tester.tap(
    find.byKey(const Key('event-type-option-job_application')),
  );
  await _pumpUntil(tester, find.byType(CalendarEventFormScreen));
}

Future<void> _openChooserAndPickTask(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 400));
  await tester.scrollUntilVisible(
    find.byKey(const Key('create-follow-up')),
    400,
    scrollable: find.descendant(
      of: find.byKey(const Key('contact-profile-tab')),
      matching: find.byType(Scrollable),
    ),
  );
  await tester.tap(find.byKey(const Key('create-follow-up')));
  await _pumpUntil(tester, find.byKey(const Key('follow-up-task')));
  // Let the bottom sheet finish its slide-up before tapping a tile.
  await tester.pump(const Duration(milliseconds: 400));
  await tester.tap(find.byKey(const Key('follow-up-task')));
  await tester.pump();
  await _pumpUntil(tester, find.byType(TaskFormScreen));
}

/// Unmount in place after every route has settled; no navigation here —
/// unmounting mid-transition corrupts the go_router element tree.
Future<void> _unmountApp(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 600));
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  testWidgets(
    'T11-ordinary: contacts= preselection alone is ordinary creation with no typed provenance',
    (tester) async {
      final harness = await _pumpApp(tester, existingContactId: _contactId);
      await _goToBaseThenPush(
        tester,
        harness.router,
        '${RoutePaths.calendarEventCreate}?contacts=$_contactId',
      );
      await _pumpUntil(
        tester,
        find.byKey(const Key('event-type-option-job_application')),
      );
      await tester.tap(
        find.byKey(const Key('event-type-option-job_application')),
      );
      await _pumpUntil(tester, find.byType(CalendarEventFormScreen));
      expect(tester.takeException(), isNull);
      final form = tester
          .widgetList<CalendarEventFormScreen>(
            find.byType(CalendarEventFormScreen),
          )
          .firstOrNull;
      expect(form, isNotNull);
      expect(form!.followUpContactId, isNull);
      await _closeEventSheet(tester);
      expect(tester.takeException(), isNull);
      await _unmountApp(tester);
    },
  );

  testWidgets(
    'T11-fails-closed: a malformed extra is not the typed intent',
    (tester) async {
      final harness = await _pumpApp(tester, existingContactId: _contactId);
      await _goToBaseThenPush(
        tester,
        harness.router,
        RoutePaths.calendarEventCreate,
        extra: const <String, String>{'not': 'a typed intent'},
      );
      await _pumpUntil(
        tester,
        find.byKey(const Key('event-type-option-job_application')),
      );
      await tester.tap(
        find.byKey(const Key('event-type-option-job_application')),
      );
      await _pumpUntil(tester, find.byType(CalendarEventFormScreen));
      expect(tester.takeException(), isNull);
      final form = tester
          .widgetList<CalendarEventFormScreen>(
            find.byType(CalendarEventFormScreen),
          )
          .firstOrNull;
      expect(form, isNotNull);
      expect(form!.followUpContactId, isNull);
      await _closeEventSheet(tester);
      expect(tester.takeException(), isNull);
      await _unmountApp(tester);
    },
  );

  testWidgets(
    'T20-ordinary: plain Task creation never carries the typed intent',
    (tester) async {
      final harness = await _pumpApp(tester, existingContactId: _contactId);
      await _goToBaseThenPush(
        tester,
        harness.router,
        '${RoutePaths.taskCreate}?contacts=$_contactId',
      );
      await _pumpUntil(tester, find.byType(TaskFormScreen));
      expect(tester.takeException(), isNull);
      final form = tester
          .widgetList<TaskFormScreen>(find.byType(TaskFormScreen))
          .firstOrNull;
      expect(form, isNotNull);
      expect(form!.followUpContactId, isNull);
      await _closeTaskForm(tester);
      expect(tester.takeException(), isNull);
      await _unmountApp(tester);
    },
  );

  testWidgets(
    'T9: the Contact chooser routes the typed intent into the Event form',
    (tester) async {
      final harness = await _pumpApp(tester, existingContactId: _contactId);
      await _goToBaseThenPush(
        tester,
        harness.router,
        RoutePaths.contactDetail(_contactId),
      );
      await _openChooserAndPickEvent(tester);
      expect(tester.takeException(), isNull);
      final form = tester
          .widgetList<CalendarEventFormScreen>(
            find.byType(CalendarEventFormScreen),
          )
          .firstOrNull;
      expect(form, isNotNull);
      expect(form!.followUpContactId, _contactId);
      await _closeEventSheet(tester);
      await _unmountApp(tester);
    },
  );

  testWidgets(
    'T12-event: cancel/back from the unsaved Event form writes nothing',
    (tester) async {
      final harness = await _pumpApp(tester, existingContactId: _contactId);
      await _goToBaseThenPush(
        tester,
        harness.router,
        RoutePaths.contactDetail(_contactId),
      );
      await _openChooserAndPickEvent(tester);
      final form = tester
          .widgetList<CalendarEventFormScreen>(
            find.byType(CalendarEventFormScreen),
          )
          .firstOrNull;
      expect(form, isNotNull);
      expect(form!.followUpContactId, _contactId);

      Future<int> tableCount(dynamic table) => harness.database
          .select(table)
          .get()
          .then((rows) => rows.length);

      await _closeEventSheet(tester);
      expect(
        await tableCount(harness.database.reminderPolicies),
        0,
        reason: 'T12: unsaved form wrote no policy',
      );
      expect(
        await tableCount(harness.database.backgroundWorkRequests),
        0,
        reason: 'T12: unsaved form wrote no work',
      );
      expect(
        await tableCount(harness.database.calendarEvents),
        0,
        reason: 'T12: unsaved form wrote no Event',
      );
      await _unmountApp(tester);
    },
  );

  testWidgets(
    'T10: the same chooser routes the typed intent into the Task form',
    (tester) async {
      final harness = await _pumpApp(tester, existingContactId: _contactId);
      await _goToBaseThenPush(
        tester,
        harness.router,
        RoutePaths.contactDetail(_contactId),
      );
      await _openChooserAndPickTask(tester);
      expect(tester.takeException(), isNull);
      final form = tester
          .widgetList<TaskFormScreen>(find.byType(TaskFormScreen))
          .firstOrNull;
      expect(form, isNotNull);
      expect(form!.followUpContactId, _contactId);
      await _closeTaskForm(tester);
      await _unmountApp(tester);
    },
  );

  testWidgets(
    'T12-task: cancel/back from the unsaved Task form writes nothing',
    (tester) async {
      final harness = await _pumpApp(tester, existingContactId: _contactId);
      await _goToBaseThenPush(
        tester,
        harness.router,
        RoutePaths.contactDetail(_contactId),
      );
      await _openChooserAndPickTask(tester);
      final form = tester
          .widgetList<TaskFormScreen>(find.byType(TaskFormScreen))
          .firstOrNull;
      expect(form, isNotNull);
      expect(form!.followUpContactId, _contactId);

      await _closeTaskForm(tester);
      expect(
        await harness.database
            .select(harness.database.reminderPolicies)
            .get()
            .then((rows) => rows.length),
        0,
      );
      expect(
        await harness.database
            .select(harness.database.backgroundWorkRequests)
            .get()
            .then((rows) => rows.length),
        0,
      );
      await _unmountApp(tester);
    },
  );

  testWidgets(
    'T9 success: chooser-sourced follow-up save persists explicit source-level purpose and closes the form',
    (tester) async {
      final harness = await _pumpApp(tester, existingContactId: _contactId);
      // The chooser's `.then` handler performs exactly this typed-intent
      // push (contact_detail_screen.dart `_createFollowUp`), so driving it
      // directly exercises the identical provenance and save path while
      // keeping no live DB-watching page beneath the form when it pops.
      // The chooser→intent routing itself is covered by the T9 test above.
      // The date param keeps the occurrence inside the reconciler's future
      // horizon (the suite's fixed planner date is static while the
      // reconciler reads the real system clock).
      await _goToBaseThenPush(
        tester,
        harness.router,
        '${RoutePaths.calendarEventCreate}?date=2026-10-15',
        extra: const ContactFollowUpCreationIntent(contactId: _contactId),
        useProtectedBase: true,
      );
      // The create route lands on the type-picker gate; job_application is
      // the seeded approved option used across this suite.
      await _pumpUntil(
        tester,
        find.byKey(const Key('event-type-option-job_application')),
      );
      await tester.tap(
        find.byKey(const Key('event-type-option-job_application')),
      );
      await _pumpUntil(tester, find.byType(CalendarEventFormScreen));
      expect(tester.takeException(), isNull);
      final form = tester
          .widgetList<CalendarEventFormScreen>(
            find.byType(CalendarEventFormScreen),
          )
          .firstOrNull;
      expect(form, isNotNull);
      expect(form!.followUpContactId, _contactId);

      await tester.enterText(
        find.byKey(const Key('event-title-field')),
        'Follow up with Fiona',
      );
      // Dismiss the keyboard so its inset does not push sheet content below
      // the viewport (an option at y=965 is untappable on a 600px surface).
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump(const Duration(milliseconds: 200));
      // Pick an explicit offset: the seeded planner default is null, so the
      // inherit mode yields no fire time and the reconciler would be a no-op.
      // The form body is a lazy ListView; the house scroll pattern brings
      // the Scheduling Details section into the build cache.
      final policyTile = find.byKey(const Key('event-reminder-policy'));
      await tester.scrollUntilVisible(
        policyTile,
        300,
        scrollable: find
            .descendant(
              of: find.byKey(const Key('calendar-event-form-scroll')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await _pumpFramesQuietly(tester);
      await tester.tap(policyTile);
      await _pumpUntil(tester, find.text('15 minutes before'));
      await _pumpFramesQuietly(tester);
      final option = find.text('15 minutes before');
      await tester.scrollUntilVisible(
        option,
        200,
        scrollable: find.byType(Scrollable).last,
      );
      await _pumpFramesQuietly(tester);
      await tester.tap(option);
      await _pumpFramesQuietly(tester);
      final save = find.byKey(const Key('save-event-button'));
      await tester.scrollUntilVisible(
        save,
        300,
        scrollable: find
            .descendant(
              of: find.byKey(const Key('calendar-event-form-scroll')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await _pumpFramesQuietly(tester);
      await tester.tap(save);
      await _drainSaveChain(tester);
      await _pumpFramesQuietly(tester);
      await _pumpTransition(tester, 20);
      await _pumpUntilGone(
        tester,
        find.byType(CalendarEventFormScreen),
        attempts: 60,
      );
      await _pumpTransition(tester, 20);
      expect(tester.takeException(), isNull);

      // §8 step 4: the save persisted the explicit source-level purpose.
      final policies = await harness.database
          .select(harness.database.reminderPolicies)
          .get();
      expect(policies, hasLength(1));
      expect(policies.single.sourceKind, 'calendarEvent');
      expect(policies.single.purpose, 'contactFollowUp');
      expect(policies.single.contactId, _contactId);
      expect(policies.single.occurrenceId, 'series');
      // §8 step 5: the reconciled source produced durable work rows.
      final workRows = await harness.database
          .select(harness.database.backgroundWorkRequests)
          .get();
      expect(workRows, isNotEmpty);
      await _unmountApp(tester);
    },
  );

  testWidgets(
    'T14/OAT14: finalize failure keeps the form open with the same stable source ID and the exact SnackBar copy; retry never mints a duplicate source',
    (tester) async {
      const missingContactId = 'e1000000-0000-4000-8000-000000000999';
      final harness = await _pumpApp(tester);
      await _goToBaseThenPush(
        tester,
        harness.router,
        RoutePaths.calendarEventCreate,
        extra: const ContactFollowUpCreationIntent(contactId: missingContactId),
        useProtectedBase: true,
      );
      await _pumpUntil(
        tester,
        find.byKey(const Key('event-type-option-job_application')),
      );
      await tester.tap(
        find.byKey(const Key('event-type-option-job_application')),
      );
      await _pumpUntil(tester, find.byType(CalendarEventFormScreen));
      expect(tester.takeException(), isNull);
      final form = tester
          .widgetList<CalendarEventFormScreen>(
            find.byType(CalendarEventFormScreen),
          )
          .firstOrNull;
      expect(form, isNotNull);
      expect(form!.followUpContactId, missingContactId);

      Future<int> eventRowCount() => harness.database
          .select(harness.database.calendarEvents)
          .get()
          .then((rows) => rows.length);

      // First save: Event commits, finalize fails closed.
      final save = find.byKey(const Key('save-event-button'));
      await tester.scrollUntilVisible(
        save,
        300,
        scrollable: find
            .descendant(
              of: find.byKey(const Key('calendar-event-form-scroll')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await _pumpFramesQuietly(tester);
      await tester.tap(save);
      await _drainSaveChain(tester);
      await _pumpFramesQuietly(tester);
      await _pumpUntil(
        tester,
        find.text('Saved, but follow-up could not be applied. Try again.'),
        attempts: 60,
      );
      expect(tester.takeException(), isNull);
      // The form stays open for retry with the same stable draft.
      expect(find.byType(CalendarEventFormScreen), findsOneWidget);
      // The Event itself was saved exactly once (no source rollback, no
      // duplicate mint), the explicit purpose was persisted, but the
      // deferred reconcile never scheduled anything.
      expect(await eventRowCount(), 1);
      final policies = await harness.database
          .select(harness.database.reminderPolicies)
          .get();
      expect(policies, hasLength(1));
      expect(policies.single.purpose, 'contactFollowUp');
      expect(policies.single.contactId, missingContactId);
      final workRows = await harness.database
          .select(harness.database.backgroundWorkRequests)
          .get();
      expect(workRows, isEmpty);

      // Let the SnackBar's own timer retire it (4s + exit animation) so the
      // retry tap reaches the save button.
      await tester.pump(const Duration(seconds: 4));
      await tester.pump(const Duration(milliseconds: 600));
      expect(
        find.text('Saved, but follow-up could not be applied. Try again.'),
        findsNothing,
      );

      // Retry: the form re-uses the same stable source ID — still exactly
      // one Event row after the second save attempt.
      await tester.ensureVisible(save);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(save);
      await _drainSaveChain(tester);
      await _pumpFramesQuietly(tester);
      await _pumpUntil(
        tester,
        find.text('Saved, but follow-up could not be applied. Try again.'),
        attempts: 60,
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(CalendarEventFormScreen), findsOneWidget);
      expect(await eventRowCount(), 1);
      final policiesAfterRetry = await harness.database
          .select(harness.database.reminderPolicies)
          .get();
      expect(policiesAfterRetry, hasLength(1));
      expect(policiesAfterRetry.single.contactId, missingContactId);
      await _unmountApp(tester);
    },
  );
}
