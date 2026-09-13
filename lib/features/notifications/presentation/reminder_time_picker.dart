import 'package:flutter/material.dart';
import 'package:rmplanner/features/notifications/domain/reminder_policy_label.dart';

Future<int?> showReminderTimePicker(BuildContext context) async {
  const custom = -2;
  final selected = await showModalBottomSheet<int?>(
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
            onTap: () => Navigator.pop(context),
          ),
          ListTile(
            title: const Text('Off'),
            onTap: () => Navigator.pop(context, -1),
          ),
          for (final value in <int>[0, 5, 10, 15, 30, 45, 60])
            ListTile(
              title: Text(ReminderPolicyLabel.offsetMinutes(value)),
              onTap: () => Navigator.pop(context, value),
            ),
          ListTile(
            title: const Text('Custom...'),
            onTap: () => Navigator.pop(context, custom),
          ),
        ],
      ),
    ),
  );
  if (selected != custom || !context.mounted) return selected;
  return showDialog<int?>(
    context: context,
    builder: (_) => const _CustomReminderDialog(),
  );
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
