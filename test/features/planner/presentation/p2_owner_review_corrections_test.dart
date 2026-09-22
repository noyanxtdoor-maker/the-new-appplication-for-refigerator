// P2 OWNER-REVIEW CORRECTION PACK (2026-09-22).
//
// The owner physically reviewed the installed P2 build and found two items:
//
// A. SETTINGS LAYOUT REGRESSION. The "Time snapping" and "Open timeline at"
//    rows overlapped in Planner & Calendar settings.
//
//    Proven source: the P2-D relocation moved the "24-hour time" tile from the
//    Timeline section into Display, and that tile's intrinsic height was the
//    ONLY thing separating the two dropdowns — `_Section` lays its children out
//    in a bare `Column` and every other pair on the screen carries its own
//    `SizedBox(height: 12)`. Measured on the pre-correction tree: the two field
//    boxes were exactly adjacent (gap 0.00) and the lower field's floating
//    "Open timeline at" label was drawn 5.5 px INSIDE the upper field's box,
//    because this app themes its fields with `OutlineInputBorder`, whose label
//    straddles the box's top edge. With the restored 12 dp rhythm the measured
//    gap is 12.00 and the label clears the field above by 6.5 px.
//
// B. CONTACT TYPE VISUALS. Each Contact Type option now carries a visual cue.
//    This is PRESENTATION ONLY: the stable keys, schema 49 and the stored
//    `contact_channel` value are untouched, and the mapping is keyed off the
//    channel so it can never alter what is saved.
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/planner/data/calendar_event_time_zones.dart';
import 'package:rmplanner/features/planner/data/drift_calendar_event_repository.dart';
import 'package:rmplanner/features/planner/data/drift_event_type_repository.dart';
import 'package:rmplanner/features/planner/data/drift_outcome_reporting_repository.dart';
import 'package:rmplanner/features/planner/data/drift_planner_repository.dart';
import 'package:rmplanner/features/planner/data/drift_task_event_link_repository.dart';
import 'package:rmplanner/features/planner/domain/calendar_event.dart';
import 'package:rmplanner/features/planner/domain/event_contact_channel.dart';
import 'package:rmplanner/features/planner/domain/event_type.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/presentation/calendar_event_detail_screen.dart';
import 'package:rmplanner/features/planner/presentation/calendar_event_form_screen.dart';
import 'package:rmplanner/features/planner/presentation/planner_settings_screen.dart';
import 'package:rmplanner/features/planner/presentation/widgets/event_contact_channel_visuals.dart';
import 'package:rmplanner/features/privacy/domain/permission_summary.dart';

import '../../../support/test_dependencies.dart';

const String _eventId = 'aaaaaaaa-2222-4222-8222-222222222201';

final PlannerDate _utcToday = PlannerDate.fromDateTime(DateTime.now().toUtc());

/// The REAL seeded system Contact type, so a fixture never invents an Event
/// Type identity (an unresolvable snapshot would be re-resolved on save).
Future<({String id, String label})> _contactType(AppDatabase database) async {
  final row = await database
      .customSelect(
        "SELECT id, label FROM activity_types WHERE stable_key = 'contact' "
        'LIMIT 1',
      )
      .getSingle();
  return (id: row.read<String>('id'), label: row.read<String>('label'));
}

CalendarEventDraft _contactDraft({
  required PlannerDate date,
  required ({String id, String label}) contactType,
  int startMinute = 9 * 60,
  int endMinute = 10 * 60,
  String timeZoneId = 'Etc/UTC',
  EventContactChannel? channel,
}) {
  return CalendarEventDraft(
    id: _eventId,
    title: 'Call Maria',
    timing: CalendarEventTiming.timed,
    startDate: date,
    startMinute: startMinute,
    endMinute: endMinute,
    timeZoneId: timeZoneId,
    requiresReport: true,
    activityTypeId: contactType.id,
    activityTypeStableKeySnapshot: 'contact',
    activityTypeLabelSnapshot: contactType.label,
    contactChannel: channel,
  );
}

