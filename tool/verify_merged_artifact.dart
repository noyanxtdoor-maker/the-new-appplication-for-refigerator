import 'dart:convert';
import 'dart:io';

import 'merged_artifact_rules.dart';

/// M-4 — verify the PACKAGED Android manifest against the committed baseline.
///
/// `dart run tool/verify_merged_artifact.dart --apk <path>` reads the real
/// merged manifest out of a built APK and fails when the artifact stops
/// matching `tool/merged_artifact_baseline.json`. This is the artifact-level
/// counterpart to `tool/verify_authority.dart` (which protects SOURCE manifest
/// truth) and it closes the M-4 blind spot: before this gate, a permission or
/// component injected by dependency/plugin manifest merging was invisible to
/// every check in the repository.
///
/// REUSE LAW: the only sanctioned way to read the packaged manifest is
/// `aapt2 dump xmltree --file AndroidManifest.xml <apk>` — exactly the seam
/// `tool/verify_maps_key.dart --apk` already uses. The APK is never unzipped,
/// binary AXML is never parsed by hand, and the archive is never byte-scanned
/// (the manifest is deflate compressed, so a byte scan would prove nothing
/// while looking like proof). That file is deliberately NOT modified.
///
/// SECRECY LAW (owner correction, 2026-09-21): the decoded manifest may carry
/// sensitive metadata, for example a Google Maps API key from an ignored
/// `android/secrets.properties`. The dump therefore stays IN MEMORY: it is
/// never written to disk, never logged, and never echoed — not on PASS and not
/// on FAIL. Differences are reported by baseline-authorized field only
/// (identity, permission names, component names, exported state), and parse
/// errors report structural context without quoting raw lines or arbitrary
/// attribute values.
///
/// BASELINE AUTHORITY (owner correction, 2026-09-21): the baseline is
/// TRANSCRIBED from the owner-locked values and is committed. It is never
/// generated, regenerated, auto-accepted or self-healed from any artifact —
/// there is no `--update-baseline` path and this runner never writes to it.
/// A mismatch is STOP S11, not a reason to edit the baseline.
///
/// Exit codes: 0 = PASS, 1 = FAIL, 2 = usage error.
Future<void> main(List<String> args) async {
  final options = _parseArguments(args);
  if (options == null) return;

  final baseline = _loadBaseline(options.baselinePath);
  final apk = File(options.apkPath);
  if (!apk.existsSync()) {
    _fail(<String>[
      'APK not found: ${apk.path}',
      'Build it first: flutter build apk --debug '
          '--dart-define-from-file=tool/env/production.json.example',
    ]);
  }

  final aapt2 = _findAapt2();
  if (aapt2 == null) {
    _fail(<String>[
      'aapt2 was not found, so the packaged manifest could not be decoded.',
      'Set ANDROID_HOME or ANDROID_SDK_ROOT to an Android SDK containing '
          'build-tools/*/aapt2.',
    ]);
  }

  final ProcessResult result;
  try {
    result = await Process.run(aapt2, <String>[
      'dump',
      'xmltree',
      '--file',
      'AndroidManifest.xml',
      apk.path,
    ]);
  } on ProcessException {
    _fail(<String>['aapt2 could not be executed: $aapt2']);
  }
  if (result.exitCode != 0) {
    _fail(<String>[
      'aapt2 could not decode ${apk.path} (exit ${result.exitCode}).',
      'The file must be a real built APK; aapt2 output is deliberately not '
          'echoed here.',
    ]);
  }

  // In memory only. Never persisted, never printed.
  final dump = '${result.stdout}${result.stderr}';

  final MergedArtifactModel model;
  try {
    model = parseMergedManifestDump(dump);
  } on MergedArtifactParseException catch (error) {
    _fail(<String>[
      'the decoded manifest could not be parsed: ${error.message}',
    ]);
  }

  if (options.printNormalized) {
    // The sanctioned evidence shape: whitelisted fields only.
    stdout.writeln(
      const JsonEncoder.withIndent('  ').convert(model.toSanitizedJson()),
    );
    return;
  }

  final differences = compareMergedArtifact(
    artifact: model,
    baseline: baseline,
  );
  if (differences.isEmpty) {
    stdout.writeln('verify_merged_artifact: PASS');
    stdout.writeln(
      '  ${apk.uri.pathSegments.last} -> ${model.identity.applicationId} '
      '${model.identity.versionName} (code ${model.identity.versionCode}), '
      'minSdk ${model.identity.minSdk}, targetSdk ${model.identity.targetSdk}; '
      '${model.usesPermissions.length} permissions; '
      '${model.activities.length} activities; '
      '${model.receivers.length} receivers; '
      '${model.services.length} services '
      '- matches the committed baseline.',
    );
    return;
  }
  _fail(differences);
}

/// Command line options, or null after a usage error has been reported.
class _Options {
  const _Options({
    required this.apkPath,
    required this.baselinePath,
    required this.printNormalized,
  });

  final String apkPath;
  final String baselinePath;
  final bool printNormalized;
}

const String _usage =
    'usage: dart run tool/verify_merged_artifact.dart --apk <path> '
    '[--baseline <path>] [--print-normalized]';

_Options? _parseArguments(List<String> args) {
  String? apkPath;
  var baselinePath = 'tool/merged_artifact_baseline.json';
  var printNormalized = false;

  String? usageError;
  for (var index = 0; index < args.length; index++) {
    final argument = args[index];
    if (argument == '--apk' || argument == '--baseline') {
      if (index + 1 >= args.length) {
        usageError = '$argument requires a path';
        break;
      }
      final value = args[index + 1];
      if (argument == '--apk') {
        apkPath = value;
      } else {
        baselinePath = value;
      }
      index++;
    } else if (argument == '--print-normalized') {
      printNormalized = true;
    } else {
      usageError = 'unknown argument: $argument';
      break;
    }
  }

  if (usageError == null && apkPath == null) {
    usageError = '--apk <path> is required';
  }
  if (usageError != null) {
    stderr.writeln('verify_merged_artifact: usage error: $usageError');
    stderr.writeln(_usage);
    exit(2);
  }
  return _Options(
    apkPath: apkPath!,
    baselinePath: baselinePath,
    printNormalized: printNormalized,
  );
}

/// Loads the committed baseline, failing closed on every unusable shape.
///
/// A missing file, an unreadable file, malformed JSON, a wrong format marker,
/// an empty or incomplete document, and duplicate or nameless entries are all
/// failures with a readable reason — never a crash and never a silent pass.
MergedArtifactBaseline _loadBaseline(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    _fail(<String>[
      'committed baseline not found: ${file.path}',
      'The baseline is transcribed from the owner-locked artifact values and '
          'committed; it is never generated from an artifact. An artifact '
          'mismatch is a STOP that requires owner review, not a baseline edit.',
    ]);
  }
  final String text;
  try {
    text = file.readAsStringSync();
  } on FileSystemException {
    _fail(<String>['committed baseline could not be read: ${file.path}']);
  }
  try {
    return MergedArtifactBaseline.parse(text);
  } on MergedArtifactBaselineException catch (error) {
    _fail(<String>['committed baseline is unusable: ${error.message}']);
  }
}

/// Reports a failure and exits 1. Never echoes the dump or arbitrary values.
Never _fail(List<String> failures) {
  stderr.writeln('verify_merged_artifact: FAIL');
  for (final failure in failures) {
    stderr.writeln('  - $failure');
  }
  exit(1);
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
