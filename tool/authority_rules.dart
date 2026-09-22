/// Pure, unit-testable authority rules for `tool/verify_authority.dart`.
///
/// M7 reconciliation (2026-09-16). Four VS-08-era expectations in the gate had
/// gone stale against the ACCEPTED M1-M6 product:
///
///   1. MainActivity: the gate forbade the substring `addFlags`, but the
///      accepted `com.nexttransfer.rmplanner/social_app_home` bridge
///      legitimately calls `intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)`.
///      The privacy intent is preserved and narrowed: the gate now rejects
///      `FLAG_SECURE`, `WindowManager`, and window-level flag calls instead.
///   2. Manifest permissions: the gate demanded exactly one permission
///      (`USE_BIOMETRIC`). The accepted manifest declares seven (VS16
///      background/notification work plus M6 contacts and location). The gate
///      now verifies the EXACT accepted set, so an eighth permission still
///      fails.
///   3. Dependencies: the gate forbade `workmanager:`, which was accepted at
///      `90d5fd0` and is pinned at `0.10.9`. The gate now requires that EXACT
///      pin and still rejects loose versions and the other forbidden packages.
///   4. Schema: the gate demanded `schemaVersion ?? 10`; the frozen product law
///      is `?? 47`.
///
/// All of the above live here, in one place, so the negative direction is
/// provable by `test/tool/authority_gate_test.dart` without running a script.
/// M-3 (2026-09-21): source-manifest permissions are now parsed as XML instead
/// of matched with a text regex. The regex recognised only
/// `<uses-permission android:name="..." />`; four legal shapes were invisible to
/// it (`android:maxSdkVersion` present, attributes reversed, an explicit closing
/// tag, `uses-permission-sdk-23`), duplicates were collapsed by the resulting
/// `Set`, a declaration with no `android:name` was invisible, and a
/// permission-looking string inside an XML comment was counted as a real
/// declaration. All of those are now decided from the parsed document.
///
/// M-7 (2026-09-22): the dependency law became STRUCTURAL too.
///
///   * [checkPubspec] decides forbidden families from the parsed keys of
///     `dependencies:` and `dev_dependencies:` instead of `String.contains`
///     over the whole file. That closes two opposite defects the M-7 forensic
///     audit re-proved: a quoted key (`"supabase_flutter": 1.0.0`) evaded the
///     old rule, while a comment mentioning a family (`# supabase_flutter:`) —
///     anywhere in the file — failed it.
///   * [checkLockfile] verifies the RESOLVED graph in `pubspec.lock`, direct
///     and transitive alike, because `flutter pub get`, `flutter pub deps` and
///     an implicit `dart run` resolution can all silently repair a tampered or
///     deleted lockfile before any gate observes it.
///
/// Both parsers are deliberately narrow: they interpret only the dependency
/// blocks they exist for, and they fail CLOSED on structure they cannot read
/// rather than letting a declaration disappear.
library;

import 'dart:convert';

import 'package:xml/xml.dart';

/// Flutter toolchain pin enforced alongside `.flutter-version`.
const String approvedFlutterVersion = '3.44.7';

/// Android identity locked by the owner amendment.
const String approvedOrganization = 'com.nexttransfer';
const String approvedApplicationId = 'com.nexttransfer.rmplanner';
const int approvedMinSdk = 24;
const int approvedCompileSdk = 36;
const int approvedTargetSdk = 36;

/// JDK facts, split apart because they are genuinely different questions.
///
/// M-1c (2026-09-21): a single ambiguous `"java": "17"` field used to stand for
/// both halves of this, and it was never read by any gate. Two facts were being
/// conflated:
///
///   * [approvedJavaBytecodeTarget] — what Android/Kotlin compile *to*. Still 17
///     (`sourceCompatibility` / `targetCompatibility` / Kotlin `jvmTarget` in
///     `android/app/build.gradle.kts`), unchanged.
///   * [approvedJavaBuildJdk] — the JDK that actually runs Gradle. The pinned
///     `maplibre_gl 0.26.2` compiles its own Android sources with Java 21, so a
///     JDK 17 runner fails with `invalid source release: 21` before any test
///     runs.
const int approvedJavaBytecodeTarget = 17;
const int approvedJavaBuildJdk = 21;

