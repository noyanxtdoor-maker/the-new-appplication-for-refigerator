/// Pure rules behind the merged-artifact (packaged Android manifest) gate.
///
/// M-4 (2026-09-21) — CI BLIND SPOT. M-3 protects SOURCE manifest truth: the
/// seven approved permissions declared in
/// `android/app/src/main/AndroidManifest.xml` are parsed as XML and the exact
/// set is enforced. Nothing protected the ARTIFACT. After Android manifest
/// merging and plugin/dependency contributions, the debug APK actually carries
/// 15 `uses-permission` elements (7 source + 7 merged + 1 app-scoped) plus 3
/// activities, 7 receivers and 5 services with their own `exported` flags — and
/// no gate in this repository observed any of it. Source authority could be
/// green while the real packaged surface drifted.
///
/// The rules here are deliberately pure — no file access, no process spawning —
/// so both directions of the gate are provable from `test/tool/` exactly like
/// `tool/authority_rules.dart` and `tool/maps_key_rules.dart`. The runner that
/// discovers `aapt2`, invokes it and reads the committed baseline lives in
/// `tool/verify_merged_artifact.dart`.
///
/// SECRECY LAW (owner correction, 2026-09-21): a decoded manifest can contain
/// sensitive metadata — for example a Google Maps API key from an ignored
/// `android/secrets.properties`. The raw dump is read INTO MEMORY ONLY and is
/// never persisted, logged, committed, echoed on PASS, or echoed on FAIL. Only
/// the whitelisted fields modelled here may leave the process: applicationId,
/// versionName/versionCode, minSdk/targetSdk, permission names, declared
/// permission names, and component names with their `exported` state. This file
/// therefore reads ONLY those attribute local names and NEVER touches any other
/// attribute value. Errors report structural context (element kind, position,
/// field name, value FORM) and never quote raw lines or arbitrary attributes.
library;

import 'dart:convert';

/// The only baseline document format this gate understands.
const int mergedArtifactBaselineFormat = 1;

/// Local attribute names this gate is allowed to read, and nothing else.
const String _nameAttribute = 'name';
const String _packageAttribute = 'package';
const String _versionCodeAttribute = 'versionCode';
const String _versionNameAttribute = 'versionName';
const String _minSdkAttribute = 'minSdkVersion';
const String _targetSdkAttribute = 'targetSdkVersion';
const String _exportedAttribute = 'exported';

/// One `E:` element frame in the decoded tree.
class _ElementFrame {
  _ElementFrame(this.name, this.indent);

  final String name;
  final int indent;
  final Map<String, String> attributes = <String, String>{};
  final List<_ElementFrame> children = <_ElementFrame>[];
}

final RegExp _elementPattern = RegExp(r'^\s*E: (\S+)');
final RegExp _attributePattern = RegExp(r'^\s*A: (.+)$');
final RegExp _hexPattern = RegExp(r'^0x([0-9a-fA-F]+)$');
final RegExp _decimalPattern = RegExp(r'^-?\d+$');

/// Raised when a decoded manifest cannot be turned into a trusted model.
///
/// The message describes STRUCTURE only: element kind, field name, value form.
/// It never contains a raw dump line or an arbitrary attribute value.
class MergedArtifactParseException implements Exception {
  const MergedArtifactParseException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Raised when the committed baseline cannot be trusted as a baseline.
class MergedArtifactBaselineException implements Exception {
  const MergedArtifactBaselineException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Identity the baseline pins, decoded from the packaged manifest.
class ArtifactIdentity {
  const ArtifactIdentity({
    required this.applicationId,
    required this.versionName,
    required this.versionCode,
    required this.minSdk,
    required this.targetSdk,
  });

  final String applicationId;
  final String versionName;
  final int versionCode;
  final int minSdk;
  final int targetSdk;
}

/// One packaged component and its TRI-STATE `exported` state.
///
/// `null` means the `android:exported` attribute is ABSENT. Absent is a real,
/// enforced value: it is neither a bypass nor a drift, and
/// `absent -> true/false` (or the reverse) is always a difference.
class ArtifactComponent {
  const ArtifactComponent({required this.name, required this.exported});

