// M7: fail-first coverage for the reconciled authority gate.
//
// `tool/verify_authority.dart` is the repository's own authority gate and runs
// in `.github/workflows/quality.yml`. M7 (2026-09-16) reconciled four stale
// VS-08-era expectations against the ACCEPTED M1-M6 product:
//
//   1. MainActivity: `addFlags` was rejected wholesale, but the accepted
//      `social_app_home` bridge legitimately calls
//      `intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)`. The guard is narrowed
//      to window/screenshot manipulation.
//   2. Manifest: exactly one permission was demanded; the accepted scope is the
//      exact seven-permission set. Exact-set verification is used so an EIGHTH
//      permission still fails.
//   3. Dependencies: `workmanager:` was forbidden but is accepted at `90d5fd0`
//      and pinned `0.10.9`; the pin must be exact and other forbidden families
//      stay forbidden.
//   4. Schema: `?? 10` was demanded; the frozen product law is `?? 47`.
//
// M-3 (2026-09-21) replaced the manifest permission regex with real XML
// parsing. The final group pins the shapes that regex could not see, the
// structural laws (duplicates, scope attributes, missing names, malformed
// XML), and the positives that must still pass (whitespace, XML comments,
// attribute order on non-permission elements).
//
// This file proves BOTH directions, so the reconciliation cannot silently
// weaken the protections it preserves.
//
// The rule set lives in `tool/authority_rules.dart` (one source of truth, no
// new framework). The same MainActivity window guard is additionally asserted
// from the security suite in
// `test/core/security/screen_capture_policy_test.dart`.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/authority_rules.dart';

const String _mainActivityPath =
    'android/app/src/main/kotlin/com/nexttransfer/rmplanner/MainActivity.kt';
const String _manifestPath = 'android/app/src/main/AndroidManifest.xml';
const String _pubspecPath = 'pubspec.yaml';
const String _schemaPath = 'lib/core/database/app_database.dart';
const String _toolchainPath = 'tool/toolchain.json';

String _read(String path) => File(path).readAsStringSync();

