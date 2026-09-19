import 'package:flutter/material.dart';
import 'package:rmplanner/features/notifications/domain/reminder_policy.dart';
import 'package:rmplanner/features/notifications/domain/reminder_policy_label.dart';

/// The owner's reminder-picker intent (owner pass 2026-09-19, defect N3).
///
/// The picker used to return `int?`, where BOTH "Use default" and a plain
/// dismissal (tap outside, back, or cancelling the Custom dialog) produced
/// `null`.  Every caller therefore read a dismissal as "Use default", so opening
/// the picker, changing your mind and tapping outside silently rewrote a
/// deliberate custom offset back to the inherited default — and on the Event
/// form it also authored an occurrence-level `inherit` row that shadowed a
/// series override.
///
/// These four outcomes are deliberately distinguishable and typed rather than
/// encoded in magic integers, so a caller cannot conflate them by accident.
sealed class ReminderPickerResult {
  const ReminderPickerResult();
}

/// The user closed the picker without choosing.  This is NOT a selection: the
/// caller must leave the reminder policy exactly as it was.
final class ReminderPickerDismissed extends ReminderPickerResult {
  const ReminderPickerDismissed();
}

/// The user explicitly chose "Use default" -> inherit the current global
/// default.
final class ReminderPickerUseDefault extends ReminderPickerResult {
  const ReminderPickerUseDefault();
}

/// The user explicitly chose "Off" -> no reminder for this record.
final class ReminderPickerOff extends ReminderPickerResult {
  const ReminderPickerOff();
}

/// The user chose an explicit offset before the source time.
final class ReminderPickerOffset extends ReminderPickerResult {
  const ReminderPickerOffset(this.minutes);

  final int minutes;

  @override
  bool operator ==(Object other) =>
      other is ReminderPickerOffset && other.minutes == minutes;

  @override
  int get hashCode => minutes.hashCode;

  @override
  String toString() => 'ReminderPickerOffset($minutes)';
}

/// The reminder policy a picker result selects.
///
/// [offsetMinutes] is non-null only for [ReminderPolicyMode.offset], mirroring
/// the storage law that an inherit/off row carries no offset.
final class ReminderSelectionIntent {
  const ReminderSelectionIntent(this.mode, [this.offsetMinutes]);

  final ReminderPolicyMode mode;
  final int? offsetMinutes;

  @override
  bool operator ==(Object other) =>
      other is ReminderSelectionIntent &&
      other.mode == mode &&
      other.offsetMinutes == offsetMinutes;

  @override
  int get hashCode => Object.hash(mode, offsetMinutes);

  @override
  String toString() => 'ReminderSelectionIntent($mode, $offsetMinutes)';
}

/// Translates a picker result into what the FORM should do.
///
/// Returns null for a DISMISSAL, which means "leave the current selection
/// exactly as it was".  This is the single call-site law shared by the Event and
/// Task forms, so neither can drift back into reading a dismissal as
/// [ReminderPickerUseDefault].  It is a pure function precisely so the four
/// outcomes can be proven without a full form harness.
ReminderSelectionIntent? reminderSelectionIntent(ReminderPickerResult result) =>
    switch (result) {
      ReminderPickerDismissed() => null,
      ReminderPickerUseDefault() => const ReminderSelectionIntent(
        ReminderPolicyMode.inherit,
      ),
      ReminderPickerOff() => const ReminderSelectionIntent(
        ReminderPolicyMode.off,
      ),
      ReminderPickerOffset(:final minutes) => ReminderSelectionIntent(
        ReminderPolicyMode.offset,
        minutes,
      ),
    };

/// Internal sentinel: the sheet closed asking for the Custom dialog.
///
/// Deliberately NOT a [ReminderPickerResult] subtype: the caller-facing sealed
/// hierarchy must contain only the four real outcomes, so a caller's switch can
/// be exhaustive without knowing this transport detail exists.
final class _CustomRequested {
  const _CustomRequested();
}

const _customRequested = _CustomRequested();

/// Shows the reminder picker and reports exactly what the user intended.
///
/// A dismissal is never reported as [ReminderPickerUseDefault].
Future<ReminderPickerResult> showReminderTimePicker(
  BuildContext context,
) async {
  final selected = await showModalBottomSheet<Object?>(
    context: context,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: <Widget>[
          const ListTile(title: Text('Reminder time')),
          const Divider(height: 1),
          ListTile(
            title: const Text('Use default'),
            onTap: () =>
                Navigator.pop(context, const ReminderPickerUseDefault()),
          ),
          ListTile(
            title: const Text('Off'),
            onTap: () => Navigator.pop(context, const ReminderPickerOff()),
          ),
          for (final value in <int>[0, 5, 10, 15, 30, 45, 60])
            ListTile(
              title: Text(ReminderPolicyLabel.offsetMinutes(value)),
              onTap: () => Navigator.pop(context, ReminderPickerOffset(value)),
            ),
          ListTile(
            title: const Text('Custom...'),
            onTap: () => Navigator.pop(context, _customRequested),
          ),
        ],
      ),
    ),
  );
  // A dismissed sheet (barrier tap / back) resolves to null: no choice was
  // made, so report the dismissal instead of inventing a selection.
  if (selected is! _CustomRequested) {
    return selected is ReminderPickerResult
        ? selected
        : const ReminderPickerDismissed();
  }
  if (!context.mounted) return const ReminderPickerDismissed();
  final custom = await showDialog<int?>(
    context: context,
    builder: (_) => const _CustomReminderDialog(),
  );
  // Cancelling the Custom dialog is also "no change", never "Use default".
  if (custom == null) return const ReminderPickerDismissed();
  return ReminderPickerOffset(custom);
}

final class _CustomReminderDialog extends StatefulWidget {
  const _CustomReminderDialog();
  @override
  State<_CustomReminderDialog> createState() => _CustomReminderDialogState();
}

final class _CustomReminderDialogState extends State<_CustomReminderDialog> {
  final TextEditingController _controller = TextEditingController();
  String? _error;
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final value = int.tryParse(_controller.text.trim());
    if (value == null || value < 0 || value > 10080) {
      setState(() => _error = 'Enter 0 to 10080 minutes.');
      return;
    }
    Navigator.pop(context, value);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Custom reminder time'),
    content: TextField(
      controller: _controller,
      autofocus: true,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(
        labelText: 'Minutes before',
        errorText: _error,
      ),
    ),
    actions: <Widget>[
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _save, child: const Text('Save')),
    ],
  );
}
