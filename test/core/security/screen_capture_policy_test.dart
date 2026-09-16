import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../../tool/authority_rules.dart';

void main() {
  // M7 reconciliation (2026-09-16): this test previously banned the substring
  // `addFlags` anywhere in MainActivity. That was too broad — it rejected the
  // ACCEPTED `com.nexttransfer.rmplanner/social_app_home` bridge, which
  // legitimately calls `intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)`, so
  // this test had been failing on the accepted tree. The assertion is now
  // delegated to the shared authority rules, which is STRICTER for the privacy
  // intent: `FLAG_SECURE`, `WindowManager`, `window.addFlags`,
  // `window.clearFlags`, `getWindow(` and `setFlags(` are all still rejected,
  // and the accepted Intent bridge flag must still be present.
  test(
    'owner amendment leaves no Android screen-capture blocking code path',
    () {
      final activity = File(
        'android/app/src/main/kotlin/com/nexttransfer/rmplanner/'
        'MainActivity.kt',
      ).readAsStringSync();
      final pubspec = File('pubspec.yaml').readAsStringSync();

      expect(checkMainActivityKt(activity), isEmpty);
      expect(activity, isNot(contains('FLAG_SECURE')));
      expect(activity, isNot(contains('WindowManager')));
      expect(pubspec, isNot(contains('secure_screen')));
      expect(pubspec, isNot(contains('screenshot_block')));
    },
  );

  // The negative direction, proven through the same shared rules so this
  // suite cannot silently lose the privacy guard.
  test('forbidden window flags still fail the screen-capture policy', () {
    const activity =
        'package com.nexttransfer.rmplanner\n'
        'class MainActivity : FlutterFragmentActivity() {\n'
        '  intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)\n'
        '}\n';

    expect(checkMainActivityKt(activity), isEmpty);
    expect(checkMainActivityKt('$activity window.addFlags(0)\n'), isNotEmpty);
    expect(checkMainActivityKt('$activity\nFLAG_SECURE\n'), isNotEmpty);
    expect(
      checkMainActivityKt('$activity\nimport android.view.WindowManager\n'),
      isNotEmpty,
    );
  });
}
