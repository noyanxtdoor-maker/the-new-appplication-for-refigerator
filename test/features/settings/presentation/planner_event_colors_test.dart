import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/ids/identifier_source.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/contacts/data/drift_contact_repository.dart';
import 'package:rmplanner/features/contacts/domain/contact.dart';
import 'package:rmplanner/features/planner/domain/event_color_preferences.dart';
import 'package:rmplanner/features/planner/presentation/widgets/planner_event_color_preview.dart';

import '../../../support/test_dependencies.dart';

void main() {
  testWidgets('Planner Event Colors route edits, persists, and restores', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(393, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final database = openMemoryDatabase();
    addTearDown(database.close);
    final privacy = TestPrivacyDependencies(database: database);
    final startup = buildTestRepository(
      database: database,
      privacyGate: privacy.gate,
    );
    final profile = await startup.completeOnboarding();
    // Built-in Groups are no longer seeded by an unrelated read. This settings
    // fixture explicitly creates the real rows it intends to edit.
    await DriftContactRepository(
      database: database,
      clock: FixedClock(DateTime.utc(2026, 8, 26, 12)),
      identifiers: const UuidIdentifierSource(),
    ).ensureBuiltInGroups(profile.id);

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
    // NX-07/08: no More tab — Settings lives in the drawer.
    await tester.tap(find.byKey(const Key('home-hamburger')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('drawer-account-settings')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('settings-colors')),
      160,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-colors')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('planner-event-colors-events-section')),
      findsOneWidget,
    );
    expect(find.text('Colors'), findsOneWidget);
    expect(find.text('Events'), findsOneWidget);
    expect(find.byType(PlannerEventColorPreview), findsWidgets);
    expect(find.text('Person Status'), findsNothing);
    for (final label in <String>[
      'Job Application',
      'Scripture Study',
      'Exercise',
      'Contact',
      'Budget Review',
      'Temple Visit',
      'Meeting',
      // Accepted prospective-presentation law: the untouched canonical system
      // Study row presents as "Study & Planning" on fresh prospective surfaces,
      // and the colors settings list is exactly such a surface
      // (`event_type_presentation.dart` via `planner_event_colors_screen`).
      // Raw storage, stable keys and historical snapshots keep "Study or Plan".
      'Study & Planning',
      'Service',
      'Shopping',
    ]) {
      expect(find.text(label), findsOneWidget);
    }
    for (final label in <String>[
      'General',
      'Teaching',
      'Finding',
      'Appointment',
      'Baptism',
    ]) {
      expect(find.text(label), findsNothing);
    }
    final colorsList = find.byKey(const Key('planner-event-colors-list'));
    await tester.drag(colorsList, const Offset(0, -2000));
    await tester.pumpAndSettle();
    expect(find.text('Travel'), findsOneWidget);
    await tester.drag(colorsList, const Offset(0, 2000));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('event-color-row-job_application')),
      findsOneWidget,
    );
    expect(
      tester.getSize(find.byKey(const Key('event-color-row-job_application'))),
      const Size(361, 44),
    );
    final preview = find.byType(PlannerEventColorPreview).first;
    expect(tester.getSize(preview), const Size(159, 40));
    final previewRect = tester.getRect(preview);
    for (final key in <Key>[
      const Key('event-color-swatch-Job Application-accent'),
      const Key('event-color-pencil-Job Application-accent'),
      const Key('event-color-swatch-Job Application-Event background'),
      const Key('event-color-pencil-Job Application-Event background'),
    ]) {
      expect(tester.getRect(find.byKey(key)).center.dy, previewRect.center.dy);
    }
    expect(
      find.byType(PlannerEventColorPreview).evaluate().length,
      greaterThanOrEqualTo(6),
    );

    final jobAccent = find.byKey(
      const Key('event-color-swatch-Job Application-accent'),
    );
    final originalAccent = tester
        .widget<PlannerEventColorPreview>(preview)
        .preference
        .accentArgb;
    await tester.tap(jobAccent);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('planner-event-color-picker')), findsOneWidget);
    expect(find.text('Choose Color'), findsOneWidget);
    await tester.drag(
      find.byKey(const Key('planner-event-color-sv-gesture')),
      const Offset(24, -18),
    );
    await tester.pump();
    expect(
      tester.widget<PlannerEventColorPreview>(preview).preference.accentArgb,
      isNot(originalAccent),
    );
    await tester.tap(find.byKey(const Key('planner-event-color-cancel')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('planner-event-color-picker')), findsNothing);
    expect(
      tester.widget<PlannerEventColorPreview>(preview).preference.accentArgb,
      originalAccent,
    );
    expect(await database.select(database.plannerPreferences).get(), isEmpty);

    await tester.tap(jobAccent);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('planner-event-color-save')));
    await tester.pumpAndSettle();
    final savedAccent =
        (await database.select(database.plannerPreferences).getSingle())
            .eventColorPreferencesJson;
    expect(savedAccent, contains('job_application'));

    final jobSurface = find.byKey(
      const Key('event-color-swatch-Job Application-Event background'),
    );
    await tester.tap(jobSurface);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('planner-event-color-save')));
    await tester.pumpAndSettle();
    final savedPair =
        (await database.select(database.plannerPreferences).getSingle())
            .eventColorPreferencesJson;
    expect(savedPair, contains('accent'));
    expect(savedPair, contains('surface'));

    await tester.drag(
      find.byKey(const Key('planner-event-colors-list')),
      const Offset(0, -2000),
    );
    await tester.pumpAndSettle();
    expect(find.text('Contact Group Colors'), findsOneWidget);
    expect(find.text('Default Groups'), findsOneWidget);
    expect(find.text('Groups'), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const Key('event-color-row-meal')),
        matching: find.text('Meal'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('event-color-row-other')),
        matching: find.text('Other'),
      ),
      findsOneWidget,
    );
    // C2: the four built-in default groups are seeded as real ContactGroup
    // rows and rendered under Default Groups.
    for (final key in <String>['family', 'friends', 'avoid', 'other']) {
      expect(
        find.byKey(Key('planner-group-color-row-$key')),
        findsOneWidget,
        reason: 'built-in $key row rendered',
      );
    }
    await tester.tap(find.byKey(const Key('group-color-swatch-family')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('group-recommended-colors-title')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const Key('group-recommended-color-Antique gold')),
    );
    await tester.tap(find.byKey(const Key('group-color-editor-save')));
    await tester.pumpAndSettle();

    // Custom Color remains backed by the existing arbitrary picker.
    await tester.tap(find.byKey(const Key('group-color-swatch-family')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('group-custom-color')));
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const Key('planner-event-color-sv-gesture')),
      const Offset(24, -18),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('planner-event-color-save')));
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const Key('group-color-editor-scroll')),
      const Offset(0, -1200),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const Key('group-color-editor-save')),
    );
    await tester.tap(find.byKey(const Key('group-color-editor-save')));
    await tester.pumpAndSettle();
    // C2: the edit persists to the REAL ContactGroup row, not Store A.
    final familyRow = await (database.select(
      database.contactGroups,
    )..where((table) => table.name.equals('Family'))).getSingle();
    expect(
      familyRow.colorValue,
      isNot(ContactBuiltInGroupDefaults.family.colorArgb),
    );
    final savedPrefs =
        (await database.select(database.plannerPreferences).getSingle())
            .eventColorPreferencesJson;
    expect(
      savedPrefs,
      isNot(contains('"groups"')),
      reason: 'Store A group map stays dormant',
    );

    await tester.tap(
      find.byKey(const Key('planner-event-colors-restore-defaults')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('planner-event-colors-restore-dialog')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const Key('planner-event-colors-restore-cancel')),
    );
    await tester.pumpAndSettle();
    expect(
      (await database.select(database.plannerPreferences).getSingle())
          .eventColorPreferencesJson,
      contains('job_application'),
    );

    await tester.tap(
      find.byKey(const Key('planner-event-colors-restore-defaults')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('planner-event-colors-restore-confirm')),
    );
    await tester.pumpAndSettle();
    final afterEventRestore =
        (await database.select(database.plannerPreferences).getSingle())
            .eventColorPreferencesJson;
    expect(afterEventRestore, isNot(contains('job_application')));
    // Event restore does not touch the real group rows.
    final familyAfterEventRestore = await (database.select(
      database.contactGroups,
    )..where((table) => table.name.equals('Family'))).getSingle();
    expect(
      familyAfterEventRestore.colorValue,
      isNot(ContactBuiltInGroupDefaults.family.colorArgb),
      reason: 'Event restore leaves group colors alone',
    );

    // The group section grows after the built-in rows are seeded
    // asynchronously; re-scroll so the restore button is built and hittable.
    await tester.drag(
      find.byKey(const Key('planner-event-colors-list')),
      const Offset(0, -1000),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('planner-group-colors-restore-defaults')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('planner-group-colors-restore-dialog')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const Key('planner-group-colors-restore-confirm')),
    );
    await tester.pumpAndSettle();
    // Restore Group Defaults resets ONLY the real built-in rows.
    final familyAfterGroupRestore = await (database.select(
      database.contactGroups,
    )..where((table) => table.name.equals('Family'))).getSingle();
    expect(
      familyAfterGroupRestore.colorValue,
      ContactBuiltInGroupDefaults.family.colorArgb,
      reason: 'Restore Group Defaults resets the built-in row',
    );

    tester.view.physicalSize = const Size(360, 844);
    tester.platformDispatcher.textScaleFactorTestValue = 1;
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byType(PlannerEventColorPreview).first),
      const Size(126, 40),
    );
    tester.view.physicalSize = const Size(393, 844);
    tester.platformDispatcher.textScaleFactorTestValue = 1.15;
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    tester.view.physicalSize = const Size(411, 844);
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('Recommended Colors Apply persists the exact mapped dark '
      'surface', (tester) async {
    tester.view.physicalSize = const Size(393, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
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
      ),
    );
    await tester.pumpAndSettle();
    // NX-07/08: no More tab — Settings lives in the drawer.
    await tester.tap(find.byKey(const Key('home-hamburger')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('drawer-account-settings')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('settings-colors')),
      160,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-colors')));
    await tester.pumpAndSettle();

    // Open the Recommended Colors dialog for Job Application and pick Dusty
    // Rose (a palette member) explicitly, then Apply.
    await tester.tap(
      find.byKey(const Key('event-color-recommended-job_application')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('recommended-event-colors-dialog')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const Key('recommended-event-color-Dusty Rose')),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('recommended-event-colors-apply')));
    await tester.pumpAndSettle();

    final row = await database.select(database.plannerPreferences).getSingle();
    final saved = EventColorPreferenceCodec.decode(
      row.eventColorPreferencesJson,
    )['job_application'];
    expect(saved?.accentArgb, 0xFFC96B8F);
    // Dusty Rose's locked dark partner (correction pack 03).
    expect(
      saved?.surfaceArgb,
      0xFF58464E,
      reason: 'a recommended Apply must persist the mapped dark surface',
    );
  });
}
