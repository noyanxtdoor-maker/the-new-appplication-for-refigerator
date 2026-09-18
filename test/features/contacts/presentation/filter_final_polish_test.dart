import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/app/theme/app_theme.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/contacts/data/drift_contact_repository.dart';
import 'package:rmplanner/features/contacts/domain/contact.dart';
import 'package:rmplanner/features/contacts/presentation/c3_contact_primitives.dart';
import 'package:rmplanner/features/contacts/presentation/contact_filter_controls.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';

import '../../../support/test_dependencies.dart';

/// Filter Final Polish widget coverage (pack 2026-08-20):
/// anchored sort dropdown, new Phone/Email/Address/Social categories,
/// lower event toggles with mutual exclusion, and the sticky Restore Defaults
/// dirty-state footer.
void main() {
  const monday = PlannerDate(year: 2026, month: 7, day: 27);

  Future<AppDatabase> pumpContacts(
    WidgetTester tester, {
    bool seedContacts = false,
  }) async {
    tester.view.physicalSize = const Size(941, 1672);
    tester.view.devicePixelRatio = 2.5;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final database = openMemoryDatabase();
    addTearDown(database.close);
    final startup = buildTestRepository(database: database);
    final profile = await startup.completeOnboarding();
    final privacy = TestPrivacyDependencies(database: database);
    final contacts = DriftContactRepository(
      database: database,
      clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
      identifiers: SequenceIdentifierSource(const <String>[]),
    );

    if (seedContacts) {
      await contacts.ensureBuiltInGroups(profile.id);
      await contacts.createContact(
        profileId: profile.id,
        draft: const ContactDraft(
          id: '11111111-1111-4111-8111-111111111111',
          firstName: 'Marilyn',
          lastName: 'Gomez',
          displayName: 'Marilyn Gomez',
          preferredContactMethod: ContactPreferredMethod.message,
          isFavorite: true,
          methods: <ContactMethodDraft>[
            ContactMethodDraft(
              type: ContactMethodType.phone,
              value: '+1 555 0100',
            ),
          ],
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
        plannerDateSource: const FixedPlannerDateSource(monday),
        contactRepository: contacts,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('nav-contacts')));
    await tester.pumpAndSettle();
    return database;
  }

  Future<AppDatabase> pumpFilter(
    WidgetTester tester, {
    bool seedContacts = false,
  }) async {
    final database = await pumpContacts(tester, seedContacts: seedContacts);
    await tester.tap(find.byKey(const Key('contacts-filter-button')));
    await tester.pumpAndSettle();
    return database;
  }

  Future<void> scrollTo(WidgetTester tester, Finder finder) {
    return tester.scrollUntilVisible(
      finder,
      300,
      scrollable: find.byType(Scrollable),
    );
  }

  /// [scrollTo] stops as soon as the target is *visible*, which can leave a row
  /// flush against the leading edge where the AppBar swallows the tap. A row
  /// that is about to be tapped must be fully inside the viewport instead —
  /// this matters more now that the section bands are hairline dividers, so the
  /// leading-edge landing lands a few pixels higher than it used to.
  Future<void> scrollToTappable(WidgetTester tester, Finder finder) async {
    await scrollTo(tester, finder);
    await tester.pumpAndSettle();
    await Scrollable.ensureVisible(tester.element(finder), alignment: 0.5);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'sort opens an anchored dropdown with the final eleven options and no New badges',
    (tester) async {
      await pumpFilter(tester);

      expect(find.byKey(const Key('filter-sort-by')), findsOneWidget);
      expect(find.text('Name (A–Z)'), findsOneWidget);

      await tester.tap(find.byKey(const Key('filter-sort-by')));
      await tester.pumpAndSettle();

      // The menu is anchored to the field (same mechanism as the Event Type
      // dropdown): it is not a modal bottom sheet and has the approved six options.
      expect(find.byType(BottomSheet), findsNothing);
      expect(
        find.byKey(const Key('filter-sort-dropdown-scroll')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('filter-sort-option-name')), findsOneWidget);
      expect(
        find.byKey(const Key('filter-sort-option-nameDesc')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('filter-sort-option-recentlyAdded')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('filter-sort-option-oldestAdded')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('filter-sort-option-mostRecentlyInteracted')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('filter-sort-option-leastRecentlyInteracted')),
        findsOneWidget,
      );
      expect(find.text('Name (A–Z)'), findsWidgets);
      expect(find.text('Name (Z–A)'), findsOneWidget);
      expect(find.text('Recently added'), findsOneWidget);
      expect(find.text('Oldest added'), findsOneWidget);
      expect(find.text('Most recently interacted'), findsOneWidget);
      expect(find.text('Least recently interacted'), findsOneWidget);
      // No "New" badge/text for the added sort entries.
      expect(
        find.textContaining('New'),
        findsNothing,
        reason: 'R2 adds no New badges to the sort menu',
      );

      await tester.tap(find.text('Name (Z–A)'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('filter-sort-by')), findsOneWidget);
      expect(find.text('Name (Z–A)'), findsOneWidget);
    },
  );

  testWidgets(
    'Phone/Email/Address/Social categories render inline with their options',
    (tester) async {
      await pumpFilter(tester);

      Future<void> verifyCategory(
        ContactFilterCategory category,
        List<String> optionKeys,
      ) async {
        final rowKey = Key('filter-category-main-${category.name}');
        final labelLower = contactFilterCategoryLabel(category).toLowerCase();
        await scrollToTappable(tester, find.byKey(rowKey));
        await tester.tap(find.byKey(rowKey));
        await tester.pumpAndSettle();
        for (final key in optionKeys) {
          expect(
            find.byKey(Key('filter-inline-option-$labelLower-$key')),
            findsOneWidget,
            reason: '$labelLower should expose option $key',
          );
        }
        // Collapse again so the next category stays reachable while scrolling down.
        await tester.tap(find.byKey(rowKey));
        await tester.pumpAndSettle();
      }

      await verifyCategory(ContactFilterCategory.phone, const <String>[
        'noPhone',
        'mobile',
        'home',
        'work',
        'other',
      ]);
      await verifyCategory(ContactFilterCategory.email, const <String>[
        'noEmail',
        'personal',
        'work',
        'family',
        'other',
      ]);
      await verifyCategory(ContactFilterCategory.address, const <String>[
        'notRecorded',
        'recorded',
      ]);
      await verifyCategory(ContactFilterCategory.socialProfile, const <String>[
        'noSocial',
        'facebook',
        'messenger',
        'whatsapp',
        'line',
        'skype',
        'kakaotalk',
        'instagram',
        'hellotalk',
        'x',
        'other',
      ]);
    },
  );

  testWidgets(
    'Event History keeps only truthful history options and lower toggles enforce mutual exclusion',
    (tester) async {
      await pumpFilter(tester);

      // Event History inline options no longer include today/future/without-future.
      await scrollTo(
        tester,
        find.byKey(const Key('filter-category-main-eventHistory')),
      );
      await tester.tap(
        find.byKey(const Key('filter-category-main-eventHistory')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(
          const Key('filter-inline-option-event history-no-interaction'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('filter-inline-option-event history-history')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('filter-inline-option-event history-today')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('filter-inline-option-event history-future')),
        findsNothing,
      );
      expect(
        find.byKey(
          const Key('filter-inline-option-event history-without-future'),
        ),
        findsNothing,
      );

      // Lower toggle switches exist and enforce the mutual exclusion law.
      await tester.scrollUntilVisible(
        find.byKey(const Key('filter-toggle-future')),
        300,
        scrollable: find.byType(Scrollable),
      );
      await tester.tap(find.byKey(const Key('filter-toggle-future')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const Key('filter-toggle-future')),
            )
            .value,
        isTrue,
      );
      await tester.tap(find.byKey(const Key('filter-toggle-without-future')));
      await tester.pumpAndSettle();
      // Turning Without Future ON forces Future OFF.
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const Key('filter-toggle-without-future')),
            )
            .value,
        isTrue,
      );
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const Key('filter-toggle-future')),
            )
            .value,
        isFalse,
      );
      // Turning Future ON forces Without Future OFF.
      await tester.tap(find.byKey(const Key('filter-toggle-future')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const Key('filter-toggle-future')),
            )
            .value,
        isTrue,
      );
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const Key('filter-toggle-without-future')),
            )
            .value,
        isFalse,
      );
    },
  );

  testWidgets(
    'sticky Restore Defaults footer appears when dirty and disappears on restore',
    (tester) async {
      await pumpFilter(tester);

      // Pristine: no footer visible.
      expect(find.byKey(const Key('filter-restore-defaults')), findsNothing);

      // Change the sort -> footer appears and stays pinned while the list scrolls.
      await tester.tap(find.byKey(const Key('filter-sort-by')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Oldest added'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('filter-restore-defaults')), findsOneWidget);

      // Scroll the list: the footer must remain in the tree (pinned below the list).
      await tester.drag(find.byType(Scrollable), const Offset(0, -200));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('filter-restore-defaults')), findsOneWidget);

      // Restore resets the draft and hides the footer.
      await tester.tap(find.byKey(const Key('filter-restore-defaults')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('filter-restore-defaults')), findsNothing);
      // Scrolling up reveals the sort field reset to the default Name (A–Z).
      await tester.scrollUntilVisible(
        find.byKey(const Key('filter-sort-by')),
        -300,
        scrollable: find.byType(Scrollable),
      );
      await tester.pumpAndSettle();
      expect(find.text('Name (A–Z)'), findsOneWidget);

      // Changing an event toggle activates the footer again.
      await tester.scrollUntilVisible(
        find.byKey(const Key('filter-toggle-today')),
        300,
        scrollable: find.byType(Scrollable),
      );
      await tester.tap(find.byKey(const Key('filter-toggle-today')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('filter-restore-defaults')), findsOneWidget);
    },
  );

  testWidgets(
    'C4 category selections preserve explicit None through final deselection',
    (tester) async {
      await pumpFilter(tester);

      await scrollToTappable(
        tester,
        find.byKey(const Key('filter-category-main-phone')),
      );
      await tester.tap(find.byKey(const Key('filter-category-main-phone')));
      await tester.pumpAndSettle();

      // C4: master All -> explicit None; None remains a valid filter state.
      await tester.tap(find.byKey(const Key('filter-master-phone')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('filter-validation-phone')), findsNothing);
      expect(
        tester.widget<Text>(find.byKey(const Key('filter-state-phone'))).data,
        'None',
      );
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('filter-builder-check')))
            .onPressed,
        isNotNull,
      );

      // Select only Mobile -> Some and valid.
      await tester.tap(
        find.byKey(const Key('filter-inline-option-phone-mobile')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('filter-validation-phone')), findsNothing);
      expect(find.byKey(const Key('filter-state-phone')), findsOneWidget);
      expect(find.text('Some'), findsOneWidget);

      // Uncheck Mobile -> explicit None; never normalize back to All.
      await tester.tap(
        find.byKey(const Key('filter-inline-option-phone-mobile')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('filter-validation-phone')), findsNothing);
      expect(
        tester.widget<Text>(find.byKey(const Key('filter-state-phone'))).data,
        'None',
      );
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('filter-builder-check')))
            .onPressed,
        isNotNull,
      );

      // Master None -> All.
      await tester.tap(find.byKey(const Key('filter-master-phone')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('filter-validation-phone')), findsNothing);
    },
  );

  testWidgets(
    'R2 Restore Defaults: no icon, centered blue text, whole white box tappable, draft-only',
    (tester) async {
      final database = await pumpFilter(tester);

      // Pristine: no footer, no restore icon anywhere.
      expect(find.byKey(const Key('filter-restore-defaults')), findsNothing);
      expect(find.byIcon(Icons.restore), findsNothing);

      // Dirty via a sort change -> footer appears.
      await tester.tap(find.byKey(const Key('filter-sort-by')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Oldest added'));
      await tester.pumpAndSettle();
      final footer = find.byKey(const Key('filter-restore-defaults'));
      expect(footer, findsOneWidget);
      expect(find.byIcon(Icons.restore), findsNothing);
      expect(find.text('Restore Defaults'), findsOneWidget);

      // Text is centered inside the box (Center ancestor), primary/blue color.
      final restoreText = tester.widget<Text>(find.text('Restore Defaults'));
      expect(
        find.ancestor(
          of: find.text('Restore Defaults'),
          matching: find.byType(Center),
        ),
        findsWidgets,
      );
      expect(
        restoreText.style?.color,
        Theme.of(
          tester.element(find.text('Restore Defaults')),
        ).colorScheme.primary,
      );

      // Tap the LEFT edge of the white rectangle: restores the draft.
      var rect = tester.getRect(footer);
      await tester.tapAt(Offset(rect.left + 8, rect.center.dy));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('filter-restore-defaults')), findsNothing);

      // Dirty again, then tap the RIGHT edge: restores the draft.
      await tester.tap(find.byKey(const Key('filter-sort-by')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Recently added'));
      await tester.pumpAndSettle();
      rect = tester.getRect(find.byKey(const Key('filter-restore-defaults')));
      await tester.tapAt(Offset(rect.right - 8, rect.center.dy));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('filter-restore-defaults')), findsNothing);

      // Restore is draft-only: no saved-filter row was written to the database.
      final savedRows = await (database.select(
        database.savedContactFilters,
      )).get();
      expect(savedRows, isEmpty);

      // Top checkmark remains apply/save; X close remains discard.
      expect(find.byKey(const Key('filter-builder-check')), findsOneWidget);
      expect(find.byKey(const Key('filter-builder-close')), findsOneWidget);
    },
  );

  testWidgets(
    'R2 typography: category labels are regular weight, option and toggle labels regular',
    (tester) async {
      await pumpFilter(tester);

      // Leading, middle, and trailing visible categories retain the regular
      // category typography after Tags retirement.
      for (final label in <String>['Groups', 'Favorites', 'Archived']) {
        await scrollTo(tester, find.text(label));
        final text = tester.widget<Text>(find.text(label));
        expect(
          text.style?.fontWeight,
          FontWeight.w400,
          reason: '$label category label must be regular weight',
        );
      }

      // Option rows (expanded) use regular body typography (no explicit
      // weight in the style resolves to the regular default).
      await scrollToTappable(
        tester,
        find.byKey(const Key('filter-category-main-phone')),
      );
      await tester.tap(find.byKey(const Key('filter-category-main-phone')));
      await tester.pumpAndSettle();
      final option = tester.widget<Text>(find.text('Mobile'));
      expect(
        option.style?.fontWeight,
        isNot(anyOf(FontWeight.w600, FontWeight.w700)),
        reason: 'expanded option labels must not be bold',
      );

      // Lower event-toggle labels use regular body typography.
      await scrollTo(tester, find.text('With Future Events Only'));
      final toggleLabel = tester.widget<Text>(
        find.text('With Future Events Only'),
      );
      expect(toggleLabel.style?.fontWeight, isNot(FontWeight.w600));
      expect(toggleLabel.style?.fontWeight, isNot(FontWeight.w700));
    },
  );

  testWidgets(
    // OWNER LAW (2026-09-18): the Filter screen separates its sections with the
    // same restrained hairline the rest of Contacts uses. The former 12px
    // filled band read as a heavy grey slab and is gone.
    'R2 dividers: neutral hairline dividers after Save, after Sort, and before toggles',
    (tester) async {
      await pumpFilter(tester);

      // Divider after Save as Contact Filter and after Contact List Sort are
      // near the top of the list and visible immediately.
      expect(find.byKey(const Key('filter-band-after-save')), findsOneWidget);
      expect(find.byKey(const Key('filter-band-after-sort')), findsOneWidget);

      // Divider before the lower event toggles (bottom of the list).
      await scrollTo(tester, find.byKey(const Key('filter-toggle-today')));
      expect(
        find.byKey(const Key('filter-band-before-toggles')),
        findsOneWidget,
      );

      // Every one of them is a hairline, and every one uses the neutral
      // section-divider token rather than theme primary.
      for (final key in <Key>[
        const Key('filter-band-after-save'),
        const Key('filter-band-after-sort'),
        const Key('filter-band-before-toggles'),
      ]) {
        final finder = find.byKey(key);
        final divider = tester.widget<Divider>(finder);
        final context = tester.element(finder);
        expect(divider.height, 1, reason: '$key must be a hairline, not a band');
        expect(divider.color, AppTheme.sectionDividerOf(context));
        expect(
          AppTheme.sectionDividerOf(context),
          isNot(Theme.of(context).colorScheme.primary),
        );
        expect(
          tester.getSize(finder).height,
          lessThanOrEqualTo(1),
          reason: '$key must not paint a thick slab',
        );
      }
    },
  );

  testWidgets(
    'R2 event toggles: exactly three, stable identity, semantics unchanged',
    (tester) async {
      await pumpFilter(tester);

      // Save as Contact Filter switch (top of the list) is untouched.
      expect(find.byKey(const Key('save-as-filter-switch')), findsOneWidget);

      await scrollTo(tester, find.byKey(const Key('filter-toggle-today')));
      // Exactly 3 lower event toggles, none added, none removed.
      expect(find.byKey(const Key('filter-toggle-today')), findsOneWidget);
      expect(find.byKey(const Key('filter-toggle-future')), findsOneWidget);
      expect(
        find.byKey(const Key('filter-toggle-without-future')),
        findsOneWidget,
      );
      expect(find.text('With Events Today Only'), findsOneWidget);
      expect(find.text('With Future Events Only'), findsOneWidget);
      expect(find.text('Without Future Events Only'), findsOneWidget);
    },
  );

  testWidgets('R2.1 Save as Contact Filter is one whole-row control', (
    tester,
  ) async {
    final database = await pumpFilter(tester);
    final row = find.byKey(const Key('save-as-filter-switch'));
    final switchFinder = find.descendant(
      of: row,
      matching: find.byType(Switch),
    );
    expect(switchFinder, findsOneWidget);
    expect(tester.widget<Switch>(switchFinder).value, isFalse);

    final savedBefore = await (database.select(
      database.savedContactFilters,
    )).get();
    var rowRect = tester.getRect(row);

    // Far-left padding toggles the row exactly once.
    await tester.tapAt(Offset(rowRect.left + 8, rowRect.center.dy));
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(switchFinder).value, isTrue);
    expect(find.byKey(const Key('filter-name-field')), findsOneWidget);
    expect(find.byKey(const Key('filter-description-field')), findsOneWidget);

    // The label is part of the same single control and toggles it back off.
    await tester.tap(find.text('Save as Contact Filter'));
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(switchFinder).value, isFalse);
    expect(find.byKey(const Key('filter-name-field')), findsNothing);
    expect(find.byKey(const Key('filter-description-field')), findsNothing);

    // Center whitespace toggles it on once.
    rowRect = tester.getRect(row);
    await tester.tapAt(Offset(rowRect.center.dx, rowRect.center.dy));
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(switchFinder).value, isTrue);

    // The switch itself toggles exactly once; it must not bubble into a
    // second parent toggle.
    await tester.tap(switchFinder);
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(switchFinder).value, isFalse);

    // Whitespace before the trailing switch is still row-owned.
    rowRect = tester.getRect(row);
    await tester.tapAt(Offset(rowRect.right - 96, rowRect.center.dy));
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(switchFinder).value, isTrue);

    // Draft interaction alone never writes a saved-filter row.
    final savedAfter = await (database.select(
      database.savedContactFilters,
    )).get();
    expect(savedAfter, savedBefore);
  });

  testWidgets('R2.1 description has intentional gap before neutral divider', (
    tester,
  ) async {
    await pumpFilter(tester);
    await tester.tap(find.byKey(const Key('save-as-filter-switch')));
    await tester.pumpAndSettle();

    final description = find.byKey(const Key('filter-description-field'));
    final divider = find.byKey(const Key('filter-band-after-save'));
    expect(description, findsOneWidget);
    expect(divider, findsOneWidget);

    final gap =
        tester.getTopLeft(divider).dy - tester.getBottomLeft(description).dy;
    expect(gap, greaterThanOrEqualTo(12));
    expect(gap, lessThanOrEqualTo(20));
  });

  testWidgets(
    'R2.2 filter icon: supplied SVG replaces the generic Material funnel and opens the Filter screen',
    (tester) async {
      await pumpContacts(tester);

      // The top app bar Filter action renders the supplied SVG FilterPlusIcon.
      expect(find.byType(FilterPlusIcon), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(FilterPlusIcon),
          matching: find.byType(SvgPicture),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('contacts-filter-button')),
          matching: find.byType(Icon),
        ),
        findsNothing,
        reason: 'the Filter action must not use a generic Material icon',
      );

      // Search / menu actions remain untouched (checked before the Filter
      // screen covers the Contacts app bar).
      expect(find.byKey(const Key('contacts-search-button')), findsOneWidget);
      expect(find.byKey(const Key('contacts-menu-button')), findsOneWidget);
      expect(
        tester.getSize(find.byKey(const Key('contacts-filter-button'))).width,
        greaterThanOrEqualTo(48),
      );

      // The action still opens the canonical Filter screen.
      await tester.tap(find.byKey(const Key('contacts-filter-button')));
      await tester.pumpAndSettle();
      expect(find.text('Filter'), findsOneWidget);
      expect(find.byKey(const Key('filter-builder-check')), findsOneWidget);
    },
  );
}
