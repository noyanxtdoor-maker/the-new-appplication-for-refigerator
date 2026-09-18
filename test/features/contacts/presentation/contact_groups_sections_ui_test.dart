// OWNER LAW (2026-09-18) — Manage Groups presentation.
//
//   OFFICIAL DEFAULT GROUPS   Family, Friends, Ministering Assignments,
//                             Members, Avoid  (canonical order, always first)
//   YOUR OTHER GROUPS         every legacy/custom row, only when one exists
//   NO GROUP                  ALWAYS the last row, always #EBC766, never a
//                             Group row: no id, no membership, no edit, no
//                             delete — tapping it shows the unassigned
//                             Contacts.
//
// Fail-first note: against the pre-change screen there is no section structure,
// no "Your Other Groups" header, no No Group row, and a same-name collision is
// only a SnackBar sentence with no colour choice.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/app/theme/app_theme.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/ids/identifier_source.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/contacts/data/drift_contact_repository.dart';
import 'package:rmplanner/features/contacts/domain/contact.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';

import '../../../support/test_dependencies.dart';

void main() {
  Future<(AppDatabase, DriftContactRepository, String)> openManageGroups(
    WidgetTester tester, {
    String? customGroupName,
    bool customGroupNamedMembers = false,
    Future<void> Function(DriftContactRepository contacts, String profileId)?
    seed,
    double physicalHeight = 2400,
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
      clock: FixedClock(DateTime.utc(2026, 9, 18, 12)),
      identifiers: UuidIdentifierSource(),
    );

    if (customGroupName != null) {
      await contacts.createGroup(
        profileId: profile.id,
        name: customGroupName,
        colorValue: 0xFF0A0B0C,
      );
    }
    if (customGroupNamedMembers) {
      // A pre-existing row that owns a canonical NAME while the canonical id
      // itself is absent: the owner-observed collision.
      await (database.delete(database.contactGroups)..where(
            (table) => table.id.equals(
              ContactBuiltInGroupIdentity.idForProfile(profile.id, 'members'),
            ),
          ))
          .go();
      await contacts.createGroup(
        profileId: profile.id,
        name: 'Members',
        colorValue: 0xFF0A0B0C,
      );
    }
    // Seeded BEFORE the screen is mounted, so the counts are read from a
    // settled state instead of racing the first frame.
    await seed?.call(contacts, profile.id);

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
          PlannerDate(year: 2026, month: 9, day: 18),
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

  /// One Contact that belongs to "Clients" and one that belongs to nothing.
  Future<void> seedGroupedAndLooseContact(
    DriftContactRepository contacts,
    String profileId,
  ) async {
    await contacts.createContact(
      profileId: profileId,
      draft: const ContactDraft(
        id: 'contact-grouped',
        firstName: 'Ada',
        lastName: 'Reyes',
        displayName: 'Ada Reyes',
        preferredContactMethod: ContactPreferredMethod.message,
        isFavorite: false,
      ),
    );
    await contacts.createContact(
      profileId: profileId,
      draft: const ContactDraft(
        id: 'contact-loose',
        firstName: 'Ben',
        lastName: 'Cruz',
        displayName: 'Ben Cruz',
        preferredContactMethod: ContactPreferredMethod.message,
        isFavorite: false,
      ),
    );
    final clientsId = (await contacts.readGroups(profileId))
        .singleWhere((row) => row.name == 'Clients')
        .id;
    await contacts.setContactGroups(
      profileId: profileId,
      contactId: 'contact-grouped',
      groupIds: <String>[clientsId],
      primaryGroupId: clientsId,
    );
  }

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

  double topOf(WidgetTester tester, Finder finder) =>
      tester.getTopLeft(finder).dy;

  testWidgets('the canonical five lead, and No Group is the last row when the '
      'profile has no other groups', (tester) async {
    await openManageGroups(tester);
    final list = find.byKey(const Key('contact-groups-list'));

    expect(find.text('Official default groups'), findsOneWidget);
    expect(
      find.text('Your Other Groups'),
      findsNothing,
      reason: 'the section only exists when such groups exist',
    );

    final order = <String>[
      'Family',
      'Friends',
      'Ministering Assignments',
      'Members',
      'Avoid',
      // Always last: it is a state, not a Group.
      ContactUngroupedColor.displayName,
    ];
    for (var index = 0; index < order.length - 1; index++) {
      expect(
        topOf(
          tester,
          find.descendant(of: list, matching: find.text(order[index])),
        ) <
            topOf(
              tester,
              find.descendant(of: list, matching: find.text(order[index + 1])),
            ),
        isTrue,
        reason: '${order[index]} must come before ${order[index + 1]}',
      );
    }
  });

  testWidgets('a profile with other groups shows them after the five and '
      'before No Group', (tester) async {
    await openManageGroups(tester, customGroupName: 'Clients');
    final list = find.byKey(const Key('contact-groups-list'));

    expect(find.text('Your Other Groups'), findsOneWidget);
    final clients = find.descendant(of: list, matching: find.text('Clients'));
    expect(clients, findsOneWidget);
    expect(
      topOf(
            tester,
            find.descendant(of: list, matching: find.text('Avoid')),
          ) <
          topOf(tester, clients),
      isTrue,
      reason: 'Avoid stays above "Your Other Groups"',
    );
    expect(
      topOf(tester, clients) <
          topOf(
            tester,
            find.descendant(
              of: list,
              matching: find.text(ContactUngroupedColor.displayName),
            ),
          ),
      isTrue,
      reason: 'No Group must never sit between the defaults and other groups',
    );
  });

  testWidgets('No Group is virtual: canonical colour, real count, and no edit '
      'or delete control', (tester) async {
    final (_, contacts, profileId) = await openManageGroups(
      tester,
      customGroupName: 'Clients',
      seed: seedGroupedAndLooseContact,
    );

    final row = find.byKey(const Key('group-row-no-group'));
    expect(row, findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const Key('no-group-contact-count')))
          .data,
      '1 contact',
      reason: 'only the genuinely unassigned contact is counted',
    );
    expect(
      find.descendant(of: row, matching: find.byIcon(Icons.edit_outlined)),
      findsNothing,
      reason: 'a virtual state is not editable',
    );
    expect(
      find.descendant(of: row, matching: find.byIcon(Icons.delete_outline)),
      findsNothing,
      reason: 'a virtual state is not deletable',
    );
    expect(
      tester
          .widgetList<Container>(
            find.descendant(of: row, matching: find.byType(Container)),
          )
          .any(
            (container) =>
                (container.decoration as BoxDecoration?)?.color ==
                const Color(ContactUngroupedColor.argb),
          ),
      isTrue,
      reason: 'the row uses the single canonical ungrouped colour',
    );
    // No Group was never persisted as a Group row.
    final rows = await contacts.readGroups(profileId);
    expect(rows.any((row) => row.name == ContactUngroupedColor.displayName),
        isFalse);
    expect(
      rows.any((row) => row.colorValue == ContactUngroupedColor.argb),
      isFalse,
    );
  });

  testWidgets('tapping No Group shows the unassigned Contacts', (tester) async {
    await openManageGroups(
      tester,
      customGroupName: 'Clients',
      seed: seedGroupedAndLooseContact,
    );

    await tester.tap(find.byKey(const Key('group-row-no-group')));
    await tester.pumpAndSettle();

    // The canonical Contacts screen carries the filter state, and the Group
    // manager is gone: no duplicate screen, no fake group route.
    expect(find.text('Manage Groups'), findsNothing);
    expect(find.text('Ben Cruz'), findsOneWidget);
    expect(
      find.text('Ada Reyes'),
      findsNothing,
      reason: 'a grouped Contact is never shown in the No Group view',
    );
  });

  testWidgets('a same-name collision offers a colour choice, OFF by default, '
      'and writes nothing on Not now', (tester) async {
    final (_, contacts, profileId) = await openManageGroups(
      tester,
      customGroupNamedMembers: true,
    );
    await revealRestoreAction(tester);
    await tester.tap(find.byKey(const Key('restore-default-groups')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('restore-default-groups-confirm')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('default-colors-dialog')), findsOneWidget);
    expect(find.text('Use default colors?'), findsOneWidget);
    expect(find.text('Current'), findsOneWidget);
    expect(find.text('Default'), findsOneWidget);

    final userMembers = (await contacts.readGroups(profileId)).singleWhere(
      (row) => row.name == 'Members',
    );
    final toggle = find.byKey(Key('default-color-toggle-${userMembers.id}'));
    expect(
      tester.widget<Switch>(toggle).value,
      isFalse,
      reason: 'adopting a default colour is never the default choice',
    );

    await tester.tap(find.byKey(const Key('default-colors-cancel')));
    await tester.pumpAndSettle();

    final after = (await contacts.readGroups(profileId)).singleWhere(
      (row) => row.name == 'Members',
    );
    expect(after.id, userMembers.id, reason: 'identity never changes');
    expect(
      after.colorValue,
      0xFF0A0B0C,
      reason: 'Not now keeps the existing colour',
    );
  });

  testWidgets('Apply selected changes ONLY the chosen colour', (tester) async {
    final (_, contacts, profileId) = await openManageGroups(
      tester,
      customGroupNamedMembers: true,
    );
    final before = (await contacts.readGroups(profileId))
        .singleWhere((row) => row.name == 'Members');

    await revealRestoreAction(tester);
    await tester.tap(find.byKey(const Key('restore-default-groups')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('restore-default-groups-confirm')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('default-color-toggle-${before.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('default-colors-apply')));
    await tester.pumpAndSettle();

    final after = (await contacts.readGroups(profileId))
        .singleWhere((row) => row.name == 'Members');
    expect(after.id, before.id);
    expect(after.name, 'Members');
    expect(after.sortOrder, before.sortOrder);
    expect(after.isArchived, isFalse);
    expect(
      after.colorValue,
      ContactBuiltInGroupDefaults.membersArgb,
      reason: 'the exact canonical PMG colour is applied',
    );
    expect(
      (await contacts.readGroups(profileId))
          .where((row) => row.name == 'Members'),
      hasLength(1),
      reason: 'no duplicate default row was created',
    );
  });

  // -------------------------------------------------------------------------
  // OWNER REVIEW #3 corrections (2026-09-18).
  // -------------------------------------------------------------------------

  testWidgets('every Manage Groups section uses the restrained 1px hairline — '
      'never a thick grey band', (tester) async {
    await openManageGroups(tester, customGroupName: 'Clients');
    final context = tester.element(
      find.byKey(const Key('contact-groups-list')),
    );

    for (final key in <Key>[
      const Key('official-default-groups-divider'),
      const Key('other-groups-divider'),
      const Key('no-group-separator'),
    ]) {
      final divider = find.byKey(key);
      expect(divider, findsOneWidget, reason: '$key must exist');
      final widget = tester.widget<Divider>(divider);
      expect(
        widget.height,
        1,
        reason: '$key is a hairline separator, never a filled slab',
      );
      expect(
        widget.color,
        AppTheme.sectionDividerOf(context),
        reason: '$key must use the shared theme-aware divider colour',
      );
    }

    // No Group keeps its own subtle separator and still gets NO section title.
    expect(
      find.text(ContactUngroupedColor.displayName),
      findsOneWidget,
      reason: 'No Group stays the single final row, with no duplicate heading',
    );
  });

  testWidgets('No Group participates in canonical filter state: Clear All '
      'restores the full default Contacts list', (tester) async {
    await openManageGroups(
      tester,
      customGroupName: 'Clients',
      seed: seedGroupedAndLooseContact,
    );

    await tester.tap(find.byKey(const Key('group-row-no-group')));
    await tester.pumpAndSettle();
    expect(find.text('Ben Cruz'), findsOneWidget);
    expect(
      find.text('Ada Reyes'),
      findsNothing,
      reason: 'the No Group view shows unassigned Contacts only',
    );
    expect(
      find.byKey(const Key('active-filter-clear-all')),
      findsOneWidget,
      reason: 'No Group is a real criterion, so Clear All is offered',
    );

    await tester.tap(find.byKey(const Key('active-filter-clear-all')));
    await tester.pumpAndSettle();

    // The owner-observed bug: Clear All appeared to do nothing because the
    // No Group criterion had become the retained baseline view.
    expect(
      find.text('Ben Cruz'),
      findsOneWidget,
      reason: 'the full list returns without a restart or a navigation trick',
    );
    expect(
      find.text('Ada Reyes'),
      findsOneWidget,
      reason: 'a grouped Contact must reappear once No Group is cleared',
    );
    expect(
      find.byKey(const Key('active-filter-clear-all')),
      findsNothing,
      reason: 'Clear All must not remain solely because of No Group',
    );
  });

  testWidgets('Restore default groups on an already-restored profile is a '
      'truthful no-op', (tester) async {
    final (_, contacts, profileId) = await openManageGroups(tester);
    final before = await contacts.readGroups(profileId, includeArchived: true);
    expect(
      ContactDefaultGroupsStatus.isFullyRestored(
        groups: before,
        profileId: profileId,
      ),
      isTrue,
      reason: 'a freshly onboarded profile already holds the canonical five',
    );

    await revealRestoreAction(tester);
    await tester.tap(find.byKey(const Key('restore-default-groups')));
    await tester.pumpAndSettle();

    expect(find.text('Default groups are already restored.'), findsOneWidget);
    expect(
      find.byKey(const Key('restore-default-groups-dialog')),
      findsNothing,
      reason: 'with nothing to restore the user is never asked to confirm',
    );
    expect(
      find.byKey(const Key('default-colors-dialog')),
      findsNothing,
      reason: 'no collision flow runs when everything is already restored',
    );

    String fingerprint(List<ContactGroup> rows) => rows
        .map(
          (row) =>
              '${row.id}|${row.name}|${row.colorValue}|${row.sortOrder}|'
              '${row.isArchived}|${row.updatedAtUtc.toIso8601String()}',
        )
        .join(',');
    final after = await contacts.readGroups(profileId, includeArchived: true);
    expect(
      fingerprint(after),
      fingerprint(before),
      reason:
          'id, name, colour, position, archive state and write timestamp must '
          'all be untouched — a redundant restore run would have rewritten them',
    );
  });

  test('isFullyRestored is false the moment one canonical colour is '
      'customized', () async {
    final database = openMemoryDatabase();
    addTearDown(database.close);
    final startup = buildTestRepository(database: database);
    final profile = await startup.completeOnboarding();
    final contacts = DriftContactRepository(
      database: database,
      clock: FixedClock(DateTime.utc(2026, 9, 18, 12)),
      identifiers: UuidIdentifierSource(),
    );

    final canonical = await contacts.readGroups(
      profile.id,
      includeArchived: true,
    );
    expect(
      ContactDefaultGroupsStatus.isFullyRestored(
        groups: canonical,
        profileId: profile.id,
      ),
      isTrue,
    );

    final members = canonical.singleWhere((row) => row.name == 'Members');
    await contacts.updateGroup(
      profileId: profile.id,
      groupId: members.id,
      name: members.name,
      colorValue: 0xFF0A0B0C,
    );

    final customized = await contacts.readGroups(
      profile.id,
      includeArchived: true,
    );
    expect(
      ContactDefaultGroupsStatus.isFullyRestored(
        groups: customized,
        profileId: profile.id,
      ),
      isFalse,
      reason:
          'a customized colour means a restore would genuinely change something, '
          'so the run (and its collision flow) must still be reachable',
    );
  });
}