/// Every value `tool/toolchain.json` must state, exactly.
///
/// One table, so a new toolchain fact is added in one place and is checked by
/// both directions of `test/tool/authority_gate_test.dart`.
const Map<String, Object?> lockedToolchainValues = <String, Object?>{
  'flutter': approvedFlutterVersion,
  'android_organization': approvedOrganization,
  'android_application_id': approvedApplicationId,
  'android_min_sdk': approvedMinSdk,
  'android_target_sdk': approvedTargetSdk,
  'java_bytecode_target': approvedJavaBytecodeTarget,
  'java_build_jdk': approvedJavaBuildJdk,
};

/// Frozen product law (M6): schema 47 through v0.1.1 build 3; schema 48 from
/// the owner-authorized Detailed Content master pass (2026-09-19, item E).
///
/// v48 is additive only: one boolean column on the existing
/// `notification_preferences` row, defaulted TRUE, with the same idempotency
/// guard v47 established.  No table, no column removal, no data rewrite, and no
/// new permission.  Any other value is unauthorized.
const int approvedSchemaVersion = 48;

/// The EXACT accepted Android permission set.
///
/// Exact-set verification: adding an eighth permission fails the authority gate,
/// and so does removing an expected one.
const Set<String> approvedManifestPermissions = <String>{
  'android.permission.USE_BIOMETRIC',
  'android.permission.INTERNET',
  'android.permission.POST_NOTIFICATIONS',
  'android.permission.RECEIVE_BOOT_COMPLETED',
  'android.permission.READ_CONTACTS',
  'android.permission.ACCESS_FINE_LOCATION',
  'android.permission.ACCESS_COARSE_LOCATION',
};

/// Exact approved dependency pins. A changed or loose version fails the gate.
const Map<String, String> approvedDependencyPins = <String, String>{
  'local_auth': '3.0.2',
  'permission_handler': '12.0.3',
  'flutter_secure_storage': '10.3.1',
  'timezone': '0.11.1',
  'flutter_timezone': '5.1.0',
  'workmanager': '0.10.9',
};

/// Dependency families that must never enter the resolved graph.
///
/// M-7 (2026-09-22): these used to be raw `name:` substrings matched with
/// `String.contains` against the WHOLE pubspec file. The M-7 forensic audit
/// re-proved that this produced two opposite defects at once:
///
///   * a QUOTED key (`"supabase_flutter": 1.0.0`) never contains the substring
///     `supabase_flutter:`, so a real forbidden dependency evaded the gate;
///   * a COMMENT mentioning the family (`# supabase_flutter: forbidden`)
///     contains it, so an innocent comment FAILED the gate — anywhere in the
///     file, including sections that are not dependency declarations at all.
///
/// The families are now bare names compared against the STRUCTURALLY PARSED
/// dependency keys of `dependencies:` and `dev_dependencies:` (see
/// [scanPubspecDependencies]), and against the resolved package names in
/// `pubspec.lock` (see [checkLockfile]). Raw text is never consulted.
const List<String> forbiddenDependencies = <String>[
  'supabase_flutter',
  'file_picker',
  'device_calendar',
  'firebase_analytics',
  'posthog_flutter',
  'sentry_flutter',
];

/// Non-package source marker that must never appear in a dependency VALUE.
///
/// `@insforge` is a hosted-source marker rather than a package name, so it is
/// checked against parsed dependency values (scalar versions and nested map
/// values) instead of raw file text.
const String forbiddenDependencySourceMarker = '@insforge';

/// Resolved package names carrying this fragment are rejected as well, so an
/// insforge-sourced package cannot hide in `pubspec.lock`.
const String forbiddenDependencySourceFragment = 'insforge';

/// Top-level pubspec sections whose direct keys are dependency declarations.
const Set<String> pubspecDependencySections = <String>{
  'dependencies',
  'dev_dependencies',
};

/// The section whose approved pins are enforced exactly.
///
/// Approved pins deliberately remain scoped to `dependencies:`; a
/// `dev_dependencies:` declaration must never satisfy a production pin.
const String approvedPinSection = 'dependencies';

/// Top-level key that opens the resolved-package map in `pubspec.lock`.
const String lockfilePackagesKey = 'packages';

/// Window/privacy manipulation that must never appear in MainActivity.
///
/// This is the guard the M7 reconciliation preserves while allowing the
/// accepted Intent bridge flag below.
const List<String> forbiddenMainActivityWindowCalls = <String>[
  'FLAG_SECURE',
  'WindowManager',
  'window.addFlags',
  'window.clearFlags',
  'getWindow(',
  'setFlags(',
];

