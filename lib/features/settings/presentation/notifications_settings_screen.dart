import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rmplanner/app/theme/app_theme.dart';
import 'package:rmplanner/app/theme/internal_screen.dart';
import 'package:rmplanner/features/notifications/application/detailed_content_providers.dart';
import 'package:rmplanner/features/notifications/application/notification_providers.dart';
import 'package:rmplanner/features/notifications/application/reminder_notification_renderer.dart';
import 'package:rmplanner/features/notifications/data/detailed_content_preferences_store.dart';
import 'package:rmplanner/features/notifications/domain/notification_preferences.dart';
import 'package:rmplanner/features/notifications/domain/reminder_policy_label.dart';
import 'package:rmplanner/features/planner/application/event_type_providers.dart';
import 'package:rmplanner/features/privacy/application/privacy_providers.dart';
import 'package:rmplanner/features/privacy/domain/permission_summary.dart';
import 'package:rmplanner/features/privacy/domain/privacy_settings.dart';

final class NotificationsSettingsScreen extends ConsumerStatefulWidget {
  const NotificationsSettingsScreen({super.key});

  static const List<int?> _leadChoices = <int?>[null, 0, 5, 10, 15, 30, 60];

  @override
  ConsumerState<NotificationsSettingsScreen> createState() =>
      _NotificationsSettingsScreenState();
}

