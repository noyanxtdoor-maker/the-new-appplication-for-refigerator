import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rmplanner/app/theme/internal_screen.dart';
import 'package:rmplanner/features/planner/application/event_type_creation_providers.dart';
import 'package:rmplanner/features/planner/application/event_type_providers.dart';
import 'package:rmplanner/features/planner/domain/event_type_creation_choice.dart';
import 'package:rmplanner/features/planner/domain/planner_settings.dart';

final class PlannerSettingsScreen extends ConsumerWidget {
  const PlannerSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(eventTypeControllerProvider);
    final controller = ref.read(eventTypeControllerProvider.notifier);
    final settings = state.settings;
    // Contract E: ONLY the Default Event Type list/value resolution uses the
    // live creation choices. Every other setting/reminder control is
    // untouched. A hidden saved default renders the existing null/Other
    // fallback; there is no passive preference mutation. While eligibility
    // is unresolved (loading/error) the dropdown collapses to the neutral
    // Other item with selection disabled — never a stale all-types list.
    final choicesAsync = ref.watch(eventTypeCreationChoicesProvider);
    final choicesReady = choicesAsync.hasValue && !choicesAsync.isLoading;
    final eligibleChoices = choicesAsync.maybeWhen(
      data: (value) => value,
      orElse: () => const <EventTypeCreationChoice>[],
    );
    final visibleDefaultEventTypeId = choicesReady
        ? eligibleChoices
              .where((choice) => choice.type.id == settings.defaultEventTypeId)
              .firstOrNull
              ?.type
              .id
        : null;
    return Scaffold(
      appBar: InternalAppBar(title: const Text('Planner and Calendar')),
      body: SafeArea(
        child: state.isLoading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: InternalScreen.pagePadding,
                children: <Widget>[
                  if (state.message != null) ...<Widget>[
                    MaterialBanner(
                      content: Text(state.message!),
                      actions: <Widget>[
                        TextButton(
                          onPressed: controller.clearMessage,
                          child: const Text('Dismiss'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                  ],
                  // P1 owner correction (2026-09-21): the Event Types
                  // MANAGEMENT row was removed from Planner settings so the
                  // visible Event Type taxonomy behaves as a standard app
                  // capability rather than an exposed settings surface. The
                  // Event Types themselves, their persistence, the picker in
                  // Event creation, system/Goal/contact mappings and the
                  // Default Event Type control below are all unchanged.
                  _Section(
                    title: 'Event defaults',
                    children: <Widget>[
                      DropdownButtonFormField<String?>(
                        key: const Key('default-event-type-setting'),
                        initialValue: visibleDefaultEventTypeId,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'Default Event Type',
                        ),
                        items: <DropdownMenuItem<String?>>[
                          const DropdownMenuItem<String?>(
                            child: Text('Other / ask each time'),
                          ),
                          for (final choice
                              in (choicesReady
                                  ? EventTypeCreationChoice.orderedForDropdown(
                                      eligibleChoices,
                                    )
                                  : const <EventTypeCreationChoice>[]))
                            DropdownMenuItem<String?>(
                              value: choice.type.id,
                              child: Text(choice.displayLabel),
                            ),
                        ],
                        onChanged: choicesReady
                            ? (value) => controller.saveSettings(
                                settings.copyWith(
                                  defaultEventTypeId: value,
                                  clearDefaultEventType: value == null,
                                ),
                              )
                            : null,
                      ),
                      const SizedBox(height: 12),
                      _DefaultDurationSetting(
                        defaultDurationMinutes: settings.defaultDurationMinutes,
                        onChanged: (value) => controller.saveSettings(
                          settings.copyWith(defaultDurationMinutes: value),
                        ),
                      ),
                    ],
                  ),
                  _Section(
                    title: 'Timeline',
                    children: <Widget>[
                      Text(
                        'Visible Planner Hours',
                        key: const Key('visible-planner-hours-heading'),
                        style: InternalScreen.sectionHeading.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Choose the one-hour start and end boundaries shown '
                        'on the Day timeline.',
                      ),
                      const SizedBox(height: 10),
                      OutlinedButton.icon(
                        key: const Key('planner-full-day-preset'),
                        onPressed: () => controller.saveSettings(
                          settings.copyWith(
                            visibleStartHour: 0,
                            visibleEndHour: 24,
                          ),
                        ),
                        icon: const Icon(Icons.view_day_outlined),
                        label: const Text('Show full 24 hours'),
                      ),
                      const SizedBox(height: 12),
                      _HourSetting(
                        label: 'Visible start hour',
                        value: settings.visibleStartHour,
                        values: List<int>.generate(24, (index) => index),
                        onChanged: (value) => controller.saveSettings(
                          settings.copyWith(visibleStartHour: value),
                        ),
                      ),
                      const SizedBox(height: 12),
                      _HourSetting(
                        label: 'Visible end hour',
                        value: settings.visibleEndHour,
                        values: List<int>.generate(24, (index) => index + 1),
                        onChanged: (value) => controller.saveSettings(
                          settings.copyWith(visibleEndHour: value),
                        ),
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<int>(
                        key: const Key('time-snap-setting'),
                        initialValue: settings.snapMinutes,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'Time snapping',
                        ),
                        items: const <DropdownMenuItem<int>>[
                          DropdownMenuItem(value: 5, child: Text('5 minutes')),
                          DropdownMenuItem(
                            value: 10,
                            child: Text('10 minutes'),
                          ),
                          DropdownMenuItem(
                            value: 15,
                            child: Text('15 minutes'),
                          ),
                          DropdownMenuItem(
                            value: 30,
                            child: Text('30 minutes'),
                          ),
                          DropdownMenuItem(value: 60, child: Text('1 hour')),
                        ],
                        onChanged: (value) => controller.saveSettings(
                          settings.copyWith(snapMinutes: value),
                        ),
                      ),
                      // P2-D owner-review correction (2026-09-22): the relocated
                      // "24-hour time" tile used to sit between these two
                      // dropdowns, and its intrinsic tile height was the only
                      // thing keeping them apart. Once it moved to Display the
                      // two `InputDecorator` fields became directly adjacent, so
                      // the lower field's floating "Open timeline at" label
                      // collided with the upper field's bottom edge. Restoring
                      // the file's own 12 dp rhythm (every other pair on this
                      // screen already uses it) removes the overlap without
                      // changing either setting.
                      const SizedBox(height: 12),
                      DropdownButtonFormField<PlannerInitialScrollBehavior>(
                        key: const Key('initial-scroll-setting'),
                        initialValue: settings.initialScrollBehavior,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'Open timeline at',
                        ),
                        items:
                            const <
                              DropdownMenuItem<PlannerInitialScrollBehavior>
                            >[
                              DropdownMenuItem(
                                value: PlannerInitialScrollBehavior.currentTime,
                                child: Text('Current time'),
                              ),
                              DropdownMenuItem(
                                value:
                                    PlannerInitialScrollBehavior.visibleStart,
                                child: Text('Visible start hour'),
                              ),
                              DropdownMenuItem(
                                value: PlannerInitialScrollBehavior.dayStart,
                                child: Text('Top of visible day'),
                              ),
                            ],
                        onChanged: (value) => controller.saveSettings(
                          settings.copyWith(initialScrollBehavior: value),
                        ),
                      ),
                    ],
                  ),
                  _Section(
                    title: 'Display',
                    children: <Widget>[
                      // P2-D owner decision (2026-09-21): the EXISTING
                      // "24-hour time" preference moved here from the Timeline
                      // section. It is the SAME preference with the same
                      // persistence, formatter and default, and it is the only
                      // time-format control — ON is 24-hour, OFF is 12-hour
                      // AM/PM. Display order is deliberately: 24-hour time,
                      // Show completed items, Show cancelled items.
                      SwitchListTile(
                        key: const Key('use-24-hour-setting'),
                        contentPadding: EdgeInsets.zero,
                        title: const Text('24-hour time'),
                        value: settings.use24HourTime,
                        onChanged: (value) => controller.saveSettings(
                          settings.copyWith(use24HourTime: value),
                        ),
                      ),
                      // P1 owner correction (2026-09-21): the "Quick edit on
                      // timeline" toggle was removed. Long-press move, edge-drag
                      // resize, commit-on-release and Undo are KEPT as STANDARD
                      // behavior rather than a user-configurable preference, so
                      // there is no control here to disable them.
                      SwitchListTile(
                        key: const Key('show-completed-setting'),
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Show completed items'),
                        value: settings.showCompletedItems,
                        onChanged: (value) => controller.saveSettings(
                          settings.copyWith(showCompletedItems: value),
                        ),
                      ),
                      SwitchListTile(
                        key: const Key('show-cancelled-setting'),
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Show cancelled items'),
                        value: settings.showCancelledItems,
                        onChanged: (value) => controller.saveSettings(
                          settings.copyWith(showCancelledItems: value),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
      ),
    );
  }
}

/// Delta 4.2R R8: Default Event Duration control.
///
/// Presets are 15 / 30 / 45 minutes and 1 hour (owner-approved list). Any
/// other value is "Custom" and changes in exact 15-minute increments via a
/// picker, so the stored preference can never leave the 15-minute product
/// grid (validated again in [PlannerSettings.validate]).
final class _DefaultDurationSetting extends StatelessWidget {
  const _DefaultDurationSetting({
    required this.defaultDurationMinutes,
    required this.onChanged,
  });

  static const int _customSentinel = -1;
  static const List<int> _presets = <int>[15, 30, 45, 60];

  final int defaultDurationMinutes;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final isCustom = !_presets.contains(defaultDurationMinutes);
    return DropdownButtonFormField<int>(
      key: const Key('default-duration-setting'),
      initialValue: isCustom ? _customSentinel : defaultDurationMinutes,
      isExpanded: true,
      decoration: const InputDecoration(labelText: 'Default duration'),
      items: <DropdownMenuItem<int>>[
        for (final preset in _presets)
          DropdownMenuItem(value: preset, child: Text(_labelFor(preset))),
        DropdownMenuItem(
          value: _customSentinel,
          child: Text(
            isCustom ? 'Custom ($defaultDurationMinutes min)' : 'Custom…',
          ),
        ),
      ],
      onChanged: (value) {
        if (value == null) {
          return;
        }
        if (value != _customSentinel) {
          onChanged(value);
          return;
        }
        _pickCustom(context);
      },
    );
  }

  static String _labelFor(int minutes) {
    return switch (minutes) {
      60 => '1 hour',
      _ => '$minutes minutes',
    };
  }

  void _pickCustom(BuildContext context) {
    // 15-minute increments from 75 minutes up to the civil-day cap.
    final options = <int>[
      for (var minutes = 75; minutes <= 24 * 60; minutes += 15) minutes,
    ];
    unawaited(
      showDialog<int>(
        context: context,
        builder: (dialogContext) => SimpleDialog(
          key: const Key('default-duration-custom-dialog'),
          title: const Text('Custom default duration'),
          children: <Widget>[
            for (final option in options)
              SimpleDialogOption(
                key: Key('default-duration-custom-$option'),
                onPressed: () => Navigator.of(dialogContext).pop(option),
                child: Text(
                  option % 60 == 0
                      ? '${option ~/ 60} hour${option ~/ 60 == 1 ? '' : 's'}'
                      : '$option minutes',
                ),
              ),
          ],
        ),
      ).then((selected) {
        if (selected != null) {
          onChanged(selected);
        }
      }),
    );
  }
}

final class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              title,
              style: InternalScreen.sectionHeading.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            ...children,
          ],
        ),
      ),
    );
  }
}

final class _HourSetting extends StatelessWidget {
  const _HourSetting({
    required this.label,
    required this.value,
    required this.values,
    required this.onChanged,
  });

  final String label;
  final int value;
  final List<int> values;
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<int>(
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      items: <DropdownMenuItem<int>>[
        for (final hour in values)
          DropdownMenuItem<int>(value: hour, child: Text(_label(hour))),
      ],
      onChanged: onChanged,
    );
  }

  String _label(int hour) {
    if (hour == 24) {
      return '12:00 AM (next day)';
    }
    final display = hour == 0
        ? 12
        : hour > 12
        ? hour - 12
        : hour;
    return '$display:00 ${hour >= 12 ? 'PM' : 'AM'}';
  }
}