/// The accepted, authorized MainActivity intent bridge flag.
const String approvedMainActivityIntentFlag =
    'intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)';

/// Sensitive fields that must never enter the Drift schema.
const List<String> forbiddenSensitiveColumns = <String>[
  'accessToken',
  'refreshToken',
  'biometricData',
  'appPin',
];

/// Declarations the frozen schema must still contain.
///
/// M7 reconciliation detail: the VS-08-era gate also listed
/// `WeeklyPlanCommitments`, `WeeklyPlanReviews`,
/// `WeeklyPlanReviewIndicatorSnapshots`, and
/// `WeeklyPlanTaskCarryoverDecisions`. Those identifiers exist only on the
/// non-authoritative VS-08 commits `0cd762e` / `af3c6b1` (and in the
/// non-authoritative `8bd94e9` snapshot) — never on this line, whose
/// authoritative weekly-plan membership table is `WeeklyPlanGoalMemberships`.
/// They were replaced by that real declaration rather than deleted, so the
/// weekly-plan boundary remains guarded.
const List<String> requiredSchemaTables = <String>[
  'PlannerTasks',
  'TaskStatusChanges',
  'CalendarEvents',
  'CalendarEventExceptions',
  'CalendarEventOperations',
  'TaskEventLinks',
  'TaskEventLinkHistory',
  'OutcomeReports',
  'OutcomeReportContributionDrafts',
  'ActivityLedgerEntries',
  'WeeklyIndicatorTargetRevisions',
  'WeeklyPlans',
  'WeeklyPlanGoalMemberships',
  'ActivityTypes',
  'ActivityTypeIndicatorMappings',
  'PlannerPreferences',
  'BoolColumn get isBackupAppointment',
  'TextColumn get preferredPresentation',
  'IntColumn get timelineHourHeight',
  'TextColumn get timeZoneId',
];

/// Android's attribute namespace inside `AndroidManifest.xml`.
const String androidManifestNamespace =
    'http://schemas.android.com/apk/res/android';

/// Whether an element name declares a permission.
///
/// Covers `uses-permission`, the `uses-permission-sdk-*` family, and
/// `permission` (a permission *definition*), so a differently-shaped but legal
/// declaration cannot become invisible.
bool _isPermissionDeclarationElement(String localName) =>
    localName == 'permission' || localName.startsWith('uses-permission');

/// One permission-declaring element found in the source manifest.
class ManifestPermissionDeclaration {
  const ManifestPermissionDeclaration({
    required this.elementName,
    required this.name,
    required this.otherAttributes,
  });

  /// The declaring element, e.g. `uses-permission` or `uses-permission-sdk-23`.
  final String elementName;

  /// The value of `android:name`, or an empty string when absent or empty.
  final String name;

  /// Every attribute except `android:name`, keyed by qualified name.
  ///
  /// Any entry here is an unapproved scope/extra attribute: the owner law
  /// authorizes `android:name` and nothing else on a permission declaration.
  final Map<String, String> otherAttributes;

  /// Whether a non-empty `android:name` was declared.
  bool get hasName => name.isNotEmpty;
}

/// Structured scan of a manifest's permission declarations.
class ManifestPermissionScan {
  const ManifestPermissionScan({
    required this.declarations,
    required this.failures,
  });

  /// Every permission-declaring element in document order, INCLUDING ones that
  /// are malformed (missing or empty `android:name`) — they must be reported,
  /// not skipped.
  final List<ManifestPermissionDeclaration> declarations;

  /// Structural problems found while parsing. Only malformed XML lands here;
  /// the permission policy comparison lives in [checkProductionManifest].
  final List<String> failures;
}

