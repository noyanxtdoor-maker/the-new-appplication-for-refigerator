// Test integrity gate: owner-approved suppression registry + discovery floor.
//
// Authority (M-5, 2026-09-21):
//   * Every suppression site under test/ must be registered, reasoned, and
//     unchanged. Unregistered, stale, duplicated, or unanalyzable sites fail
//     this gate.
//   * The set of discovered *_test.dart files under test/ must equal the
//     committed discovery manifest exactly. A legitimate addition or removal
//     requires a deliberate, reviewed manifest diff in the same change.
//   * This gate is read-only. There is no update, accept, or self-healing mode
//     anywhere, and the gate never writes either artifact.
//   * Failure messages name the file plus identity or field and never echo
//     arbitrary source lines or suppression expression text.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String _registryPath = 'test/integrity/skip_registry.json';
const String _manifestPath = 'test/integrity/test_discovery_manifest.json';
const String _testRoot = 'test';
const String _testFilePathPattern = r'^test/.*_test\.dart$';
const String _selfPath = 'test/integrity/test_integrity_gate_test.dart';

final RegExp _suppressionTokenPattern = RegExp(r'\bskip\s*:');
final RegExp _callPattern = RegExp(r'\b(testWidgets|test|group)\s*\(');
final RegExp _allowedTestPathPattern = RegExp(_testFilePathPattern);

class _SuppressionSite {
  const _SuppressionSite({
    required this.file,
    required this.kind,
    required this.identity,
    required this.expression,
  });

  final String file;
  final String kind;
  final String identity;
  final String expression;

  String get bindingKey => '$file\u0000$kind\u0000$identity';
}

class _RegistryEntry {
  const _RegistryEntry({
    required this.id,
    required this.file,
    required this.kind,
    required this.identity,
    required this.expression,
  });

  final String id;
  final String file;
  final String kind;
  final String identity;
  final String expression;

  String get bindingKey => '$file\u0000$kind\u0000$identity';
}

