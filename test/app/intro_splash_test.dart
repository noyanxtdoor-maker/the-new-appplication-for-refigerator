import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/app/intro_splash.dart';
import 'package:rmplanner/features/startup/presentation/startup_screen.dart';

void main() {
  testWidgets('M5: approved intro artwork is opaque and full-screen', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: NextTransferIntroSplash()));

    expect(find.byKey(const Key('next-transfer-intro-splash')), findsOneWidget);
    expect(
      find.byKey(const Key('next-transfer-intro-splash-artwork')),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(NextTransferIntroSplash.semanticLabel),
      findsOneWidget,
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Opening your local planner…'), findsNothing);

    final artwork = tester.widget<Image>(
      find.byKey(const Key('next-transfer-intro-splash-artwork')),
    );
    expect(artwork.fit, BoxFit.cover);
    expect(artwork.image, const AssetImage(NextTransferIntroSplash.assetPath));
  });

  testWidgets('M5: startup opening route presents only the approved intro', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: StartupScreen()));

    expect(find.byKey(const Key('next-transfer-intro-splash')), findsOneWidget);
    expect(find.byType(Scaffold), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}
