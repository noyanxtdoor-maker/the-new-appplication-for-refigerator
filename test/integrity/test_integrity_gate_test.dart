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
//   * Suppression and lifecycle-token discovery is lexically code-aware: the
//     contents of comments and string literals are masked before matching, so a
//     purely textual mention of a suppression token can never be mistaken for a
//     real suppression site. (M-5 surgical correction, 2026-09-22.)
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

// Fragmented so this gate never carries a contiguous suppression token or
// marker in its own raw text; the lexer, not string matching, decides meaning.
const String _suppressionToken =
    'sk'
    'ip: true';
const String _runtimeSuppressionMarker =
    'markTest'
    'Skipped';
const String _platformAnnotationMarker =
    '@Test'
    'On';

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

/// Builds a same-length, index-aligned copy of [source] in which the contents
/// of every line comment, block comment, and string literal are replaced by
/// inert whitespace. Newlines and all real code are preserved exactly, so any
/// offset found in the mask addresses the same position in [source].
///
/// Normal, raw, triple-quoted, and escaped literals are all handled. This is
/// what keeps a textual mention of a suppression token from reading as code.
String _lexicalCodeMask(String source) {
  final buffer = StringBuffer();
  var index = 0;
  while (index < source.length) {
    final char = source[index];
    if (char == '/' && index + 1 < source.length && source[index + 1] == '/') {
      final newline = source.indexOf('\n', index);
      final end = newline == -1 ? source.length : newline;
      buffer.write(_inertSpan(source, index, end));
      index = end;
      continue;
    }
    if (char == '/' && index + 1 < source.length && source[index + 1] == '*') {
      final close = source.indexOf('*/', index + 2);
      final end = close == -1 ? source.length : close + 2;
      buffer.write(_inertSpan(source, index, end));
      index = end;
      continue;
    }
    if (char == "'" || char == '"') {
      final end = _stringEnd(source, index);
      buffer.write(_inertSpan(source, index, end));
      index = end;
      continue;
    }
    buffer.write(char);
    index += 1;
  }
  return buffer.toString();
}

