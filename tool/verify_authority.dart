import 'dart:io';

import 'package:crypto/crypto.dart';

import 'authority_rules.dart';

// Android identity and Flutter pin are asserted from `authority_rules.dart`
// (including `tool/toolchain.json`), so they are not duplicated here.
const _applicationId = 'com.nexttransfer.rmplanner';
const _flutterVersion = '3.44.7';

const _approvedSources = <String, String>{
  'Next_Transfer_Phase_3_Approved_Baseline_and_Vertical_Slices.xlsx':
      '8c457c5c605fc714d6733061f5c010fa7d1f02190e1706ed0ee5ffc0edbc83e1',
  'Next_Transfer_Phase_3_Vertical_Slice_Specifications_Draft.docx':
      '1cecc97a29ccf789f957b210fda8add5f2145a65a651dd5a6d3d609c072f644b',
};

Future<void> main() async {
  final failures = <String>[];

  for (final source in _approvedSources.entries) {
    await _verifyHash(File('docs/${source.key}'), source.value, failures);
    await _verifyHash(
      File('docs/baseline/phase-3/${source.key}'),
      source.value,
      failures,
    );
  }

  _expectFileText(
    File('.flutter-version'),
    (text) => text.trim() == _flutterVersion,
    'Flutter version is not pinned to $_flutterVersion',
    failures,
  );
  _expectFileText(
    File('android/app/build.gradle.kts'),
    (text) =>
        text.contains('namespace = "$_applicationId"') &&
        text.contains('applicationId = "$_applicationId"') &&
        text.contains('minSdk = 24') &&
        text.contains('targetSdk = 36') &&
        text.contains('compileSdk = 36'),
    'Android Gradle identity or SDK baseline differs from the lock',
    failures,
  );
  // M7 reconciliation: the accepted `social_app_home` Intent bridge uses
  // `intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)`. The guard is narrowed to
  // the window/screenshot manipulation it exists to prevent
  // (FLAG_SECURE, WindowManager, window-level flag calls).
  _expectRules(
    File(
      'android/app/src/main/kotlin/'
      'com/nexttransfer/rmplanner/MainActivity.kt',
    ),
    checkMainActivityKt,
    failures,
  );
  _expectFileText(
    File('android/app/src/main/res/values/styles.xml'),
    (text) => text.contains('Theme.AppCompat.DayNight.NoActionBar'),
    'Android launch theme does not satisfy the local_auth AppCompat host '
    'requirement',
    failures,
  );
  // M7 reconciliation: the accepted manifest declares the exact seven-permission
  // set (VS16 background/notification work + M6 contacts/location).
  // Exact-set verification means an eighth permission still fails.
  _expectRules(
    File('android/app/src/main/AndroidManifest.xml'),
    checkProductionManifest,
    failures,
  );
  // M7 reconciliation: `workmanager` was accepted at 90d5fd0 and is pinned at
  // 0.10.9. Every approved pin must be EXACT, and the other forbidden families
  // remain forbidden.
  _expectRules(File('pubspec.yaml'), checkPubspec, failures);
  // M7 reconciliation: the frozen product law is schema 47 (was 10 at VS-08).
  // The sensitive-field exclusion and the frozen table set are unchanged.
  _expectRules(
    File('lib/core/database/app_database.dart'),
    checkSchemaBoundary,
    failures,
  );
  _expectFileText(
    File('docs/implementation/vs-08-traceability.md'),
    (text) =>
        List<int>.generate(20, (index) => index + 1).every(
          (number) =>
              text.contains('FR-I-${number.toString().padLeft(3, '0')}'),
        ) &&
        List<int>.generate(10, (index) => index + 1).every(
          (number) =>
              text.contains('BR-I-${number.toString().padLeft(3, '0')}'),
        ) &&
        List<int>.generate(20, (index) => index + 1).every(
          (number) =>
              text.contains('AC-I-${number.toString().padLeft(3, '0')}'),
        ),
    'VS-08 FR, BR, or AC traceability is incomplete',
    failures,
  );
  _expectFileText(
    File('docs/implementation/phase-3-authority.md'),
    (text) =>
        text.contains('implementation-ready through VS-08') &&
        text.contains('VS-08 — Weekly Planning Lifecycle') &&
        text.contains('VS-09 and later slices remain unauthorized'),
    'The active authorization overlay does not stop after VS-08',
    failures,
  );
  // M-1c (2026-09-21): the single ambiguous `java` field became two explicit
  // ones — the bytecode target the app compiles to (17) and the JDK that
  // actually runs Gradle (21, required by the pinned maplibre_gl). The rules
  // live in `authority_rules.dart` so both values are provable in BOTH
  // directions from `test/tool/authority_gate_test.dart`.
  _expectRules(File('tool/toolchain.json'), checkToolchain, failures);

  // M-7 (2026-09-22): existence was never the real question. The M-7 forensic
  // audit proved that `flutter pub get` silently REWRITES a structurally valid
  // but inconsistent `pubspec.lock`, that `flutter pub deps` repairs it too,
  // and that an implicit `dart run` resolution regenerates a deleted one — so
  // the old `existsSync()` branch was unreachable in normal CI ordering and, in
  // any case, could not see a forbidden family hiding in the resolved graph.
  // The lockfile CONTENT is now verified structurally. `_expectRules` still
  // reports a missing file ('Required file is missing'), which preserves the
  // original missing-file protection.
  _expectRules(File('pubspec.lock'), checkLockfile, failures);

  if (failures.isNotEmpty) {
    stderr.writeln('Authority verification failed:');
    for (final failure in failures) {
      stderr.writeln('- $failure');
    }
    exitCode = 1;
    return;
  }

  stdout.writeln(
    'Authority verification passed: approved hashes, Flutter pin, '
    'Android identity, accepted permission scope, exact dependency pins, '
    'frozen schema $approvedSchemaVersion, and MainActivity privacy guard.',
  );
}

Future<void> _verifyHash(
  File file,
  String expected,
  List<String> failures,
) async {
  if (!file.existsSync()) {
    failures.add('Required approved source is missing: ${file.path}');
    return;
  }
  final actual = (await sha256.bind(file.openRead()).first).toString();
  if (actual != expected) {
    failures.add(
      'Hash mismatch for ${file.path}: expected $expected, found $actual',
    );
  }
}

void _expectFileText(
  File file,
  bool Function(String text) predicate,
  String failure,
  List<String> failures,
) {
  if (!file.existsSync()) {
    failures.add('Required file is missing: ${file.path}');
    return;
  }
  try {
    if (!predicate(file.readAsStringSync())) {
      failures.add(failure);
    }
  } on Object catch (error) {
    failures.add('$failure (${error.runtimeType})');
  }
}

/// Apply a pure rule set from `authority_rules.dart` to [file], surfacing the
/// specific rule violations instead of one opaque boolean.
void _expectRules(
  File file,
  List<String> Function(String text) rules,
  List<String> failures,
) {
  if (!file.existsSync()) {
    failures.add('Required file is missing: ${file.path}');
    return;
  }
  try {
    for (final violation in rules(file.readAsStringSync())) {
      failures.add('${file.path}: $violation');
    }
  } on Object catch (error) {
    failures.add('${file.path}: unreadable (${error.runtimeType})');
  }
}
