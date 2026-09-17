import 'package:flutter/material.dart';

/// The two app-owned Location education surfaces for Maps.
///
/// Neither of them gates the base map: both are dismissible, and the map stays
/// fully usable (pan, zoom, map type, Drop Pin, saved pins) behind them.

/// What the user chose on the first-entry education.
enum MapsLocationEducationChoice { allow, notNow }

/// What the user chose on the permanently-denied Android Settings route.
enum MapsLocationSettingsChoice { openSettings, notNow }

/// ONE first-entry education before Android's runtime prompt.
///
/// "Allow location" is handled by the caller through the EXISTING Locate path,
/// which is what actually invokes the operating-system runtime dialog and
/// records the truthful privacy audit. Dart side never navigates to Android
/// Settings on a first request.
Future<MapsLocationEducationChoice?> showMapsLocationEducationDialog(
  BuildContext context,
) {
  return showDialog<MapsLocationEducationChoice>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      key: const Key('maps-location-education'),
      title: const Text('Allow location?'),
      content: const Text(
        'Location access lets Next Transfer show where you are and use '
        'Locate me. You can still view and use Maps without sharing your '
        'location.',
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('maps-location-education-not-now'),
          onPressed: () => Navigator.of(
            dialogContext,
          ).pop(MapsLocationEducationChoice.notNow),
          child: const Text('Not now'),
        ),
        FilledButton(
          key: const Key('maps-location-education-allow'),
          onPressed: () =>
              Navigator.of(dialogContext).pop(MapsLocationEducationChoice.allow),
          child: const Text('Allow location'),
        ),
      ],
    ),
  );
}

/// Shown only when Android reports the permission as permanently denied and
/// the only remaining route is this app's system settings page.
Future<MapsLocationSettingsChoice?> showMapsLocationSettingsDialog(
  BuildContext context,
) {
  return showDialog<MapsLocationSettingsChoice>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      key: const Key('maps-location-settings-education'),
      title: const Text('Location permission is turned off'),
      content: const Text(
        'Enable location permission in Android Settings to use Locate me.',
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('maps-location-settings-not-now'),
          onPressed: () => Navigator.of(
            dialogContext,
          ).pop(MapsLocationSettingsChoice.notNow),
          child: const Text('Not now'),
        ),
        FilledButton(
          key: const Key('maps-location-settings-open'),
          onPressed: () => Navigator.of(
            dialogContext,
          ).pop(MapsLocationSettingsChoice.openSettings),
          child: const Text('Open Settings'),
        ),
      ],
    ),
  );
}
