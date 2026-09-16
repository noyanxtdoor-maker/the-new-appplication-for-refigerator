import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:rmplanner/app/router/route_names.dart';
import 'package:rmplanner/app/theme/app_theme.dart';
import 'package:rmplanner/app/theme/internal_screen.dart';
import 'package:rmplanner/core/colors/vs11_color_system.dart';
import 'package:rmplanner/features/contacts/application/contact_providers.dart';
import 'package:rmplanner/features/contacts/domain/contact.dart';
import 'package:rmplanner/features/contacts/presentation/contact_multi_select_screen.dart';
import 'package:rmplanner/features/planner/application/planner_providers.dart';
import 'package:rmplanner/features/planner/domain/event_color_math.dart';
import 'package:rmplanner/features/planner/presentation/widgets/event_color_picker_components.dart';

const List<String> _suggestedGroupNames = <String>[
  'Family',
  'Friends',
  'Work',
  'School',
  'Clients',
  'Team',
  'Other',
];

/// Group manager for user-owned Groups. Every saved Group can be renamed,
/// recolored, or permanently deleted. Suggested names are optional shortcuts,
/// never protected records or an automatically recreated catalog.
final class ContactGroupsScreen extends ConsumerStatefulWidget {
  const ContactGroupsScreen({super.key});

  @override
  ConsumerState<ContactGroupsScreen> createState() =>
      _ContactGroupsScreenState();
}