/// Replaces [start]..[end) with spaces, preserving every newline and the
/// original character count.
String _inertSpan(String source, int start, int end) {
  final buffer = StringBuffer();
  for (var index = start; index < end; index += 1) {
    buffer.write(source[index] == '\n' ? '\n' : ' ');
  }
  return buffer.toString();
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
    sites.addAll(
      _suppressionSitesInSource(
        _normalizePath(file.path),
        file.readAsStringSync(),
      ),
    );
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

/// Detects every real suppression site in one already-read source file.
///
/// Token and lifecycle-call matching run against the lexical code mask, so a
/// comment or string literal can never contribute a false site. Identity and
/// expression extraction read the original source at the offsets the mask
/// points to.
List<_SuppressionSite> _suppressionSitesInSource(String path, String source) {
  final sites = <_SuppressionSite>[];
  final mask = _lexicalCodeMask(source);
  final calls = _callPattern.allMatches(mask).toList();
  for (final token in _suppressionTokenPattern.allMatches(mask)) {
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
  _assertManifestSorted(paths);
  return paths;
}

/// Fails unless [paths] is in the exact lexicographic order the committed
/// manifest uses. The manifest is a committed artifact: keeping it sorted makes
/// every legitimate addition or removal a single reviewable line in the diff.
void _assertManifestSorted(List<String> paths) {
  final ordered = List<String>.of(paths)..sort();
  for (var index = 0; index < paths.length; index += 1) {
    if (paths[index] != ordered[index]) {
      _fail(
        'the discovery manifest is not sorted lexicographically '
        '(first out-of-order entry at index $index)',
      );
    }
  }
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

/// Fails when a real runtime suppression call or platform test annotation
/// appears in [source]. Matching runs against the lexical code mask, so the
/// same words appearing in a comment or string literal are ignored.
void _assertNoUnregisteredMechanismsIn(String path, String source) {
  final mask = _lexicalCodeMask(source);
  if (mask.contains(_runtimeSuppressionMarker)) {
    _fail('an unregistered runtime suppression call exists in $path');
  }
  if (mask.contains(_platformAnnotationMarker)) {
    _fail('an unregistered platform test annotation exists in $path');
  }
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
      for (final file in _dartFilesUnderTest()) {
        _assertNoUnregisteredMechanismsIn(
          _normalizePath(file.path),
          file.readAsStringSync(),
        );
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

    // M-5 surgical correction (2026-09-22): the scanner must decide from real
    // Dart code, never from text that merely looks like code. Every fixture
    // below is assembled from fragments, so this gate's own raw text never
    // carries a contiguous suppression token or marker. Nothing here weakens
    // detection of real suppression code.
    group('scanner lexical correction', () {
      String realCall({String identity = 'probe real test'}) =>
          "test('$identity', () {}, sk"
          'ip: true);';
      String realGroup() =>
          "group('probe real group', () {}, sk"
          'ip: true);';

      /// Wraps the suppression token in [open]/[close] literal delimiters so the
      /// decoy text exists only at runtime, never contiguously in this file.
      String decoy(String open, String close) =>
          'final value = $open$_suppressionToken$close;';

      test('CORR-N1 a token inside a line comment is ignored', () {
        expect(
          _suppressionSitesInSource(
            'test/probe_fixture.dart',
            '// textual mention only: $_suppressionToken',
          ),
          isEmpty,
        );
      });

      test('CORR-N2 a token inside a block comment is ignored', () {
        expect(
          _suppressionSitesInSource(
            'test/probe_fixture.dart',
            '/* textual mention only: $_suppressionToken */',
          ),
          isEmpty,
        );
      });

      test('CORR-N3 a token inside string literals is ignored', () {
        final literals = <String>[
          decoy("'", "'"),
          decoy("r'", "'"),
          decoy("'''", "'''"),
          decoy('"""', '"""'),
          decoy("'a\\'", "'"),
        ];
        for (final literal in literals) {
          expect(
            _suppressionSitesInSource('test/probe_fixture.dart', literal),
            isEmpty,
          );
        }
      });

      test('CORR-N4 fake lifecycle text cannot bias suppression binding', () {
        final fromComment = [
          "// test('decoy comment', (",
          realCall(),
        ].join('\n');
        final stringDecoy = [
          'final String s = "test(',
          "'decoy string', (",
          '";',
        ].join();
        final fromString = [stringDecoy, realCall()].join('\n');
        for (final source in <String>[fromComment, fromString]) {
          final sites = _suppressionSitesInSource(
            'test/probe_fixture.dart',
            source,
          );
          expect(sites, hasLength(1));
          expect(sites.single.identity, 'probe real test');
        }
      });

      test('CORR-N5 marker text inside comments and strings is ignored', () {
        final sources = <String>[
          '// $_runtimeSuppressionMarker appears as prose only',
          "final marker = '$_runtimeSuppressionMarker';",
          '/* $_platformAnnotationMarker and $_platformAnnotationMarker */',
          "final annotation = '$_platformAnnotationMarker';",
        ];
        for (final source in sources) {
          expect(
            () => _assertNoUnregisteredMechanismsIn(
              'test/probe_fixture.dart',
              source,
            ),
            returnsNormally,
          );
        }
      });

      test(
        'CORR-N6 a real suppression on a real call is detected and bound',
        () {
          final sites = _suppressionSitesInSource(
            'test/probe_fixture.dart',
            realCall(),
          );
          expect(sites, hasLength(1));
          expect(sites.single.kind, 'test');
          expect(sites.single.identity, 'probe real test');
          expect(sites.single.expression, 'true');

          final groupSites = _suppressionSitesInSource(
            'test/probe_fixture.dart',
            realGroup(),
          );
          expect(groupSites, hasLength(1));
          expect(groupSites.single.kind, 'group');
          expect(groupSites.single.identity, 'probe real group');
        },
      );

      test('CORR-N7 a real unregistered suppression is still unregistered', () {
        final sites = _suppressionSitesInSource(
          'test/probe_fixture.dart',
          realCall(identity: 'probe unregistered real'),
        );
        final registry = <String, _RegistryEntry>{
          for (final entry in _loadRegistry()) entry.bindingKey: entry,
        };
        final unregistered = sites
            .where((site) => !registry.containsKey(site.bindingKey))
            .toList();
        expect(unregistered, hasLength(1));
        expect(unregistered.single.identity, 'probe unregistered real');
      });

      test('CORR-N8 real marker constructs still fail closed', () {
        expect(
          () => _assertNoUnregisteredMechanismsIn(
            'test/probe_fixture.dart',
            'void probe() { $_runtimeSuppressionMarker(); }',
          ),
          throwsA(isA<_GateFailure>()),
        );
        expect(
          () => _assertNoUnregisteredMechanismsIn(
            'test/probe_fixture.dart',
            "$_platformAnnotationMarker('vm')",
          ),
          throwsA(isA<_GateFailure>()),
        );
      });

      test('CORR-N9 an unsorted discovery manifest fails closed', () {
        final committed = _loadManifest();
        expect(() => _assertManifestSorted(committed), returnsNormally);

        final swapped = List<String>.of(committed);
        final index = swapped.length ~/ 2;
        final held = swapped[index];
        swapped[index] = swapped[index + 1];
        swapped[index + 1] = held;

        expect(
          () => _assertManifestSorted(swapped),
          throwsA(
            predicate(
              (Object? error) =>
                  error.toString().contains('not sorted lexicographically'),
            ),
          ),
        );
      });

      test('the lexical mask preserves length, offsets and newlines', () {
        final source = [
          "final value = '$_suppressionToken';",
          realCall(),
        ].join('\n');
        final mask = _lexicalCodeMask(source);
        expect(mask.length, source.length);
        expect(_suppressionTokenPattern.allMatches(source), hasLength(2));
        expect(_suppressionTokenPattern.allMatches(mask), hasLength(1));
        expect('\n'.allMatches(mask).length, '\n'.allMatches(source).length);
      });

      test('failure output stays structural and never echoes source text', () {
        const planted = 'PROBE_MARKER_9F3C7';
        final source = "final planted = '$planted';\n$_suppressionToken\n";
        expect(
          () => _suppressionSitesInSource('test/probe_fixture.dart', source),
          throwsA(
            predicate(
              (Object? error) =>
                  error.toString().contains('test/probe_fixture.dart') &&
                  !error.toString().contains(planted),
            ),
          ),
        );
      });
    });
  });
}
