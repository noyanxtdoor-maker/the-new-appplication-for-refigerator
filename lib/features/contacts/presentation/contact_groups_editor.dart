import 'package:flutter/material.dart';
import 'package:rmplanner/features/contacts/domain/contact.dart';
import 'package:rmplanner/features/contacts/presentation/unsaved_changes_guard.dart';

/// The deliberate A3 selection is only the Contact's one visible primary
/// group. Existing non-primary membership rows are historical data and are
/// intentionally not represented as active selections here.
final class ContactGroupsEditResult {
  const ContactGroupsEditResult({required this.primaryGroupId});

  final String? primaryGroupId;
}

final class ContactGroupsEditor extends StatefulWidget {
  const ContactGroupsEditor({
    required this.groups,
    required this.initialPrimaryGroupId,
    super.key,
  });

  final List<ContactGroup> groups;
  final String? initialPrimaryGroupId;

  @override
  State<ContactGroupsEditor> createState() => _ContactGroupsEditorState();
}

final class _ContactGroupsEditorState extends State<ContactGroupsEditor> {
  late String? _primaryGroupId;

  @override
  void initState() {
    super.initState();
    _primaryGroupId =
        widget.groups.any((group) => group.id == widget.initialPrimaryGroupId)
        ? widget.initialPrimaryGroupId
        : null;
  }

  bool get _isDirty => _primaryGroupId != widget.initialPrimaryGroupId;

  void _saveAndLeave() => Navigator.of(
    context,
  ).pop(ContactGroupsEditResult(primaryGroupId: _primaryGroupId));

  Future<void> _requestClose() async {
    if (!_isDirty) {
      Navigator.of(context).pop();
      return;
    }
    final decision = await showUnsavedChangesGuard(context);
    if (!mounted) {
      return;
    }
    switch (decision) {
      case UnsavedChangesDecision.saveAndLeave:
        _saveAndLeave();
        return;
      case UnsavedChangesDecision.discardAndLeave:
        Navigator.of(context).pop();
        return;
      case UnsavedChangesDecision.keepEditing:
      case null:
        return;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Groups'),
        leading: IconButton(
          key: const Key('groups-editor-cancel'),
          tooltip: 'Cancel',
          onPressed: _requestClose,
          icon: const Icon(Icons.close),
        ),
        actions: <Widget>[
          TextButton(
            key: const Key('groups-editor-save'),
            onPressed: _saveAndLeave,
            child: const Text('Save'),
          ),
        ],
      ),
      body: SafeArea(
        child: RadioGroup<String?>(
          groupValue: _primaryGroupId,
          onChanged: (value) => setState(() => _primaryGroupId = value),
          child: ListView(
            children: <Widget>[
              // The ungrouped state is a first-class choice here, not a
              // missing one, and it carries the single canonical ungrouped
              // colour so it reads like any other row.
              RadioListTile<String?>(
                key: const Key('groups-editor-none'),
                value: null,
                secondary: Container(
                  width: 15,
                  height: 15,
                  decoration: const BoxDecoration(
                    color: Color(ContactUngroupedColor.argb),
                    shape: BoxShape.circle,
                  ),
                ),
                title: const Text(ContactUngroupedColor.displayName),
              ),
              for (final group in widget.groups)
                RadioListTile<String?>(
                  key: Key('groups-editor-${group.id}'),
                  value: group.id,
                  secondary: Container(
                    width: 15,
                    height: 15,
                    decoration: BoxDecoration(
                      color: Color(group.colorValue),
                      shape: BoxShape.circle,
                    ),
                  ),
                  title: Text(group.name),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
