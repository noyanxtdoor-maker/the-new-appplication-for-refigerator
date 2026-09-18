import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/features/startup/presentation/startup_screen.dart';

void main() {
  testWidgets('M5 splash is an opaque responsive approved-logo field', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: StartupScreen()));

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.textContaining('Opening your local planner'), findsNothing);
    expect(find.byType(Image), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Scaffold &&
            widget.backgroundColor == const Color(0xFF002A72),
      ),
      findsOneWidget,
    );

    final logo = tester.getSize(find.byType(Image));
    final viewport = tester.getSize(find.byType(StartupScreen));
    expect(
      logo.width,
      closeTo((viewport.width * 0.46).clamp(0, 360).toDouble(), 0.1),
    );
  });

  test('M5 Android resources map the approved asset to adaptive and launch UI', () {
    final root = Directory.current.path;
    final pubspec = File('$root/pubspec.yaml').readAsStringSync();
    final manifest = File(
      '$root/android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    final adaptive = File(
      '$root/android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml',
    ).readAsStringSync();
    final launch = File(
      '$root/android/app/src/main/res/drawable/launch_background.xml',
    ).readAsStringSync();
    final api31 = File(
      '$root/android/app/src/main/res/values-v31/styles.xml',
    ).readAsStringSync();

    expect(pubspec, contains('assets/branding/'));
    expect(
      File('$root/lib/app/router/app_router.dart').readAsStringSync(),
      contains('const NoTransitionPage<void>(child: StartupScreen())'),
    );
    expect(manifest, contains('android:icon="@mipmap/ic_launcher"'));
    expect(manifest, contains('android:roundIcon="@mipmap/ic_launcher"'));
    expect(adaptive, contains('@drawable/ic_launcher_foreground'));
    expect(adaptive, contains('@color/next_transfer_deep_blue'));
    expect(launch, contains('@drawable/launch_logo'));
    expect(api31, contains('android:windowSplashScreenBackground'));
    expect(api31, contains('android:windowSplashScreenAnimatedIcon'));
    expect(
      File('$root/android/app/src/main/res/values/styles.xml').readAsStringSync(),
      contains('android:windowBackground">@color/next_transfer_deep_blue'),
    );
  });
}