final class _ContactGroupsScreenState
    extends ConsumerState<ContactGroupsScreen> {
  @override
  Widget build(BuildContext context) {
    final groupsAsync = ref.watch(contactGroupsProvider);
    return Scaffold(
      appBar: InternalAppBar(title: const Text('Manage Groups')),
      body: groupsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) =>
            const Center(child: Text('Groups could not be opened.')),
        data: (groups) {
          final memberCountsAsync = ref.watch(contactGroupMemberCountsProvider);
          final memberCounts = memberCountsAsync.maybeWhen(
            data: (counts) => counts,
            orElse: () => const <String, int>{},
          );
          final active = groups.where((g) => !g.isArchived).toList();
          final archived = groups.where((g) => g.isArchived).toList();
          final existingNames = groups
              .map((group) => group.name.trim().toLowerCase())
              .toSet();
          final suggestions = _suggestedGroupNames
              .where((name) => !existingNames.contains(name.toLowerCase()))
              .toList(growable: false);
          return ListView(
            key: const Key('contact-groups-list'),
            padding: InternalScreen.pagePadding,
            children: <Widget>[
              for (final group in active)
                _GroupRow(
                  group: group,
                  memberCount: memberCounts[group.id] ?? 0,
                  onOpen: () => unawaited(
                    context.push(RoutePaths.contactGroupDetail(group.id)),
                  ),
                  onEdit: () => _editGroup(group),
                  onDelete: () => _confirmHardDelete(group),
                ),
              if (active.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 32),
                  child: Text(
                    'No groups yet. Create one or choose a suggestion to give '
                    'your contacts a shared color.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppTheme.secondaryTextOf(context)),
                  ),
                ),
              if (suggestions.isNotEmpty) ...<Widget>[
                const SizedBox(height: 8),
                const Text(
                  'Suggested groups',
                  style: InternalScreen.sectionHeading,
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    for (final suggestion in suggestions)
                      ActionChip(
                        key: Key('suggested-group-${suggestion.toLowerCase()}'),
                        label: Text(suggestion),
                        onPressed: () => _createSuggestedGroup(suggestion),
                      ),
                  ],
                ),
              ],
              if (archived.isNotEmpty) ...<Widget>[
                const SizedBox(height: 24),
                const Text(
                  'Previously archived',
                  style: InternalScreen.sectionHeading,
                ),
                const SizedBox(height: 4),
                for (final group in archived)
                  _GroupRow(
                    group: group,
                    memberCount: memberCounts[group.id] ?? 0,
                    onOpen: () => unawaited(
                      context.push(RoutePaths.contactGroupDetail(group.id)),
                    ),
                    onEdit: () => _editGroup(group),
                    onDelete: () => _confirmHardDelete(group),
                    isLegacyArchived: true,
                  ),
              ],
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('create-group-fab'),
        heroTag: 'contact-groups-fab',
        onPressed: () => _editGroup(null),
        // POST-M7 CLOSURE: inherit the canonical FAB surface role instead of
        // bypassing it with the ColorScheme primary (a floating control is one
        // identity in Light and Dark).
        icon: const Icon(Icons.add),
        label: const Text('New Group'),
      ),
    );
  }

  Future<void> _editGroup(ContactGroup? group) async {
    final repository = ref.read(contactRepositoryProvider);
    final profileId = ref.read(contactProfileIdProvider);
    final activeGroups = await repository.readGroups(profileId);
    if (!mounted) {
      return;
    }
    final result = await showModalBottomSheet<_GroupEditorResult>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) => _GroupEditor(
        group: group,
        peerColors: activeGroups
            .where((candidate) => candidate.id != group?.id)
            .map((candidate) => candidate.colorValue)
            .toList(growable: false),
      ),
    );
    if (result == null || !mounted) {
      return;
    }
    final save = result as _GroupEditorSave;
    try {
      if (group == null) {
        await repository.createGroup(
          profileId: profileId,
          name: save.name,
          colorValue: save.color,
        );
      } else {
        await repository.updateGroup(
          profileId: profileId,
          groupId: group.id,
          name: save.name,
          colorValue: save.color,
        );
      }
    } on ContactValidationException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.message)));
      }
    }
  }

  Future<void> _createSuggestedGroup(String name) async {
    final repository = ref.read(contactRepositoryProvider);
    final profileId = ref.read(contactProfileIdProvider);
    final active = await repository.readGroups(profileId);
    final color = Vs11ColorSystem.nextUnused(
      active
          .where((group) => !group.isArchived)
          .map((group) => group.colorValue),
    );
    if (color == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'All recommended Group colors are in use. Choose a Custom Color for a new Group.',
            ),
          ),
        );
      }
      return;
    }
    try {
      await repository.createGroup(
        profileId: profileId,
        name: name,
        colorValue: color,
      );
    } on ContactValidationException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.message)));
      }
    }
  }

  Future<void> _confirmHardDelete(ContactGroup group) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: Key('group-delete-dialog-${group.id}'),
        title: const Text('Delete group permanently?'),
        content: Text(
          '“${group.name}” will be removed from every Contact that uses it. '
          'Contacts stay in place, but this cannot be undone.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: Key('group-delete-confirm-${group.id}'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    final repository = ref.read(contactRepositoryProvider);
    final profileId = ref.read(contactProfileIdProvider);
    try {
      await repository.hardDeleteGroup(profileId: profileId, groupId: group.id);
    } on ContactValidationException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.message)));
      }
    }
  }
}

sealed class _GroupEditorResult {
  const _GroupEditorResult();
}

final class _GroupEditorSave extends _GroupEditorResult {
  const _GroupEditorSave(this.name, this.color);

  final String name;
  final int color;
}

final class _GroupRow extends StatelessWidget {
  const _GroupRow({
    required this.group,
    required this.memberCount,
    required this.onOpen,
    required this.onEdit,
    required this.onDelete,
    this.isLegacyArchived = false,
  });