typedef _Repos = ({
  AppDatabase database,
  DriftPlannerRepository planner,
  DriftCalendarEventRepository calendar,
  String profileId,
});

Future<_Repos> _buildRepositories() async {
  final database = openMemoryDatabase();
  addTearDown(database.close);
  final clock = FixedClock(DateTime.utc(2026, 7, 27, 12));
  final timeZones = IanaCalendarEventTimeZones(
    displayTimeZoneId: 'Asia/Manila',
  );
  final linkRepository = DriftTaskEventLinkRepository(
    database: database,
    clock: clock,
  );
  final reportingRepository = DriftOutcomeReportingRepository(
    database: database,
    clock: clock,
  );
  final calendarRepository = DriftCalendarEventRepository(
    database: database,
    clock: clock,
    timeZones: timeZones,
    taskContextSource: linkRepository,
    linkContextTransfer: linkRepository,
    reportSource: reportingRepository,
  );
  final plannerRepository = DriftPlannerRepository(
    database: database,
    clock: clock,
    calendarSource: calendarRepository,
    taskContextSource: linkRepository,
    historicalEffectReader: reportingRepository,
  );
  final profile = await buildTestRepository(
    database: database,
  ).completeOnboarding();
  await DriftEventTypeRepository(
    database: database,
    clock: clock,
  ).readEventTypes(profileId: profile.id);
  return (
    database: database,
    planner: plannerRepository,
    calendar: calendarRepository,
    profileId: profile.id,
  );
}

