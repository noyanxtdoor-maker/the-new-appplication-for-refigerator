// OWNER LAW (2026-09-17) — Manage Groups surface.
//
//  * An existing profile (one that predates the canonical default set) is
//    offered a small, non-blocking card inside Manage Groups only: "Default
//    groups available" + "Use default groups". Cancel writes nothing.
//  * A permanent, lower-prominence "Restore default groups" action uses the
//    same engine.
//  * A same-name collision is reported truthfully and never throws.
//  * A custom Group colour uses the SHARED visual picker
//    (showPlannerEventColorPicker) — typing a hex code is not required.
import 'package:drift/drift.dart' hide isNull;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/ids/identifier_source.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/contacts/data/drift_contact_repository.dart';
import 'package:rmplanner/features/contacts/domain/contact.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';

import '../../../support/test_dependencies.dart';

void main() {
  /// Mounts the app, then navigates Contacts -> Manage Groups.
  ///
  /// [makeExistingProfile] simulates a profile created BEFORE the canonical
  /// default set existed: the two new defaults are absent, an existing built-in
  /// carries a user edit, and the user owns a custom group.
  Future<(AppDatabase, DriftContactRepository, String)> openManageGroups(
    WidgetTester tester, {
    bool makeExistingProfile = false,
    String? customGroupName,
    // Tall enough that the whole Groups list is on screen at once, for the cases
    // that never scroll. 3000 / 2.5 = 1200 logical pixels.
    double physicalHeight = 1800,
  }) async {
    tester.view.physicalSize = Size(1000, physicalHeight);
    tester.view.devicePixelRatio = 2.5;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final database = openMemoryDatabase();
    addTearDown(database.close);
    final startup = buildTestRepository(database: database);
    final profile = await startup.completeOnboarding();
    final contacts = DriftContactRepository(
      database: database,
      clock: FixedClock(DateTime.utc(2026, 9, 17, 12)),
      identifiers: UuidIdentifierSource(),
    );

    if (makeExistingProfile) {
      await (database.delete(database.contactGroups)..where(
            (table) => table.id.isIn(<String>[
              ContactBuiltInGroupIdentity.idForProfile(
                profile.id,
                'ministering_assignments',
              ),
              ContactBuiltInGroupIdentity.idForProfile(profile.id, 'members'),
            ]),
          ))
          .go();
      await (database.update(database.contactGroups)..where(
            (table) => table.id.equals(
              ContactBuiltInGroupIdentity.idForProfile(profile.id, 'family'),
            ),
          ))
          .write(
            ContactGroupsCompanion(
              name: const Value<String>('My Family'),
              updatedAtUtc: Value<DateTime>(DateTime.utc(2026, 9, 17, 12)),
            ),
          );
    }
    if (customGroupName != null) {
      await contacts.createGroup(
        profileId: profile.id,
        name: customGroupName,
        colorValue: 0xFF0A0B0C,
      );
    }

    final privacy = TestPrivacyDependencies(database: database);
    await tester.pumpWidget(
      privacy.buildApp(
        environment: const AppEnvironment(
          name: AppEnvironmentName.production,
          label: 'PRODUCTION',
        ),
        diagnostics: SanitizedDiagnostics(),
        startupRepository: startup,
        plannerDateSource: const FixedPlannerDateSource(
          PlannerDate(year: 2026, month: 9, day: 17),
        ),
        contactRepository: contacts,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('nav-contacts')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('contacts-groups-button')));
    await tester.pumpAndSettle();
    expect(find.text('Manage Groups'), findsOneWidget);
    return (database, contacts, profile.id);
  }

  /// The permanent restore action sits at the end of the list, so a tall list
  /// has to be scrolled before it is built.
  Future<void> revealRestoreAction(WidgetTester tester) async {
    await tester.scrollUntilVisible(
      find.byKey(const Key('restore-default-groups')),
      300,
      scrollable: find
          .descendant(
            of: find.byKey(const Key('contact-groups-list')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
  }

  Future<int> groupCount(AppDatabase database, String profileId) async {
    final rows =
        await (database.select(database.contactGroups)
              ..where((table) => table.profileId.equals(profileId)))
            .get();
    return rows.length;
  }

  testWidgets('a new profile is complete: no migration card, but the '
      'permanent restore action is always available', (tester) async {
    await openManageGroups(tester);

    expect(find.byKey(const Key('default-groups-card')), findsNothing);
    await revealRestoreAction(tester);
    expect(find.byKey(const Key('restore-default-groups')), findsOneWidget);
  });

  testWidgets('an existing profile sees the opt-in card with the exact copy',
      (tester) async {
    await openManageGroups(tester, makeExistingProfile: true);

    expect(find.byKey(const Key('default-groups-card')), findsOneWidget);
    expect(find.text('Default groups available'), findsOneWidget);
    expect(
      find.text(
        "Use Next Transfer's recommended groups and colors. Your existing "
        'custom groups and contact assignments will stay intact.',
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('use-default-groups')), findsOneWidget);
  });

  testWidgets('Cancel writes nothing at all', (tester) async {
    final (database, _, profileId) = await openManageGroups(
      tester,
      makeExistingProfile: true,
    );
    final before = await groupCount(database, profileId);

    await tester.tap(find.byKey(const Key('use-default-groups')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('use-default-groups-dialog')), findsOneWidget);
    expect(find.text('Use default groups?'), findsOneWidget);
    expect(
      find.text(
        'Next Transfer will add or restore the recommended groups and their '
        'default colors. Your existing custom groups and contact assignments '
        'will stay intact.',
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('use-default-groups-cancel')));
    await tester.pumpAndSettle();

    expect(await groupCount(database, profileId), before);
    expect(find.byKey(const Key('default-groups-card')), findsOneWidget);
    expect(find.text('Members'), findsNothing);
  });

  testWidgets('Use default groups adds only what is missing, keeps custom '
      'groups, and the card then disappears', (tester) async {
    final (database, contacts, profileId) = await openManageGroups(
      tester,
      makeExistingProfile: true,
      customGroupName: 'Client',
    );
    final before = await groupCount(database, profileId);

    await tester.tap(find.byKey(const Key('use-default-groups')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('use-default-groups-confirm')));
    await tester.pumpAndSettle();

    expect(await groupCount(database, profileId), before + 2);
    expect(find.byKey(const Key('default-groups-card')), findsNothing);
    expect(
      (await contacts.readGroups(profileId))
          .map((row) => row.name)
          .toList(growable: false),
      <String>[
        'My Family',
        'Friends',
        'Ministering Assignments',
        'Members',
        'Avoid',
        'Client',
      ],
    );
    // The user-relevant part of the UI: the new default is a real, visible row
    // and the custom group was not consumed by the migration.
    expect(
      find.descendant(
        of: find.byKey(const Key('contact-groups-list')),
        matching: find.text('Members'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('the canonical five occupy the first five positions in order',
      (tester) async {
    await openManageGroups(tester);

    final positions = <String, double>{
      for (final name in <String>[
        'Family',
        'Friends',
        'Ministering Assignments',
        'Members',
        'Avoid',
      ])
        name: tester
            .getTopLeft(
              find.descendant(
                of: find.byKey(const Key('contact-groups-list')),
                matching: find.text(name),
              ),
            )
            .dy,
    };
    expect(
      positions['Family']! < positions['Friends']!,
      isTrue,
      reason: 'Family -> Friends',
    );
    expect(
      positions['Friends']! < positions['Ministering Assignments']!,
      isTrue,
      reason: 'Friends -> Ministering Assignments',
    );
    expect(
      positions['Ministering Assignments']! < positions['Members']!,
      isTrue,
      reason: 'Ministering Assignments -> Members',
    );
    expect(
      positions['Members']! < positions['Avoid']!,
      isTrue,
      reason: 'Members -> Avoid',
    );
  });

  testWidgets('a same-name collision is reported truthfully and never throws',
      (tester) async {
    final (_, contacts, profileId) = await openManageGroups(
      tester,
      makeExistingProfile: true,
      customGroupName: 'Members',
    );

    await tester.tap(find.byKey(const Key('use-default-groups')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('use-default-groups-confirm')));
    await tester.pumpAndSettle();

    expect(
      find.textContaining(
        "Some default groups couldn't be added because groups with the same "
        'names already exist: Members.',
      ),
      findsWidgets,
      reason: 'the collision is explained, not hidden',
    );
    // Nothing was overwritten: the user's own "Members" row survives intact
    // and no duplicate was invented.
    final rows = await contacts.readGroups(profileId);
    final members = rows.where((row) => row.name == 'Members').toList();
    expect(members, hasLength(1), reason: 'no duplicate row was invented');
    expect(members.single.colorValue, 0xFF0A0B0C);
    // The other missing default did land, so nothing is left that the card could
    // actionably offer: it stops prompting, and the permanent
    // "Restore default groups" action remains as the retry path.
    expect(
      find.descendant(
        of: find.byKey(const Key('contact-groups-list')),
        matching: find.text('Ministering Assignments'),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('default-groups-card')), findsNothing);
  });

  testWidgets('Restore default groups re-applies the canonical name and order',
      (tester) async {
    await openManageGroups(
      tester,
      makeExistingProfile: true,
      physicalHeight: 3000,
    );
    expect(find.text('My Family'), findsOneWidget);

    await tester.tap(find.byKey(const Key('restore-default-groups')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('restore-default-groups-dialog')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('restore-default-groups-confirm')));
    await tester.pumpAndSettle();

    expect(find.text('My Family'), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const Key('contact-groups-list')),
        matching: find.text('Family'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('Restore default groups Cancel writes nothing', (tester) async {
    final (database, _, profileId) = await openManageGroups(
      tester,
      makeExistingProfile: true,
      physicalHeight: 3000,
    );
    final before = await groupCount(database, profileId);

    await tester.tap(find.byKey(const Key('restore-default-groups')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('restore-default-groups-cancel')));
    await tester.pumpAndSettle();

    expect(await groupCount(database, profileId), before);
    expect(find.byKey(const Key('restore-default-groups-dialog')), findsNothing);
    expect(find.text('My Family'), findsOneWidget);
  });

  testWidgets('a custom Group colour opens the SHARED visual picker, so typing '
      'a hex code is no longer required', (tester) async {
    final (database, _, profileId) = await openManageGroups(tester);
    final before = await groupCount(database, profileId);

    await tester.tap(find.byKey(const Key('create-group-fab')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('group-name-field')),
      'Field Team',
    );
    await tester.tap(find.byKey(const Key('group-custom-color')));
    await tester.pumpAndSettle();

    // This is the same dialog Settings -> Colors uses.
    expect(find.byKey(const Key('planner-event-color-picker')), findsOneWidget);
    expect(
      find.byKey(const Key('planner-event-color-sv-picker')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('planner-event-color-picker')),
        matching: find.byType(TextField),
      ),
      findsNothing,
      reason: 'no hex text field is required to pick a custom Group colour',
    );

    await tester.tap(find.byKey(const Key('planner-event-color-cancel')));
    await tester.pumpAndSettle();
    expect(await groupCount(database, profileId), before);
  });
}