/// Parses [manifest] as XML and returns every permission declaration it makes.
///
/// Malformed XML is reported as a violation rather than thrown, so the gate
/// always fails closed with a readable reason instead of crashing.
ManifestPermissionScan scanManifestPermissions(String manifest) {
  final XmlDocument document;
  try {
    document = XmlDocument.parse(manifest);
  } on XmlException catch (error) {
    return ManifestPermissionScan(
      declarations: const <ManifestPermissionDeclaration>[],
      failures: <String>['Manifest is not well-formed XML: $error'],
    );
  }

  final declarations = <ManifestPermissionDeclaration>[];
  for (final element in document.descendants.whereType<XmlElement>()) {
    if (!_isPermissionDeclarationElement(element.name.local)) continue;
    declarations.add(
      ManifestPermissionDeclaration(
        elementName: element.name.local,
        name:
            element.getAttribute(
              'name',
              namespaceUri: androidManifestNamespace,
            ) ??
            '',
        otherAttributes: <String, String>{
          for (final attribute in element.attributes)
            if (!(attribute.name.local == 'name' &&
                attribute.name.namespaceUri == androidManifestNamespace))
              attribute.name.qualified: attribute.value,
        },
      ),
    );
  }
  return ManifestPermissionScan(
    declarations: declarations,
    failures: const <String>[],
  );
}

/// One direct dependency declaration parsed out of a pubspec dependency block.
class PubspecDependencyDeclaration {
  const PubspecDependencyDeclaration({
    required this.name,
    required this.section,
    required this.quoted,
    required this.inlineVersion,
    required this.nestedKeys,
    required this.values,
  });

  /// The package name with any YAML quoting stripped.
  final String name;

  /// `dependencies` or `dev_dependencies`.
  final String section;

  /// Whether the key was written with single or double quotes.
  final bool quoted;

  /// The scalar value on the same line, or null for a nested map form.
  final String? inlineVersion;

  /// Keys of a nested map form (`sdk`, `git`, `path`, `hosted`, `url`, ...).
  final List<String> nestedKeys;

  /// Every value fragment belonging to this declaration, used only for the
  /// [forbiddenDependencySourceMarker] check.
  final List<String> values;
}

/// Result of structurally parsing a pubspec's dependency sections.
class PubspecDependencyScan {
  const PubspecDependencyScan({
    required this.declarations,
    required this.failures,
  });

  final List<PubspecDependencyDeclaration> declarations;
  final List<String> failures;
}

/// Indentation width of [line]; a tab counts as one column.
int _indentWidth(String line) {
  var width = 0;
  for (final unit in line.codeUnits) {
    if (unit == 0x20 || unit == 0x09) {
      width++;
    } else {
      break;
    }
  }
  return width;
}

/// [line] with a trailing YAML comment removed.
///
/// YAML starts a comment only at the beginning of a line or after whitespace,
/// and never inside a quoted scalar. Both rules matter here: `"a#b": 1.0.0`
/// is a key and a URL fragment is a value, while `  intl: 0.20.3 # pinned`
/// carries a comment.
String _stripYamlComment(String line) {
  var inSingle = false;
  var inDouble = false;
  for (var index = 0; index < line.length; index++) {
    final char = line[index];
    if (char == "'" && !inDouble) {
      inSingle = !inSingle;
    } else if (char == '"' && !inSingle) {
      inDouble = !inDouble;
    } else if (char == '#' && !inSingle && !inDouble) {
      if (index == 0 || line[index - 1] == ' ' || line[index - 1] == '\t') {
        return line.substring(0, index);
      }
    }
  }
  return line;
}

/// Index of the `key: value` separator, ignoring colons inside quotes.
int _separatorIndex(String text) {
  var inSingle = false;
  var inDouble = false;
  for (var index = 0; index < text.length; index++) {
    final char = text[index];
    if (char == "'" && !inDouble) {
      inSingle = !inSingle;
    } else if (char == '"' && !inSingle) {
      inDouble = !inDouble;
    } else if (char == ':' && !inSingle && !inDouble) {
      return index;
    }
  }
  return -1;
}

/// A structural problem with a raw YAML key, or null when it is usable.
String? _keyError(String rawKey) {
  final key = rawKey.trim();
  if (key.isEmpty) return 'empty key';
  final quoted =
      key.length >= 2 &&
      ((key.startsWith('"') && key.endsWith('"')) ||
          (key.startsWith("'") && key.endsWith("'")));
  if (quoted) {
    return key.length == 2 ? 'empty quoted key' : null;
  }
  if (key.contains('"') || key.contains("'")) {
    return 'unbalanced quote in key';
  }
  if (key.startsWith('-')) return 'sequence entry is not a mapping key';
  return null;
}

/// The key text with surrounding YAML quotes stripped.
String _unquotedKey(String rawKey) {
  final key = rawKey.trim();
  if (key.length >= 2 &&
      ((key.startsWith('"') && key.endsWith('"')) ||
          (key.startsWith("'") && key.endsWith("'")))) {
    return key.substring(1, key.length - 1);
  }
  return key;
}

