import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rmplanner/app/shell/window_size_class.dart';
import 'package:rmplanner/app/theme/app_theme.dart';
import 'package:rmplanner/app/theme/internal_screen.dart';
import 'package:rmplanner/app/theme/theme_color_mode.dart';
import 'package:rmplanner/features/settings/application/appearance_providers.dart';
import 'package:rmplanner/features/settings/application/appearance_repository.dart';

/// User-facing Appearance + Theme Color selector.
///
/// Two independent device-scoped dimensions:
/// - APPEARANCE: System / Light / Dark (drives ThemeMode).
/// - THEME COLOR: Rose / Blue (drives the semantic palette).
///
/// The current persisted values are preselected.  Choosing a different value
/// applies it LIVE (MaterialApp theme) and persists it immediately for the
/// device.  Persistence failures never lie: the UI does not switch to a value
/// that could not be saved.  Neither dimension touches Goal/Planner data.
final class AppearanceScreen extends ConsumerWidget {
  const AppearanceScreen({super.key});

  static const List<(AppearanceMode, String)> _appearanceOptions =
      <(AppearanceMode, String)>[
        (AppearanceMode.system, 'System'),
        (AppearanceMode.light, 'Light'),
        (AppearanceMode.dark, 'Dark'),
      ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(appearanceProvider);
    final currentColor = ref.watch(themeColorProvider);
    return Scaffold(
      appBar: InternalAppBar(title: const Text('Appearance')),
      body: SafeArea(
        // PRE-BETA RESPONSIVE (owner law, 2026-09-16): this settings detail is
        // ordinary content, so it is capped on a wide window instead of
        // stretching.  Layout-neutral at phone widths.
        child: MaxContentWidth(
          child: ListView(
            padding: InternalScreen.pagePadding,
            children: <Widget>[
              Text('APPEARANCE', style: InternalScreen.sectionHeading),
              const SizedBox(height: 4),
              RadioGroup<AppearanceMode>(
                groupValue: current,
                onChanged: (value) {
                  if (value == null || value == current) {
                    return;
                  }
                  unawaited(_onSelectMode(ref, value));
                },
                child: Column(
                  children: <Widget>[
                    for (final (mode, title) in _appearanceOptions)
                      RadioListTile<AppearanceMode>(
                        key: Key('appearance-option-${mode.storageName}'),
                        value: mode,
                        title: Text(title),
                        activeColor: Theme.of(context).colorScheme.primary,
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              Text('THEME COLOR', style: InternalScreen.sectionHeading),
              const SizedBox(height: 4),
              RadioGroup<ThemeColorMode>(
                groupValue: currentColor,
                onChanged: (value) {
                  if (value == null || value == currentColor) {
                    return;
                  }
                  unawaited(_onSelectColor(ref, value));
                },
                child: Column(
                  children: <Widget>[
                    for (final color in ThemeColorMode.values)
                      RadioListTile<ThemeColorMode>(
                        key: Key('theme-color-option-${color.storageName}'),
                        value: color,
                        title: Row(
                          children: <Widget>[
                            _ColorSwatch(color: color),
                            const SizedBox(width: 12),
                            Text(_colorLabel(color)),
                          ],
                        ),
                        activeColor: Theme.of(context).colorScheme.primary,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _onSelectMode(WidgetRef ref, AppearanceMode mode) async {
    // Persist first; only a successful save flips the live selection so a
    // persistence failure can never make the UI claim a mode that was not
    // stored (it stays on the last confirmed value).
    final messenger = ScaffoldMessenger.of(ref.context);
    final saved = await ref.read(appearanceProvider.notifier).setMode(mode);
    if (!saved) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not save appearance')),
      );
    }
  }

  Future<void> _onSelectColor(WidgetRef ref, ThemeColorMode color) async {
    final messenger = ScaffoldMessenger.of(ref.context);
    final saved = await ref.read(themeColorProvider.notifier).setColor(color);
    if (!saved) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not save theme color')),
      );
    }
  }

  static String _colorLabel(ThemeColorMode color) => switch (color) {
    ThemeColorMode.rose => 'Rose',
    ThemeColorMode.blue => 'Blue',
  };
}

class _ColorSwatch extends StatelessWidget {
  const _ColorSwatch({required this.color});

  final ThemeColorMode color;

  @override
  Widget build(BuildContext context) {
    final fill = switch (color) {
      ThemeColorMode.rose => AppTheme.roseLightPrimary,
      ThemeColorMode.blue => AppTheme.blueLightPrimary,
    };
    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        color: fill,
        shape: BoxShape.circle,
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
    );
  }
}
