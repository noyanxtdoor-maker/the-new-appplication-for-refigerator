// M5 (clean restart) — the app-owned startup splash.
//
// The splash is presentation only: it owns no route, no startup decision and no
// privacy state, so these tests pin only its own shipped contract:
//   * it presents the single approved asset full-screen, so no phone aspect
//     ratio can leave an empty band at the top or the bottom;
//   * it starts as an opaque brand field and only then fades the approved
//     emblem in, so no app surface behind it is ever visible;
//   * it blocks pointers while it is mounted;
//   * it removes itself exactly once, and only after the hold has elapsed.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/app/m5_app_splash.dart';

void main() {
  Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

  List<FadeTransition> splashesFades(WidgetTester tester) => tester
      .widgetList<FadeTransition>(
        find.descendant(
          of: find.byType(M5AppSplash),
          matching: find.byType(FadeTransition),
        ),
      )
      .toList();

  testWidgets('presents the approved asset full-screen over the brand field', (
    tester,
  ) async {
    await tester.pumpWidget(host(M5AppSplash(onFinished: () {})));
    await tester.pump();

    final image = tester.widget<Image>(
      find.descendant(
        of: find.byType(M5AppSplash),
        matching: find.byType(Image),
      ),
    );
    expect(image.image, isA<AssetImage>());
    expect((image.image as AssetImage).assetName, nextTransferSplashAsset);
    expect(image.fit, BoxFit.cover, reason: 'cover removes top/bottom bands');
    expect(image.alignment, Alignment.center);

    // The overlay owns the whole window and blocks the app behind it. (The
    // navigator contributes its own, non-absorbing AbsorbPointer, so the
    // assertion is scoped to the splash.)
    final absorbers = tester
        .widgetList<AbsorbPointer>(
          find.descendant(
            of: find.byType(M5AppSplash),
            matching: find.byType(AbsorbPointer),
          ),
        )
        .toList();
    expect(absorbers, hasLength(1));
    expect(absorbers.single.absorbing, isTrue);

    // The field behind the artwork is the approved brand colour, not a theme
    // surface, so the hand-off from the Android launch window is invisible.
    final field = tester
        .widgetList<ColoredBox>(
          find.descendant(
            of: find.byType(M5AppSplash),
            matching: find.byType(ColoredBox),
          ),
        )
        .first;
    expect(field.color, nextTransferSplashBlue);
  });

  testWidgets('starts as the opaque brand field before the emblem fades in', (
    tester,
  ) async {
    await tester.pumpWidget(host(M5AppSplash(onFinished: () {})));

    final fades = splashesFades(tester);
    expect(fades, hasLength(2));
    expect(
      fades.first.opacity.value,
      1.0,
      reason: 'the brand field is opaque from the very first frame',
    );
    expect(
      fades.last.opacity.value,
      0.0,
      reason: 'the approved emblem has not faded in yet',
    );
  });

  testWidgets('blocks pointers while it is mounted', (tester) async {
    var backgroundTaps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Stack(
          children: <Widget>[
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => backgroundTaps++,
                child: const SizedBox.expand(),
              ),
            ),
            Positioned.fill(child: M5AppSplash(onFinished: () {})),
          ],
        ),
      ),
    );
    await tester.pump();

    await tester.tapAt(tester.getCenter(find.byType(M5AppSplash)));
    await tester.pump();

    expect(
      backgroundTaps,
      0,
      reason: 'the app behind the splash is neither visible nor reachable',
    );
  });

  testWidgets('removes itself exactly once, only after the hold elapses', (
    tester,
  ) async {
    var finished = 0;
    await tester.pumpWidget(host(M5AppSplash(onFinished: () => finished++)));
    await tester.pump();

    await tester.pump(
      nextTransferSplashFadeIn +
          nextTransferSplashHold -
          const Duration(milliseconds: 16),
    );
    expect(finished, 0, reason: 'the finished splash still holds');

    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(nextTransferSplashFadeOut);
    expect(finished, 1);

    await tester.pumpAndSettle();
    expect(finished, 1, reason: 'the overlay only ever reports once');
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