/// Whether [rawKey] carries YAML quoting.
bool _isQuotedKey(String rawKey) {
  final key = rawKey.trim();
  return key.length >= 2 &&
      ((key.startsWith('"') && key.endsWith('"')) ||
          (key.startsWith("'") && key.endsWith("'")));
}

/// Structurally parse every direct dependency declaration in [pubspec].
///
/// Only the [pubspecDependencySections] blocks are interpreted. Full-line
/// comments are skipped, trailing comments are stripped, quoted keys are
/// recognised, and nested forms (`sdk:`, `git:`, `path:`, `hosted:`) are read
/// as nested keys of their parent rather than mistaken for package names.
///
/// This is deliberately NOT a general YAML parser. Anything it cannot
/// interpret is reported through [PubspecDependencyScan.failures] so the gate
/// fails closed instead of silently dropping a declaration.
PubspecDependencyScan scanPubspecDependencies(String pubspec) {
  final declarations = <PubspecDependencyDeclaration>[];
  final failures = <String>[];
  final declaredIn = <String, String>{};

  final lines = pubspec.replaceAll('\r\n', '\n').split('\n');
  String? section;
  var headerIndent = 0;
  int? childIndent;
  PubspecDependencyDeclaration? current;
  var nestedIndent = 0;

  void closeDeclaration() {
    current = null;
    nestedIndent = 0;
  }

  for (var lineNumber = 0; lineNumber < lines.length; lineNumber++) {
    final stripped = _stripYamlComment(lines[lineNumber]);
    if (stripped.trim().isEmpty) continue;
    final indent = _indentWidth(stripped);

    if (section == null) {
      final separator = _separatorIndex(stripped);
      if (separator == -1) continue;
      final head = _unquotedKey(stripped.substring(0, separator));
      final rest = stripped.substring(separator + 1).trim();
      if (pubspecDependencySections.contains(head) && rest.isEmpty) {
        section = head;
        headerIndent = indent;
        childIndent = null;
        closeDeclaration();
      }
      continue;
    }

    if (indent <= headerIndent) {
      // The dependency block ended; replay this line as a possible header.
      section = null;
      closeDeclaration();
      lineNumber--;
      continue;
    }

    childIndent ??= indent;

    if (indent < childIndent) {
      failures.add(
        'Section $section declares an inconsistent indentation level '
        '(line ${lineNumber + 1})',
      );
      section = null;
      closeDeclaration();
      continue;
    }

    final separator = _separatorIndex(stripped);

    if (indent == childIndent) {
      if (separator == -1) {
        failures.add(
          'Section $section has an unparseable declaration '
          '(line ${lineNumber + 1})',
        );
        closeDeclaration();
        continue;
      }
      final rawKey = stripped.substring(0, separator);
      final keyError = _keyError(rawKey);
      if (keyError != null) {
        failures.add('Section $section: $keyError (line ${lineNumber + 1})');
        closeDeclaration();
        continue;
      }
      final name = _unquotedKey(rawKey);
      final previous = declaredIn[name];
      if (previous != null) {
        failures.add(
          'Duplicate dependency declaration for $name in $previous and '
          '$section',
        );
      } else {
        declaredIn[name] = section;
      }
      final value = stripped.substring(separator + 1).trim();
      final declaration = PubspecDependencyDeclaration(
        name: name,
        section: section,
        quoted: _isQuotedKey(rawKey),
        inlineVersion: value.isEmpty ? null : value,
        nestedKeys: <String>[],
        values: value.isEmpty ? <String>[] : <String>[value],
      );
      declarations.add(declaration);
      current = declaration;
      nestedIndent = 0;
      continue;
    }

    // Deeper than a direct key: nested content of the current declaration.
    final declaration = current;
    if (declaration == null) {
      failures.add(
        'Section $section has nested content before any dependency key '
        '(line ${lineNumber + 1})',
      );
      continue;
    }
    if (nestedIndent == 0) nestedIndent = indent;
    if (indent != nestedIndent) {
      failures.add(
        'Section $section: unsupported nesting depth under ${declaration.name} '
        '(line ${lineNumber + 1})',
      );
      continue;
    }
    if (separator == -1) {
      failures.add(
        'Section $section: unparseable nested entry under '
        '${declaration.name} (line ${lineNumber + 1})',
      );
      continue;
    }
    final nestedRawKey = stripped.substring(0, separator);
    final nestedError = _keyError(nestedRawKey);
    if (nestedError != null) {
      failures.add(
        'Section $section: $nestedError under ${declaration.name} '
        '(line ${lineNumber + 1})',
      );
      continue;
    }
    declaration.nestedKeys.add(_unquotedKey(nestedRawKey));
    final nestedValue = stripped.substring(separator + 1).trim();
    if (nestedValue.isNotEmpty) declaration.values.add(nestedValue);
  }

  return PubspecDependencyScan(declarations: declarations, failures: failures);
}

