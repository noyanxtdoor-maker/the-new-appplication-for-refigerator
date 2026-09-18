import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/app/m5_app_splash.dart';

void main() {
  testWidgets('M5 splash is opaque, full-screen, and uses the supplied asset', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: M5AppSplashScreen())),
    );

    final image = tester.widget<Image>(
      find.byKey(const Key('m5-app-owned-splash')),
    );
    expect(image.image, isA<AssetImage>());
    expect((image.image as AssetImage).assetName,
        'assets/branding/next_transfer_splash.png');
    expect(image.fit, BoxFit.cover);
    expect(find.bySemanticsLabel('Next Transfer is opening'), findsOneWidget);
  });
}
