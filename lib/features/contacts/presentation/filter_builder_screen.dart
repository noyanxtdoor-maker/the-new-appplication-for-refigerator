import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rmplanner/app/theme/app_theme.dart';
import 'package:rmplanner/features/contacts/application/contact_providers.dart';
import 'package:rmplanner/features/contacts/domain/contact.dart';
import 'package:rmplanner/features/contacts/presentation/c3_contact_primitives.dart';
import 'package:rmplanner/features/contacts/presentation/contact_filter_controls.dart';
import 'package:rmplanner/features/planner/presentation/widgets/anchored_top_bar_popup.dart';

final class FilterBuilderArgs {
  const FilterBuilderArgs({
    this.initialCriteria = const ContactFilterCriteria(),
    this.initialName = '',
    this.initialDescription = '',
    this.initialDisplayedFields = ContactDisplayedFieldCodec.defaults,
    this.initialSortBy = ContactSortBy.name,
    this.saveAsFilter = false,
    this.editingFilterId,
  });

  final ContactFilterCriteria initialCriteria;
  final String initialName;
  final String initialDescription;
  final List<ContactDisplayedField> initialDisplayedFields;
  final ContactSortBy initialSortBy;
  final bool saveAsFilter;
  final String? editingFilterId;
}

final class FilterBuilderResult {
  const FilterBuilderResult({
    required this.criteria,
    required this.sortBy,
    this.savedFilterName,
    this.savedFilter,
  });

  final ContactFilterCriteria criteria;
  final ContactSortBy sortBy;
  final String? savedFilterName;
  final SavedContactFilter? savedFilter;
}

final class FilterBuilderScreen extends ConsumerStatefulWidget {
  const FilterBuilderScreen({super.key, this.args = const FilterBuilderArgs()});

  final FilterBuilderArgs args;

  @override
  ConsumerState<FilterBuilderScreen> createState() =>
      _FilterBuilderScreenState();
}