/// The version spec declared for [packageName] directly under `dependencies:`.
///
/// Scoping to that one section is deliberate: a `dev_dependencies:` declaration
/// must never satisfy a production pin.
///
/// A nested map form (`sdk:`, `git:`, `path:`, `hosted:`) carries no inline
/// version and returns null. The previous regex returned the literal `git:` for
/// such a declaration, which was a misparse rather than a version.
String? pinnedVersionOf(String pubspec, String packageName) {
  for (final declaration in scanPubspecDependencies(pubspec).declarations) {
    if (declaration.section == approvedPinSection &&
        declaration.name == packageName) {
      return declaration.inlineVersion;
    }
  }
  return null;
}

/// MainActivity must keep the accepted identity and intent bridge, and must
/// never introduce window or screenshot manipulation.
List<String> checkMainActivityKt(String text) {
  final failures = <String>[];
  if (!text.contains('package $approvedApplicationId')) {
    failures.add('MainActivity package identity changed');
  }
  if (!text.contains('FlutterFragmentActivity')) {
    failures.add('MainActivity no longer hosts FlutterFragmentActivity');
  }
  if (!text.contains(approvedMainActivityIntentFlag)) {
    failures.add(
      'MainActivity lost the accepted social_app_home Intent bridge flag',
    );
  }
  for (final forbidden in forbiddenMainActivityWindowCalls) {
    if (text.contains(forbidden)) {
      failures.add(
        'MainActivity contains forbidden window/privacy call: $forbidden',
      );
    }
  }
  return failures;
}

/// Production manifest identity, backup policy, and EXACT permission scope.
List<String> checkProductionManifest(String text) {
  final failures = <String>[];
  if (!text.contains('android:label="Next Transfer"')) {
    failures.add('Manifest application label changed');
  }
  if (!text.contains('android:allowBackup="false"')) {
    failures.add('Manifest backup policy changed');
  }
  failures.addAll(_checkManifestPermissionScope(text));
  return failures;
}

/// Source-manifest permission law.
///
/// Exact scope: the seven approved permissions, each declared exactly once, and
/// every declaration carrying nothing but `android:name`. A duplicate, a scope
/// attribute (`android:maxSdkVersion`, `tools:*`, ...), a declaration without a
/// name, or an eighth permission all fail closed.
List<String> _checkManifestPermissionScope(String text) {
  final failures = <String>[];
  final scan = scanManifestPermissions(text);
  failures.addAll(scan.failures);
  if (scan.failures.isNotEmpty) {
    // Malformed XML: there is no truthful declaration list, so stop here rather
    // than adding a misleading "all permissions missing" cascade on top.
    return failures;
  }

  final declared = <String>[];
  for (final declaration in scan.declarations) {
    if (!declaration.hasName) {
      failures.add(
        'Permission declaration <${declaration.elementName}> has no '
        'android:name',
      );
      continue;
    }
    final name = declaration.name;
    for (final attribute in declaration.otherAttributes.keys.toList()..sort()) {
      failures.add(
        'Permission $name carries unapproved attribute $attribute; only '
        'android:name is authorized',
      );
    }
    if (!approvedManifestPermissions.contains(name)) {
      failures.add('Unexpected Android permission: $name');
    }
    declared.add(name);
  }

  final counts = <String, int>{};
  for (final name in declared) {
    counts[name] = (counts[name] ?? 0) + 1;
  }
  final duplicates = counts.entries.where((entry) => entry.value > 1).toList()
    ..sort((a, b) => a.key.compareTo(b.key));
  for (final duplicate in duplicates) {
    failures.add(
      'Duplicate Android permission declaration: ${duplicate.key} appears '
      '${duplicate.value} times; the approved scope declares it exactly once',
    );
  }

  if (scan.declarations.length != approvedManifestPermissions.length) {
    failures.add(
      'Expected exactly ${approvedManifestPermissions.length} permission '
      'declarations, found ${scan.declarations.length}',
    );
  }

  final missing = approvedManifestPermissions.difference(declared.toSet());
  if (missing.isNotEmpty) {
    failures.add(
      'Missing expected Android permission(s): ${(missing.toList()..sort()).join(', ')}',
    );
  }
  return failures;
}