void main() {
  group('authority gate — the accepted tree passes', () {
    test('accepted MainActivity keeps identity, the Intent bridge and no '
        'window/privacy manipulation', () {
      final text = _read(_mainActivityPath);

      expect(checkMainActivityKt(text), isEmpty);
      expect(text, contains(approvedMainActivityIntentFlag));
    });

    test('accepted manifest declares exactly the approved permission set', () {
      final text = _read(_manifestPath);

      expect(checkProductionManifest(text), isEmpty);
      expect(
        scanManifestPermissions(text).declarations.map((d) => d.name).toSet(),
        approvedManifestPermissions,
      );
      expect(approvedManifestPermissions, hasLength(7));
    });

    test('accepted pubspec pins every approved dependency exactly and carries '
        'no forbidden dependency family', () {
      final text = _read(_pubspecPath);

      expect(checkPubspec(text), isEmpty);
      expect(pinnedVersionOf(text, 'workmanager'), '0.10.9');
    });

    test('frozen schema boundary holds at version $approvedSchemaVersion', () {
      final text = _read(_schemaPath);

      expect(checkSchemaBoundary(text), isEmpty);
      expect(
        text,
        contains(
          'int get schemaVersion => '
          '_schemaVersionOverride ?? $approvedSchemaVersion',
        ),
      );
    });
  });

  group('authority gate — negative direction still fails', () {
    late String mainActivity;
    late String manifest;
    late String pubspec;
    late String schema;

    setUp(() {
      mainActivity = _read(_mainActivityPath);
      manifest = _read(_manifestPath);
      pubspec = _read(_pubspecPath);
      schema = _read(_schemaPath);
    });

    test('FLAG_SECURE introduced in MainActivity fails', () {
      expect(
        checkMainActivityKt('$mainActivity\nval blocked = "FLAG_SECURE"\n'),
        isNotEmpty,
      );
    });

    test('WindowManager privacy manipulation fails', () {
      expect(
        checkMainActivityKt(
          '$mainActivity\nimport android.view.WindowManager\n',
        ),
        isNotEmpty,
      );
    });

    test('window.addFlags manipulation fails', () {
      expect(
        checkMainActivityKt('$mainActivity\nwindow.addFlags(0)\n'),
        isNotEmpty,
      );
    });

    test('window.clearFlags manipulation fails', () {
      expect(
        checkMainActivityKt('$mainActivity\nwindow.clearFlags(0)\n'),
        isNotEmpty,
      );
    });

    test('losing the accepted Intent bridge flag fails', () {
      final stripped = mainActivity.replaceAll(
        'intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)',
        '// bridge flag removed',
      );

      expect(checkMainActivityKt(stripped), isNotEmpty);
    });

    test(
      'the accepted Intent bridge alone is authorized (no false positive)',
      () {
        const minimal =
            'package com.nexttransfer.rmplanner\n'
            'class MainActivity : FlutterFragmentActivity() {\n'
            '    intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)\n'
            '}\n';

        expect(checkMainActivityKt(minimal), isEmpty);
      },
    );

    test('an eighth unexpected Android permission fails', () {
      final mutated = manifest.replaceFirst(
        '<uses-permission android:name="android.permission.INTERNET"/>',
        '<uses-permission android:name="android.permission.INTERNET"/>\n'
            '    <uses-permission android:name="android.permission.CAMERA"/>',
      );

      expect(scanManifestPermissions(mutated).declarations, hasLength(8));
      expect(checkProductionManifest(mutated), isNotEmpty);
    });

    test('removing an expected permission fails', () {
      final mutated = manifest.replaceFirst(
        '<uses-permission android:name="android.permission.USE_BIOMETRIC"/>',
        '',
      );

      expect(checkProductionManifest(mutated), isNotEmpty);
    });

    test('weakening the backup policy fails', () {
      final mutated = manifest.replaceFirst(
        'android:allowBackup="false"',
        'android:allowBackup="true"',
      );

      expect(checkProductionManifest(mutated), isNotEmpty);
    });

    test('a changed WorkManager pin fails', () {
      final mutated = pubspec.replaceFirst(
        'workmanager: 0.10.9',
        'workmanager: 0.11.0',
      );

      expect(checkPubspec(mutated), isNotEmpty);
    });

    test('a loose WorkManager version spec fails', () {
      final mutated = pubspec.replaceFirst(
        'workmanager: 0.10.9',
        'workmanager: ^0.10.9',
      );

      expect(checkPubspec(mutated), isNotEmpty);
    });

    test('an unapproved dependency family fails', () {
      final mutated = pubspec.replaceFirst(
        '  workmanager: 0.10.9',
        '  workmanager: 0.10.9\n  file_picker: 10.0.0',
      );

      expect(checkPubspec(mutated), isNotEmpty);
    });

    test('the superseded schema 47 fails', () {
      final mutated = schema.replaceFirst('?? 48', '?? 47');

      expect(checkSchemaBoundary(mutated), isNotEmpty);
    });

    test('the superseded schema 10 fails', () {
      final mutated = schema.replaceFirst('?? 48', '?? 10');

      expect(checkSchemaBoundary(mutated), isNotEmpty);
    });

    test('a sensitive/token field entering the schema fails', () {
      final mutated = '$schema\n// StringColumn get accessToken => _x;\n';

      expect(checkSchemaBoundary(mutated), isNotEmpty);
    });

    test('removing a frozen schema declaration fails', () {
      final mutated = schema.replaceAll('WeeklyPlanGoalMemberships', 'X');

      expect(checkSchemaBoundary(mutated), isNotEmpty);
    });
  });

  group('authority gate — pin parsing', () {
    test('reads an exact pin from the dependencies block', () {
      expect(
        pinnedVersionOf('dependencies:\n  local_auth: 3.0.2\n', 'local_auth'),
        '3.0.2',
      );
    });

    test(
      'ignores comment lines and returns null when the package is absent',
      () {
        expect(
          pinnedVersionOf(
            'dependencies:\n  # local_auth: 9.9.9\n',
            'local_auth',
          ),
          isNull,
        );
      },
    );

    test('a dev_dependencies pin does not satisfy a dependencies pin', () {
      final pubspec =
          'dependencies:\n  intl: 0.20.3\n'
          'dev_dependencies:\n  local_auth: 3.0.2\n';

      expect(pinnedVersionOf(pubspec, 'local_auth'), isNull);
    });

    test('moving an approved pin out of dependencies fails the gate', () {
      final pubspec =
          'dependencies:\n  intl: 0.20.3\n'
          'dev_dependencies:\n  workmanager: 0.10.9\n';

      expect(checkPubspec(pubspec), isNotEmpty);
    });
  });

  // M-1c (2026-09-21): one ambiguous `"java": "17"` field became two explicit
  // ones. Both directions are proven for BOTH values, so neither the bytecode
  // target nor the build JDK can drift unnoticed again.
  group('authority gate — toolchain authority', () {
    late String toolchain;

    setUp(() {
      toolchain = _read(_toolchainPath);
    });

    test('the live toolchain.json satisfies the locked baseline', () {
      expect(checkToolchain(toolchain), isEmpty);
      expect(toolchain, contains('"flutter": "$approvedFlutterVersion"'));
      expect(
        toolchain,
        contains('"android_organization": "$approvedOrganization"'),
      );
    });

    test('the ambiguous single java field is gone', () {
      expect(toolchain, isNot(contains('"java"')));
    });

    test('the two Java facts are stated separately', () {
      expect(
        toolchain,
        contains('"java_bytecode_target": $approvedJavaBytecodeTarget'),
      );
      expect(toolchain, contains('"java_build_jdk": $approvedJavaBuildJdk'));
      expect(approvedJavaBytecodeTarget, 17);
      expect(approvedJavaBuildJdk, 21);
    });

    test('a build JDK pinned back to 17 fails', () {
      final mutated = toolchain.replaceFirst(
        '"java_build_jdk": 21',
        '"java_build_jdk": 17',
      );

      expect(checkToolchain(mutated), isNotEmpty);
    });

    test('a bytecode target raised to 21 fails', () {
      final mutated = toolchain.replaceFirst(
        '"java_bytecode_target": 17',
        '"java_bytecode_target": 21',
      );

      expect(checkToolchain(mutated), isNotEmpty);
    });

    test('a missing build JDK fails', () {
      final mutated = toolchain.replaceFirst(
        RegExp(r'\s*"java_build_jdk": 21,'),
        '',
      );

      expect(checkToolchain(mutated), isNotEmpty);
    });

    test('a missing bytecode target fails', () {
      final mutated = toolchain.replaceFirst(
        RegExp(r'\s*"java_bytecode_target": 17,'),
        '',
      );

      expect(checkToolchain(mutated), isNotEmpty);
    });

    test('a changed Flutter pin fails', () {
      final mutated = toolchain.replaceFirst(
        '"flutter": "3.44.7"',
        '"flutter": "3.44.6"',
      );

      expect(checkToolchain(mutated), isNotEmpty);
    });

    test('malformed JSON fails closed instead of throwing', () {
      expect(checkToolchain('{ not json'), isNotEmpty);
    });

    test('the controls are real: correcting a mutation restores a pass', () {
      final mutated = toolchain.replaceFirst(
        '"java_build_jdk": 21',
        '"java_build_jdk": 17',
      );

      expect(checkToolchain(mutated), isNotEmpty);
      expect(
        checkToolchain(
          mutated.replaceFirst('"java_build_jdk": 17', '"java_build_jdk": 21'),
        ),
        isEmpty,
      );
    });
  });

  // M-3: the source manifest is parsed as XML. Every mutation below is applied
  // to the REAL manifest text, so each case is a shape a real edit could take.
  //
  // N-8 (an eighth permission in the previously-matched shape) stays covered by
  // `an eighth unexpected Android permission fails` in the group above, and
  // N-13 / N-14 by `removing an expected permission fails` and `weakening the
  // backup policy fails`. This group covers the shapes the regex could not see
  // plus the structural laws.
  group('authority gate — M-3 manifest permissions are parsed as XML', () {
    const camera = 'android.permission.CAMERA';
    late String manifest;

    setUp(() => manifest = _read(_manifestPath));

    String withExtraPermission(String declaration) => manifest.replaceFirst(
      '<uses-permission android:name="android.permission.INTERNET"/>',
      '<uses-permission android:name="android.permission.INTERNET"/>\r\n'
          '    $declaration',
    );

    test('N-9 an eighth permission carrying android:maxSdkVersion fails', () {
      final failures = checkProductionManifest(
        withExtraPermission(
          '<uses-permission android:name="$camera" '
          'android:maxSdkVersion="32"/>',
        ),
      );

      expect(failures, isNotEmpty);
      expect(failures.join(' '), contains(camera));
    });

    test('N-10 a reversed attribute order fails', () {
      final failures = checkProductionManifest(
        withExtraPermission(
          '<uses-permission android:maxSdkVersion="32" '
          'android:name="$camera"/>',
        ),
      );

      expect(failures, isNotEmpty);
      expect(failures.join(' '), contains(camera));
    });

    test('N-11 an explicit closing tag fails', () {
      final failures = checkProductionManifest(
        withExtraPermission(
          '<uses-permission android:name="$camera"></uses-permission>',
        ),
      );

      expect(failures, isNotEmpty);
      expect(failures.join(' '), contains(camera));
    });

    test('N-12 uses-permission-sdk-23 fails', () {
      final failures = checkProductionManifest(
        withExtraPermission('<uses-permission-sdk-23 android:name="$camera"/>'),
      );

      expect(failures, isNotEmpty);
      expect(failures.join(' '), contains(camera));
    });

    test('a bare <permission> definition is an unapproved declaration', () {
      final failures = checkProductionManifest(
        manifest.replaceFirst(
          '<application',
          '<permission android:name="com.example.ROGUE"/>\r\n    '
              '<application',
        ),
      );

      expect(failures, isNotEmpty);
    });

    test('N-16A a duplicated approved permission fails', () {
      final failures = checkProductionManifest(
        withExtraPermission(
          '<uses-permission android:name="android.permission.INTERNET"/>',
        ),
      );

      expect(failures, isNotEmpty);
      expect(failures.join(' '), contains('Duplicate Android permission'));
    });

    test('N-16B an approved permission carrying a scope attribute fails', () {
      final failures = checkProductionManifest(
        manifest.replaceFirst(
          '<uses-permission android:name="android.permission.INTERNET"/>',
          '<uses-permission android:name="android.permission.INTERNET" '
              'android:maxSdkVersion="32"/>',
        ),
      );

      expect(failures, isNotEmpty);
      expect(failures.join(' '), contains('unapproved attribute'));
      expect(failures.join(' '), contains('android:maxSdkVersion'));
    });

    test('N-16C a permission element with no android:name fails closed', () {
      final failures = checkProductionManifest(
        withExtraPermission('<uses-permission android:maxSdkVersion="32"/>'),
      );

      expect(failures, isNotEmpty);
      expect(failures.join(' '), contains('has no android:name'));
    });

    test('N-16C2 an empty android:name fails closed', () {
      final failures = checkProductionManifest(
        withExtraPermission('<uses-permission android:name=""/>'),
      );

      expect(failures, isNotEmpty);
      expect(failures.join(' '), contains('has no android:name'));
    });

    test('N-16D malformed manifest XML fails closed instead of throwing', () {
      final failures = checkProductionManifest(
        manifest.replaceFirst('</manifest>', '</manifest'),
      );

      expect(failures, isNotEmpty);
      expect(failures.join(' '), contains('not well-formed XML'));
    });

    test('P-2 legal whitespace and line wrapping do not change authority', () {
      final rewrapped = manifest.replaceFirst(
        '<uses-permission android:name="android.permission.INTERNET"/>',
        '<uses-permission\r\n'
            '        android:name="android.permission.INTERNET"\r\n'
            '        />',
      );

      expect(checkProductionManifest(rewrapped), isEmpty);
    });

    test('P-3 permission-looking text inside an XML comment is not a '
        'declaration', () {
      final commented = manifest.replaceFirst(
        '<manifest',
        '<!-- <uses-permission android:name="$camera"/> -->\r\n<manifest',
      );

      expect(checkProductionManifest(commented), isEmpty);
      expect(
        scanManifestPermissions(commented).declarations,
        hasLength(approvedManifestPermissions.length),
      );
    });

    test('P-4 attribute order on a non-permission element is irrelevant', () {
      final reordered = manifest.replaceFirstMapped(
        RegExp(
          r'(android:name="com\.google\.android\.geo\.API_KEY")\s+'
          r'(android:value="[^"]*")',
        ),
        (match) => '${match.group(2)}\n            ${match.group(1)}',
      );

      expect(
        reordered,
        isNot(equals(manifest)),
        reason: 'the reorder mutation must actually apply',
      );
      expect(checkProductionManifest(reordered), isEmpty);
    });
  });
}