final class _NotificationsSettingsScreenState
    extends ConsumerState<NotificationsSettingsScreen>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(
        ref.read(notificationSettingsControllerProvider.notifier).load(),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(notificationSettingsControllerProvider);
    final controller = ref.read(
      notificationSettingsControllerProvider.notifier,
    );
    final privacy = ref.watch(privacyControllerProvider);
    final eventTypes = ref.watch(eventTypeControllerProvider);
    final preferences = state.preferences;
    final systemEnabled = preferences.effectiveSystemEnabled(
      androidPermissionGranted:
          state.permission == OperatingSystemPermissionState.granted,
    );

    return Scaffold(
      appBar: InternalAppBar(title: const Text('Notifications')),
      body: SafeArea(
        child: state.loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: InternalScreen.pagePadding,
                children: <Widget>[
                  if (state.message != null) ...<Widget>[
                    _Notice(text: state.message!),
                    const SizedBox(height: 12),
                  ],
                  const _SectionLabel('NOTIFICATIONS'),
                  _Card(
                    children: <Widget>[
                      ListTile(
                        key: const Key('notifications-system-status'),
                        leading: const Icon(Icons.notifications_outlined),
                        title: const Text('System notifications'),
                        trailing: Switch(
                          key: const Key('notifications-system-toggle'),
                          value:
                              preferences.systemNotificationsEnabled &&
                              state.permission ==
                                  OperatingSystemPermissionState.granted,
                          onChanged: (enabled) =>
                              controller.setSystemNotificationsEnabled(enabled),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  const _SectionLabel('CALENDAR EVENTS'),
                  _Card(
                    children: <Widget>[
                      SwitchListTile(
                        key: const Key('notifications-event-reminders'),
                        title: const Text('Event reminders'),
                        value: preferences.effectiveEventEnabled(
                          androidPermissionGranted:
                              state.permission ==
                              OperatingSystemPermissionState.granted,
                        ),
                        onChanged: systemEnabled
                            ? controller.setEventRemindersEnabled
                            : null,
                      ),
                      const Divider(height: 1),
                      ListTile(
                        key: const Key('notifications-default-event-reminder'),
                        title: const Text('Default event reminder'),
                        trailing: _ValueChevron(
                          value: _leadLabel(
                            eventTypes.settings.defaultReminderMinutes,
                          ),
                        ),
                        enabled: systemEnabled,
                        onTap: systemEnabled
                            ? () async {
                                final value = await _chooseLead(
                                  context,
                                  eventTypes.settings.defaultReminderMinutes,
                                );
                                if (!context.mounted ||
                                    value == _unchangedLead) {
                                  return;
                                }
                                await ref
                                    .read(eventTypeControllerProvider.notifier)
                                    .saveSettings(
                                      eventTypes.settings.copyWith(
                                        defaultReminderMinutes: value as int?,
                                        clearDefaultReminder: value == null,
                                      ),
                                    );
                              }
                            : null,
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  const _SectionLabel('TASKS'),
                  _Card(
                    children: <Widget>[
                      SwitchListTile(
                        key: const Key('notifications-task-reminders'),
                        title: const Text('Task reminders'),
                        value: preferences.effectiveTaskEnabled(
                          androidPermissionGranted:
                              state.permission ==
                              OperatingSystemPermissionState.granted,
                        ),
                        onChanged: systemEnabled
                            ? controller.setTaskRemindersEnabled
                            : null,
                      ),
                      const Divider(height: 1),
                      ListTile(
                        key: const Key('notifications-default-task-reminder'),
                        title: const Text('Default task reminder'),
                        trailing: _ValueChevron(
                          value: _leadLabel(
                            preferences.defaultTaskReminderMinutes,
                          ),
                        ),
                        enabled: systemEnabled,
                        onTap: systemEnabled
                            ? () async {
                                final value = await _chooseLead(
                                  context,
                                  preferences.defaultTaskReminderMinutes,
                                );
                                if (value == _unchangedLead) return;
                                await controller.savePreferences(
                                  preferences.copyWith(
                                    defaultTaskReminderMinutes: value as int?,
                                    clearDefaultTaskReminder: value == null,
                                  ),
                                );
                              }
                            : null,
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  const _SectionLabel('PLANNING'),
                  _Card(
                    children: <Widget>[
                      SwitchListTile(
                        key: const Key('notifications-weekly-review-reminders'),
                        title: const Text('Weekly Review reminders'),
                        value: preferences.effectiveWeeklyReviewEnabled(
                          androidPermissionGranted:
                              state.permission ==
                              OperatingSystemPermissionState.granted,
                        ),
                        onChanged: systemEnabled
                            ? controller.setWeeklyReviewRemindersEnabled
                            : null,
                      ),
                      const Divider(height: 1),
                      SwitchListTile(
                        key: const Key(
                          'notifications-awaiting-report-reminders',
                        ),
                        title: const Text('Awaiting Report reminders'),
                        value: preferences.effectiveAwaitingReportEnabled(
                          androidPermissionGranted:
                              state.permission ==
                              OperatingSystemPermissionState.granted,
                        ),
                        onChanged: systemEnabled
                            ? controller.setAwaitingReportRemindersEnabled
                            : null,
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  const _SectionLabel('DETAILED CONTENT'),
                  _DetailedContentCard(),
                  const SizedBox(height: 18),
                  const _SectionLabel('PRIVACY'),
                  _Card(
                    children: <Widget>[
                      ListTile(
                        key: const Key('notifications-preview'),
                        leading: const Icon(Icons.visibility_outlined),
                        title: const Text('Notification preview'),
                        trailing: Switch(
                          value:
                              privacy.settings.notificationPreviewMode ==
                              NotificationPreviewMode.showContent,
                          onChanged: systemEnabled
                              ? (showDetails) => ref
                                    .read(privacyControllerProvider.notifier)
                                    .setNotificationPreviewMode(
                                      showDetails
                                          ? NotificationPreviewMode.showContent
                                          : NotificationPreviewMode.hidden,
                                    )
                              : null,
                        ),
                      ),
                      if (privacy.settings.lockEnabled)
                        const Padding(
                          padding: EdgeInsets.fromLTRB(16, 0, 16, 14),
                          child: Text(
                            'Privacy Lock protects app entry. It does not change notification content — use the Detailed Content options above.',
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  const _SectionLabel('QUIET HOURS'),
                  _Card(
                    children: <Widget>[
                      SwitchListTile(
                        key: const Key('notifications-quiet-hours'),
                        title: const Text('Quiet hours'),
                        value: systemEnabled && preferences.quietHours.enabled,
                        onChanged: systemEnabled
                            ? (enabled) async {
                                if (!enabled) {
                                  await controller.savePreferences(
                                    preferences.copyWith(
                                      quietHours: QuietHoursSettings(
                                        enabled: false,
                                        startMinute:
                                            preferences.quietHours.startMinute,
                                        endMinute:
                                            preferences.quietHours.endMinute,
                                      ),
                                    ),
                                  );
                                  return;
                                }
                                await controller.savePreferences(
                                  preferences.copyWith(
                                    quietHours: QuietHoursSettings(
                                      enabled: true,
                                      startMinute:
                                          preferences.quietHours.startMinute ??
                                          22 * 60,
                                      endMinute:
                                          preferences.quietHours.endMinute ??
                                          7 * 60,
                                    ),
                                  ),
                                );
                              }
                            : null,
                      ),
                      const Divider(height: 1),
                      _TimeRow(
                        key: const Key('notifications-quiet-start'),
                        label: 'Start',
                        enabled:
                            systemEnabled && preferences.quietHours.enabled,
                        minute: preferences.quietHours.startMinute,
                        onSelected: (minute) => controller.savePreferences(
                          preferences.copyWith(
                            quietHours: QuietHoursSettings(
                              enabled: true,
                              startMinute: minute,
                              endMinute: preferences.quietHours.endMinute,
                            ),
                          ),
                        ),
                      ),
                      const Divider(height: 1),
                      _TimeRow(
                        key: const Key('notifications-quiet-end'),
                        label: 'End',
                        enabled:
                            systemEnabled && preferences.quietHours.enabled,
                        minute: preferences.quietHours.endMinute,
                        onSelected: (minute) => controller.savePreferences(
                          preferences.copyWith(
                            quietHours: QuietHoursSettings(
                              enabled: true,
                              startMinute: preferences.quietHours.startMinute,
                              endMinute: minute,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
      ),
    );
  }

  static const Object _unchangedLead = Object();
  static const Object _customLead = Object();
  static const int _maximumReminderLeadMinutes = 10080;

  static Future<Object?> _chooseLead(BuildContext context, int? current) async {
    final selected = await showModalBottomSheet<Object?>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: <Widget>[
            const Padding(
              padding: EdgeInsets.only(top: 10, bottom: 8),
              child: Center(
                child: SizedBox(
                  width: 36,
                  height: 4,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Color(0xFF8A8D92),
                      borderRadius: BorderRadius.all(Radius.circular(2)),
                    ),
                  ),
                ),
              ),
            ),
            const ListTile(title: Text('Reminder time')),
            const Divider(height: 1),
            for (final choice in NotificationsSettingsScreen._leadChoices)
              ListTile(
                title: Text(_leadLabel(choice)),
                trailing: choice == current ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(context, choice),
              ),
            ListTile(
              key: const Key('notifications-reminder-custom'),
              title: const Text('Custom...'),
              onTap: () => Navigator.pop(context, _customLead),
            ),
          ],
        ),
      ),
    );
    if (selected != _customLead) return selected ?? _unchangedLead;
    if (!context.mounted) return _unchangedLead;
    return _chooseCustomLead(context, current);
  }

  static Future<Object?> _chooseCustomLead(
    BuildContext context,
    int? current,
  ) => showDialog<Object?>(
    context: context,
    builder: (_) => _CustomReminderDialog(
      initialMinutes: current,
      minimumMinutes: 0,
      maximumMinutes: _maximumReminderLeadMinutes,
      unchangedValue: _unchangedLead,
    ),
  ).then((value) => value ?? _unchangedLead);

  static String _leadLabel(int? minutes) {
    if (minutes == null) return 'Off';
    // Existing "1 hour before" shorthand is preserved product copy (O8 keeps
    // existing suffixes); every other numeric value goes through the shared
    // formatter so 0/1 are never pluralised incorrectly.
    if (minutes == 60) return '1 hour before';
    return ReminderPolicyLabel.offsetMinutes(minutes);
  }
}

final class _DetailedContentCard extends ConsumerWidget {
  const _DetailedContentCard();

  /// Representative sample used by the live preview.
  ///
  /// It is deliberately fixed, not read from the database: the preview must
  /// show what the chosen combination PRODUCES, and a stable sample keeps the
  /// preview readable and testable. It exercises every field at once so that
  /// turning a field off visibly removes exactly that line.
  static const String _sampleEventTitle = '🦷 Dentist appointment';
  static const String _sampleFollowUpName = 'Bea';
  static const String _sampleLocation = 'Riverside Clinic';
  static const String _sampleNotes =
      'Bring the insurance card and the referral letter from the last visit, '
      'plus the receipt for the fluoride treatment.';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preferences = ref.watch(detailedContentPreferencesProvider);
    final stored = preferences.value;
    // M2 OWNER CORRECTION (Issue 1): the preview follows ONLY the saved
    // Detailed choices.  Privacy Lock is not consulted for content.
    final options = stored ?? DetailedContentPreferences.defaults;

    return _Card(
      children: <Widget>[
        if (stored == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 18),
            child: Center(child: CircularProgressIndicator()),
          )
        else ...<Widget>[
          _DetailedToggle(
            key: const Key('notifications-detailed-title'),
            title: 'Show title',
            subtitle: 'The event or task title, including its emoji',
            value: stored.showTitle,
            onChanged: (value) => ref
                .read(detailedContentControllerProvider)
                .setField(current: stored, showTitle: value),
          ),
          const Divider(height: 1),
          _DetailedToggle(
            key: const Key('notifications-detailed-description'),
            title: 'Show description',
            subtitle:
                'Up to ${ReminderNotificationRenderer.maxDescriptionGraphemes} '
                'characters',
            value: stored.showDescription,
            onChanged: (value) => ref
                .read(detailedContentControllerProvider)
                .setField(current: stored, showDescription: value),
          ),
          const Divider(height: 1),
          _DetailedToggle(
            key: const Key('notifications-detailed-time'),
            title: 'Show time',
            subtitle: 'When the event runs or the task is due',
            value: stored.showTime,
            onChanged: (value) => ref
                .read(detailedContentControllerProvider)
                .setField(current: stored, showTime: value),
          ),
          const Divider(height: 1),
          _DetailedToggle(
            key: const Key('notifications-detailed-contacts'),
            title: 'Show contacts',
            subtitle: 'Who to follow up with',
            value: stored.showContacts,
            onChanged: (value) => ref
                .read(detailedContentControllerProvider)
                .setField(current: stored, showContacts: value),
          ),
          const Divider(height: 1),
          _DetailedToggle(
            key: const Key('notifications-detailed-location'),
            title: 'Show location',
            subtitle: 'The saved place name as text',
            value: stored.showLocation,
            onChanged: (value) => ref
                .read(detailedContentControllerProvider)
                .setField(current: stored, showLocation: value),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Preview',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.5,
                    color: AppTheme.secondaryTextOf(context),
                  ),
                ),
                const SizedBox(height: 8),
                _DetailedPreview(
                  key: const Key('notifications-detailed-preview'),
                  options: options,
                ),
                const SizedBox(height: 10),
                Text(
                  'This is the exact text a notification will show.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppTheme.secondaryTextOf(context),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

final class _DetailedToggle extends StatelessWidget {
  const _DetailedToggle({
    super.key,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => SwitchListTile(
    title: Text(title),
    subtitle: Text(subtitle),
    value: value,
    onChanged: onChanged,
  );
}

/// Renders the live preview through the canonical renderer.
final class _DetailedPreview extends StatelessWidget {
  const _DetailedPreview({
    super.key,
    required this.options,
  });

  final DetailedContentPreferences options;

  @override
  Widget build(BuildContext context) {
    final reminder = buildDetailedPreview(
      isEvent: true,
      options: options,
      sourceTitle: _DetailedContentCard._sampleEventTitle,
      startDisplay: DateTime(2026, 1, 1, 9, 30),
      endDisplay: DateTime(2026, 1, 1, 10, 30),
      notes: _DetailedContentCard._sampleNotes,
      followUpName: _DetailedContentCard._sampleFollowUpName,
      locationText: _DetailedContentCard._sampleLocation,
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppTheme.surfaceVariantOf(context),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              reminder.title,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            Text(
              reminder.body,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}

final class _CustomReminderDialog extends StatefulWidget {
  const _CustomReminderDialog({
    required this.initialMinutes,
    required this.minimumMinutes,
    required this.maximumMinutes,
    required this.unchangedValue,
  });

  final int? initialMinutes;
  final int minimumMinutes;
  final int maximumMinutes;
  final Object unchangedValue;

  @override
  State<_CustomReminderDialog> createState() => _CustomReminderDialogState();
}
final class _CustomReminderDialogState extends State<_CustomReminderDialog> {
  late final TextEditingController _input = TextEditingController(
    text: widget.initialMinutes?.toString() ?? '',
  );
  String? _error;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _save() {
    final value = int.tryParse(_input.text.trim());
    if (value == null ||
        value < widget.minimumMinutes ||
        value > widget.maximumMinutes) {
      setState(() {
        _error =
            'Enter ${widget.minimumMinutes} to ${widget.maximumMinutes} minutes.';
      });
      return;
    }
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Custom reminder time'),
    content: TextField(
      key: const Key('notifications-reminder-custom-input'),
      controller: _input,
      autofocus: true,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(
        labelText: 'Minutes before',
        errorText: _error,
      ),
    ),
    actions: <Widget>[
      TextButton(
        onPressed: () => Navigator.of(context).pop(widget.unchangedValue),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _save, child: const Text('Save')),
    ],
  );
}

final class _TimeRow extends StatelessWidget {
  const _TimeRow({
    super.key,
    required this.label,
    required this.enabled,
    required this.minute,
    required this.onSelected,
  });

  final String label;
  final bool enabled;
  final int? minute;
  final Future<void> Function(int minute) onSelected;

  @override
  Widget build(BuildContext context) {
    final resolved = minute == null
        ? null
        : TimeOfDay(hour: minute! ~/ 60, minute: minute! % 60);
    return ListTile(
      enabled: enabled,
      title: Text(label),
      trailing: _ValueChevron(value: resolved?.format(context) ?? 'Not set'),
      onTap: !enabled
          ? null
          : () async {
              final selected = await showTimePicker(
                context: context,
                initialTime: resolved ?? const TimeOfDay(hour: 22, minute: 0),
              );
              if (selected != null) {
                await onSelected(selected.hour * 60 + selected.minute);
              }
            },
    );
  }
}

final class _ValueChevron extends StatelessWidget {
  const _ValueChevron({required this.value});

  final String value;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      Text(value, style: Theme.of(context).textTheme.bodyMedium),
      const SizedBox(width: 4),
      const Icon(Icons.chevron_right, size: 20),
    ],
  );
}

final class _Card extends StatelessWidget {
  const _Card({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    color: Colors.transparent,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(10),
      side: BorderSide(color: AppTheme.outlineOf(context)),
    ),
    child: Column(children: children),
  );
}

final class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 2, 4, 8),
    child: Text(
      label,
      style: TextStyle(
        fontSize: 12.5,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.5,
        color: AppTheme.secondaryTextOf(context),
      ),
    ),
  );
}

final class _Notice extends StatelessWidget {
  const _Notice({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(10),
    ),
    child: Padding(padding: const EdgeInsets.all(14), child: Text(text)),
  );
}
