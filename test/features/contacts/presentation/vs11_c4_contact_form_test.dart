import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/ids/identifier_source.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/contacts/data/drift_contact_repository.dart';
import 'package:rmplanner/features/contacts/domain/contact.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';

import '../../../support/test_dependencies.dart';

void main() {
  Future<void> openAddContact(WidgetTester tester) async {
    // The synthetic Ahem test font is materially wider than production Roboto.
    // Keep this focused C4 lifecycle/layout test on the approved 400dp mobile
    // harness so it reaches the Add Contact behavior it is intended to cover.
    tester.view.physicalSize = const Size(1000, 1672);
    tester.view.devicePixelRatio = 2.5;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final database = openMemoryDatabase();
    addTearDown(database.close);
    final startup = buildTestRepository(database: database);
    final profile = await startup.completeOnboarding();
    final contacts = DriftContactRepository(
      database: database,
      clock: FixedClock(DateTime.utc(2026, 8, 23, 12)),
      identifiers: UuidIdentifierSource(),
    );
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
          PlannerDate(year: 2026, month: 8, day: 23),
        ),
        contactRepository: contacts,
      ),
    );
    await tester.pumpAndSettle();
    expect(profile.id, isNotEmpty);

    await tester.tap(find.byKey(const Key('nav-contacts')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('add-contact-fab')));
    await tester.pumpAndSettle();
  }

  Future<void> scrollTo(WidgetTester tester, Finder target) async {
    await tester.scrollUntilVisible(
      target,
      260,
      scrollable: find
          .descendant(
            of: find.byKey(const Key('contact-form-scroll')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'C4 Add Contact uses compact contact flow and keeps advanced facts behind a button',
    (tester) async {
      await openAddContact(tester);

      final themePrimary = Theme.of(
        tester.element(find.byKey(const Key('contact-form-scroll'))),
      ).colorScheme.primary;

      expect(find.text('First Name *'), findsOneWidget);
      expect(find.text('Last Name *'), findsOneWidget);
      expect(find.byKey(const Key('contact-groups-field')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('save-contact-button')),
          matching: find.byIcon(Icons.check),
        ),
        findsOneWidget,
        reason: 'the reference-style completion control is an icon, not text',
      );
      expect(
        tester
            .widget<Icon>(
              find.descendant(
                of: find.byKey(const Key('save-contact-button')),
                matching: find.byIcon(Icons.check),
              ),
            )
            .size,
        20,
      );
      expect(
        tester.getSize(find.byKey(const Key('save-contact-button'))),
        const Size(40, 40),
      );
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('save-contact-button')))
            .style
            ?.backgroundColor
            ?.resolve(<WidgetState>{}),
        themePrimary,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('save-contact-button')),
          matching: find.text('Save'),
        ),
        findsNothing,
      );
      for (final text in <String>[
        'Contact basics',
        'Ways to reach them',
        'Location',
        'More details',
        'Start with the details that identify this contact.',
        'Add a phone, email, or social profile.',
        'Add an address or map pin when it is useful.',
        'Preferences, tags, availability, and notes.',
      ]) {
        expect(find.text(text), findsNothing);
      }
      expect(
        find.byKey(const Key('contact-form-divider-after-basics')),
        findsOneWidget,
      );
      expect(
        tester
            .getSize(find.byKey(const Key('contact-form-divider-after-basics')))
            .width,
        closeTo(tester.getSize(find.byType(Scaffold)).width, 0.01),
      );

      await tester.tap(find.byKey(const Key('contact-groups-field')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('group-picker-manage')), findsOneWidget);
      await tester.tap(find.byKey(const Key('group-picker-manage')));
      await tester.pumpAndSettle();
      expect(find.text('Manage Groups'), findsOneWidget);
      // Family and Friends are canonical default groups now (seeded at profile
      // creation), so they are no longer offered as suggestions — they are real
      // rows instead. The remaining shortcuts are unchanged.
      for (final key in <Key>[
        const Key('suggested-group-work'),
        const Key('suggested-group-school'),
        const Key('suggested-group-clients'),
        const Key('suggested-group-team'),
        const Key('suggested-group-other'),
      ]) {
        expect(find.byKey(key), findsOneWidget);
      }
      for (final key in <Key>[
        const Key('suggested-group-family'),
        const Key('suggested-group-friends'),
      ]) {
        expect(
          find.byKey(key),
          findsNothing,
          reason: 'a canonical default group is a real row, not a suggestion',
        );
      }
      for (final name in <String>[
        'Family',
        'Friends',
        'Ministering Assignments',
        'Members',
        'Avoid',
      ]) {
        expect(
          find.descendant(
            of: find.byKey(const Key('contact-groups-list')),
            matching: find.text(name),
          ),
          findsOneWidget,
          reason: 'canonical default $name is a real row',
        );
      }
      for (final key in <Key>[
        const Key('suggested-group-household'),
        const Key('suggested-group-community'),
        const Key('suggested-group-neighbors'),
      ]) {
        expect(find.byKey(key), findsNothing);
      }
      await tester.tap(find.byKey(const Key('suggested-group-work')));
      await tester.pumpAndSettle();
      final createdWorkRow = find.ancestor(
        of: find.text('Work'),
        matching: find.byWidgetPredicate((widget) {
          final key = widget.key;
          return key is ValueKey<String> && key.value.startsWith('group-row-');
        }),
      );
      expect(
        find.descendant(
          of: createdWorkRow,
          matching: find.byIcon(Icons.edit_outlined),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: createdWorkRow,
          matching: find.byIcon(Icons.delete_outline),
        ),
        findsOneWidget,
      );
      expect(find.byKey(const Key('group-archive')), findsNothing);

      // Scope to the group this test just created: the five canonical defaults
      // are also rows now, so a bare `group-row-*` finder would no longer be
      // unique.
      final createdGroupRow = find.ancestor(
        of: find.text('Work'),
        matching: find.byWidgetPredicate((widget) {
          final key = widget.key;
          return key is ValueKey<String> && key.value.startsWith('group-row-');
        }),
      );
      expect(createdGroupRow, findsOneWidget);
      // The Groups list now leads with the five canonical defaults and ends with
      // the virtual No Group row, so a shortcut-created group can sit below the
      // fold; bring it into view before touching it.
      await tester.ensureVisible(createdGroupRow);
      await tester.pumpAndSettle();
      await tester.tapAt(tester.getCenter(createdGroupRow));
      await tester.pumpAndSettle();
      expect(
        find.text('Members (0)'),
        findsOneWidget,
        reason: 'touching the Group row opens Group Detail, not the editor',
      );
      expect(
        find.text('Work'),
        findsWidgets,
        reason: 'the opened group is the one this test created',
      );
      expect(find.text('Add Contacts to Group'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();

      final editGroupControl = find.descendant(
        of: createdGroupRow,
        matching: find.byIcon(Icons.edit_outlined),
      );
      await tester.tap(editGroupControl);
      await tester.pumpAndSettle();
      expect(find.text('Edit Group'), findsOneWidget);
      expect(
        tester
                .widget<TextField>(find.byKey(const Key('group-name-field')))
                .focusNode
                ?.hasFocus ??
            false,
        isFalse,
        reason:
            'Editing an existing Group must start idle and never force the '
            'keyboard open; New Group remains the only autofocus flow.',
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      for (final key in <Key>[
        const Key('add-phone-row'),
        const Key('add-email-row'),
        const Key('add-social-row'),
        const Key('add-address-row'),
        const Key('add-map-row'),
        const Key('expand-contact-options'),
      ]) {
        await scrollTo(tester, find.byKey(key));
        expect(find.byKey(key), findsOneWidget);
      }
      final phoneAction = tester.widget<TextButton>(
        find.descendant(
          of: find.byKey(const Key('add-phone-row')),
          matching: find.byType(TextButton),
        ),
      );
      expect(phoneAction.style?.textStyle?.resolve({})?.fontSize, 15);
      expect(
        phoneAction.style?.foregroundColor?.resolve(<WidgetState>{}),
        themePrimary,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('add-phone-row')),
          matching: find.byType(SvgPicture),
        ),
        findsOneWidget,
      );
      for (final icon in <IconData>[
        Icons.mail_outline,
        Icons.alternate_email,
      ]) {
        expect(
          tester.widget<Icon>(find.byIcon(icon).first).color,
          themePrimary,
          reason: '$icon must use the selected Next Transfer theme color',
        );
      }
      expect(find.text('Preferred contact method'), findsNothing);
      expect(find.byKey(const Key('contact-favorite-toggle')), findsNothing);

      await scrollTo(tester, find.byKey(const Key('add-phone-row')));
      await tester.tap(find.byKey(const Key('add-phone-row')));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Phone type: Mobile'), findsOneWidget);
      expect(find.text('Mobile'), findsNothing);

      await scrollTo(tester, find.byKey(const Key('add-map-row')));
      await tester.tap(find.byKey(const Key('add-map-row')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('map-picker-map')), findsOneWidget);
      expect(find.byKey(const Key('contact-map-set')), findsNothing);
      await tester.tap(find.byKey(const Key('map-picker-cancel')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await scrollTo(
        tester,
        find.byKey(const Key('contact-form-divider-before-options')),
      );
      expect(
        tester
            .getSize(
              find.byKey(const Key('contact-form-divider-before-options')),
            )
            .height,
        1,
        reason:
            'Pass B replaced the former heavy 10dp Contacts form band with a subtle rule.',
      );
      expect(
        tester
            .getSize(
              find.byKey(const Key('contact-form-divider-before-options')),
            )
            .width,
        closeTo(tester.getSize(find.byType(Scaffold)).width, 0.01),
      );

      await scrollTo(tester, find.byKey(const Key('expand-contact-options')));
      final expandControl = find.byKey(const Key('expand-contact-options'));
      final expandButton = find.descendant(
        of: expandControl,
        matching: find.byType(FilledButton),
      );
      expect(expandButton, findsOneWidget);
      expect(find.text('Expand Options'), findsOneWidget);
      expect(tester.getSize(expandButton), const Size(184, 44));
      expect(
        tester.getCenter(expandButton).dx,
        closeTo(tester.getCenter(find.byType(Scaffold)).dx, 0.5),
      );
      expect(
        tester
            .widget<FilledButton>(expandButton)
            .style
            ?.backgroundColor
            ?.resolve(<WidgetState>{}),
        themePrimary,
      );
      expect(
        tester.widget<FilledButton>(expandButton).style?.shape?.resolve({}),
        isA<StadiumBorder>(),
      );
      expect(
        find.descendant(
          of: expandControl,
          matching: find.byIcon(Icons.expand_more),
        ),
        findsNothing,
      );
      await tester.tap(find.byKey(const Key('expand-contact-options')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('contact-favorite-toggle')), findsOneWidget);
      expect(tester.widget<Text>(find.text('Favorite')).style?.fontSize, 14);
      expect(find.text('Preferred contact method'), findsOneWidget);
      expect(find.byKey(const Key('contact-tags-field')), findsNothing);
      expect(find.byKey(const Key('add-availability-row')), findsOneWidget);
      expect(find.byKey(const Key('add-notes-row')), findsOneWidget);
      for (final key in <Key>[
        const Key('add-availability-row'),
        const Key('add-notes-row'),
      ]) {
        final action = tester.widget<TextButton>(
          find.descendant(
            of: find.byKey(key),
            matching: find.byType(TextButton),
          ),
        );
        expect(
          action.style?.foregroundColor?.resolve(<WidgetState>{}),
          themePrimary,
        );
      }
      expect(find.byKey(const Key('collapse-contact-options')), findsNothing);
      expect(find.text('Expanded Options'), findsNothing);
    },
  );

  testWidgets(
    'C4 method add actions advance canonical labels through icon selectors',
    (tester) async {
      await openAddContact(tester);
      final themePrimary = Theme.of(
        tester.element(find.byKey(const Key('contact-form-scroll'))),
      ).colorScheme.primary;

      Future<void> expectSequence(
        ContactMethodType type,
        List<String> expectedLabels,
      ) async {
        final section = switch (type) {
          ContactMethodType.phone => 'Phone',
          ContactMethodType.email => 'Email',
          ContactMethodType.social => 'Social Profile',
        };
        final addRow = Key('add-${type.name}-row');
        for (var index = 0; index < expectedLabels.length; index++) {
          await scrollTo(tester, find.byKey(addRow));
          await tester.tap(find.byKey(addRow));
          await tester.pumpAndSettle();

          final selected = expectedLabels[index];
          final expectedCount = expectedLabels
              .take(index + 1)
              .where((label) => label == selected)
              .length;
          expect(
            find.bySemanticsLabel('$section type: $selected'),
            findsNWidgets(expectedCount),
          );
        }
      }

      await expectSequence(ContactMethodType.phone, <String>[
        'Mobile',
        'Home',
        'Work',
        'Other',
        'Other',
      ]);
      await expectSequence(ContactMethodType.email, <String>[
        'Personal',
        'Work',
        'Family',
        'Other',
        'Other',
      ]);
      await expectSequence(ContactMethodType.social, <String>[
        'Facebook',
        'Facebook Messenger',
        'WhatsApp',
        'LINE',
        'Skype',
        'KakaoTalk',
        'Instagram',
        'X',
        'Facebook',
        'Facebook Messenger',
      ]);
      final xSelector = find.bySemanticsLabel('Social Profile type: X');
      expect(xSelector, findsOneWidget);
      final xGlyph = find.descendant(of: xSelector, matching: find.text('𝕏'));
      expect(xGlyph, findsOneWidget);
      expect(tester.widget<Text>(xGlyph).style?.color, themePrimary);
    },
  );
}
