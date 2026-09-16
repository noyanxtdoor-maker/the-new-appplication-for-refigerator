import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/features/contacts/application/contact_providers.dart';
import 'package:rmplanner/features/contacts/data/drift_contact_repository.dart';
import 'package:rmplanner/features/contacts/domain/contact.dart';
import 'package:rmplanner/features/contacts/presentation/device_contact_import_screen.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/privacy/domain/permission_summary.dart';

import '../../../support/test_dependencies.dart';

/// POST-M7 CLOSURE (2026-09-16) — device-import count + truthful-result contract.
///
/// The bulk import used to abort on the first draft that repeated a normalized
/// method WITHIN ONE device contact: only the prefix before the offender
/// persisted, and the screen returned to an unchanged selection page with no
/// message at all.  These tests drive the real screen over a real repository and
/// pin:  N selected -> N imported, a within-contact repeat is not fatal, and a
/// hard failure surfaces truthfully instead of silently or behind a spinner.
void main() {
  List<DeviceContactDraft> cleanDrafts(int count) => <DeviceContactDraft>[
    for (var i = 0; i < count; i++)
      DeviceContactDraft(
        displayName: 'Person $i',
        firstName: 'Person',
        lastName: '$i',
        phones: <String>['+1 555 ${i.toString().padLeft(4, '0')}'],
      ),
  ];

  // Same number under two labels on ONE device contact.
  const duplicateLabelDraft = DeviceContactDraft(
    displayName: 'Person offender',
    firstName: 'Person',
    lastName: 'offender',
    phones: <String>['+1 555 0999', '(1) 555-0999'],
  );

  Future<
    ({AppDatabase database, DriftContactRepository contacts, String profileId})
  >
  harness() async {
    final database = openMemoryDatabase();
    final startup = buildTestRepository(database: database);
    final profile = await startup.completeOnboarding();
    return (
      database: database,
      contacts: DriftContactRepository(
        database: database,
        clock: FixedClock(DateTime.utc(2026, 9, 16, 12)),
        identifiers: SequenceIdentifierSource(<String>[
          for (var i = 0; i < 4000; i++)
            'c${i.toString().padLeft(7, '0')}-0000-4000-8000-000000000000',
        ]),
      ),
      profileId: profile.id,
    );
  }

  Future<void> openSelector(
    WidgetTester tester, {
    required List<DeviceContactDraft> drafts,
    required DriftContactRepository contacts,
    required String profileId,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          contactRepositoryProvider.overrideWithValue(contacts),
          contactProfileIdProvider.overrideWithValue(profileId),
        ],
        child: MaterialApp(
          home: DeviceContactImportScreen(
            deviceReader: () async => drafts,
            permissionRequester: () async =>
                OperatingSystemPermissionState.granted,
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('device-import-start')));
    await tester.pumpAndSettle();
  }

  testWidgets('Select All then Import persists every selected contact', (
    tester,
  ) async {
    final result = await harness();
    addTearDown(result.database.close);
    await openSelector(
      tester,
      drafts: cleanDrafts(12),
      contacts: result.contacts,
      profileId: result.profileId,
    );

    await tester.tap(find.byKey(const Key('device-import-select-all')));
    await tester.pump();
    expect(find.text('Import 12'), findsOneWidget);

    await tester.tap(find.byKey(const Key('device-import-confirm')));
    await tester.pumpAndSettle();

    // The truthful result surface, not an unchanged selection page.
    expect(find.text('12 contacts imported'), findsOneWidget);

    final stored = await result.contacts.readContacts(
      profileId: result.profileId,
      criteria: const ContactFilterCriteria(),
      sortBy: ContactSortBy.name,
      today: PlannerDate(year: 2026, month: 9, day: 16),
    );
    expect(stored, hasLength(12));
  });

  testWidgets('a within-contact repeat never truncates the batch', (
    tester,
  ) async {
    final result = await harness();
    addTearDown(result.database.close);
    final drafts = cleanDrafts(24);
    drafts[7] = duplicateLabelDraft;
    await openSelector(
      tester,
      drafts: drafts,
      contacts: result.contacts,
      profileId: result.profileId,
    );

    await tester.tap(find.byKey(const Key('device-import-select-all')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('device-import-confirm')));
    await tester.pumpAndSettle();

    expect(find.text('24 contacts imported'), findsOneWidget);

    final stored = await result.contacts.readContacts(
      profileId: result.profileId,
      criteria: const ContactFilterCriteria(),
      sortBy: ContactSortBy.name,
      today: PlannerDate(year: 2026, month: 9, day: 16),
    );
    expect(stored, hasLength(24));
  });

  testWidgets('a hard import failure is surfaced, never silent or a spinner', (
    tester,
  ) async {
    final result = await harness();
    // No addTearDown: this test closes the database on purpose.
    await openSelector(
      tester,
      drafts: cleanDrafts(6),
      contacts: result.contacts,
      profileId: result.profileId,
    );

    await tester.tap(find.byKey(const Key('device-import-select-all')));
    await tester.pump();

    // Force the write path to fail after selection succeeded.
    await result.database.close();

    await tester.tap(find.byKey(const Key('device-import-confirm')));
    await tester.pumpAndSettle();

    expect(
      find.byType(CircularProgressIndicator),
      findsNothing,
      reason: 'the import must never leave the user on a spinner',
    );
    expect(
      find.textContaining('could not be completed'),
      findsOneWidget,
      reason: 'the failure must be explained, not hidden',
    );
  });
}
