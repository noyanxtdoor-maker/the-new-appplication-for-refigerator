import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/features/notifications/application/background_diagnostics_provider.dart';
import 'package:rmplanner/features/privacy/presentation/diagnostic_preview_screen.dart';
import 'package:rmplanner/features/startup/application/startup_providers.dart';

void main() {
  final snapshot = BackgroundDiagnosticSnapshot(
    capturedAtUtc: DateTime.utc(2026, 9, 10, 12),
    notificationAdapter: DiagnosticAdapterState.available,
    backgroundAdapter: DiagnosticAdapterState.unavailable,
    countsByState: const <String, int>{'scheduled': 2},
    recoveryState: 'Not recorded',
    pendingNativeReminderCount: 1,
    workerState: 'Unavailable',
  );

  Widget buildPreview() => ProviderScope(
    overrides: <Override>[
      diagnosticsProvider.overrideWithValue(SanitizedDiagnostics()),
      backgroundDiagnosticsProvider.overrideWith((ref) async => snapshot),
    ],
    child: const MaterialApp(home: DiagnosticPreviewScreen()),
  );

  testWidgets(
    'T71 background cards require both approved details and explicit Prepare',
    (tester) async {
      await tester.pumpWidget(buildPreview());
      expect(find.text('Background work'), findsNothing);

      await tester.tap(
        find.byKey(const Key('prepare-diagnostic-preview-button')),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Background work'), findsNothing);

      await tester.tap(find.byKey(const Key('diagnostic-context-checkbox')));
      await tester.pump();
      expect(find.text('Background work'), findsNothing);

      await tester.tap(
        find.byKey(const Key('prepare-diagnostic-preview-button')),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Background work'), findsOneWidget);
      expect(find.text('Notification scheduler'), findsOneWidget);
      expect(find.text('Background scheduler'), findsOneWidget);
      expect(find.text('Pending reminders'), findsOneWidget);
    },
  );

  testWidgets(
    'T72 background heading reuses titleMedium w700 with no route-specific chrome',
    (tester) async {
      await tester.pumpWidget(buildPreview());
      await tester.tap(find.byKey(const Key('diagnostic-context-checkbox')));
      await tester.tap(
        find.byKey(const Key('prepare-diagnostic-preview-button')),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      final heading = tester.widget<Text>(find.text('Background work'));
      expect(heading.style?.fontWeight, FontWeight.w700);
      expect(find.byType(Navigator), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