  final ContactGroup group;
  final int memberCount;
  final VoidCallback onOpen;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final bool isLegacyArchived;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: Key('group-row-${group.id}'),
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: <Widget>[
              Container(
                width: 21,
                height: 21,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Color(group.colorValue),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      group.name,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    Text(
                      isLegacyArchived
                          ? 'Previously archived'
                          : '$memberCount contact${memberCount == 1 ? '' : 's'}',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppTheme.secondaryTextOf(context),
                      ),
                    ),
                    if (isLegacyArchived)
                      Text(
                        '$memberCount contact${memberCount == 1 ? '' : 's'}',
                        style: TextStyle(
                          fontSize: 12,
                          color: AppTheme.secondaryTextOf(context),
                        ),
                      ),
                  ],
                ),
              ),
              Tooltip(
                message: 'Edit ${group.name}',
                child: IconButton(
                  key: Key('group-edit-${group.id}'),
                  onPressed: onEdit,
                  icon: const Icon(Icons.edit_outlined),
                ),
              ),
              Tooltip(
                message: 'Delete ${group.name} permanently',
                child: IconButton(
                  key: Key('group-delete-${group.id}'),
                  onPressed: onDelete,
                  color: Theme.of(context).colorScheme.error,
                  icon: const Icon(Icons.delete_outline),
                ),
              ),
              ExcludeSemantics(
                child: Icon(
                  Icons.chevron_right,
                  key: Key('group-open-${group.id}'),
                  color: AppTheme.secondaryTextOf(context),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A compact, primary-membership management surface.  It deliberately uses
/// the existing Group write laws: adding makes this Group active for the
/// selected Contact while preserving other memberships as dormant; removing
/// touches only this exact membership.
final class ContactGroupDetailScreen extends ConsumerWidget {
  const ContactGroupDetailScreen({required this.groupId, super.key});

  final String groupId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groups = ref.watch(contactGroupsProvider);
    final group = groups.maybeWhen(
      data: (all) =>
          all.where((candidate) => candidate.id == groupId).firstOrNull,
      orElse: () => null,
    );
    if (group == null) {
      return Scaffold(
        appBar: const InternalAppBar(title: Text('Group')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final membersAsync = ref.watch(contactGroupMembersProvider(group.id));
    return Scaffold(
      appBar: InternalAppBar(title: const Text('Group')),
      body: membersAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) =>
            const Center(child: Text('Group members could not be opened.')),
        data: (members) => ListView(
          key: Key('group-detail-${group.id}'),
          padding: InternalScreen.pagePadding,
          children: <Widget>[
            Row(
              children: <Widget>[
                Container(
                  width: 19,
                  height: 19,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Color(group.colorValue),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    group.name,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Text(
              'Members (${members.length})',
              style: InternalScreen.sectionHeading,
            ),
            const SizedBox(height: 8),
            if (members.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text(
                  'No contacts are active in this group yet.',
                  style: TextStyle(color: AppTheme.secondaryTextOf(context)),
                ),
              )
            else
              for (final member in members)
                ListTile(
                  key: Key('group-member-${member.contact.id}'),
                  contentPadding: EdgeInsets.zero,
                  title: Text(member.contact.displayName),
                  subtitle: member.subtitle.isEmpty
                      ? null
                      : Text(member.subtitle),
                  trailing: TextButton(
                    key: Key('group-remove-member-${member.contact.id}'),
                    onPressed: () => _removeMember(context, ref, group, member),
                    child: const Text('Remove'),
                  ),
                ),
            const SizedBox(height: 12),
            FilledButton.icon(
              key: Key('group-add-members-${group.id}'),
              onPressed: () => _addMembers(context, ref, group, members),
              icon: const Icon(Icons.person_add_alt_1_outlined),
              label: const Text('Add Contacts to Group'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _addMembers(
    BuildContext context,
    WidgetRef ref,
    ContactGroup group,
    List<ContactSummary> members,
  ) async {
    final ids = await context.push<List<String>>(
      RoutePaths.multiSelect,
      extra: MultiSelectArgs(
        title: 'Add Contacts to Group',
        initialIds: members
            .map((member) => member.contact.id)
            .toList(growable: false),
        allowSmsHandoff: false,
        groupTargetId: group.id,
        groupTargetName: group.name,
      ),
    );
    if (ids == null || !context.mounted) return;
    final repository = ref.read(contactRepositoryProvider);
    final profileId = ref.read(contactProfileIdProvider);
    final summaries = await repository.readContacts(
      profileId: profileId,
      criteria: const ContactFilterCriteria(),
      sortBy: ContactSortBy.name,
      today: ref.read(plannerDateSourceProvider).today(),
    );
    if (!context.mounted) return;
    final byId = <String, ContactSummary>{
      for (final summary in summaries) summary.contact.id: summary,
    };
    final selected = ids
        .toSet()
        .map((id) => byId[id])
        .whereType<ContactSummary>()
        .toList(growable: false);
    final changes = selected
        .where((summary) => summary.primaryGroup?.id != group.id)
        .toList(growable: false);
    final reassigned = changes
        .where((summary) => summary.primaryGroup != null)
        .toList(growable: false);
    if (reassigned.isNotEmpty) {
      final confirmed = await _confirmGroupReassignment(
        context,
        target: group,
        reassigned: reassigned,
        ungroupedCount: changes.length - reassigned.length,
      );
      if (confirmed != true || !context.mounted) return;
    }
    for (final summary in changes) {
      await repository.setContactGroups(
        profileId: profileId,
        contactId: summary.contact.id,
        groupIds: <String>[group.id],
        primaryGroupId: group.id,
      );
    }
  }

  Future<bool?> _confirmGroupReassignment(
    BuildContext context, {
    required ContactGroup target,
    required List<ContactSummary> reassigned,
    required int ungroupedCount,
  }) {
    final movingCount = reassigned.length + ungroupedCount;
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          movingCount == reassigned.length
              ? 'Move contacts to ${target.name}?'
              : 'Add $movingCount contacts to ${target.name}?',
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 360),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '${reassigned.length} contact${reassigned.length == 1 ? '' : 's'} '
                  'will move from another group:',
                ),
                const SizedBox(height: 12),
                for (final summary in reassigned)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      '${summary.contact.displayName} — ${summary.primaryGroup!.name}',
                    ),
                  ),
                if (ungroupedCount > 0) ...<Widget>[
                  const SizedBox(height: 4),
                  Text(
                    '$ungroupedCount contact${ungroupedCount == 1 ? '' : 's'} currently '
                    'have no group.',
                  ),
                ],
                const SizedBox(height: 12),
                Text('Their primary group will change to ${target.name}.'),
              ],
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            key: const Key('group-reassignment-cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('group-reassignment-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Move Contacts'),
          ),
        ],
      ),
    );
  }

  Future<void> _removeMember(
    BuildContext context,
    WidgetRef ref,
    ContactGroup group,
    ContactSummary member,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remove contact from group?'),
        content: Text(
          '${member.contact.displayName} will no longer be in ${group.name}.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: Key('group-confirm-remove-${member.contact.id}'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    await ref
        .read(contactRepositoryProvider)
        .removeContactFromGroup(
          profileId: ref.read(contactProfileIdProvider),
          contactId: member.contact.id,
          groupId: group.id,
        );
  }
}

final class _GroupEditor extends StatefulWidget {
  const _GroupEditor({this.group, required this.peerColors});

  final ContactGroup? group;
  final List<int> peerColors;

  @override
  State<_GroupEditor> createState() => _GroupEditorState();
}

final class _GroupEditorState extends State<_GroupEditor> {
  late final TextEditingController _nameController = TextEditingController(
    text: widget.group?.name ?? '',
  );
  late int _color =
      widget.group?.colorValue ??
      Vs11ColorSystem.nextUnused(widget.peerColors) ??
      ContactGroupColorPalette.recommended.first.argb;

  bool get _hasCustomCurrentColor => !Vs11ColorSystem.isCanonical(_color);

  bool _isUnavailable(int color) => widget.peerColors.any(
    (peer) => Vs11ColorSystem.sameOpaqueRgb(peer, color),
  );

  bool _isSelectable(int color) =>
      Vs11ColorSystem.sameOpaqueRgb(color, _color) || !_isUnavailable(color);

  Iterable<ContactGroupRecommendedColor> get _visibleRecommendedColors sync* {
    if (_hasCustomCurrentColor) {
      yield ContactGroupRecommendedColor(
        name: 'Current custom color',
        argb: _color,
      );
    }
    for (final color in ContactGroupColorPalette.recommended) {
      if (_isSelectable(color.argb)) {
        yield color;
      }
    }
  }

  Color _checkColor(int swatchArgb) {
    const dark = 0xFF1A1C1F;
    const light = 0xFFFFFFFF;
    return Color(
      EventColorMath.contrastRatio(dark, swatchArgb) >=
              EventColorMath.contrastRatio(light, swatchArgb)
          ? dark
          : light,
    );
  }

  Future<void> _chooseCustomColor(BuildContext context) async {
    final chosen = await showCustomHexColorDialog(
      context,
      initialColor: Color(Vs11ColorSystem.opaqueRgb(_color)),
    );
    if (chosen == null || !mounted) {
      return;
    }
    final next = chosen.toARGB32();
    final nearPeer = widget.peerColors.any(
      (peer) =>
          !Vs11ColorSystem.sameOpaqueRgb(peer, next) &&
          EventColorMath.isNearDuplicate(
            Vs11ColorSystem.opaqueRgb(peer),
            Vs11ColorSystem.opaqueRgb(next),
          ),
    );
    setState(() => _color = next);
    if (nearPeer) {
      ScaffoldMessenger.of(this.context).showSnackBar(
        const SnackBar(
          content: Text(
            'This custom color is close to another active Group color. It can still be used.',
          ),
        ),
      );
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: GestureDetector(
        key: const Key('group-editor-blank-space-dismiss'),
        behavior: HitTestBehavior.translucent,
        onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                widget.group == null ? 'New Group' : 'Edit Group',
                style: const TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                key: const Key('group-name-field'),
                controller: _nameController,
                autofocus: widget.group == null,
                decoration: InputDecoration(
                  labelText: 'Name',
                  filled: true,
                  fillColor: AppTheme.surfaceOf(context),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text('Color', style: InternalScreen.fieldLabel),
              const SizedBox(height: 8),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: <Widget>[
                  for (final color in _visibleRecommendedColors)
                    Semantics(
                      button: true,
                      selected: Vs11ColorSystem.sameOpaqueRgb(
                        color.argb,
                        _color,
                      ),
                      label:
                          '${color.name} #${(color.argb & 0x00FFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}',
                      child: SizedBox(
                        width: 48,
                        height: 48,
                        child: InkWell(
                          key: Key(
                            'group-color-${color.argb.toRadixString(16)}',
                          ),
                          customBorder: const CircleBorder(),
                          onTap: () => setState(() => _color = color.argb),
                          child: Center(
                            child: Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: Color(color.argb),
                                border: Border.all(
                                  color:
                                      Vs11ColorSystem.sameOpaqueRgb(
                                        color.argb,
                                        _color,
                                      )
                                      ? Theme.of(context).colorScheme.onSurface
                                      : Theme.of(context).colorScheme.outline,
                                  width:
                                      Vs11ColorSystem.sameOpaqueRgb(
                                        color.argb,
                                        _color,
                                      )
                                      ? 3
                                      : 1,
                                ),
                              ),
                              child:
                                  Vs11ColorSystem.sameOpaqueRgb(
                                    color.argb,
                                    _color,
                                  )
                                  ? Icon(
                                      Icons.check,
                                      size: 20,
                                      color: _checkColor(color.argb),
                                    )
                                  : null,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 48,
                child: TextButton.icon(
                  key: const Key('group-custom-color'),
                  onPressed: () => _chooseCustomColor(context),
                  icon: const Icon(Icons.palette_outlined, size: 18),
                  label: const Text('Custom Color'),
                ),
              ),
              const SizedBox(height: 20),
              FilledButton(
                key: const Key('group-save'),
                onPressed: () {
                  final name = _nameController.text.trim();
                  if (name.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Group name cannot be blank.'),
                      ),
                    );
                    return;
                  }
                  Navigator.of(context).pop(_GroupEditorSave(name, _color));
                },
                child: const Text('Save'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
