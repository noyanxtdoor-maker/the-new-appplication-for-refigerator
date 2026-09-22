import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rmplanner/app/theme/app_theme.dart';
import 'package:rmplanner/app/theme/internal_screen.dart';
import 'package:rmplanner/features/maps/application/map_session_provider.dart';
import 'package:rmplanner/features/maps/application/maps_preferences_provider.dart';
import 'package:rmplanner/features/maps/presentation/google_maps_surface.dart'
    show NextTransferMapTypePresentation;

/// VS-15 M6.2: centralized Maps settings destination.
///
/// MAPS: Map Type (persist-first, same canonical path as the in-map
/// chooser — [MapsSessionController.selectMapType]).
/// MAP CONTENT: Group nearby markers, Contacts, Events, Saved Places,
/// Boundaries — all device-scoped, persisted in the single-row
/// `MapsPreferences` table (schema v37). Every switch is persist-first:
/// the visible state only changes after the write succeeds, so the UI never
/// claims a save that did not happen.
final class MapsSettingsScreen extends ConsumerWidget {
  const MapsSettingsScreen({super.key});

  Future<void> _pickMapType(BuildContext context, WidgetRef ref) async {
    final current = ref.read(mapsPreferencesProvider).mapType;
    NextTransferMapType? chosen;
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: RadioGroup<NextTransferMapType>(
          groupValue: current,
          onChanged: (value) {
            if (value == null || value == current) return;
            chosen = value;
            Navigator.of(sheetContext).pop();
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('MAP TYPE', style: InternalScreen.sectionHeading),
                ),
              ),
              for (final type in NextTransferMapType.values)
                RadioListTile<NextTransferMapType>(
                  key: Key('maps-settings-map-type-${type.name}'),
                  value: type,
                  title: Text(type.label),
                  activeColor: Theme.of(context).colorScheme.primary,
                ),
            ],
          ),
        ),
      ),
    );
    if (chosen == null || !context.mounted) return;
    // The SAME canonical persist-first path the in-map chooser uses.
    final ok = await ref
        .read(mapsSessionProvider.notifier)
        .selectMapType(chosen!);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Couldn't save the map type. Please try again."),
        ),
      );
    }
  }

  Future<void> _toggle(
    BuildContext context,
    WidgetRef ref,
    Future<bool> Function(MapsPreferencesNotifier notifier) change,
  ) async {
    final ok = await change(ref.read(mapsPreferencesProvider.notifier));
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Couldn't save this setting. Please try again."),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preferences = ref.watch(mapsPreferencesProvider);
    return Scaffold(
      appBar: InternalAppBar(title: const Text('Maps')),
      body: SafeArea(
        child: ListView(
          padding: InternalScreen.pagePadding,
          children: <Widget>[
            Text('MAPS', style: InternalScreen.sectionHeading),
            const SizedBox(height: 4),
            Card(
              margin: EdgeInsets.zero,
              color: AppTheme.settingsCardOf(context),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
                side: BorderSide(color: AppTheme.outlineOf(context)),
              ),
              child: ListTile(
                key: const Key('maps-settings-map-type'),
                leading: const Icon(Icons.map_outlined),
                title: const Text('Map Type'),
                subtitle: Text(preferences.mapType.label),
                trailing: const Icon(Icons.chevron_right, size: 20),
                onTap: () => unawaited(_pickMapType(context, ref)),
              ),
            ),
            const SizedBox(height: 18),
            Text('MAP CONTENT', style: InternalScreen.sectionHeading),
            const SizedBox(height: 4),
            Card(
              margin: EdgeInsets.zero,
              color: AppTheme.settingsCardOf(context),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
                side: BorderSide(color: AppTheme.outlineOf(context)),
              ),
              child: Column(
                children: <Widget>[
                  SwitchListTile(
                    key: const Key('maps-settings-group-nearby'),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                    title: const Text('Group nearby markers'),
                    value: preferences.groupNearbyMarkers,
                    onChanged: (value) => unawaited(
                      _toggle(
                        context,
                        ref,
                        (notifier) => notifier.setGroupNearbyMarkers(value),
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                  SwitchListTile(
                    key: const Key('maps-settings-contacts'),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                    title: const Text('Contacts'),
                    value: preferences.showContacts,
                    onChanged: (value) => unawaited(
                      _toggle(
                        context,
                        ref,
                        (notifier) => notifier.setShowContacts(value),
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                  SwitchListTile(
                    key: const Key('maps-settings-events'),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                    title: const Text('Events'),
                    value: preferences.showEvents,
                    onChanged: (value) => unawaited(
                      _toggle(
                        context,
                        ref,
                        (notifier) => notifier.setShowEvents(value),
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                  SwitchListTile(
                    key: const Key('maps-settings-saved-places'),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                    title: const Text('Saved Places'),
                    value: preferences.showSavedPlaces,
                    onChanged: (value) => unawaited(
                      _toggle(
                        context,
                        ref,
                        (notifier) => notifier.setShowSavedPlaces(value),
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                  SwitchListTile(
                    key: const Key('maps-settings-boundaries'),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                    title: const Text('Boundaries'),
                    value: preferences.showBoundaries,
                    onChanged: (value) => unawaited(
                      _toggle(
                        context,
                        ref,
                        (notifier) => notifier.setShowBoundaries(value),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