  final String name;
  final bool? exported;
}

/// The parsed, normalized model of a packaged manifest.
class MergedArtifactModel {
  const MergedArtifactModel({
    required this.identity,
    required this.usesPermissions,
    required this.declaredPermissions,
    required this.activities,
    required this.receivers,
    required this.services,
  });

  final ArtifactIdentity identity;
  final List<String> usesPermissions;
  final List<String> declaredPermissions;
  final List<ArtifactComponent> activities;
  final List<ArtifactComponent> receivers;
  final List<ArtifactComponent> services;

  /// The SANITIZED projection: whitelisted fields only, deterministic ordering.
  ///
  /// This is the only artifact shape that may be written to an evidence file or
  /// printed. It never carries metadata values, arbitrary attributes, or raw
  /// dump text.
  Map<String, Object?> toSanitizedJson() {
    List<Map<String, Object?>> components(List<ArtifactComponent> entries) {
      final sorted = entries.toList()..sort((a, b) => a.name.compareTo(b.name));
      return <Map<String, Object?>>[
        for (final entry in sorted)
          <String, Object?>{'name': entry.name, 'exported': entry.exported},
      ];
    }

    final permissions = usesPermissions.toList()..sort();
    final declared = declaredPermissions.toList()..sort();
    return <String, Object?>{
      'applicationId': identity.applicationId,
      'versionName': identity.versionName,
      'versionCode': identity.versionCode,
      'minSdk': identity.minSdk,
      'targetSdk': identity.targetSdk,
      'usesPermissions': permissions,
      'declaredPermissions': declared,
      'activities': components(activities),
      'receivers': components(receivers),
      'services': components(services),
    };
  }
}

/// The committed, owner-locked artifact baseline.
class MergedArtifactBaseline {
  const MergedArtifactBaseline({
    required this.identity,
    required this.usesPermissions,
    required this.declaredPermissions,
    required this.activities,
    required this.receivers,
    required this.services,
  });

  final ArtifactIdentity identity;
  final List<String> usesPermissions;
  final List<String> declaredPermissions;
  final List<ArtifactComponent> activities;
  final List<ArtifactComponent> receivers;
  final List<ArtifactComponent> services;

