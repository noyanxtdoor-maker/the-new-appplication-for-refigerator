/// Pure rules behind the Google Maps API key guard.
///
/// OWNER REVIEW #4 — a placeholder-key APK must never ship again.
///
/// The audit proved the profile APK was built with
/// `com.google.android.geo.API_KEY = "DEFAULT_API_KEY"`, the tracked fallback
/// from `android/secrets.defaults.properties`, because the untracked
/// `android/secrets.properties` was absent from the worktree. The Google Maps
/// Android SDK cannot authorize against that value, so the map could not render
/// on a build that otherwise passed every test.
///
/// There is deliberately no new framework here: the rules are pure functions so
/// the gate can be proven in both directions from `test/tool/`, exactly like
/// `tool/authority_rules.dart`.
library;

/// The Gradle/manifest placeholder name the secrets plugin substitutes.
const String mapsPropertyName = 'MAPS_API_KEY';

/// The tracked fallback value. Never a usable key.
const String mapsKeyPlaceholder = 'DEFAULT_API_KEY';

/// Untracked per-machine file holding the real restricted key.
const String mapsSecretsFileName = 'secrets.properties';

/// Tracked fallback file. Its only legitimate value is the placeholder.
const String mapsDefaultsFileName = 'secrets.defaults.properties';

/// The manifest meta-data name the SDK reads.
const String mapsManifestMetaDataName = 'com.google.android.geo.API_KEY';

/// Reads [mapsPropertyName] out of a Java-properties document.
///
/// Returns null when the file is absent, the key is not declared, or the
/// declaration is commented out. Handles `key=value`, `key = value`, `key:value`
/// and trailing whitespace/CR, and ignores `#`/`!` comment lines.
String? readMapsKey(String? propertiesText) {
  if (propertiesText == null) return null;
  for (final rawLine in propertiesText.split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#') || line.startsWith('!')) {
      continue;
    }
    final separator = _firstSeparator(line);
    if (separator == -1) continue;
    final name = line.substring(0, separator).trim();
    if (name != mapsPropertyName) continue;
    final value = line.substring(separator + 1).trim();
    return value;
  }
  return null;
}

int _firstSeparator(String line) {
  final equals = line.indexOf('=');
  final colon = line.indexOf(':');
  if (equals == -1) return colon;
  if (colon == -1) return equals;
  return equals < colon ? equals : colon;
}

/// Resolves the key the secrets plugin will substitute.
///
/// Precedence matches the plugin: the untracked local file wins and the tracked
/// defaults file is only a fallback. The EMPTY STRING means "nothing usable was
/// declared anywhere", which is a failure and never a silent success.
String resolveMapsKey({
  required String? localSecrets,
  required String? defaults,
}) => readMapsKey(localSecrets) ?? readMapsKey(defaults) ?? '';

/// True when the SDK can actually authorize with [value].
///
/// A missing, blank or placeholder value is not usable. The real key is never
/// echoed anywhere by this gate.
bool mapsKeyIsUsable(String value) {
  final trimmed = value.trim();
  return trimmed.isNotEmpty && trimmed != mapsKeyPlaceholder;
}

/// True when a packaged manifest dump still carries the placeholder.
///
/// Operates on the DECODED manifest text (for example `aapt2 dump xmltree`
/// output), never on raw APK bytes: the manifest inside an APK is deflate
/// compressed, so a byte scan of the archive would silently prove nothing.
bool packagedManifestHasPlaceholder(String decodedManifest) =>
    decodedManifest.contains(mapsKeyPlaceholder);

/// The only value classes the gate is allowed to report.
///
/// SECRET OUTPUT — FULL OPACITY (M-6 owner decision). A configured value is
/// secret in every respect: its characters, its prefix, its suffix and its
/// length. Output therefore carries a classification token and nothing else —
/// never a prefix, never a length, never a hash or encoded form.
enum MapsKeyClass {
  /// Nothing usable was declared anywhere.
  empty('<empty>'),

  /// The tracked fallback value, which the SDK cannot authorize against.
  placeholder('<placeholder>'),

  /// A value the SDK could use. Its contents and size stay secret.
  configured('<configured>');

  const MapsKeyClass(this.label);

  /// The safe, opaque label safe to print in any failure message.
  final String label;
}

/// Classifies [value] without exposing anything derived from it.
MapsKeyClass classifyMapsKey(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return MapsKeyClass.empty;
  if (trimmed == mapsKeyPlaceholder) return MapsKeyClass.placeholder;
  return MapsKeyClass.configured;
}