/// Dependency lock: every approved pin exact, every forbidden family absent.
///
/// M-7 (2026-09-22): the forbidden-family check is now STRUCTURAL. It is
/// decided from the parsed keys of `dependencies:` and `dev_dependencies:` —
/// never from raw pubspec text — so a quoted key is caught and a mere comment
/// is not. `@insforge` is checked against parsed dependency VALUES for the
/// same reason.
List<String> checkPubspec(String text) {
  final failures = <String>[];
  final scan = scanPubspecDependencies(text);
  failures.addAll(scan.failures);

  for (final entry in approvedDependencyPins.entries) {
    final actual = pinnedVersionOf(text, entry.key);
    if (actual == null) {
      failures.add('Approved dependency is missing: ${entry.key}');
    } else if (actual != entry.value) {
      failures.add(
        'Dependency ${entry.key} is $actual; approved pin is ${entry.value}',
      );
    }
  }

  for (final declaration in scan.declarations) {
    if (forbiddenDependencies.contains(declaration.name)) {
      failures.add(
        'Forbidden dependency family present in ${declaration.section}: '
        '${declaration.name}',
      );
      continue;
    }
    final marker = declaration.values.any(
      (value) => value.contains(forbiddenDependencySourceMarker),
    );
    if (marker) {
      failures.add(
        'Forbidden dependency source present in ${declaration.section}: '
        '${declaration.name}',
      );
    }
  }
  return failures;
}

/// One resolved package entry parsed from a `pubspec.lock`.
class LockfilePackage {
  const LockfilePackage({required this.name, required this.classification});

  final String name;

  /// `direct main`, `direct dev`, `transitive`, ... as declared by pub.
  final String classification;
}

/// Result of structurally parsing a `pubspec.lock`.
class LockfileScan {
  const LockfileScan({required this.packages, required this.failures});

  final List<LockfilePackage> packages;
  final List<String> failures;
}

/// Structurally parse the resolved-package map of a `pubspec.lock`.
///
/// Only package NAMES and their `dependency:` classification are read. Hashes,
/// URLs, descriptions and versions are never retained, so they can never reach
/// a failure message. Malformed structure, duplicate entries, a missing
/// `packages:` block and an empty resolution are all reported as failures.
LockfileScan scanLockfilePackages(String lockfileText) {
  final packages = <LockfilePackage>[];
  final failures = <String>[];
  final declaredAt = <String, int>{};
  final normalized = lockfileText.replaceAll('\r\n', '\n');

  if (!RegExp(
    '^$lockfilePackagesKey:'
    r'\s*$',
    multiLine: true,
  ).hasMatch(normalized)) {
    failures.add(
      'pubspec.lock declares no top-level $lockfilePackagesKey: map',
    );
    return LockfileScan(packages: packages, failures: failures);
  }

  final lines = normalized.split('\n');
  var headerIndent = -1;
  int? entryIndent;
  var inPackages = false;
  var name = '';
  var classification = '';
  var hasClassification = false;

  void closeEntry() {
    if (name.isEmpty) return;
    if (!hasClassification) {
      failures.add('Lockfile package $name declares no dependency: value');
    }
    packages.add(
      LockfilePackage(
        name: name,
        classification: classification.isEmpty ? 'unknown' : classification,
      ),
    );
    name = '';
    classification = '';
    hasClassification = false;
  }

  for (var lineNumber = 0; lineNumber < lines.length; lineNumber++) {
    final raw = lines[lineNumber];
    if (raw.trim().isEmpty) continue;
    if (raw.trimLeft().startsWith('#')) continue;
    final indent = _indentWidth(raw);

    if (!inPackages) {
      if (RegExp(
        '^$lockfilePackagesKey:'
        r'\s*$',
      ).hasMatch(raw)) {
        inPackages = true;
        headerIndent = indent;
      }
      continue;
    }

    if (indent <= headerIndent) {
      closeEntry();
      inPackages = false;
      continue;
    }

    entryIndent ??= indent;

    if (indent == entryIndent) {
      closeEntry();
      final separator = _separatorIndex(raw);
      if (separator == -1) {
        failures.add(
          'pubspec.lock has an unparseable package entry '
          '(line ${lineNumber + 1})',
        );
        continue;
      }
      final rawKey = raw.substring(0, separator);
      final keyError = _keyError(rawKey);
      if (keyError != null) {
        failures.add('pubspec.lock: $keyError (line ${lineNumber + 1})');
        continue;
      }
      final entryName = _unquotedKey(rawKey);
      final previousLine = declaredAt[entryName];
      if (previousLine != null) {
        failures.add(
          'pubspec.lock declares $entryName more than once '
          '(lines $previousLine and ${lineNumber + 1})',
        );
      } else {
        declaredAt[entryName] = lineNumber + 1;
      }
      name = entryName;
      continue;
    }

    final separator = _separatorIndex(raw);
    if (separator == -1) continue;
    final nestedKey = _unquotedKey(raw.substring(0, separator));
    if (nestedKey == 'dependency') {
      hasClassification = true;
      classification = _unquotedKey(raw.substring(separator + 1));
    }
  }
  closeEntry();

  if (packages.isEmpty) {
    failures.add('pubspec.lock resolves no packages');
  }
  return LockfileScan(packages: packages, failures: failures);
}