  /// Parses a baseline document, failing closed on anything untrustworthy.
  ///
  /// Malformed JSON, a wrong format marker, a missing or empty identity field,
  /// an empty or incomplete list, a duplicate entry, or a component without a
  /// real name all raise [MergedArtifactBaselineException]. There is
  /// deliberately no lenient path and no partial acceptance.
  static MergedArtifactBaseline parse(String jsonText) {
    if (jsonText.trim().isEmpty) {
      throw const MergedArtifactBaselineException(
        'the committed baseline file is empty',
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(jsonText);
    } on FormatException {
      throw const MergedArtifactBaselineException(
        'the committed baseline is not valid JSON',
      );
    }
    return parseJson(decoded);
  }

  /// Parses an already-decoded baseline document.
  static MergedArtifactBaseline parseJson(Object? decoded) {
    if (decoded is! Map<String, Object?>) {
      throw const MergedArtifactBaselineException(
        'the committed baseline is not a JSON object',
      );
    }
    final format = decoded['baselineFormat'];
    if (format is! int || format != mergedArtifactBaselineFormat) {
      throw MergedArtifactBaselineException(
        'the committed baseline does not declare baselineFormat '
        '$mergedArtifactBaselineFormat',
      );
    }
    return MergedArtifactBaseline(
      identity: ArtifactIdentity(
        applicationId: _baselineString(decoded, 'applicationId'),
        versionName: _baselineString(decoded, 'versionName'),
        versionCode: _baselineInt(decoded, 'versionCode'),
        minSdk: _baselineInt(decoded, 'minSdk'),
        targetSdk: _baselineInt(decoded, 'targetSdk'),
      ),
      usesPermissions: _baselineNameList(decoded, 'usesPermissions'),
      declaredPermissions: _baselineNameList(decoded, 'declaredPermissions'),
      activities: _baselineComponents(decoded, 'activities'),
      receivers: _baselineComponents(decoded, 'receivers'),
      services: _baselineComponents(decoded, 'services'),
    );
  }
}

/// Parses the decoded manifest dump into a normalized model.
///
/// Structural, not textual: the tree is rebuilt from element/attribute lines
/// and relative indentation DEPTH, so a changed indent width, a reordered
/// attribute list, a `(0x...)` resource-id suffix, a `(Raw: "...")` echo, a
/// bare integer, a typed-hex integer, an explicit closing tag or a `$` inside a
/// class name cannot change the answer. Volatile fields (`(line=N)`,
/// `platformBuildVersion*`, namespace lines) are ignored because they are never
/// read.
///
/// Throws [MergedArtifactParseException] — never crashes — when the input is
/// empty, is not a manifest tree, or is missing a field the baseline pins.
MergedArtifactModel parseMergedManifestDump(String dump) {
  if (dump.trim().isEmpty) {
    throw const MergedArtifactParseException(
      'the decoded manifest is empty: aapt2 produced no manifest tree',
    );
  }

  final roots = <_ElementFrame>[];
  final frames = <_ElementFrame>[];
  for (final rawLine in dump.split('\n')) {
    final line = rawLine.endsWith('\r')
        ? rawLine.substring(0, rawLine.length - 1)
        : rawLine;

    final elementMatch = _elementPattern.firstMatch(line);
    if (elementMatch != null) {
      final indent = _indentOf(line);
      while (frames.isNotEmpty && frames.last.indent >= indent) {
        frames.removeLast();
      }
      final frame = _ElementFrame(elementMatch.group(1)!, indent);
      if (frames.isEmpty) {
        roots.add(frame);
      } else {
        frames.last.children.add(frame);
      }
      frames.add(frame);
      continue;
    }

    final attributeMatch = _attributePattern.firstMatch(line);
    if (attributeMatch == null) continue;
    final owner = _ownerOf(frames, _indentOf(line));
    if (owner == null) continue;
    final attribute = attributeMatch.group(1)!;
    final separator = attribute.indexOf('=');
    if (separator <= 0) continue;
    owner.attributes.putIfAbsent(
      _localAttributeName(attribute.substring(0, separator)),
      () => attribute.substring(separator + 1),
    );
  }

  final manifest = _singleFrame(roots, 'manifest');
  if (manifest == null) {
    throw const MergedArtifactParseException(
      'the decoded manifest has no <manifest> element',
    );
  }
  final application = _singleFrame(manifest.children, 'application');
  if (application == null) {
    throw const MergedArtifactParseException(
      'the decoded manifest has no <application> element',
    );
  }
  final usesSdk = _singleFrame(manifest.children, 'uses-sdk');
  if (usesSdk == null) {
    throw const MergedArtifactParseException(
      'the decoded manifest has no <uses-sdk> element',
    );
  }

  final usesPermissions = <String>[];
  final declaredPermissions = <String>[];
  for (final child in manifest.children) {
    if (child.name == 'uses-permission' ||
        child.name.startsWith('uses-permission-')) {
      usesPermissions.add(_stringAttribute(child, _nameAttribute));
    } else if (child.name == 'permission') {
      declaredPermissions.add(_stringAttribute(child, _nameAttribute));
    }
  }

  return MergedArtifactModel(
    identity: ArtifactIdentity(
      applicationId: _stringAttribute(manifest, _packageAttribute),
      versionName: _stringAttribute(manifest, _versionNameAttribute),
      versionCode: _intAttribute(manifest, _versionCodeAttribute),
      minSdk: _intAttribute(usesSdk, _minSdkAttribute),
      targetSdk: _intAttribute(usesSdk, _targetSdkAttribute),
    ),
    usesPermissions: usesPermissions,
    declaredPermissions: declaredPermissions,
    activities: _componentsOf(application, const <String>[
      'activity',
      'activity-alias',
    ]),
    receivers: _componentsOf(application, const <String>['receiver']),
    services: _componentsOf(application, const <String>['service']),
  );
}

/// Compares a parsed artifact against the committed baseline.
///
/// Exact-set comparison in BOTH directions: an extra permission fails, a
/// missing one fails, duplicates fail, an added or removed component fails, and
/// an `exported` change including `true|false -> absent` fails. Returns one
/// human-readable line per difference, sorted and deduplicated; an empty list
/// means the artifact matches the baseline exactly.
///
/// Every returned line names baseline-authorized fields only (identity values,
/// permission names, component names, exported state).
List<String> compareMergedArtifact({
  required MergedArtifactModel artifact,
  required MergedArtifactBaseline baseline,
}) {
  final differences = <String>[];
  final observed = artifact.identity;
  final expected = baseline.identity;

  if (observed.applicationId != expected.applicationId) {
    differences.add(
      'applicationId is ${observed.applicationId}; baseline expects '
      '${expected.applicationId}',
    );
  }
  if (observed.versionName != expected.versionName) {
    differences.add(
      'versionName is ${observed.versionName}; baseline expects '
      '${expected.versionName}',
    );
  }
  if (observed.versionCode != expected.versionCode) {
    differences.add(
      'versionCode is ${observed.versionCode}; baseline expects '
      '${expected.versionCode}',
    );
  }
  if (observed.minSdk != expected.minSdk) {
    differences.add(
      'minSdk is ${observed.minSdk}; baseline expects ${expected.minSdk}',
    );
  }
  if (observed.targetSdk != expected.targetSdk) {
    differences.add(
      'targetSdk is ${observed.targetSdk}; baseline expects '
      '${expected.targetSdk}',
    );
  }

  _compareNames(
    label: 'merged permission',
    observed: artifact.usesPermissions,
    expected: baseline.usesPermissions,
    differences: differences,
  );
  _compareNames(
    label: 'declared permission',
    observed: artifact.declaredPermissions,
    expected: baseline.declaredPermissions,
    differences: differences,
  );
  _compareComponents(
    label: 'activity',
    observed: artifact.activities,
    expected: baseline.activities,
    differences: differences,
  );
  _compareComponents(
    label: 'receiver',
    observed: artifact.receivers,
    expected: baseline.receivers,
    differences: differences,
  );
  _compareComponents(
    label: 'service',
    observed: artifact.services,
    expected: baseline.services,
    differences: differences,
  );

  final sorted = differences.toSet().toList()..sort();
  return sorted;
}

/// Whether an `exported` value means exported, evaluated fail-closed.
///
/// aapt2 has been observed to emit a literal `true`/`false`; the typed forms
/// (`(type 0x12)0xffffffff`, `0xffffffff`, `-1`, `1`) are accepted defensively.
bool? exportedFromDecoded(Object? decoded) {
  switch (decoded) {
    case null:
      return null;
    case bool():
      return decoded;
    case int():
      if (decoded == 0) return false;
      if (decoded == 1 || decoded == -1 || decoded == 0xffffffff) return true;
      throw const MergedArtifactParseException(
        'android:exported carries an unrecognised integer value form',
      );
    default:
      throw const MergedArtifactParseException(
        'android:exported is neither a boolean nor an integer value form',
      );
  }
}

void _compareNames({
  required String label,
  required List<String> observed,
  required List<String> expected,
  required List<String> differences,
}) {
  final counts = <String, int>{};
  for (final name in observed) {
    counts[name] = (counts[name] ?? 0) + 1;
  }
  final duplicates = counts.entries.where((entry) => entry.value > 1).toList()
    ..sort((a, b) => a.key.compareTo(b.key));
  for (final duplicate in duplicates) {
    differences.add(
      'Duplicate $label in the artifact: ${duplicate.key} appears '
      '${duplicate.value} times; the baseline declares it exactly once',
    );
  }

  final observedNames = observed.toSet();
  final expectedNames = expected.toSet();
  final unexpected = observedNames.difference(expectedNames).toList()..sort();
  for (final name in unexpected) {
    differences.add('Unexpected $label in the artifact: $name');
  }
  final missing = expectedNames.difference(observedNames).toList()..sort();
  for (final name in missing) {
    differences.add('Baseline $label missing from the artifact: $name');
  }
}

void _compareComponents({
  required String label,
  required List<ArtifactComponent> observed,
  required List<ArtifactComponent> expected,
  required List<String> differences,
}) {
  final counts = <String, int>{};
  for (final component in observed) {
    counts[component.name] = (counts[component.name] ?? 0) + 1;
  }
  final duplicates = counts.entries.where((entry) => entry.value > 1).toList()
    ..sort((a, b) => a.key.compareTo(b.key));
  for (final duplicate in duplicates) {
    differences.add(
      'Duplicate $label in the artifact: ${duplicate.key} appears '
      '${duplicate.value} times; the baseline declares it exactly once',
    );
  }

  final observedByName = <String, bool?>{};
  for (final component in observed) {
    observedByName.putIfAbsent(component.name, () => component.exported);
  }
  final expectedByName = <String, bool?>{
    for (final component in expected) component.name: component.exported,
  };

  for (final name
      in (observedByName.keys
          .toSet()
          .difference(expectedByName.keys.toSet())
          .toList()
        ..sort())) {
    differences.add(
      'Unexpected $label in the artifact: $name (exported '
      '${_describeExported(observedByName[name])})',
    );
  }
  for (final name
      in (expectedByName.keys
          .toSet()
          .difference(observedByName.keys.toSet())
          .toList()
        ..sort())) {
    differences.add('Baseline $label missing from the artifact: $name');
  }
  for (final name
      in (observedByName.keys
          .toSet()
          .intersection(expectedByName.keys.toSet())
          .toList()
        ..sort())) {
    final actual = observedByName[name];
    final expectedValue = expectedByName[name];
    if (actual != expectedValue) {
      differences.add(
        'Merged $label $name exported is ${_describeExported(actual)}; '
        'baseline expects ${_describeExported(expectedValue)}',
      );
    }
  }
}

String _describeExported(bool? value) =>
    value == null ? 'absent (no android:exported attribute)' : '$value';

_ElementFrame? _singleFrame(List<_ElementFrame> frames, String name) {
  for (final frame in frames) {
    if (frame.name == name) return frame;
  }
  return null;
}

/// The frame an attribute belongs to: the deepest open frame that starts
/// ABOVE the attribute's indentation.
///
/// This is what makes the parser indentation-WIDTH tolerant while still being
/// structure-aware: an attribute never inherits a nested child's identity, and
/// a nested child's attributes can never be mistaken for the parent's.
_ElementFrame? _ownerOf(List<_ElementFrame> frames, int indent) {
  for (final frame in frames.reversed) {
    if (frame.indent < indent) return frame;
  }
  return null;
}

int _indentOf(String line) {
  var indent = 0;
  while (indent < line.length) {
    final unit = line.codeUnitAt(indent);
    if (unit != 0x20 && unit != 0x09) break;
    indent++;
  }
  return indent;
}

/// The local attribute name, regardless of namespace prefix and `(0x...)`
/// resource-id suffix: `android:name(0x01010003)` -> `name`.
String _localAttributeName(String qualifiedName) {
  var name = qualifiedName.trim();
  final suffix = RegExp(r'\(0x[0-9a-fA-F]+\)$');
  name = name.replaceFirst(suffix, '');
  final separator = name.lastIndexOf(':');
  if (separator >= 0) name = name.substring(separator + 1);
  return name;
}

String _stringAttribute(_ElementFrame frame, String attribute) {
  final raw = frame.attributes[attribute];
  if (raw == null) {
    throw MergedArtifactParseException(
      '<${frame.name}> is missing the required attribute $attribute',
    );
  }
  final decoded = _decodeValue(raw, frame, attribute);
  if (decoded is! String || decoded.isEmpty) {
    throw MergedArtifactParseException(
      '<${frame.name}> attribute $attribute is not a non-empty string value '
      'form',
    );
  }
  return decoded;
}

int _intAttribute(_ElementFrame frame, String attribute) {
  final raw = frame.attributes[attribute];
  if (raw == null) {
    throw MergedArtifactParseException(
      '<${frame.name}> is missing the required attribute $attribute',
    );
  }
  final decoded = _decodeValue(raw, frame, attribute);
  if (decoded is! int) {
    throw MergedArtifactParseException(
      '<${frame.name}> attribute $attribute is not an integer value form',
    );
  }
  return decoded;
}

List<ArtifactComponent> _componentsOf(
  _ElementFrame application,
  List<String> elementNames,
) {
  final components = <ArtifactComponent>[];
  for (final child in application.children) {
    if (!elementNames.contains(child.name)) continue;
    components.add(
      ArtifactComponent(
        name: _stringAttribute(child, _nameAttribute),
        exported: exportedFromDecoded(
          child.attributes.containsKey(_exportedAttribute)
              ? _decodeValue(
                  child.attributes[_exportedAttribute]!,
                  child,
                  _exportedAttribute,
                )
              : null,
        ),
      ),
    );
  }
  return components;
}

/// Decodes one attribute value WITHOUT ever echoing it.
///
/// Accepted forms: a quoted string with an optional `(Raw: "...")` echo, a
/// typed wrapper (`(type 0x10)0x18`), a bare integer, a bare hex integer, and
/// the boolean literals. Anything else is an unresolvable value FORM and fails
/// closed — the message names the field, never the value.
Object _decodeValue(String raw, _ElementFrame frame, String attribute) {
  var value = raw.trim();
  if (value.startsWith('(type ')) {
    final close = value.indexOf(')');
    if (close < 0) {
      throw MergedArtifactParseException(
        '<${frame.name}> attribute $attribute carries a truncated typed value '
        'form',
      );
    }
    value = value.substring(close + 1).trim();
  }
  if (value.startsWith('"')) {
    final end = _closingQuoteIndex(value);
    if (end < 0) {
      throw MergedArtifactParseException(
        '<${frame.name}> attribute $attribute carries an unterminated string '
        'value form',
      );
    }
    return value.substring(1, end);
  }
  final hex = _hexPattern.firstMatch(value);
  if (hex != null) return int.parse(hex.group(1)!, radix: 16);
  if (_decimalPattern.hasMatch(value)) return int.parse(value);
  if (value == 'true') return true;
  if (value == 'false') return false;
  throw MergedArtifactParseException(
    '<${frame.name}> attribute $attribute carries an unrecognised value form',
  );
}

int _closingQuoteIndex(String value) {
  for (var index = 1; index < value.length; index++) {
    if (value.codeUnitAt(index) == 0x5c) {
      index++;
      continue;
    }
    if (value.codeUnitAt(index) == 0x22) return index;
  }
  return -1;
}

String _baselineString(Map<String, Object?> decoded, String key) {
  final value = decoded[key];
  if (value is! String || value.isEmpty) {
    throw MergedArtifactBaselineException(
      'the committed baseline is missing a non-empty $key',
    );
  }
  return value;
}

int _baselineInt(Map<String, Object?> decoded, String key) {
  final value = decoded[key];
  if (value is! int) {
    throw MergedArtifactBaselineException(
      'the committed baseline is missing an integer $key',
    );
  }
  return value;
}

List<String> _baselineNameList(Map<String, Object?> decoded, String key) {
  final value = decoded[key];
  if (value is! List || value.isEmpty) {
    throw MergedArtifactBaselineException(
      'the committed baseline is missing a non-empty $key list',
    );
  }
  final names = <String>[];
  for (final entry in value) {
    if (entry is! String || entry.isEmpty) {
      throw MergedArtifactBaselineException(
        'the committed baseline $key list contains a non-string entry',
      );
    }
    names.add(entry);
  }
  if (names.toSet().length != names.length) {
    throw MergedArtifactBaselineException(
      'the committed baseline $key list contains a duplicate entry',
    );
  }
  return names;
}

List<ArtifactComponent> _baselineComponents(
  Map<String, Object?> decoded,
  String key,
) {
  final value = decoded[key];
  if (value is! List || value.isEmpty) {
    throw MergedArtifactBaselineException(
      'the committed baseline is missing a non-empty $key list',
    );
  }
  final components = <ArtifactComponent>[];
  for (final entry in value) {
    if (entry is! Map) {
      throw MergedArtifactBaselineException(
        'the committed baseline $key list contains a non-object entry',
      );
    }
    final name = entry['name'];
    if (name is! String || name.isEmpty) {
      throw MergedArtifactBaselineException(
        'the committed baseline $key list contains an entry without a name',
      );
    }
    if (!entry.containsKey('exported')) {
      throw MergedArtifactBaselineException(
        'the committed baseline $key entry $name does not declare exported '
        '(true, false or null)',
      );
    }
    final exported = entry['exported'];
    if (exported != null && exported is! bool) {
      throw MergedArtifactBaselineException(
        'the committed baseline $key entry $name declares a non-boolean '
        'exported value',
      );
    }
    components.add(ArtifactComponent(name: name, exported: exported as bool?));
  }
  if (components.map((component) => component.name).toSet().length !=
      components.length) {
    throw MergedArtifactBaselineException(
      'the committed baseline $key list contains a duplicate component name',
    );
  }
  return components;
}
