import 'dart:io';

import 'maps_key_rules.dart';

/// OWNER REVIEW #4 — the Maps API key gate.
///
/// Two modes, because the two questions are genuinely different:
///
/// * default (no arguments) — SOURCE mode. Resolves what the secrets Gradle
///   plugin will substitute into `com.google.android.geo.API_KEY` and fails when
///   the answer is missing, blank or the placeholder. This is the mode a
///   repository/CI gate can run with no Android SDK present, and it is exactly
///   equivalent to the packaged value because the plugin substitutes the
///   resolved property verbatim.
///
/// * `--apk <path>` — ARTIFACT mode. Reads the real packaged manifest out of a
///   built APK with `aapt2` and fails when it carries the placeholder. Raw APK
///   bytes are deliberately NOT scanned: the manifest is deflate compressed, so
///   a byte scan would prove nothing while looking like proof.
///
/// SECRET OUTPUT — FULL OPACITY (M-6 owner decision). No output in either mode
/// may contain a configured key or anything derived from it: not the value, not
/// a prefix, not a suffix, not a length, not a hash or any encoded form. Failures
/// report a value CLASS only (`<empty>`, `<placeholder>`, `<configured>`) or a
/// file path / exit code.
///
/// CLI LAW (M-6 owner decision). Unknown or malformed arguments never fall back
/// to SOURCE mode:
///
/// * no arguments                       -> SOURCE
/// * exactly `--apk <path>`             -> ARTIFACT
/// * `--apk` with no path               -> usage error, exit 2
/// * `--apk` given more than once       -> usage error, exit 2
/// * any unrecognised argument          -> usage error, exit 2
Future<void> main(List<String> args) async {
  final failures = <String>[];

  String? apkPath;
  var apkCount = 0;

  for (var index = 0; index < args.length; index++) {
    final argument = args[index];
    if (argument != '--apk') {
      // The argument itself is never echoed: a mistyped invocation could carry a
      // pasted key, and echoing it would breach the opacity law.
      _usageError('unrecognised argument at position $index.');
    }
    apkCount++;
    if (index + 1 >= args.length || args[index + 1].trim().isEmpty) {
      _usageError('--apk requires a path.');
    }
    apkPath = args[index + 1];
    index++;
  }

  if (apkCount > 1) {
    _usageError('--apk may be given at most once.');
  }

  if (apkPath == null) {
    _verifySource(failures);
  } else {
    await _verifyArtifact(File(apkPath), failures);
  }

  if (failures.isEmpty) {
    stdout.writeln('verify_maps_key: PASS');
    return;
  }
  stderr.writeln('verify_maps_key: FAIL');
  for (final failure in failures) {
    stderr.writeln('  - $failure');
  }
  exit(1);
}

const String _usage =
    'usage: verify_maps_key.dart                (SOURCE mode)\n'
    '       verify_maps_key.dart --apk <path>    (ARTIFACT mode)';

Never _usageError(String message) {
  stderr.writeln('verify_maps_key: $message');
  stderr.writeln(_usage);
  exit(2);
}

void _verifySource(List<String> failures) {
  final local = File('android/$mapsSecretsFileName');
  final defaults = File('android/$mapsDefaultsFileName');
  final resolved = resolveMapsKey(
    localSecrets: local.existsSync() ? local.readAsStringSync() : null,
    defaults: defaults.existsSync() ? defaults.readAsStringSync() : null,
  );

  if (mapsKeyIsUsable(resolved)) {
    stdout.writeln(
      '  android/$mapsSecretsFileName -> $mapsPropertyName is configured.',
    );
    return;
  }
  failures.add(
    'Maps API key is not configured.\n'
    '    Provide android/$mapsSecretsFileName with '
    '$mapsPropertyName=<restricted Google Maps Android key>.\n'
    '    The tracked android/$mapsDefaultsFileName only supplies the '
    'placeholder '
    '"$mapsKeyPlaceholder", so a build without the local file packages an '
    'unusable key and the map cannot load on device.\n'
    '    Resolved value class: ${classifyMapsKey(resolved).label}',
  );
}

Future<void> _verifyArtifact(File apk, List<String> failures) async {
  if (!apk.existsSync()) {
    failures.add('APK not found: ${apk.path}');
    return;
  }
  final aapt2 = _findAapt2();
  if (aapt2 == null) {
    failures.add(
      'aapt2 was not found, so the packaged Maps key could not be verified.\n'
      '    Set ANDROID_HOME/ANDROID_SDK_ROOT to an Android SDK containing '
      'build-tools/*/aapt2.',
    );
    return;
  }
  final result = await Process.run(aapt2, <String>[
    'dump',
    'xmltree',
    '--file',
    'AndroidManifest.xml',
    apk.path,
  ]);
  final dump = '${result.stdout}${result.stderr}';
  if (result.exitCode != 0) {
    failures.add('aapt2 could not read ${apk.path} (exit ${result.exitCode}).');
    return;
  }
  if (!dump.contains(mapsManifestMetaDataName)) {
    failures.add(
      '$mapsManifestMetaDataName is missing from the packaged manifest of '
      '${apk.path}.',
    );
    return;
  }
  if (packagedManifestHasPlaceholder(dump)) {
    failures.add(
      '${apk.path} packages the placeholder Maps key "$mapsKeyPlaceholder". '
      'Provide android/$mapsSecretsFileName and rebuild.',
    );
    return;
  }
  stdout.writeln(
    '  ${apk.path} -> $mapsManifestMetaDataName is present and is not the '
    'placeholder.',
  );
}

String? _findAapt2() {
  for (final variable in <String>['ANDROID_HOME', 'ANDROID_SDK_ROOT']) {
    final root = Platform.environment[variable];
    if (root == null || root.trim().isEmpty) continue;
    final buildTools = Directory('$root${Platform.pathSeparator}build-tools');
    if (!buildTools.existsSync()) continue;
    final candidates = buildTools.listSync().whereType<Directory>().toList()
      ..sort((a, b) => b.path.compareTo(a.path));
    for (final candidate in candidates) {
      for (final name in <String>['aapt2.exe', 'aapt2']) {
        final exe = File('${candidate.path}${Platform.pathSeparator}$name');
        if (exe.existsSync()) return exe.path;
      }
    }
  }
  return null;
}
