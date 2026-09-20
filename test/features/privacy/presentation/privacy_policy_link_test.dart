import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/privacy/presentation/privacy_policy_link.dart';

import '../../../support/test_dependencies.dart';

/// The published page the Settings row must open, written out in full so this
/// test fails if the constant is ever repointed somewhere else.
const String canonicalPrivacyPolicyUrl =
    'https://nexttransferapp-create.github.io/planwardlabs-legal/privacy/';

/// Records external handoffs instead of touching the platform launcher.
final class RecordingUriLauncher {
  RecordingUriLauncher({this.result = true});

  /// What the platform reports back: true when an app accepted the handoff.
  bool result;

  final List<Uri> launched = <Uri>[];

  Future<bool> call(Uri uri) async {
    launched.add(uri);
    return result;
  }
}

void main() {
  testWidgets(
    'Privacy and Data links to the canonical published Privacy Policy',
    (tester) async {
      final launcher = RecordingUriLauncher();
      final harness = await _openPrivacyCenter(tester, launcher: launcher);
      addTearDown(harness.repository.database.close);

      // Requirement: the row exists under Settings -> Privacy and Data.
      expect(find.text('Privacy Policy'), findsOneWidget);
      expect(
        find.text('Read how Next Transfer handles your data.'),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('privacy-policy-link')));
      await tester.pumpAndSettle();

      // Requirement: tapping performs the EXTERNAL handoff for the exact
      // canonical URL, with nothing about the user or device appended.
      expect(launcher.launched, hasLength(1));
      expect(launcher.launched.single.toString(), canonicalPrivacyPolicyUrl);
      expect(launcher.launched.single.query, isEmpty);
      expect(launcher.launched.single.fragment, isEmpty);
      expect(privacyPolicyUrl, canonicalPrivacyPolicyUrl);

      // Requirement: the link is not a permission-bearing action.
      expect(harness.permissionGateway.requestCount, 0);

      // Requirement: the schema is untouched by this correction.
      expect(harness.repository.database.schemaVersion, 48);

      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a handoff no installed app accepts reports feedback instead of failing',
    (tester) async {
      final launcher = RecordingUriLauncher(result: false);
      final harness = await _openPrivacyCenter(tester, launcher: launcher);
      addTearDown(harness.repository.database.close);

      await tester.tap(find.byKey(const Key('privacy-policy-link')));
      await tester.pumpAndSettle();

      expect(find.text('Unable to open the Privacy Policy.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('existing privacy disclosures and entries remain unchanged', (
    tester,
  ) async {
    final launcher = RecordingUriLauncher();
    final harness = await _openPrivacyCenter(tester, launcher: launcher);
    addTearDown(harness.repository.database.close);
    final scrollable = find.byType(Scrollable).first;

    // The standing factual disclaimer.
    await tester.scrollUntilVisible(
      find.textContaining('does not claim full-database encryption'),
      180,
      scrollable: scrollable,
    );
    expect(
      find.textContaining('does not claim full-database encryption'),
      findsOneWidget,
    );

    // Privacy Lock and the Backup & Restore entry are untouched.
    await tester.scrollUntilVisible(
      find.byKey(const Key('privacy-lock-switch')),
      -180,
      scrollable: scrollable,
    );
    expect(find.byKey(const Key('privacy-lock-switch')), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const Key('backup-recovery-tile')),
      180,
      scrollable: scrollable,
    );
    expect(find.byKey(const Key('backup-recovery-tile')), findsOneWidget);
    expect(harness.permissionGateway.requestCount, 0);
    expect(tester.takeException(), isNull);
  });
}

/// Pumps the real app, signs in past onboarding, and walks the established
/// drawer -> Settings -> Privacy and Data path with [launcher] installed as the
/// external-launch seam.
Future<TestPrivacyDependencies> _openPrivacyCenter(
  WidgetTester tester, {
  required RecordingUriLauncher launcher,
}) async {
  final database = openMemoryDatabase();
  final privacy = TestPrivacyDependencies(database: database);
  final startupRepository = buildTestRepository(
    database: database,
    privacyGate: privacy.gate,
  );
  await startupRepository.completeOnboarding();

  await tester.pumpWidget(
    privacy.buildApp(
      environment: const AppEnvironment(
        name: AppEnvironmentName.production,
        label: 'PRODUCTION',
      ),
      diagnostics: SanitizedDiagnostics(),
      startupRepository: startupRepository,
      extraOverrides: <Override>[
        externalUriLauncherProvider.overrideWithValue(launcher.call),
      ],
    ),
  );
  await tester.pumpAndSettle();

  await tester.tap(find.byKey(const Key('home-hamburger')));
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(
    find.byKey(const Key('drawer-account-settings')),
    300,
    scrollable: find.descendant(
      of: find.byKey(const Key('global-app-drawer-list')),
      matching: find.byType(Scrollable),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('drawer-account-settings')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('settings-privacy-data')));
  await tester.pumpAndSettle();

  await tester.scrollUntilVisible(
    find.byKey(const Key('privacy-policy-link')),
    200,
    scrollable: find.byType(Scrollable).first,
  );
  return privacy;
}