class _GateFailure implements Exception {
  _GateFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

Never _fail(String message) => throw _GateFailure(message);

bool _isIdentifierChar(int code) {
  if (code >= 0x30 && code <= 0x39) {
    return true;
  }
  if (code >= 0x41 && code <= 0x5A) {
    return true;
  }
  if (code >= 0x61 && code <= 0x7A) {
    return true;
  }
  return code == 0x5F || code == 0x24;
}

String _normalizePath(String path) => path.replaceAll(r'\', '/');

bool _isRawStringPrefix(String source, int quoteIndex) {
  if (quoteIndex == 0 || source[quoteIndex - 1] != 'r') {
    return false;
  }
  if (quoteIndex == 1) {
    return true;
  }
  return !_isIdentifierChar(source.codeUnitAt(quoteIndex - 2));
}

int _stringEnd(String source, int quoteIndex) {
  final quote = source[quoteIndex];
  final isRaw = _isRawStringPrefix(source, quoteIndex);
  final triple = source.startsWith(quote * 3, quoteIndex);
  final delimiter = triple ? quote * 3 : quote;
  var index = quoteIndex + delimiter.length;
  while (index < source.length) {
    if (!isRaw && source[index] == r'\') {
      index += 2;
      continue;
    }
    if (source.startsWith(delimiter, index)) {
      return index + delimiter.length;
    }
    index += 1;
  }
  return source.length;
}

/// Returns the matching close paren index for [openIndex], skipping strings
/// and comments. Returns null when unbalanced.
int? _matchingDelimiter(String source, int openIndex) {
  var depth = 0;
  var index = openIndex;
  while (index < source.length) {
    final char = source[index];
    if (char == '/' && index + 1 < source.length) {
      if (source[index + 1] == '/') {
        final newline = source.indexOf('\n', index);
        index = newline == -1 ? source.length : newline + 1;
        continue;
      }
      if (source[index + 1] == '*') {
        final end = source.indexOf('*/', index + 2);
        index = end == -1 ? source.length : end + 2;
        continue;
      }
    }
    if (char == "'" || char == '"') {
      index = _stringEnd(source, index);
      continue;
    }
    if (char == '(') {
      depth += 1;
    } else if (char == ')') {
      depth -= 1;
      if (depth == 0) {
        return index;
      }
    }
    index += 1;
  }
  return null;
}

/// Reads the first string literal at or after [from], skipping comments and
/// whitespace. Returns the decoded value and the index after the literal, or
/// null when no closed literal is found before the argument list ends.
(String, int)? _readFirstStringLiteral(String source, int from) {
  var index = from;
  while (index < source.length) {
    final char = source[index];
    if (char == ')' || char == ',') {
      return null;
    }
    if (char == '/' && index + 1 < source.length && source[index + 1] == '/') {
      final newline = source.indexOf('\n', index);
      index = newline == -1 ? source.length : newline + 1;
      continue;
    }
    if (char == '/' && index + 1 < source.length && source[index + 1] == '*') {
      final end = source.indexOf('*/', index + 2);
      index = end == -1 ? source.length : end + 2;
      continue;
    }
    if (char == "'" || char == '"') {
      final isRaw = _isRawStringPrefix(source, index);
      final triple = source.startsWith(char * 3, index);
      final delimiter = triple ? char * 3 : char;
      final end = _stringEnd(source, index);
      final contentEnd = end >= index + delimiter.length
          ? end - delimiter.length
          : index + delimiter.length;
      final rawValue = source.substring(index + delimiter.length, contentEnd);
      final value = isRaw ? rawValue : _decodeEscapes(rawValue);
      return (value, end);
    }
    index += 1;
  }
  return null;
}

String _decodeEscapes(String value) {
  if (!value.contains(r'\')) {
    return value;
  }
  final buffer = StringBuffer();
  var index = 0;
  while (index < value.length) {
    final char = value[index];
    if (char != r'\' || index + 1 >= value.length) {
      buffer.write(char);
      index += 1;
      continue;
    }
    final next = value[index + 1];
    switch (next) {
      case 'n':
        buffer.write('\n');
      case 't':
        buffer.write('\t');
      case 'r':
        buffer.write('\r');
      default:
        buffer.write(next);
    }
    index += 2;
  }
  return buffer.toString();
}

/// Extracts and normalizes the suppression expression that starts after the
/// token colon at [from], stopping at the first top-level comma or the end of
/// the argument list. Whitespace is collapsed and no trailing comma remains.
String _extractExpression(String source, int from) {
  final buffer = StringBuffer();
  var depth = 0;
  var index = from;
  while (index < source.length) {
    final char = source[index];
    if (char == '/' && index + 1 < source.length && source[index + 1] == '/') {
      final newline = source.indexOf('\n', index);
      index = newline == -1 ? source.length : newline + 1;
      buffer.write(' ');
      continue;
    }
    if (char == '/' && index + 1 < source.length && source[index + 1] == '*') {
      final end = source.indexOf('*/', index + 2);
      index = end == -1 ? source.length : end + 2;
      buffer.write(' ');
      continue;
    }
    if (char == "'" || char == '"') {
      final end = _stringEnd(source, index);
      buffer.write(source.substring(index, end));
      index = end;
      continue;
    }
    if (char == '(' || char == '[' || char == '{') {
      depth += 1;
    }
    if (char == ')' || char == ']' || char == '}') {
      if (depth == 0) {
        break;
      }
      depth -= 1;
    }
    if (char == ',' && depth == 0) {
      break;
    }
    buffer.write(char);
    index += 1;
  }
  return buffer.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
}

List<File> _dartFilesUnderTest() {
  final directory = Directory(_testRoot);
  if (!directory.existsSync()) {
    _fail('the test directory is missing at $_testRoot');
  }
  final files = <File>[];
  for (final entity in directory.listSync(
    recursive: true,
    followLinks: false,
  )) {
    if (entity is File && entity.path.endsWith('.dart')) {
      files.add(entity);
    }
  }
  files.sort(
    (a, b) => _normalizePath(a.path).compareTo(_normalizePath(b.path)),
  );
  return files;
}

List<_SuppressionSite> _detectSuppressionSites() {
  final sites = <_SuppressionSite>[];
  for (final file in _dartFilesUnderTest()) {
    final path = _normalizePath(file.path);
    final source = file.readAsStringSync();
    final calls = _callPattern.allMatches(source).toList();
    for (final token in _suppressionTokenPattern.allMatches(source)) {
      String? callKind;
      var openIndex = -1;
      for (final call in calls) {
        if (call.start >= token.start) {
          break;
        }
        final candidateOpen = call.end - 1;
        final closeIndex = _matchingDelimiter(source, candidateOpen);
        if (closeIndex == null) {
          _fail(
            '$path: an unbalanced argument list surrounds a suppression token',
          );
        }
        if (closeIndex > token.start) {
          callKind = call.group(1);
          openIndex = candidateOpen;
        }
      }
      if (callKind == null) {
        _fail(
          '$path: a suppression token is not bound to a recognized test, testWidgets, or group call',
        );
      }
      final literal = _readFirstStringLiteral(source, openIndex + 1);
      if (literal == null) {
        _fail(
          '$path: a lifecycle call containing a suppression token has no string-literal identity',
        );
      }
      final identity = literal.$1;
      final expression = _extractExpression(source, token.end);
      if (identity.trim().isEmpty) {
        _fail('$path: a suppression site has an empty identity');
      }
      if (expression.isEmpty) {
        _fail('$path: a suppression site has an empty expression');
      }
      sites.add(
        _SuppressionSite(
          file: path,
          kind: callKind == 'group' ? 'group' : 'test',
          identity: identity,
          expression: expression,
        ),
      );
    }
  }
  sites.sort((a, b) => a.bindingKey.compareTo(b.bindingKey));
  final seen = <String>{};
  for (final site in sites) {
    if (!seen.add(site.bindingKey)) {
      _fail(
        '${site.file}: duplicate suppression identity "${site.identity}" (kind ${site.kind})',
      );
    }
  }
  return sites;
}

String _requiredString(Map<dynamic, dynamic> entry, String key, String label) {
  final value = entry[key];
  if (value is! String || value.trim().isEmpty) {
    _fail('$label is missing a non-empty "$key" field');
  }
  return value;
}

List<_RegistryEntry> _loadRegistry() {
  final file = File(_registryPath);
  if (!file.existsSync()) {
    _fail('the suppression registry file is missing at $_registryPath');
  }
  Object? decoded;
  try {
    decoded = jsonDecode(file.readAsStringSync());
  } on FormatException {
    _fail('the suppression registry is not valid JSON (structural error only)');
  }
  if (decoded is! Map<dynamic, dynamic>) {
    _fail('the suppression registry root is not an object');
  }
  if (decoded['version'] != 1) {
    _fail('the suppression registry version must be 1');
  }
  final rawEntries = decoded['skips'];
  if (rawEntries is! List) {
    _fail('the suppression registry "skips" field is not a list');
  }
  final entries = <_RegistryEntry>[];
  final ids = <String>{};
  final bindings = <String>{};
  for (var index = 0; index < rawEntries.length; index += 1) {
    final raw = rawEntries[index];
    final label = 'suppression registry entry #${index + 1}';
    if (raw is! Map<dynamic, dynamic>) {
      _fail('$label is not an object');
    }
    final id = _requiredString(raw, 'id', label);
    final kind = _requiredString(raw, 'kind', label);
    final entryFile = _requiredString(raw, 'file', label);
    final identity = _requiredString(raw, 'testName', label);
    final expression = _requiredString(raw, 'expression', label);
    _requiredString(raw, 'reason', label);
    if (kind != 'test' && kind != 'group') {
      _fail('$label has an invalid kind "$kind"');
    }
    if (!_allowedTestPathPattern.hasMatch(entryFile)) {
      _fail('$label file is not an allowed test path: $entryFile');
    }
    if (!ids.add(id)) {
      _fail('$label reuses the id "$id"');
    }
    final entry = _RegistryEntry(
      id: id,
      file: entryFile,
      kind: kind,
      identity: identity,
      expression: expression,
    );
    if (!bindings.add(entry.bindingKey)) {
      _fail(
        '$label duplicates the binding for "${entry.identity}" in ${entry.file}',
      );
    }
    entries.add(entry);
  }
  return entries;
}

List<String> _loadManifest() {
  final file = File(_manifestPath);
  if (!file.existsSync()) {
    _fail('the discovery manifest is missing at $_manifestPath');
  }
  Object? decoded;
  try {
    decoded = jsonDecode(file.readAsStringSync());
  } on FormatException {
    _fail('the discovery manifest is not valid JSON (structural error only)');
  }
  if (decoded is! List) {
    _fail('the discovery manifest root is not a list');
  }
  final paths = <String>[];
  final seen = <String>{};
  for (final raw in decoded) {
    if (raw is! String || raw.trim().isEmpty) {
      _fail(
        'the discovery manifest contains an entry that is not a non-empty string',
      );
    }
    if (!_allowedTestPathPattern.hasMatch(raw)) {
      _fail(
        'the discovery manifest lists a path that is not an allowed test file: $raw',
      );
    }
    if (!seen.add(raw)) {
      _fail('the discovery manifest repeats the path: $raw');
    }
    paths.add(raw);
  }
  return paths;
}

Set<String> _discoveredTestFiles() {
  final discovered = <String>{};
  for (final entity in Directory(
    _testRoot,
  ).listSync(recursive: true, followLinks: false)) {
    if (entity is! File) {
      continue;
    }
    final path = _normalizePath(entity.path);
    if (path.endsWith('_test.dart')) {
      discovered.add(path);
    }
  }
  return discovered;
}

void main() {
  group('test integrity gate', () {
    test('suppression registry is well-formed and internally consistent', () {
      _loadRegistry();
    });

    test('every registered suppression site still exists unchanged in source', () {
      final registry = _loadRegistry();
      final detected = <String, _SuppressionSite>{
        for (final site in _detectSuppressionSites()) site.bindingKey: site,
      };
      for (final entry in registry) {
        final site = detected[entry.bindingKey];
        if (site == null) {
          _fail(
            'registered suppression site is missing from source: ${entry.file} :: "${entry.identity}" (${entry.id})',
          );
        }
        if (site.identity != entry.identity) {
          _fail(
            'registered suppression identity changed in source: ${entry.file} (${entry.id})',
          );
        }
        if (site.expression != entry.expression) {
          _fail(
            'registered suppression expression differs from source: ${entry.file} :: "${entry.identity}" (${entry.id})',
          );
        }
      }
    });

    test('every suppression site in source is registered', () {
      final registry = <String, _RegistryEntry>{
        for (final entry in _loadRegistry()) entry.bindingKey: entry,
      };
      for (final site in _detectSuppressionSites()) {
        if (!registry.containsKey(site.bindingKey)) {
          _fail(
            'unregistered suppression site: ${site.file} :: "${site.identity}" (kind ${site.kind})',
          );
        }
      }
    });

    test('no unregistered suppression mechanisms exist under test/', () {
      final runtimeCallMarker =
          'markTest'
          'Skipped';
      final platformAnnotationMarker =
          '@Test'
          'On';
      for (final file in _dartFilesUnderTest()) {
        final path = _normalizePath(file.path);
        final source = file.readAsStringSync();
        if (source.contains(runtimeCallMarker)) {
          _fail('an unregistered runtime suppression call exists in $path');
        }
        if (source.contains(platformAnnotationMarker)) {
          _fail('an unregistered platform test annotation exists in $path');
        }
      }
    });

    test('discovery manifest is well-formed', () {
      _loadManifest();
    });

    test('discovery manifest exactly matches the discovered test files', () {
      final manifest = _loadManifest().toSet();
      final discovered = _discoveredTestFiles();
      final missingOnDisk =
          manifest.where((path) => !File(path).existsSync()).toList()..sort();
      if (missingOnDisk.isNotEmpty) {
        _fail(
          'the discovery manifest lists paths that do not exist on disk '
          '(${missingOnDisk.length}): ${missingOnDisk.take(5).join(', ')}',
        );
      }
      final undiscovered = manifest.difference(discovered).toList()..sort();
      if (undiscovered.isNotEmpty) {
        _fail(
          'the discovery manifest lists paths that are not discovered test files '
          '(${undiscovered.length}): ${undiscovered.take(5).join(', ')}',
        );
      }
      final unlisted = discovered.difference(manifest).toList()..sort();
      if (unlisted.isNotEmpty) {
        _fail(
          'discovered test files are missing from the manifest '
          '(${unlisted.length}): ${unlisted.take(5).join(', ')}',
        );
      }
    });

    test('integrity gate never writes its own artifacts', () {
      final source = File(_selfPath).readAsStringSync();
      final writeCapableMarkers = <String>[
        'write'
            'AsString',
        'write'
            'AsBytes',
        'write'
            'AsStringSync',
        'write'
            'AsBytesSync',
        'open'
            'Write',
        'File'
            'Mode.write',
        'delete'
            'Sync',
        'rename'
            'Sync',
        'copy'
            'Sync',
      ];
      for (final marker in writeCapableMarkers) {
        if (source.contains(marker)) {
          _fail(
            'the integrity gate contains a write-capable marker "$marker"; it must stay read-only',
          );
        }
      }
    });
  });
}