/// Pumps the real app so every provider exists, then pushes the real screen
/// onto the navigator (the same screens the product opens).
Future<void> _pushOnApp(
  WidgetTester tester, {
  required _Repos repos,
  required PlannerDate originalDate,
  required Widget Function() builder,
}) async {
  final privacy = TestPrivacyDependencies(database: repos.database);
  await tester.pumpWidget(
    privacy.buildApp(
      environment: const AppEnvironment(
        name: AppEnvironmentName.production,
        label: 'PRODUCTION',
      ),
      diagnostics: SanitizedDiagnostics(),
      startupRepository: buildTestRepository(
        database: repos.database,
        privacyGate: privacy.gate,
      ),
      plannerRepository: repos.planner,
      calendarEventRepository: repos.calendar,
      plannerDateSource: FixedPlannerDateSource(originalDate),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('Planner'));
  await tester.pumpAndSettle();
  final anchor = tester.element(
    find.byKey(const Key('planner-date-picker-trigger')),
  );
  // The push future completes when the route closes, which is the behaviour
  // under test, so it is intentionally not awaited.
  _unawaitedPush(
    Navigator.of(
      anchor,
    ).push(MaterialPageRoute<void>(builder: (_) => builder())),
  );
  await tester.pumpAndSettle();
}

void _unawaitedPush(Future<void> future) {}

Future<void> _openEditForm(
  WidgetTester tester, {
  required _Repos repos,
  required PlannerDate originalDate,
}) => _pushOnApp(
  tester,
  repos: repos,
  originalDate: originalDate,
  builder: () => CalendarEventFormScreen.edit(
    eventId: _eventId,
    originalDate: originalDate,
    scope: CalendarEventEditScope.series,
  ),
);

/// A BRAND-NEW Contact Event, opened through the real create form.
Future<void> _openCreateForm(
  WidgetTester tester, {
  required _Repos repos,
  required PlannerDate date,
  required EventType contactType,
}) => _pushOnApp(
  tester,
  repos: repos,
  originalDate: date,
  builder: () => CalendarEventFormScreen.create(
    initialDate: date,
    initialEventType: contactType,
  ),
);

Future<void> _openDetailScreen(
  WidgetTester tester, {
  required _Repos repos,
  required PlannerDate originalDate,
}) => _pushOnApp(
  tester,
  repos: repos,
  originalDate: originalDate,
  builder: () =>
      CalendarEventDetailScreen(eventId: _eventId, originalDate: originalDate),
);

Future<CalendarEventRow> _storedRow(AppDatabase database, String eventId) =>
    (database.select(
      database.calendarEvents,
    )..where((table) => table.id.equals(eventId))).getSingle();

/// The real seeded Contact Event Type, so a create fixture uses a canonical
/// identity rather than an invented one.
Future<EventType> _contactEventType(_Repos repos) async {
  final types = await DriftEventTypeRepository(
    database: repos.database,
    clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
  ).readEventTypes(profileId: repos.profileId);
  return types.firstWhere(
    (type) => type.stableKey == SystemEventTypeKeys.contact,
  );
}

/// The owner's device class: a phone-sized surface.
void _sizeView(WidgetTester tester) {
  tester.view.physicalSize = const Size(862, 1824);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Opens Planner & Calendar settings through the real navigation, at a tall
/// surface so every card lays out without scrolling.
Future<void> _openPlannerSettings(WidgetTester tester) async {
  tester.view.physicalSize = const Size(431, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final database = openMemoryDatabase();
  addTearDown(database.close);
  final privacy = TestPrivacyDependencies(
    database: database,
    permissionGateway: FakePermissionGateway(
      states: const <OptionalPermission, OperatingSystemPermissionState>{
        OptionalPermission.notifications: OperatingSystemPermissionState.denied,
      },
    ),
  );
  final startup = buildTestRepository(
    database: database,
    privacyGate: privacy.gate,
  );
  await startup.completeOnboarding();
  await tester.pumpWidget(
    privacy.buildApp(
      environment: const AppEnvironment(
        name: AppEnvironmentName.production,
        label: 'PRODUCTION',
      ),
      diagnostics: SanitizedDiagnostics(),
      startupRepository: startup,
    ),
  );
  await tester.pumpAndSettle();

  await tester.tap(find.byKey(const Key('home-hamburger')));
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(
    find.byKey(const Key('drawer-account-settings')),
    200,
    scrollable: find.descendant(
      of: find.byKey(const Key('global-app-drawer-list')),
      matching: find.byType(Scrollable),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('drawer-account-settings')));
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(
    find.byKey(const Key('settings-planner-calendar')),
    160,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.tap(find.byKey(const Key('settings-planner-calendar')));
  await tester.pumpAndSettle();
  expect(find.byType(PlannerSettingsScreen), findsOneWidget);
}

void main() {
  group('A. Planner settings layout', () {
    testWidgets(
      'Time snapping and Open timeline at keep the screen rhythm and never '
      'overlap',
      (tester) async {
        await _openPlannerSettings(tester);

        final snap = tester.getRect(find.byKey(const Key('time-snap-setting')));
        final scroll = tester.getRect(
          find.byKey(const Key('initial-scroll-setting')),
        );

        // Pre-correction this gap measured exactly 0.00: the relocated 24-hour
        // tile had been the only widget between the two fields. Every other
        // adjacent pair on this screen carries the same 12 dp rhythm, including
        // the "Visible end hour" -> "Time snapping" pair the owner accepted.
        expect(
          scroll.top - snap.bottom,
          greaterThanOrEqualTo(12),
          reason:
              'the two dropdowns must keep the screen\'s 12 dp rhythm rather '
              'than being laid directly against each other',
        );

        // The exact owner symptom. This app themes fields with
        // OutlineInputBorder, so a floating label straddles its own box's top
        // edge; at gap 0 the "Open timeline at" label was drawn 5.5 px inside
        // the field above it.
        final lowerLabel = tester.getRect(find.text('Open timeline at'));
        expect(
          lowerLabel.top,
          greaterThanOrEqualTo(snap.bottom),
          reason:
              'the lower field\'s floating label must not reach into the field '
              'above it',
        );
      },
    );

    testWidgets('the layout also holds at a larger accessibility text scale', (
      tester,
    ) async {
      // The owner judges at normal accessibility defaults; this proves the fix
      // is not tuned to one text scale.
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await _openPlannerSettings(tester);

      final snap = tester.getRect(find.byKey(const Key('time-snap-setting')));
      final scroll = tester.getRect(
        find.byKey(const Key('initial-scroll-setting')),
      );
      expect(scroll.top - snap.bottom, greaterThanOrEqualTo(12));
      expect(
        tester.getRect(find.text('Open timeline at')).top,
        greaterThanOrEqualTo(snap.bottom),
      );
    });

    testWidgets(
      'the 24-hour toggle stays in Display, exactly once, in the approved '
      'order',
      (tester) async {
        await _openPlannerSettings(tester);

        expect(find.byKey(const Key('use-24-hour-setting')), findsOneWidget);
        expect(
          find.text('24-hour time'),
          findsOneWidget,
          reason: 'there is exactly one time-format control',
        );

        // It belongs to the Display card...
        final displayCard = find
            .ancestor(
              of: find.byKey(const Key('show-completed-setting')),
              matching: find.byType(Card),
            )
            .first;
        expect(
          find.descendant(
            of: displayCard,
            matching: find.byKey(const Key('use-24-hour-setting')),
          ),
          findsOneWidget,
          reason: 'Display order is 24-hour time, then Show completed events',
        );
        // ...and no longer to the Timeline card.
        final timelineCard = find
            .ancestor(
              of: find.byKey(const Key('time-snap-setting')),
              matching: find.byType(Card),
            )
            .first;
        expect(
          find.descendant(
            of: timelineCard,
            matching: find.byKey(const Key('use-24-hour-setting')),
          ),
          findsNothing,
        );

        final t24 = tester.getRect(
          find.byKey(const Key('use-24-hour-setting')),
        );
        final completed = tester.getRect(
          find.byKey(const Key('show-completed-setting')),
        );
        // Post-P2 owner decision (2026-09-22): the "Show cancelled items"
        // control was REMOVED, so the Display section is exactly two rows and
        // the ordering law is now 24-hour time -> Show completed events.
        expect(
          find.byKey(const Key('show-cancelled-setting')),
          findsNothing,
          reason: 'the cancelled control was removed by owner decision',
        );
        expect(
          find.text('Show completed events'),
          findsOneWidget,
          reason: 'the completed setting was renamed for truthfulness',
        );
        expect(t24.top, lessThan(completed.top));
        expect(completed.top, greaterThanOrEqualTo(t24.bottom));

        // "Open timeline at" is a separate setting and must still be present.
        expect(find.byKey(const Key('initial-scroll-setting')), findsOneWidget);
      },
    );
  });

  group('B. Contact Type visuals', () {
    testWidgets(
      'a legacy NULL channel reads as In Person, never as "Not set"',
      (tester) async {
        _sizeView(tester);
        final repos = await _buildRepositories();
        final date = _utcToday.addDays(-3);
        await repos.calendar.saveEvent(
          profileId: repos.profileId,
          // No contactChannel: a legacy schema-49 NULL row.
          draft: _contactDraft(
            contactType: await _contactType(repos.database),
            date: date,
          ),
        );

        await _openEditForm(tester, repos: repos, originalDate: date);

        // Owner revision (2026-09-22): "Not set" was removed completely, so a
        // Contact Event that never stored a channel presents as the default.
        expect(
          tester
              .widget<Text>(
                find.byKey(const Key('selected-contact-type-label')),
              )
              .data,
          'In Person',
        );
        final mark = find.descendant(
          of: find.byKey(const Key('selected-contact-type-visual')),
          matching: find.byType(Icon),
        );
        expect(mark, findsOneWidget);
        expect(
          tester.widget<Icon>(mark).icon,
          Icons.people_outline,
          reason:
              'In Person uses the generic Contacts/People glyph the Contacts '
              'surfaces already use',
        );
        expect(
          find.text('Not set'),
          findsNothing,
          reason: 'there is no such Contact Type any more',
        );

        // Rendering must not have written anything.
        final row = await _storedRow(repos.database, _eventId);
        expect(
          row.contactChannel,
          isNull,
          reason:
              'opening and rendering a legacy Event must not write: the '
              'convergence happens only on a normal save',
        );
      },
    );

    testWidgets('all eight options carry their own visual', (tester) async {
      _sizeView(tester);
      final repos = await _buildRepositories();
      final date = _utcToday.addDays(-3);
      await repos.calendar.saveEvent(
        profileId: repos.profileId,
        draft: _contactDraft(
          contactType: await _contactType(repos.database),
          date: date,
        ),
      );

      await _openEditForm(tester, repos: repos, originalDate: date);
      await tester.tap(find.byKey(const Key('contact-type-field')));
      await tester.pumpAndSettle();

      for (final channel in EventContactChannel.values) {
        final tile = find.byKey(
          Key('contact-type-option-${channel.stableKey}'),
        );
        expect(tile, findsOneWidget, reason: channel.stableKey);

        final asset = eventContactChannelAsset(channel);
        if (asset != null) {
          final svg = find.descendant(
            of: tile,
            matching: find.byType(SvgPicture),
          );
          expect(svg, findsOneWidget, reason: '${channel.label} uses $asset');
          expect(
            tester.widget<SvgPicture>(svg).colorFilter,
            isNotNull,
            reason:
                'the artwork must be tinted like every other contact visual '
                'rather than shipping its source colours',
          );
        } else {
          final icon = find.descendant(of: tile, matching: find.byType(Icon));
          expect(icon, findsOneWidget, reason: channel.label);
          expect(
            tester.widget<Icon>(icon).icon,
            eventContactChannelIcon(channel),
          );
        }
      }
    });

    testWidgets(
      'choosing through a visual-bearing option persists exactly that stable '
      'key and leaves the Event Type alone',
      (tester) async {
        _sizeView(tester);
        final repos = await _buildRepositories();
        final date = _utcToday.addDays(-3);
        await repos.calendar.saveEvent(
          profileId: repos.profileId,
          draft: _contactDraft(
            contactType: await _contactType(repos.database),
            date: date,
          ),
        );

        await _openEditForm(tester, repos: repos, originalDate: date);
        await tester.tap(find.byKey(const Key('contact-type-field')));
        await tester.pumpAndSettle();
        // Social Media is one of the three owner-supplied SVGs, so this path
        // proves the artwork does not travel with the value.
        await tester.tap(
          find.byKey(const Key('contact-type-option-social_media')),
        );
        await tester.pumpAndSettle();

        expect(
          tester
              .widget<Text>(
                find.byKey(const Key('selected-contact-type-label')),
              )
              .data,
          'Social Media',
        );
        expect(
          find.descendant(
            of: find.byKey(const Key('selected-contact-type-visual')),
            matching: find.byType(SvgPicture),
          ),
          findsOneWidget,
        );

        final save = find.byKey(const Key('save-event-button'));
        await tester.ensureVisible(save);
        await tester.tap(save);
        await tester.pumpAndSettle();

        final row = await _storedRow(repos.database, _eventId);
        expect(
          row.contactChannel,
          'social_media',
          reason: 'the visual cue is presentation only',
        );
        expect(
          row.activityTypeStableKeySnapshot,
          'contact',
          reason: 'a Contact Type choice must not rewrite the Event Type',
        );
      },
    );

    testWidgets('the Event detail row uses the same visual convention', (
      tester,
    ) async {
      _sizeView(tester);
      final repos = await _buildRepositories();
      final date = _utcToday.addDays(-3);
      await repos.calendar.saveEvent(
        profileId: repos.profileId,
        draft: _contactDraft(
          contactType: await _contactType(repos.database),
          date: date,
          channel: EventContactChannel.videoCall,
        ),
      );

      await _openDetailScreen(tester, repos: repos, originalDate: date);

      expect(
        find.byKey(const Key('event-detail-contact-type')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('event-detail-contact-type-visual')),
          matching: find.byType(SvgPicture),
        ),
        findsOneWidget,
      );
      expect(find.text('Video Call'), findsWidgets);
    });
  });

  group('C. Contact Type default law (revised steer)', () {
    testWidgets(
      'a NEW Contact Event starts at In Person and an untouched save persists '
      'in_person',
      (tester) async {
        _sizeView(tester);
        final repos = await _buildRepositories();
        final date = _utcToday.addDays(-1);

        await _openCreateForm(
          tester,
          repos: repos,
          date: date,
          contactType: await _contactEventType(repos),
        );

        // A brand-new Contact Event never starts as "Not set".
        expect(find.byKey(const Key('contact-type-field')), findsOneWidget);
        expect(
          tester
              .widget<Text>(
                find.byKey(const Key('selected-contact-type-label')),
              )
              .data,
          'In Person',
        );

        await tester.enterText(
          find.byKey(const Key('event-title-field')),
          'Coffee with Maria',
        );
        await tester.pumpAndSettle();
        final save = find.byKey(const Key('save-event-button'));
        await tester.ensureVisible(save);
        await tester.tap(save);
        await tester.pumpAndSettle();

        final rows = await repos.database
            .select(repos.database.calendarEvents)
            .get();
        expect(rows, hasLength(1));
        expect(
          rows.single.contactChannel,
          'in_person',
          reason:
              'the user never touched the control, so the owner-approved '
              'standard default is what gets stored',
        );
      },
    );

    testWidgets('a normal save converges a legacy NULL row to in_person', (
      tester,
    ) async {
      _sizeView(tester);
      final repos = await _buildRepositories();
      final date = _utcToday.addDays(-3);
      await repos.calendar.saveEvent(
        profileId: repos.profileId,
        draft: _contactDraft(
          contactType: await _contactType(repos.database),
          date: date,
        ),
      );
      expect(
        (await _storedRow(repos.database, _eventId)).contactChannel,
        isNull,
        reason: 'the fixture starts as a legacy NULL row',
      );

      await _openEditForm(tester, repos: repos, originalDate: date);

      // The user changes nothing about the Contact Type.
      final save = find.byKey(const Key('save-event-button'));
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();

      final row = await _storedRow(repos.database, _eventId);
      expect(
        row.contactChannel,
        'in_person',
        reason:
            'a normal Event save is the ONLY thing that converges a legacy '
            'NULL row; there is no backfill job',
      );
    });

    testWidgets(
      'the selector offers exactly the eight Contact Types and no ninth '
      'option',
      (tester) async {
        _sizeView(tester);
        final repos = await _buildRepositories();
        final date = _utcToday.addDays(-3);
        await repos.calendar.saveEvent(
          profileId: repos.profileId,
          draft: _contactDraft(
            contactType: await _contactType(repos.database),
            date: date,
          ),
        );

        await _openEditForm(tester, repos: repos, originalDate: date);
        await tester.tap(find.byKey(const Key('contact-type-field')));
        await tester.pumpAndSettle();

        expect(
          find.descendant(
            of: find.byKey(const Key('contact-type-options')),
            matching: find.byType(ListTile),
          ),
          findsNWidgets(8),
          reason: 'exactly eight: no "Not set" and no blank placeholder',
        );
        for (final label in const <String>[
          'In Person',
          'Phone Call',
          'Text',
          'Email',
          'WhatsApp',
          'Social Media',
          'Video Call',
          'Other',
        ]) {
          expect(find.text(label), findsWidgets, reason: label);
        }
        expect(find.text('Not set'), findsNothing);
        expect(find.text('None'), findsNothing);
      },
    );
  });
}
