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
library;

/// Flutter toolchain pin enforced alongside `.flutter-version`.
const String approvedFlutterVersion = '3.44.7';

/// Android identity locked by the owner amendment.
const String approvedOrganization = 'com.nexttransfer';
const String approvedApplicationId = 'com.nexttransfer.rmplanner';
const int approvedMinSdk = 24;
const int approvedCompileSdk = 36;
const int approvedTargetSdk = 36;

/// Frozen product law (M6): schema 47. Any other value is unauthorized.
const int approvedSchemaVersion = 47;

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

/// Permissions declared with a self-closing `<uses-permission ... />` tag.
Set<String> declaredPermissions(String manifest) {
  final matches = RegExp(
    r'<uses-permission\s+android:name="([^"]+)"\s*/>',
  ).allMatches(manifest);
  return <String>{for (final match in matches) match.group(1)!};
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
  final declared = declaredPermissions(text);
  final unexpected = declared.difference(approvedManifestPermissions);
  final missing = approvedManifestPermissions.difference(declared);
  if (unexpected.isNotEmpty) {
    failures.add(
      'Unexpected Android permission(s): ${(unexpected.toList()..sort()).join(', ')}',
    );
  }
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