/// Resolved-graph dependency law.
///
/// Every package in `pubspec.lock` is checked regardless of whether it is
/// `direct main`, `direct dev` or `transitive`, so a forbidden family cannot
/// hide in the resolved graph while `pubspec.yaml` stays clean.
///
/// This exists because `pubspec.yaml` alone was never sufficient: the M-7
/// forensic audit proved that `flutter pub get` — and `flutter pub deps`, and
/// even an implicit `dart run` resolution — can silently repair or regenerate a
/// lockfile, while the authority gate only ever asked whether the file existed.
List<String> checkLockfile(String text) {
  final failures = <String>[];
  final scan = scanLockfilePackages(text);
  failures.addAll(scan.failures);
  for (final package in scan.packages) {
    if (forbiddenDependencies.contains(package.name)) {
      failures.add(
        'Forbidden dependency family resolved in pubspec.lock: '
        '${package.name} (${package.classification})',
      );
    } else if (package.name.contains(forbiddenDependencySourceFragment)) {
      failures.add(
        'Forbidden dependency source resolved in pubspec.lock: '
        '${package.name} (${package.classification})',
      );
    }
  }
  return failures;
}

/// Frozen schema boundary: version, required tables, no sensitive columns.
List<String> checkSchemaBoundary(String text) {
  final failures = <String>[];
  for (final column in forbiddenSensitiveColumns) {
    if (text.contains(column)) {
      failures.add('Sensitive field entered the schema: $column');
    }
  }
  if (!text.contains(
    'int get schemaVersion => _schemaVersionOverride ?? $approvedSchemaVersion',
  )) {
    failures.add('Schema version is not the frozen $approvedSchemaVersion');
  }
  for (final table in requiredSchemaTables) {
    if (!text.contains(table)) {
      failures.add('Frozen schema is missing required declaration: $table');
    }
  }
  return failures;
}

/// `tool/toolchain.json` must state the locked toolchain exactly.
///
/// Fail-closed by construction: malformed JSON is reported as a violation
/// rather than allowed to throw, and a MISSING key is a violation too — a null
/// lookup never silently equals an expected value. Both Java facts are checked,
/// so neither the bytecode target nor the build JDK can drift unnoticed.
List<String> checkToolchain(String text) {
  final Object? parsed;
  try {
    parsed = jsonDecode(text);
  } on FormatException {
    return <String>['toolchain.json is not valid JSON'];
  }
  if (parsed is! Map<String, Object?>) {
    return <String>['toolchain.json is not a JSON object'];
  }
  final failures = <String>[];
  for (final entry in lockedToolchainValues.entries) {
    final actual = parsed[entry.key];
    if (actual != entry.value) {
      failures.add(
        'toolchain.json ${entry.key} is $actual (locked: ${entry.value})',
      );
    }
  }
  return failures;
}
