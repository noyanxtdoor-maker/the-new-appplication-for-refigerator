import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/features/contacts/domain/contact.dart';
import 'package:rmplanner/features/contacts/presentation/device_contact_import_screen.dart';
import 'package:rmplanner/features/privacy/domain/permission_summary.dart';

void main() {
  final drafts = <DeviceContactDraft>[
    const DeviceContactDraft(
      displayName: 'Maria Santos',
      phones: <String>['+63 917 555 0101'],
      emails: <String>['maria@example.com'],
    ),
    const DeviceContactDraft(
      displayName: 'Diego Cruz',
      phones: <String>['+63 917 555 0202'],
      emails: <String>['diego@example.com'],
    ),
    const DeviceContactDraft(
      displayName: 'Lina Reyes',
      phones: <String>['+63 917 555 0303'],
      emails: <String>['lina@example.com'],
    ),
  ];

  Future<void> openSelector(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
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

  testWidgets('filters by name, email, and phone', (tester) async {
    await openSelector(tester);

    await tester.enterText(
      find.byKey(const Key('device-import-search')),
      'diego@example',
    );
    await tester.pump();
    expect(find.text('Diego Cruz'), findsOneWidget);
    expect(find.text('Maria Santos'), findsNothing);

    await tester.enterText(
      find.byKey(const Key('device-import-search')),
      '5550303',
    );
    await tester.pump();
    expect(find.text('Lina Reyes'), findsOneWidget);
    expect(find.text('Diego Cruz'), findsNothing);
  });

  testWidgets('Select visible never changes hidden selections', (tester) async {
    await openSelector(tester);

    await tester.tap(find.byKey(const Key('device-import-row-0')));
    await tester.enterText(
      find.byKey(const Key('device-import-search')),
      'diego',
    );
    await tester.pump();
    expect(find.text('Select visible'), findsOneWidget);

    await tester.tap(find.byKey(const Key('device-import-select-all')));
    await tester.pump();
    expect(find.text('Import 2'), findsOneWidget);

    await tester.tap(find.byKey(const Key('device-import-select-all')));
    await tester.pump();
    expect(find.text('Import 1'), findsOneWidget);
  });
}
