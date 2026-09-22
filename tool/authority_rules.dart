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
/// the owner-authorized Detailed Content master pass (2026-09-19, item E);
/// schema 49 from the owner-authorized P2-A independent Event contact channel
/// (2026-09-21, design D1).
///
/// v48 is additive only: one boolean column on the existing
/// `notification_preferences` row, defaulted TRUE, with the same idempotency
/// guard v47 established.  No table, no column removal, no data rewrite, and no
/// new permission.
///
/// v49 is additive only: ONE nullable text column (`contact_channel`) on the
/// EXISTING `calendar_events` row, with NO default and NO backfill, so a legacy
/// Event reads back as NULL rather than being handed an invented Contact Type.
/// Same idempotency guard as v47/v48.  No new table, no column removal, no data
/// rewrite, no dependency change and no new permission.  Any other value is
/// unauthorized.
const int approvedSchemaVersion = 49;

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

/// Dependency families that must never enter the graph.
const List<String> forbiddenDependencies = <String>[
  'supabase_flutter:',
  'file_picker:',
  'device_calendar:',
  'firebase_analytics:',
  'posthog_flutter:',
  'sentry_flutter:',
  '@insforge',
];

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

/// The `dependencies:` block of a pubspec, up to the next top-level key.
///
/// Scoping to this block is deliberate: a `dev_dependencies:` pin must not
/// satisfy the production dependency lock.
String productionDependenciesSection(String pubspec) {
  final buffer = StringBuffer();
  var inSection = false;
  for (final line in pubspec.replaceAll('\r\n', '\n').split('\n')) {
    if (line.startsWith('dependencies:')) {
      inSection = true;
      continue;
    }
    if (!inSection) continue;
    final isTopLevel =
        line.isNotEmpty &&
        !line.startsWith(' ') &&
        !line.startsWith('\t') &&
        !line.startsWith('#');
    if (isTopLevel) break;
    buffer.writeln(line);
  }
  return buffer.toString();
}

/// The version spec declared for [packageName] under `dependencies:`, or null.
String? pinnedVersionOf(String pubspec, String packageName) {
  final match = RegExp(
    '^\\s{2}${RegExp.escape(packageName)}:\\s*(\\S+)\\s*\$',
    multiLine: true,
  ).firstMatch(productionDependenciesSection(pubspec));
  return match?.group(1);
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
List<String> checkPubspec(String text) {
  final failures = <String>[];
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
  for (final forbidden in forbiddenDependencies) {
    if (text.contains(forbidden)) {
      failures.add('Forbidden dependency family present: $forbidden');
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