final class _FilterBuilderScreenState
    extends ConsumerState<FilterBuilderScreen> {
  late final ContactFilterCriteria _initialCriteria = widget
      .args
      .initialCriteria
      .withoutRetiredTags();
  late final Set<ContactDisplayedField> _initialDisplayedFields = widget
      .args
      .initialDisplayedFields
      .toSet();
  late ContactFilterCriteria _criteria = widget.args.initialCriteria
      .withoutRetiredTags();
  late ContactSortBy _sortBy = widget.args.initialSortBy;
  final GlobalKey _sortAnchorKey = GlobalKey();
  late Set<ContactDisplayedField> _displayedFields = widget
      .args
      .initialDisplayedFields
      .toSet();
  late final TextEditingController _nameController = TextEditingController(
    text: widget.args.initialName,
  );
  late final TextEditingController _descriptionController =
      TextEditingController(text: widget.args.initialDescription);
  late final Map<ContactFilterCategory, Set<String>?> _categorySelections;

  bool _saveAsFilter = false;
  bool _saving = false;
  bool _handlingSystemBack = false;
  final Set<String> _expanded = <String>{};

  @override
  void initState() {
    super.initState();
    _saveAsFilter = widget.args.saveAsFilter;
    _categorySelections = <ContactFilterCategory, Set<String>?>{
      for (final category in filterBuilderCategories)
        category: contactFilterCategoryIsActive(_initialCriteria, category)
            ? contactFilterActiveKeys(_initialCriteria, category)
            : null,
    };
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final groups =
        ref.watch(contactGroupsProvider).value ?? const <ContactGroup>[];
    final tags = ref.watch(contactTagsProvider).value ?? const <ContactTag>[];
    final canComplete = !_hasInvalidNone && !_saving;

    return PopScope<void>(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && !_handlingSystemBack) {
          _handlingSystemBack = true;
          unawaited(
            _confirmSystemBack().whenComplete(() {
              _handlingSystemBack = false;
            }),
          );
        }
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            key: const Key('filter-builder-close'),
            tooltip: 'Discard',
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close),
          ),
          title: Text(
            widget.args.editingFilterId == null
                ? 'Filter'
                : 'Edit Contact Filter',
          ),
          actions: <Widget>[
            IconButton(
              key: const Key('filter-builder-check'),
              tooltip: 'Apply',
              onPressed: canComplete ? () => unawaited(_apply()) : null,
              icon: const Icon(Icons.check),
            ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: Column(
            children: <Widget>[
              Expanded(
                child: ListView(
                  key: const Key('filter-builder-scroll'),
                  padding: const EdgeInsets.only(bottom: 24),
                  children: <Widget>[
                    // SwitchListTile is the single semantic control for the
                    // whole setting row: label, whitespace, and switch all
                    // invoke this one callback exactly once.
                    SwitchListTile(
                      key: const Key('save-as-filter-switch'),
                      title: const Text('Save as Contact Filter'),
                      value: _saveAsFilter,
                      contentPadding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                      onChanged: (value) =>
                          setState(() => _saveAsFilter = value),
                    ),
                    if (_saveAsFilter) ...<Widget>[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                        child: TextField(
                          key: const Key('filter-name-field'),
                          controller: _nameController,
                          textInputAction: TextInputAction.next,
                          decoration: const InputDecoration(
                            labelText: 'Filter Name',
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                        child: TextField(
                          key: const Key('filter-description-field'),
                          controller: _descriptionController,
                          maxLines: 1,
                          decoration: const InputDecoration(
                            labelText: 'Filter Description',
                          ),
                        ),
                      ),
                    ],
                    // Neutral hairline after Save as Contact Filter. Owner law
                    // (2026-09-18): the Filter screen uses the same restrained
                    // 1px section divider as the rest of Contacts — the former
                    // thick filled band read as a heavy grey slab.
                    Divider(
                      key: const Key('filter-band-after-save'),
                      height: 1,
                      color: AppTheme.sectionDividerOf(context),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                      child: PmgStyleSortField(
                        key: const Key('filter-sort-by'),
                        value: _sortLabel(_sortBy),
                        anchorKey: _sortAnchorKey,
                        onTap: _chooseSort,
                      ),
                    ),
                    Divider(
                      key: const Key('filter-band-after-sort'),
                      height: 1,
                      color: AppTheme.sectionDividerOf(context),
                    ),
                    _buildDisplayedFieldsSection(),
                    for (final category in filterBuilderCategories)
                      _buildCategorySection(
                        category: category,
                        groups: groups,
                        tags: tags,
                      ),
                    const SizedBox(height: 8),
                    Divider(
                      key: const Key('filter-band-before-toggles'),
                      height: 1,
                      color: AppTheme.sectionDividerOf(context),
                    ),
                    _buildEventToggleSection(),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
              _buildRestoreDefaultsFooter(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDisplayedFieldsSection() {
    final state = _displayedFieldState;
    final expanded = _expanded.contains('displayedFields');
    return _InlineFilterSection(
      sectionKey: const Key('filter-accordion-displayedFields'),
      rowKey: const Key('displayed-fields-row'),
      label: 'Displayed Fields',
      state: state,
      expanded: expanded,
      options: <ContactFilterOption>[
        for (final field in ContactDisplayedField.values)
          ContactFilterOption(field.name, _displayedFieldLabel(field)),
      ],
      selectedKeys: _displayedFields.map((field) => field.name).toSet(),
      validationLabel: 'displayed field',
      allowNone: true,
      onToggle: () => setState(() {
        if (!_expanded.add('displayedFields')) {
          _expanded.remove('displayedFields');
        }
      }),
      onMasterChanged: (_) => _toggleDisplayedFieldsMaster(state),
      onOptionChanged: (key, checked) => _toggleDisplayedField(key, checked),
    );
  }

  Widget _buildCategorySection({
    required ContactFilterCategory category,
    required List<ContactGroup> groups,
    required List<ContactTag> tags,
  }) {
    final options = contactFilterOptions(
      category: category,
      groups: groups,
      tags: tags,
    );
    final selection = _categorySelections[category];
    return _InlineFilterSection(
      sectionKey: Key('filter-accordion-${category.name}'),
      rowKey: Key('filter-category-main-${category.name}'),
      label: contactFilterCategoryLabel(category),
      state: _categoryState(category, options),
      expanded: _expanded.contains(category.name),
      options: options,
      selectedKeys: selection ?? options.map((option) => option.key).toSet(),
      validationLabel: contactFilterValidationLabel(category),
      allowNone: true,
      onToggle: () => setState(() {
        if (!_expanded.add(category.name)) {
          _expanded.remove(category.name);
        }
      }),
      onMasterChanged: (_) => _toggleCategoryMaster(category, options),
      onOptionChanged: (key, checked) =>
          _toggleCategoryOption(category, options, key, checked),
    );
  }

  ContactFilterSelectionState _categoryState(
    ContactFilterCategory category,
    List<ContactFilterOption> options,
  ) {
    if (options.isEmpty) return ContactFilterSelectionState.none;
    final selection = _categorySelections[category];
    if (contactFilterCategoryIsBoolean(category) &&
        (selection == null || selection.isEmpty)) {
      return ContactFilterSelectionState.none;
    }
    if (category == ContactFilterCategory.source &&
        selection?.contains('all') == true) {
      return ContactFilterSelectionState.all;
    }
    if (category == ContactFilterCategory.archived &&
        selection?.contains('active') == true) {
      return ContactFilterSelectionState.all;
    }
    if (selection == null || selection.length == options.length) {
      return ContactFilterSelectionState.all;
    }
    if (selection.isEmpty) return ContactFilterSelectionState.none;
    return ContactFilterSelectionState.some;
  }

  ContactFilterSelectionState get _displayedFieldState {
    if (_displayedFields.isEmpty) return ContactFilterSelectionState.none;
    if (_displayedFields.length == ContactDisplayedField.values.length) {
      return ContactFilterSelectionState.all;
    }
    return ContactFilterSelectionState.some;
  }

  void _toggleCategoryMaster(
    ContactFilterCategory category,
    List<ContactFilterOption> options,
  ) {
    if (options.isEmpty) return;
    final state = _categoryState(category, options);
    if (contactFilterCategoryIsBoolean(category)) {
      _setCategorySelection(
        category,
        state == ContactFilterSelectionState.all
            ? <String>{}
            : options.map((option) => option.key).toSet(),
        options,
      );
      return;
    }
    _setCategorySelection(
      category,
      state == ContactFilterSelectionState.all ? <String>{} : null,
      options,
    );
  }

  void _toggleCategoryOption(
    ContactFilterCategory category,
    List<ContactFilterOption> options,
    String key,
    bool checked,
  ) {
    if (options.isEmpty) return;
    final current = _categorySelections[category];
    final next = current == null
        ? options.map((option) => option.key).toSet()
        : {...current};
    if (checked) {
      if (category == ContactFilterCategory.source ||
          category == ContactFilterCategory.archived) {
        next
          ..clear()
          ..add(key);
      } else {
        next.add(key);
      }
    } else {
      next.remove(key);
    }
    _setCategorySelection(category, next, options);
  }

  void _setCategorySelection(
    ContactFilterCategory category,
    Set<String>? selection,
    List<ContactFilterOption> options,
  ) {
    Set<String>? normalized;
    if (selection != null) {
      normalized = <String>{...selection};
      normalized.retainAll(options.map((option) => option.key));
    }
    setState(() {
      _categorySelections[category] = normalized;
      if (normalized == null || normalized.length == options.length) {
        _categorySelections[category] = null;
        _criteria = clearContactFilterCategory(_criteria, category);
      } else {
        _criteria = contactFilterCriteriaForSelection(
          _criteria,
          category,
          normalized,
        );
      }
    });
  }

  void _toggleDisplayedFieldsMaster(ContactFilterSelectionState state) {
    setState(() {
      _displayedFields = state == ContactFilterSelectionState.all
          ? <ContactDisplayedField>{}
          : ContactDisplayedField.values.toSet();
    });
  }

  void _toggleDisplayedField(String key, bool checked) {
    final field = ContactDisplayedField.values.asNameMap()[key];
    if (field == null) return;
    setState(() {
      if (checked) {
        _displayedFields.add(field);
      } else {
        _displayedFields.remove(field);
      }
    });
  }

  bool get _hasInvalidNone {
    return false;
  }

  bool get _draftDiffersFromDefaults {
    if (_criteria.encode() != const ContactFilterCriteria().encode()) {
      return true;
    }
    if (_sortBy != ContactSortBy.name || _saveAsFilter) return true;
    if (!_setEquals(
      _displayedFields,
      ContactDisplayedFieldCodec.defaults.toSet(),
    )) {
      return true;
    }
    final groups =
        ref.read(contactGroupsProvider).value ?? const <ContactGroup>[];
    final tags = ref.read(contactTagsProvider).value ?? const <ContactTag>[];
    return filterBuilderCategories.any((category) {
      final options = contactFilterOptions(
        category: category,
        groups: groups,
        tags: tags,
      );
      final state = _categoryState(category, options);
      return options.isNotEmpty &&
          state != ContactFilterSelectionState.all &&
          !(contactFilterCategoryIsBoolean(category) &&
              state == ContactFilterSelectionState.none);
    });
  }

  bool get _isDirty {
    return _criteria.encode() != _initialCriteria.encode() ||
        _sortBy != widget.args.initialSortBy ||
        _saveAsFilter != widget.args.saveAsFilter ||
        _nameController.text.trim() != widget.args.initialName.trim() ||
        _descriptionController.text.trim() !=
            widget.args.initialDescription.trim() ||
        !_setEquals(_displayedFields, _initialDisplayedFields) ||
        _hasInvalidNone;
  }

  Future<void> _confirmSystemBack() async {
    if (!_isDirty) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    final discard = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Discard filter changes?'),
        content: const Text('Your changes have not been applied.'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Keep Editing'),
          ),
          FilledButton(
            key: const Key('confirm-discard-filter'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (discard == true && mounted) Navigator.of(context).pop();
  }

  bool _setEquals(Set<Object> left, Set<Object> right) {
    return left.length == right.length && left.containsAll(right);
  }

  Future<void> _chooseSort() async {
    final fieldContext = _sortAnchorKey.currentContext;
    final fieldBox = fieldContext?.findRenderObject() as RenderBox?;
    if (fieldBox == null || !fieldBox.hasSize) {
      return;
    }
    ContactSortBy? selected;
    await showAnchoredTopBarPopup(
      context: context,
      triggerKey: _sortAnchorKey,
      width: fieldBox.size.width,
      maxHeight: 336,
      topGap: 5,
      borderRadius: 5,
      builder: (popupContext) => SingleChildScrollView(
        key: const Key('filter-sort-dropdown-scroll'),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (final value in ContactSortBy.activeOptions)
              SizedBox(
                height: 48,
                child: InkWell(
                  key: Key('filter-sort-option-${value.name}'),
                  onTap: () {
                    selected = value;
                    anchoredTopBarPopupController.dismiss();
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            _sortLabel(value),
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: value == _sortBy
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                            ),
                          ),
                        ),
                        if (value == _sortBy) const Icon(Icons.check, size: 20),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
    if (selected != null && mounted) {
      setState(() => _sortBy = selected!);
    }
  }

  void _restoreDefaults() {
    setState(() {
      _criteria = const ContactFilterCriteria();
      _sortBy = ContactSortBy.name;
      _displayedFields = ContactDisplayedFieldCodec.defaults.toSet();
      _saveAsFilter = false;
      _categorySelections
        ..clear()
        ..addEntries(
          filterBuilderCategories.map(
            (category) =>
                MapEntry<ContactFilterCategory, Set<String>?>(category, null),
          ),
        );
      if (widget.args.editingFilterId == null) {
        _nameController.clear();
        _descriptionController.clear();
      }
    });
  }

  Widget _buildEventToggleSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SwitchListTile(
          key: const Key('filter-toggle-today'),
          title: const Text('With Events Today Only'),
          value: _criteria.withEventsToday,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          onChanged: (value) => setState(() {
            _criteria = _criteria.copyWith(withEventsToday: value);
          }),
        ),
        SwitchListTile(
          key: const Key('filter-toggle-future'),
          title: const Text('With Future Events Only'),
          value: _criteria.withFutureEvents,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          onChanged: (value) => setState(() {
            // Future and Without Future are mutually exclusive by owner law.
            _criteria = _criteria.copyWith(
              withFutureEvents: value,
              withoutFutureEvents: value
                  ? false
                  : _criteria.withoutFutureEvents,
            );
          }),
        ),
        SwitchListTile(
          key: const Key('filter-toggle-without-future'),
          title: const Text('Without Future Events Only'),
          value: _criteria.withoutFutureEvents,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          onChanged: (value) => setState(() {
            // Turning Without Future ON forces Future OFF; turning it OFF is
            // independent of Future (it simply stops requiring absence).
            _criteria = _criteria.copyWith(
              withoutFutureEvents: value,
              withFutureEvents: value ? false : _criteria.withFutureEvents,
            );
          }),
        ),
      ],
    );
  }

  Widget _buildRestoreDefaultsFooter() {
    final visible = _draftDiffersFromDefaults;
    final surface = Theme.of(context).scaffoldBackgroundColor;
    final borderColor = Theme.of(
      context,
    ).colorScheme.outlineVariant.withValues(alpha: .5);
    final primary = Theme.of(context).colorScheme.primary;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      child: visible
          ? Container(
              key: const Key('filter-restore-defaults'),
              decoration: BoxDecoration(
                color: surface,
                border: Border(top: BorderSide(color: borderColor, width: 1)),
              ),
              child: SafeArea(
                top: false,
                child: SizedBox(
                  height: 60,
                  width: double.infinity,
                  // The ENTIRE existing white rectangular box is the tap
                  // target; the rectangular Material clips the pressed
                  // feedback to the same rectangle (no circular center spot).
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: _restoreDefaults,
                      splashColor: primary.withValues(alpha: .10),
                      highlightColor: primary.withValues(alpha: .08),
                      child: Center(
                        child: Text(
                          'Restore Defaults',
                          style: TextStyle(
                            color: primary,
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            )
          : const SizedBox.shrink(key: Key('filter-restore-defaults-hidden')),
    );
  }

  Future<void> _apply() async {
    if (_hasInvalidNone) return;
    if (_saveAsFilter && _nameController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Name this saved filter before applying.'),
        ),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      SavedContactFilter? savedFilter;
      if (_saveAsFilter) {
        final profileId = ref.read(contactProfileIdProvider);
        final draft = SavedContactFilterDraft(
          name: _nameController.text.trim(),
          description: _descriptionController.text.trim(),
          displayedFields: _displayedFields.toList(growable: false),
          criteria: _criteria,
          sortBy: _sortBy,
        );
        final repository = ref.read(contactRepositoryProvider);
        savedFilter = widget.args.editingFilterId == null
            ? await repository.saveSavedFilter(
                profileId: profileId,
                draft: draft,
              )
            : await repository.updateSavedFilter(
                profileId: profileId,
                filterId: widget.args.editingFilterId!,
                draft: draft,
              );
        ref.invalidate(savedContactFiltersProvider);
      }
      if (mounted) {
        Navigator.of(context).pop(
          FilterBuilderResult(
            criteria: _criteria,
            sortBy: _sortBy,
            savedFilterName: savedFilter?.name,
            savedFilter: savedFilter,
          ),
        );
      }
    } on ContactValidationException catch (error) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.message)));
      }
    }
  }

  String _sortLabel(ContactSortBy value) {
    return switch (value) {
      ContactSortBy.name => 'Name (A–Z)',
      ContactSortBy.nameDesc => 'Name (Z–A)',
      ContactSortBy.recentlyAdded => 'Recently added',
      ContactSortBy.oldestAdded => 'Oldest added',
      ContactSortBy.mostRecentlyInteracted => 'Most recently interacted',
      ContactSortBy.leastRecentlyInteracted => 'Least recently interacted',
      _ => 'Legacy sort',
    };
  }

  String _displayedFieldLabel(ContactDisplayedField value) {
    return switch (value) {
      ContactDisplayedField.currentGroup => 'Current Group',
      ContactDisplayedField.tags => 'Tags',
      ContactDisplayedField.nextEvent => 'Next Event Date',
      ContactDisplayedField.lastEvent => 'Last Event Date',
      ContactDisplayedField.lastHappenedEvent => 'Last Happened Event Date',
      ContactDisplayedField.contactMethod => 'Contact Method',
      ContactDisplayedField.address => 'Address',
      ContactDisplayedField.lastInteraction => 'Last Interaction',
      ContactDisplayedField.lastViewed => 'Last Viewed',
      ContactDisplayedField.createdDate => 'Created Date',
    };
  }
}

final class _InlineFilterSection extends StatelessWidget {
  const _InlineFilterSection({
    required this.sectionKey,
    required this.rowKey,
    required this.label,
    required this.state,
    required this.expanded,
    required this.options,
    required this.selectedKeys,
    required this.validationLabel,
    required this.onToggle,
    required this.onMasterChanged,
    required this.onOptionChanged,
    this.allowNone = false,
  });

  final Key sectionKey;
  final Key rowKey;
  final String label;
  final ContactFilterSelectionState state;
  final bool expanded;
  final List<ContactFilterOption> options;
  final Set<String> selectedKeys;
  final String validationLabel;
  final VoidCallback onToggle;
  final ValueChanged<bool?> onMasterChanged;
  final void Function(String key, bool checked) onOptionChanged;
  final bool allowNone;

  @override
  Widget build(BuildContext context) {
    final isNone = state == ContactFilterSelectionState.none;
    final isInvalidNone = isNone && !allowNone;
    final outline = Theme.of(
      context,
    ).colorScheme.outlineVariant.withValues(alpha: .7);
    return Semantics(
      container: true,
      key: sectionKey,
      label: '$label ${_stateLabel(state)}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Material(
            color: Colors.transparent,
            child: InkWell(
              key: rowKey,
              onTap: onToggle,
              child: Container(
                constraints: const BoxConstraints(minHeight: 60),
                padding: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: outline)),
                ),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Flexible(
                            child: Text(
                              label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              // Filter category labels use regular body weight
                              // (R2 owner lock); state emphasis is preserved
                              // in the All / Some / None label instead.
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w400,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Icon(
                            expanded
                                ? Icons.keyboard_arrow_up
                                : Icons.keyboard_arrow_down,
                            size: 22,
                            color: AppTheme.secondaryTextOf(context),
                          ),
                        ],
                      ),
                    ),
                    Text(
                      _stateLabel(state),
                      key: Key('filter-state-${label.toLowerCase()}'),
                      style: TextStyle(
                        color: isInvalidNone
                            ? Theme.of(context).colorScheme.error
                            : Theme.of(context).colorScheme.primary,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Opacity(
                      opacity: options.isEmpty ? 0.38 : 1,
                      child: IgnorePointer(
                        ignoring: options.isEmpty,
                        child: TriStateMasterCheckbox(
                          key: Key('filter-master-${label.toLowerCase()}'),
                          value: switch (state) {
                            ContactFilterSelectionState.all => true,
                            ContactFilterSelectionState.some => null,
                            ContactFilterSelectionState.none => false,
                          },
                          onChanged: onMasterChanged,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (isInvalidNone)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text(
                'Select at least one $validationLabel.',
                key: Key('filter-validation-${label.toLowerCase()}'),
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 14,
                ),
              ),
            ),
          if (expanded && options.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(32, 12, 16, 12),
              child: Text(
                'No ${label.toLowerCase()} available.',
                style: TextStyle(color: AppTheme.secondaryTextOf(context)),
              ),
            ),
          if (expanded && options.isNotEmpty)
            for (final option in options)
              Material(
                color: Colors.transparent,
                child: InkWell(
                  key: Key(
                    'filter-inline-option-${label.toLowerCase()}-${option.key}',
                  ),
                  onTap: () => onOptionChanged(
                    option.key,
                    !selectedKeys.contains(option.key),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.only(left: 32, right: 8),
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            option.label,
                            style: const TextStyle(fontSize: 15),
                          ),
                        ),
                        Checkbox(
                          value: selectedKeys.contains(option.key),
                          onChanged: (checked) =>
                              onOptionChanged(option.key, checked == true),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          if (expanded && options.isNotEmpty)
            Container(height: 1, color: outline),
        ],
      ),
    );
  }

  String _stateLabel(ContactFilterSelectionState value) {
    return switch (value) {
      ContactFilterSelectionState.all => 'All',
      ContactFilterSelectionState.some => 'Some',
      ContactFilterSelectionState.none => 'None',
    };
  }
}
