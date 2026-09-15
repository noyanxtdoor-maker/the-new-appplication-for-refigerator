import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/app/m5_app_splash.dart';

void main() {
  Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

  testWidgets(
    'first submitted branded frame is opaque and uses the approved asset',
    (tester) async {
      await tester.pumpWidget(host(const M5AppSplash()));
      await tester.pump();

      final image = tester.widget<Image>(
        find.descendant(
          of: find.byType(M5AppSplash),
          matching: find.byType(Image),
        ),
      );
      expect(image.image, same(nextTransferSplashImage));
      expect(image.fit, BoxFit.cover, reason: 'cover removes top/bottom bands');
      expect(image.alignment, Alignment.center);
      expect(
        find.descendant(
          of: find.byType(M5AppSplash),
          matching: find.byType(AnimatedOpacity),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byType(M5AppSplash),
          matching: find.byType(FadeTransition),
        ),
        findsNothing,
      );

      final field = tester.widget<ColoredBox>(
        find.descendant(
          of: find.byType(M5AppSplash),
          matching: find.byType(ColoredBox),
        ),
      );
      expect(field.color, nextTransferSplashBlue);
      expect(find.bySemanticsLabel('Opening Next Transfer'), findsOneWidget);
    },
  );

  testWidgets('blocks pointers and underlying semantics while it is mounted', (
    tester,
  ) async {
    var backgroundTaps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Stack(
          children: <Widget>[
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => backgroundTaps++,
                child: Semantics(
                  label: 'Private app content',
                  child: const SizedBox.expand(),
                ),
              ),
            ),
            const Positioned.fill(child: M5AppSplash()),
          ],
        ),
      ),
    );
    await tester.pump();

    await tester.tapAt(tester.getCenter(find.byType(M5AppSplash)));
    await tester.pump();

    expect(backgroundTaps, 0);
    expect(find.bySemanticsLabel('Private app content'), findsNothing);
    expect(
      find.descendant(
        of: find.byType(M5AppSplash),
        matching: find.byType(AbsorbPointer),
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    'decode failure is explicit and cannot silently become blue-only',
    (tester) async {
      var acknowledgements = 0;
      await tester.pumpWidget(
        host(
          M5AppSplash(
            imageFailed: true,
            onFailureAcknowledged: () => acknowledgements++,
          ),
        ),
      );
      await tester.pump();

      expect(
        find.text('Next Transfer could not load its approved launch artwork.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Continue safely'));
      expect(acknowledgements, 1);
    },
  );

  test('first-frame gate balances one deferral and is idempotent', () {
    var deferrals = 0;
    var releases = 0;
    final gate = SplashFirstFrameGate(
      deferFirstFrame: () => deferrals++,
      allowFirstFrame: () => releases++,
    );

    gate.defer();
    gate.defer();
    gate.release();
    gate.release();

    expect(deferrals, 1);
    expect(releases, 1);
  });

  test('the app-owned splash ships enabled', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(appSplashEnabledProvider), isTrue);
  });

  test('the brand field is the approved splash asset edge colour', () {
    expect(nextTransferSplashBlue, const Color(0xFF002161));
  });
}
