// P2 owner-review corrections (2026-09-22) — Unreported > Contacts markers.
//
// The owner observed that every Contact Event used the same generic three-person
// marker in Unreported even when their Contact Types differed. The revised law:
// the marker follows the Event's EFFECTIVE Contact Type.
//
//   In Person (and a legacy NULL, which IS In Person) -> the generic
//       Contacts/People glyph;
//   Phone Call / WhatsApp       -> the Contact Information method assets;
//   Text / Email                -> the Contact Information action visuals;
//   Social Media / Video Call / Other -> the three owner-supplied SVGs.
//
// The marker delegates to the ONE shared presentation mapper, so these tests pin
// the marker-to-channel wiring and the exact asset identity per channel; the
// mapper's own label/key law is pinned in
// `event_contact_channel_visuals_test.dart`.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/planner/domain/awaiting_report_event.dart';
import 'package:rmplanner/features/planner/domain/event_contact_channel.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_day.dart';
import 'package:rmplanner/features/planner/presentation/widgets/event_contact_channel_visuals.dart';
import 'package:rmplanner/features/unreported/application/unreported_providers.dart';
import 'package:rmplanner/features/unreported/domain/unreported_entry.dart';

import '../../support/test_dependencies.dart';

void main() {
  Future<void> pumpHub(
    WidgetTester tester, {
    required List<UnreportedEntry> entries,
  }) async {
    // Tall enough that every fixture row is laid out without scrolling, so a
    // missing marker can only mean a real presentation gap.
    tester.view.physicalSize = const Size(431, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final database = openMemoryDatabase();
    addTearDown(database.close);
    final privacy = TestPrivacyDependencies(database: database);
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
        extraOverrides: <Override>[
          unreportedEntriesProvider.overrideWith((ref) async => entries),
        ],
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home-hamburger')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('drawer-unreported')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('unreported-tab-contacts')));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'the marker follows the Event Contact Type, not one generic glyph',
    (tester) async {
      await pumpHub(
        tester,
        entries: <UnreportedEntry>[
          for (final channel in EventContactChannel.values)
            _entry(id: channel.stableKey, channel: channel),
          _entry(id: 'legacy-null', channel: null),
        ],
      );

      for (final channel in EventContactChannel.values) {
        final marker = find.byKey(
          Key('unreported-contact-marker-${channel.stableKey}'),
        );
        expect(marker, findsOneWidget, reason: channel.label);

        final asset = eventContactChannelAsset(channel);
        if (asset != null) {
          final svg = tester.widget<SvgPicture>(marker);
          expect(
            (svg.bytesLoader as SvgAssetLoader).assetName,
            asset,
            reason: '${channel.label} must draw its own art',
          );
          expect(
            svg.colorFilter,
            isNotNull,
            reason: 'the art is tinted like every other contact visual',
          );
        } else {
          expect(
            tester.widget<Icon>(marker).icon,
            eventContactChannelIcon(channel),
            reason: channel.label,
          );
        }
      }

      // A legacy NULL row is In Person: the generic Contacts/People glyph, and
      // never a "Not set" anywhere.
      final legacy = find.byKey(
        const Key('unreported-contact-marker-legacy-null'),
      );
      expect(legacy, findsOneWidget);
      expect(tester.widget<Icon>(legacy).icon, Icons.people_outline);
      expect(find.text('Not set'), findsNothing);
    },
  );

  testWidgets('the marker ignores the Event Type entirely', (tester) async {
    // Two rows sharing ONE Event Type but different Contact Types must differ,
    // and two rows sharing ONE Contact Type but different Event Types must
    // match. That is only possible if the marker reads the channel alone.
    await pumpHub(
      tester,
      entries: <UnreportedEntry>[
        _entry(
          id: 'same-type-a',
          channel: EventContactChannel.phoneCall,
          activityTypeStableKey: 'contact',
        ),
        _entry(
          id: 'same-type-b',
          channel: EventContactChannel.whatsApp,
          activityTypeStableKey: 'contact',
        ),
        _entry(
          id: 'different-type-a',
          channel: EventContactChannel.whatsApp,
          activityTypeStableKey: 'other',
        ),
        _entry(
          id: 'different-type-b',
          channel: EventContactChannel.whatsApp,
          activityTypeStableKey: 'meaningful_connection',
        ),
        _entry(
          id: 'in-person-row',
          channel: EventContactChannel.inPerson,
          activityTypeStableKey: 'contact',
        ),
      ],
    );

    String assetFor(String id) {
      final svg = tester.widget<SvgPicture>(
        find.byKey(Key('unreported-contact-marker-$id')),
      );
      return (svg.bytesLoader as SvgAssetLoader).assetName;
    }

    expect(
      assetFor('same-type-a'),
      isNot(assetFor('same-type-b')),
      reason:
          'the same Event Type with different Contact Types must not render '
          'the same marker',
    );
    expect(
      assetFor('different-type-a'),
      assetFor('different-type-b'),
      reason:
          'the same Contact Type must render the same marker whatever the '
          'Event Type is',
    );
    expect(
      assetFor('same-type-b'),
      assetFor('different-type-a'),
      reason: 'WhatsApp is WhatsApp regardless of Event Type',
    );
    // In Person is the generic Contacts glyph, never an SVG — and it shares an
    // Event Type with an SVG-rendered row, which is the whole point.
    expect(
      tester
          .widget<Icon>(
            find.byKey(const Key('unreported-contact-marker-in-person-row')),
          )
          .icon,
      Icons.people_outline,
    );
  });
}

UnreportedEntry _entry({
  required String id,
  required EventContactChannel? channel,
  String? activityTypeStableKey = 'contact',
}) {
  final endUtc = DateTime.utc(2026, 9, 19, 10);
  return UnreportedEntry(
    tab: UnreportedTab.contacts,
    event: AwaitingReportEvent(
      item: PlannerCalendarItem(
        id: id,
        eventId: 'event-$id',
        originalDate: PlannerDate(year: 2026, month: 9, day: 19),
        title: 'Unreported $id',
        date: PlannerDate(year: 2026, month: 9, day: 19),
        timing: PlannerEventTiming.timed,
        state: PlannerEventState.scheduled,
        requiresReport: true,
        hasOutcomeReport: false,
        startUtc: endUtc.subtract(const Duration(hours: 1)),
        endUtc: endUtc,
      ),
      goalId: null,
      activityTypeStableKey: activityTypeStableKey,
      contactChannel: channel,
    ),
    goalId: null,
    contacts: const <UnreportedContactRef>[],
  );
}
