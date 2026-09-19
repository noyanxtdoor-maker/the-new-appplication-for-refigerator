/// The published Next Transfer Privacy Policy, as linked from Privacy and Data.
///
/// Google Play's User Data policy expects a valid privacy policy both in the
/// store listing and within the application itself, so this screen links to the
/// exact canonical page rather than restating policy text. The URL lives here
/// as one constant so the screen and its regression test cannot drift apart.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

const String privacyPolicyUrl =
    'https://nexttransferapp-create.github.io/planwardlabs-legal/privacy/';

/// Opens [uri] outside Next Transfer, returning false when no installed
/// application accepted the handoff.
typedef ExternalUriLauncher = Future<bool> Function(Uri uri);

/// Injection seam for [ExternalUriLauncher].
///
/// Production resolves the platform launcher. Tests override this provider with
/// a recording fake so the handoff — and its failure path — can be asserted
/// without a device.
final externalUriLauncherProvider = Provider<ExternalUriLauncher>(
  (ref) => launchExternalUri,
);

/// Hands [uri] to the operating system.
///
/// `launchUrl` is called directly and deliberately NOT pre-flighted with
/// `canLaunchUrl`: on Android 11+ the `resolveActivity` lookup behind
/// `canLaunchUrl` is filtered by package visibility, while `startActivity`
/// itself is not. An `https` handoff therefore needs no `<queries>` manifest
/// declaration, and checking first would report a false negative.
Future<bool> launchExternalUri(Uri uri) async {
  try {
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  } on Object {
    // A missing handler surfaces as a platform exception on some devices. The
    // caller owns the user-facing message, so report "did not open" rather
    // than letting the platform error escape into the UI.
    return false;
  }
}
