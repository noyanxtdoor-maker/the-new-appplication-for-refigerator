import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:rmplanner/app/router/route_names.dart';
import 'package:rmplanner/app/theme/app_theme.dart';
import 'package:rmplanner/app/theme/contact_reference_style.dart';
import 'package:rmplanner/app/theme/internal_screen.dart';
import 'package:rmplanner/features/contacts/application/contact_providers.dart';
import 'package:rmplanner/features/contacts/domain/contact.dart';
import 'package:rmplanner/features/contacts/presentation/contact_method_entry_row.dart';
import 'package:rmplanner/features/contacts/presentation/contact_method_visuals.dart';
import 'package:rmplanner/features/contacts/presentation/unsaved_changes_guard.dart';
import 'package:rmplanner/features/maps/application/map_coordinate_repository.dart';
import 'package:rmplanner/features/maps/application/map_providers.dart';
import 'package:rmplanner/features/maps/domain/map_coordinate.dart';
import 'package:rmplanner/features/maps/presentation/map_location_picker_screen.dart';
import 'package:rmplanner/features/maps/presentation/map_pin_section.dart';
import 'package:rmplanner/features/planner/application/planner_providers.dart';

enum ContactFormMode { create, edit }

const Map<ContactMethodType, List<String>> _contactMethodLabels =
    <ContactMethodType, List<String>>{
      ContactMethodType.phone: <String>['Mobile', 'Home', 'Work', 'Other'],
      ContactMethodType.email: <String>['Personal', 'Work', 'Family', 'Other'],
      ContactMethodType.social: activeSocialProfileLabels,
    };

/// Progressive C4 Add/Edit Contact form. Name, one current Group, and
/// method/address/map entry points are visible first; Favorite, preferred
/// method, Tags, Availability, and additive Notes stay under Expand Options.
final class ContactFormScreen extends ConsumerStatefulWidget {
  const ContactFormScreen.create({super.key, this.initialCoordinate})
    : mode = ContactFormMode.create,
      contactId = null;

  const ContactFormScreen.edit({required this.contactId, super.key})
    : mode = ContactFormMode.edit,
      initialCoordinate = null;

  final ContactFormMode mode;
  final String? contactId;

  /// Maps-origin Add Contact seam: a chosen map coordinate pre-populated into
  /// the Map draft field. Never fabricates an address and never adds a second
  /// Contact form.
  final MapCoordinate? initialCoordinate;

  @override
  ConsumerState<ContactFormScreen> createState() => _ContactFormScreenState();
}

final class _MethodRow {
  _MethodRow({
    required this.type,
    required this.controller,
    this.id,
    this.label,
    this.isPrimary = false,
    this.receivesTexts,
    this.hasWhatsApp,
    this.defaultedMobileText = false,
  });

  final String? id;
  final ContactMethodType type;
  final TextEditingController controller;
  String? label;
  final bool isPrimary;
  bool? receivesTexts;
  bool? hasWhatsApp;
  bool defaultedMobileText;

  void setLabel(String value) {
    label = value;
    if (type == ContactMethodType.phone &&
        defaultedMobileText &&
        value != 'Mobile') {
      receivesTexts = null;
      defaultedMobileText = false;
    }
  }
}

final class _ContactFormScreenState extends ConsumerState<ContactFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _firstNameController = TextEditingController();
  final _lastNameController = TextEditingController();
  final _addressController = TextEditingController();
  final _noteController = TextEditingController();
  final List<_MethodRow> _methodRows = <_MethodRow>[];
  final List<ContactAvailability> _availability = <ContactAvailability>[];
  MapCoordinate? _mapCoordinate;
  MapCoordinate? _initialMapCoordinate;
  List<String> _groupIds = <String>[];
  String? _primaryGroupId;
  ContactPreferredMethod _preferredMethod = ContactPreferredMethod.message;
  ContactSource _source = ContactSource.manual;
  String? _initialDisplayName;
  List<String> _tagNames = <String>[];
  bool _isFavorite = false;
  bool _optionsExpanded = false;
  bool _mapExpanded = false;
  bool _loading = false;
  bool _saving = false;
  bool _hasUnsavedChanges = false;

  @override
  void initState() {
    super.initState();
    for (final controller in <TextEditingController>[
      _firstNameController,
      _lastNameController,
      _addressController,
      _noteController,
    ]) {
      controller.addListener(_markDirty);
    }
    if (widget.mode == ContactFormMode.edit) {
      _loading = true;
      unawaited(Future<void>.microtask(_loadExisting));
    } else if (widget.initialCoordinate case final coordinate?) {
      _mapCoordinate = coordinate;
      _mapExpanded = true;
    }
  }

  void _markDirty() {
    if (!_loading && !_hasUnsavedChanges && mounted) {
      setState(() => _hasUnsavedChanges = true);
    }
  }

  void _trackMethodRow(_MethodRow row) {
    row.controller.addListener(_markDirty);
  }

  @override
  void dispose() {
    _firstNameController.dispose();
    _lastNameController.dispose();
    _addressController.dispose();
    _noteController.dispose();
    for (final row in _methodRows) {
      row.controller.dispose();
    }
    super.dispose();
  }

  Future<void> _loadExisting() async {
    try {
      final detail = await ref.read(
        contactDetailProvider(widget.contactId!).future,
      );
      if (!mounted) {
        return;
      }
      MapCoordinate? loadedCoordinate;
      try {
        final profileId = ref.read(contactProfileIdProvider);
        loadedCoordinate = await ref
            .read(mapCoordinateRepositoryProvider)
            .readCoordinate(
              profileId: profileId,
              owner: MapCoordinateOwner.contact,
              recordId: widget.contactId!,
            );
      } on Object {
        // Coordinate read failure must not block editing the contact.
        loadedCoordinate = null;
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _firstNameController.text = detail.contact.firstName ?? '';
        _lastNameController.text = detail.contact.lastName ?? '';
        _addressController.text = detail.contact.addressText ?? '';
        _preferredMethod = detail.contact.preferredContactMethod;
        _source = detail.contact.source;
        _initialDisplayName = detail.contact.displayName;
        _isFavorite = detail.contact.isFavorite;
        _tagNames = detail.tags.map((tag) => tag.name).toList();
        _groupIds = detail.groups.map((group) => group.id).toList();
        _primaryGroupId = detail.primaryGroupId;
        _availability.addAll(detail.availability);
        _mapCoordinate = loadedCoordinate;
        _initialMapCoordinate = loadedCoordinate;
        _addressExpanded = _addressController.text.isNotEmpty;
        _mapExpanded = loadedCoordinate != null;
        for (final method in detail.methods) {
          final row = _MethodRow(
            id: method.id,
            type: method.type,
            controller: TextEditingController(text: method.rawValue),
            label: method.label,
            isPrimary: method.isPrimary,
            receivesTexts: method.receivesTexts,
            hasWhatsApp: method.hasWhatsApp,
          );
          _trackMethodRow(row);
          _methodRows.add(row);
        }
        _loading = false;
      });
    } on Object {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  String get _displayName {
    final entered =
        '${_firstNameController.text.trim()} ${_lastNameController.text.trim()}'
            .trim();
    // Imported/display-name-only contacts remain editable.  A user can still
    // add structured names later, but opening and saving an unrelated fact
    // must never replace the canonical existing display identity with blank.
    return entered.isEmpty ? _initialDisplayName ?? '' : entered;
  }

  @override
  Widget build(BuildContext context) {
    final groups =
        ref.watch(contactGroupsProvider).value ?? const <ContactGroup>[];
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          unawaited(_requestClose());
        }
      },
      child: Scaffold(
        backgroundColor: ContactReferenceStyle.canvasOf(context),
        appBar: InternalAppBar(
          backgroundColor: ContactReferenceStyle.canvasOf(context),
          surfaceTintColor: Colors.transparent,
          scrolledUnderElevation: 0,
          title: Text(
            widget.mode == ContactFormMode.create
                ? 'Add Contact'
                : 'Edit Contact',
            style: TextStyle(
              color: ContactReferenceStyle.onCanvasOf(context),
              fontSize: 26,
              fontWeight: FontWeight.w400,
            ),
          ),
          leading: IconButton(
            key: const Key('contact-form-close'),
            tooltip: 'Close',
            iconSize: 26,
            onPressed: _requestClose,
            icon: const Icon(Icons.close),
          ),
          actions: <Widget>[_buildSaveButton()],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
                child: SafeArea(
                  child: Form(
                    key: _formKey,
                    child: ListView(
                      key: const Key('contact-form-scroll'),
                      padding: const EdgeInsets.only(top: 16, bottom: 48),
                      children: <Widget>[
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: <Widget>[
                              _field(
                                key: const Key('contact-first-name'),
                                controller: _firstNameController,
                                label: widget.mode == ContactFormMode.create
                                    ? 'First Name *'
                                    : 'First Name',
                                onChanged: (_) => setState(() {}),
                                required: widget.mode == ContactFormMode.create,
                              ),
                              const SizedBox(height: 16),
                              _field(
                                key: const Key('contact-last-name'),
                                controller: _lastNameController,
                                label: widget.mode == ContactFormMode.create
                                    ? 'Last Name *'
                                    : 'Last Name',
                                onChanged: (_) => setState(() {}),
                                required: widget.mode == ContactFormMode.create,
                              ),
                              const SizedBox(height: 16),
                              _GroupsField(
                                groups: groups,
                                primaryGroupId: _primaryGroupId,
                                onManage: _openGroupManager,
                                onChanged: (ids, primaryId) => setState(() {
                                  _groupIds = ids;
                                  _primaryGroupId = primaryId;
                                  _hasUnsavedChanges = true;
                                }),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 20),
                        const _ContactFormSectionDivider(
                          key: Key('contact-form-divider-after-basics'),
                        ),
                        const SizedBox(height: 12),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: <Widget>[
                              _buildMethodSection(ContactMethodType.phone),
                              _buildMethodSection(ContactMethodType.email),
                              _buildMethodSection(ContactMethodType.social),
                              if (_addressController.text.isEmpty &&
                                  !_addressExpanded) ...<Widget>[
                                _ProgressiveRow(
                                  key: const Key('add-address-row'),
                                  icon: Icons.place_outlined,
                                  label: '+ Address',
                                  onTap: () =>
                                      setState(() => _addressExpanded = true),
                                ),
                                const SizedBox(height: 4),
                              ],
                              if (_addressExpanded) ...<Widget>[
                                _field(
                                  key: const Key('contact-address'),
                                  controller: _addressController,
                                  label: 'Address',
                                  onChanged: (_) => setState(() {}),
                                  fontSize: 15,
                                ),
                                Align(
                                  alignment: Alignment.centerRight,
                                  child: TextButton(
                                    key: const Key('remove-address'),
                                    onPressed: () {
                                      _addressController.clear();
                                      setState(() => _addressExpanded = false);
                                    },
                                    child: const Text('Remove'),
                                  ),
                                ),
                                const SizedBox(height: 8),
                              ],
                              if (!_mapExpanded) ...<Widget>[
                                _ProgressiveRow(
                                  key: const Key('add-map-row'),
                                  icon: Icons.map_outlined,
                                  label: '+ Map',
                                  onTap: _openMapPicker,
                                ),
                                const SizedBox(height: 4),
                              ],
                              if (_mapExpanded) ...<Widget>[
                                MapPinSection(
                                  displayName: _displayName.isEmpty
                                      ? 'Contact'
                                      : _displayName,
                                  coordinate: _mapCoordinate,
                                  onChanged: (value) => setState(() {
                                    _mapCoordinate = value;
                                    _mapExpanded = value != null;
                                    _hasUnsavedChanges = true;
                                  }),
                                  contactFormStyle: true,
                                ),
                                const SizedBox(height: 12),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        const _ContactFormSectionDivider(
                          key: Key('contact-form-divider-before-options'),
                        ),
                        const SizedBox(height: 20),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: _optionsExpanded
                              ? _buildExpandedOptions()
                              : _ExpandOptionsButton(
                                  key: const Key('expand-contact-options'),
                                  onTap: () =>
                                      setState(() => _optionsExpanded = true),
                                ),
                        ),
                        const SizedBox(height: 16),
                      ],
                    ),
                  ),
                ),
              ),
      ),
    );
  }

  Future<void> _openMapPicker() async {
    final result = await context.push<MapCoordinate>(
      RoutePaths.mapPicker,
      extra: MapPickerArgs(
        displayName: _displayName.isEmpty ? 'Contact' : _displayName,
        initialCoordinate: _mapCoordinate,
      ),
    );
    if (result != null && mounted) {
      setState(() {
        _mapCoordinate = result;
        _mapExpanded = true;
        _hasUnsavedChanges = true;
      });
    }
  }

  Future<void> _openGroupManager() async {
    await context.push<void>(RoutePaths.contactGroups);
    if (!mounted) {
      return;
    }
    // A group can be permanently deleted while this Contact form stays in the
    // navigation stack. Refresh before saving so its deleted ID cannot be
    // written back into this Contact draft.
    ref.invalidate(contactGroupsProvider);
    final groups = await ref.read(contactGroupsProvider.future);
    if (!mounted) {
      return;
    }
    final hasCurrentPrimary =
        _primaryGroupId == null ||
        groups.any((group) => group.id == _primaryGroupId && !group.isArchived);
    if (!hasCurrentPrimary) {
      setState(() {
        _groupIds = <String>[];
        _primaryGroupId = null;
      });
    }
  }

  bool _addressExpanded = false;
  bool _notesExpanded = false;

  List<_MethodRow> _rowsFor(ContactMethodType type) =>
      _methodRows.where((row) => row.type == type).toList(growable: false);

  String _nextMethodLabel(ContactMethodType type) {
    if (type == ContactMethodType.social) {
      return nextSocialProfileLabel(_rowsFor(type).map((row) => row.label));
    }
    final labels = _contactMethodLabels[type]!;
    final usedLabels = _rowsFor(
      type,
    ).map((row) => row.label).whereType<String>().toSet();
    return labels.firstWhere(
      (label) => !usedLabels.contains(label),
      orElse: () => labels.last,
    );
  }

  Widget _buildMethodSection(ContactMethodType type) {
    final rows = _rowsFor(type);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (rows.isNotEmpty) ...<Widget>[
          const SizedBox(height: 6),
          for (final row in rows) ...<Widget>[
            _MethodRowTile(
              row: row,
              onLabelChanged: (label) => setState(() {
                row.setLabel(label);
                _hasUnsavedChanges = true;
              }),
              onRemove: () {
                setState(() {
                  _methodRows.remove(row);
                  _hasUnsavedChanges = true;
                });
                row.controller.dispose();
              },
            ),
            const SizedBox(height: 8),
          ],
        ],
        ContactMethodEntryRow(
          key: Key('add-${type.name}-row'),
          type: type,
          hasExistingRows: rows.isNotEmpty,
          includeAddQualifier: true,
          onTap: () => setState(() {
            final row = _MethodRow(
              type: type,
              label: _nextMethodLabel(type),
              controller: TextEditingController(),
              receivesTexts: type == ContactMethodType.phone ? true : null,
              hasWhatsApp: type == ContactMethodType.phone ? false : null,
              defaultedMobileText: type == ContactMethodType.phone,
            );
            _trackMethodRow(row);
            _methodRows.add(row);
            _hasUnsavedChanges = true;
          }),
        ),
        const SizedBox(height: 2),
      ],
    );
  }

  Widget _buildExpandedOptions() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SizedBox(height: 4),
        SwitchListTile.adaptive(
          key: const Key('contact-favorite-toggle'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Favorite', style: TextStyle(fontSize: 14)),
          value: _isFavorite,
          onChanged: (value) => setState(() {
            _isFavorite = value;
            _hasUnsavedChanges = true;
          }),
        ),
        const SizedBox(height: 8),
        _PreferredMethodField(
          value: _preferredMethod,
          onChanged: (value) => setState(() {
            _preferredMethod = value;
            _hasUnsavedChanges = true;
          }),
        ),
        const SizedBox(height: 16),
        if (_availability.isEmpty)
          _ProgressiveRow(
            key: const Key('add-availability-row'),
            icon: Icons.schedule_outlined,
            label: 'Availability',
            onTap: _editAvailability,
          )
        else
          _AvailabilityTile(
            windows: _availability,
            onEdit: _editAvailability,
            onRemove: (window) => setState(() => _availability.remove(window)),
          ),
        const SizedBox(height: 8),
        if (!_notesExpanded)
          _ProgressiveRow(
            key: const Key('add-notes-row'),
            icon: Icons.notes_outlined,
            label: '+ Add Note',
            onTap: () => setState(() => _notesExpanded = true),
          )
        else ...<Widget>[
          TextFormField(
            key: const Key('contact-notes'),
            controller: _noteController,
            maxLines: 4,
            style: const TextStyle(fontSize: 14),
            decoration: _decoration(context, 'Add Note'),
          ),
          const SizedBox(height: 8),
        ],
      ],
    );
  }

  Widget _field({
    required Key key,
    required TextEditingController controller,
    required String label,
    required ValueChanged<String> onChanged,
    bool required = false,
    double fontSize = 17,
  }) {
    return TextFormField(
      key: key,
      controller: controller,
      onChanged: onChanged,
      style: TextStyle(fontSize: fontSize),
      decoration: _decoration(context, label),
      validator: required
          ? (value) => (value ?? '').trim().isEmpty ? 'Required' : null
          : null,
    );
  }

  Widget _buildSaveButton() {
    return Semantics(
      button: true,
      label: 'Save',
      child: SizedBox.square(
        dimension: 40,
        child: FilledButton(
          key: const Key('save-contact-button'),
          onPressed: _saving ? null : _save,
          style: FilledButton.styleFrom(
            padding: EdgeInsets.zero,
            shape: const CircleBorder(),
            backgroundColor: _contactFormActionColor(context),
            foregroundColor: Colors.white,
          ),
          child: _saving
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.check, size: 20),
        ),
      ),
    );
  }

  Future<void> _editAvailability() async {
    final result = await showModalBottomSheet<List<ContactAvailability>>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) => _AvailabilityEditor(
        initial: List<ContactAvailability>.from(_availability),
      ),
    );
    if (result != null && mounted) {
      setState(() {
        _availability
          ..clear()
          ..addAll(result);
        _hasUnsavedChanges = true;
      });
    }
  }

  Future<void> _requestClose() async {
    if (!_hasUnsavedChanges) {
      Navigator.of(context).pop();
      return;
    }
    final decision = await showUnsavedChangesGuard(context);
    if (!mounted) {
      return;
    }
    switch (decision) {
      case UnsavedChangesDecision.saveAndLeave:
        await _save();
        return;
      case UnsavedChangesDecision.discardAndLeave:
        Navigator.of(context).pop();
        return;
      case UnsavedChangesDecision.keepEditing:
      case null:
        return;
    }
  }

  Future<void> _save() async {
    FocusScope.of(context).unfocus();
    if (!_formKey.currentState!.validate()) {
      return;
    }
    final displayName = _displayName;
    if (displayName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('A Contact needs a usable name.')),
      );
      return;
    }
    setState(() => _saving = true);
    final ids = ref.read(plannerIdentifierSourceProvider);
    final contactId = widget.mode == ContactFormMode.create
        ? ids.nextUuid()
        : widget.contactId!;
    final draft = ContactDraft(
      id: contactId,
      firstName: _firstNameController.text,
      lastName: _lastNameController.text,
      displayName: displayName,
      preferredContactMethod: _preferredMethod,
      isFavorite: _isFavorite,
      addressText: _addressController.text,
      source: _source,
      methods: <ContactMethodDraft>[
        for (final row in _methodRows)
          if (row.controller.text.trim().isNotEmpty)
            ContactMethodDraft(
              id: row.id,
              type: row.type,
              value: row.controller.text,
              label: row.label,
              isPrimary: row.isPrimary,
              receivesTexts: row.type == ContactMethodType.phone
                  ? row.receivesTexts
                  : null,
              hasWhatsApp: row.type == ContactMethodType.phone
                  ? row.hasWhatsApp
                  : null,
            ),
      ],
      groupIds: _groupIds,
      primaryGroupId: _primaryGroupId,
      tagNames: _tagNames,
      availability: List<ContactAvailability>.from(_availability),
      initialNoteText: widget.mode == ContactFormMode.create
          ? _noteController.text
          : null,
      requiresNewManualContactValidation:
          widget.mode == ContactFormMode.create &&
          _source == ContactSource.manual,
    );
    final profileId = ref.read(contactProfileIdProvider);
    try {
      final contact = widget.mode == ContactFormMode.create
          ? await ref
                .read(contactRepositoryProvider)
                .createContact(profileId: profileId, draft: draft)
          : await ref
                .read(contactRepositoryProvider)
                .updateContact(
                  profileId: profileId,
                  contactId: contactId,
                  draft: draft,
                );
      if (widget.mode == ContactFormMode.edit &&
          _noteController.text.trim().isNotEmpty) {
        await ref
            .read(contactRepositoryProvider)
            .addNote(
              profileId: profileId,
              contactId: contactId,
              text: _noteController.text,
            );
      }
      await _persistMapPin(contactId: contactId);
      if (!mounted) {
        return;
      }
      Navigator.of(context).pop(contact);
    } on ContactValidationException catch (error) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.message)));
      }
    } on Object {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Contact could not be saved. Your input is intact.'),
          ),
        );
      }
    }
  }

  Future<void> _persistMapPin({required String contactId}) async {
    try {
      final maps = ref.read(mapCoordinateRepositoryProvider);
      final profileId = ref.read(contactProfileIdProvider);
      final current = _mapCoordinate;
      if (current != null) {
        await maps.setCoordinate(
          profileId: profileId,
          owner: MapCoordinateOwner.contact,
          recordId: contactId,
          coordinate: current,
        );
      } else if (_initialMapCoordinate != null) {
        await maps.clearCoordinate(
          profileId: profileId,
          owner: MapCoordinateOwner.contact,
          recordId: contactId,
        );
      }
    } on Object {
      // A missing/offline Maps layer must never block saving the Contact.
    }
  }
}

InputDecoration _decoration(BuildContext context, String label) {
  final border = OutlineInputBorder(
    borderRadius: BorderRadius.circular(8),
    borderSide: BorderSide(color: ContactReferenceStyle.lineOf(context)),
  );
  return InputDecoration(
    labelText: label,
    labelStyle: InternalScreen.fieldLabel.copyWith(
      color: ContactReferenceStyle.onCanvasOf(context),
    ),
    filled: true,
    fillColor: ContactReferenceStyle.canvasOf(context),
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
    border: border,
    enabledBorder: border,
    focusedBorder: border.copyWith(
      borderSide: BorderSide(
        color: ContactReferenceStyle.actionOf(context),
        width: 2,
      ),
    ),
  );
}

/// Form-only action color. This deliberately bypasses the PMG-derived
/// ContactReferenceStyle.actionOf token, which is shared by accepted Contact
/// Detail and Timeline surfaces. Add/Edit Contact actions follow the active
/// Next Transfer ColorScheme instead.
Color _contactFormActionColor(BuildContext context) =>
    Theme.of(context).colorScheme.primary;

InputDecoration _methodDecoration(BuildContext context, String hint) {
  final line = BorderSide(color: ContactReferenceStyle.lineOf(context));
  return InputDecoration(
    hintText: hint,
    hintStyle: TextStyle(
      color: AppTheme.secondaryTextOf(context),
      fontSize: 14,
    ),
    isDense: true,
    contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
    enabledBorder: UnderlineInputBorder(borderSide: line),
    focusedBorder: UnderlineInputBorder(
      borderSide: BorderSide(
        color: ContactReferenceStyle.actionOf(context),
        width: 2,
      ),
    ),
  );
}

final class _ProgressiveRow extends StatelessWidget {
  const _ProgressiveRow({
    required this.icon,
    required this.label,
    required this.onTap,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: onTap,
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 44),
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
        alignment: Alignment.centerLeft,
        foregroundColor: _contactFormActionColor(context),
        textStyle: AppTypography.button.copyWith(fontSize: 15),
      ),
      icon: Icon(icon, size: 20, color: _contactFormActionColor(context)),
      label: Text(label),
    );
  }
}

final class _ContactFormSectionDivider extends StatelessWidget {
  const _ContactFormSectionDivider({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(height: 1, color: ContactReferenceStyle.lineOf(context));
  }
}

final class _ExpandOptionsButton extends StatelessWidget {
  const _ExpandOptionsButton({required this.onTap, super.key});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.center,
      child: SizedBox(
        width: 184,
        height: 44,
        child: FilledButton(
          onPressed: onTap,
          style: FilledButton.styleFrom(
            minimumSize: Size.zero,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            backgroundColor: _contactFormActionColor(context),
            foregroundColor: Colors.white,
            shape: const StadiumBorder(),
            textStyle: AppTypography.button.copyWith(fontSize: 15),
          ),
          child: const Text('Expand Options'),
        ),
      ),
    );
  }
}

final class _GroupsField extends StatelessWidget {
  const _GroupsField({
    required this.groups,
    required this.primaryGroupId,
    required this.onManage,
    required this.onChanged,
  });

  final List<ContactGroup> groups;
  final String? primaryGroupId;
  final Future<void> Function() onManage;
  final void Function(List<String> ids, String? primaryId) onChanged;

  @override
  Widget build(BuildContext context) {
    final activeGroups = groups
        .where((group) => !group.isArchived)
        .toList(growable: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        InkWell(
          key: const Key('contact-groups-field'),
          borderRadius: BorderRadius.circular(6),
          onTap: () async {
            final result = await showModalBottomSheet<_GroupPickerResult>(
              context: context,
              isScrollControlled: true,
              useSafeArea: true,
              builder: (sheetContext) => _GroupPicker(
                groups: activeGroups,
                primaryGroupId: primaryGroupId,
              ),
            );
            if (!context.mounted || result == null) {
              return;
            }
            switch (result) {
              case _GroupPickerSelection(
                :final groupIds,
                :final primaryGroupId,
              ):
                onChanged(groupIds, primaryGroupId);
              case _GroupPickerManage():
                await onManage();
            }
          },
          child: InputDecorator(
            decoration: _decoration(
              context,
              'Groups',
            ).copyWith(suffixIcon: const Icon(Icons.arrow_drop_down, size: 24)),
            child: primaryGroupId == null
                ? Text(
                    'No groups',
                    style: TextStyle(
                      color: AppTheme.secondaryTextOf(context),
                      fontSize: 16,
                    ),
                  )
                : Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: <Widget>[
                      Builder(
                        builder: (context) {
                          final group = groups
                              .where((g) => g.id == primaryGroupId)
                              .firstOrNull;
                          return Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: AppTheme.surfaceRaisedOf(context),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: group == null
                                    ? AppTheme.surfaceVariantOf(context)
                                    : Color(group.colorValue),
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                Text(
                                  group?.name ?? 'Group',
                                  style: const TextStyle(fontSize: 13),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }
}

sealed class _GroupPickerResult {
  const _GroupPickerResult();
}

final class _GroupPickerSelection extends _GroupPickerResult {
  const _GroupPickerSelection({
    required this.groupIds,
    required this.primaryGroupId,
  });

  final List<String> groupIds;
  final String? primaryGroupId;
}

final class _GroupPickerManage extends _GroupPickerResult {
  const _GroupPickerManage();
}

final class _GroupPicker extends StatefulWidget {
  const _GroupPicker({required this.groups, required this.primaryGroupId});

  final List<ContactGroup> groups;
  final String? primaryGroupId;

  @override
  State<_GroupPicker> createState() => _GroupPickerState();
}

final class _GroupPickerState extends State<_GroupPicker> {
  // C2 one-group V1: zero or one current/primary group only.
  String? _primary;

  @override
  void initState() {
    super.initState();
    _primary = widget.primaryGroupId;
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: EdgeInsets.fromLTRB(20, 18, 20, 4),
              child: Row(
                children: <Widget>[
                  const Expanded(
                    child: Text(
                      'Groups',
                      style: TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  TextButton(
                    key: const Key('group-picker-manage'),
                    onPressed: () =>
                        Navigator.of(context).pop(const _GroupPickerManage()),
                    child: const Text('Manage'),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
              child: Text(
                'Choose zero or one current group.',
                style: TextStyle(
                  color: AppTheme.secondaryTextOf(context),
                  fontSize: 13,
                ),
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: <Widget>[
                  // Owner law (2026-09-18): the ungrouped state is a visible,
                  // selectable option in the picker, painted with the single
                  // canonical ungrouped colour. Choosing it only clears the
                  // draft: nothing is persisted until Save, and Cancel leaves
                  // the stored memberships exactly as they were.
                  ListTile(
                    key: const Key('group-option-none'),
                    leading: Icon(
                      _primary == null
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                      color: _primary == null
                          ? Theme.of(context).colorScheme.primary
                          : AppTheme.secondaryTextOf(context),
                    ),
                    title: Row(
                      children: <Widget>[
                        Container(
                          width: 13,
                          height: 13,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: Color(ContactUngroupedColor.argb),
                          ),
                        ),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: Text(ContactUngroupedColor.displayName),
                        ),
                      ],
                    ),
                    onTap: () => setState(() => _primary = null),
                  ),
                  for (final group in widget.groups)
                    ListTile(
                      key: Key('group-option-${group.id}'),
                      leading: Icon(
                        _primary == group.id
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                        color: _primary == group.id
                            ? Color(group.colorValue)
                            : AppTheme.secondaryTextOf(context),
                      ),
                      title: Row(
                        children: <Widget>[
                          Container(
                            width: 13,
                            height: 13,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Color(group.colorValue),
                            ),
                          ),
                          const SizedBox(width: 10),
                          // The canonical default name "Ministering Assignments"
                          // is long enough that a bare Text would overflow this
                          // ListTile title on a narrow screen or at a larger text
                          // scale, so the name flexes and ellipsises instead.
                          Expanded(
                            child: Text(
                              group.name,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      onTap: () => setState(() => _primary = group.id),
                    ),
                  if (widget.groups.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text(
                        'Use Manage to create or edit groups.',
                        style: TextStyle(
                          color: AppTheme.secondaryTextOf(context),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: FilledButton(
                key: const Key('groups-picker-done'),
                onPressed: () => Navigator.of(context).pop(
                  _GroupPickerSelection(
                    groupIds: _primary == null
                        ? const <String>[]
                        : <String>[_primary!],
                    primaryGroupId: _primary,
                  ),
                ),
                child: const Text('Done'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final class _PreferredMethodField extends StatelessWidget {
  const _PreferredMethodField({required this.value, required this.onChanged});

  final ContactPreferredMethod value;
  final ValueChanged<ContactPreferredMethod> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Text(
          'Preferred contact method',
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        SegmentedButton<ContactPreferredMethod>(
          segments: const <ButtonSegment<ContactPreferredMethod>>[
            ButtonSegment<ContactPreferredMethod>(
              value: ContactPreferredMethod.message,
              icon: Icon(Icons.chat_outlined, size: 16),
              label: Text('Message', style: TextStyle(fontSize: 13)),
            ),
            ButtonSegment<ContactPreferredMethod>(
              value: ContactPreferredMethod.call,
              icon: Icon(Icons.call_outlined, size: 16),
              label: Text('Call', style: TextStyle(fontSize: 13)),
            ),
            ButtonSegment<ContactPreferredMethod>(
              value: ContactPreferredMethod.email,
              icon: Icon(Icons.mail_outline, size: 16),
              label: Text('Email', style: TextStyle(fontSize: 13)),
            ),
          ],
          selected: <ContactPreferredMethod>{value},
          onSelectionChanged: (selection) => onChanged(selection.first),
        ),
      ],
    );
  }
}

// Dormant compatibility helper retained temporarily with Tag persistence; no
// active Contact form path constructs it after the C5 UX retirement.
// ignore: unused_element
final class _TagsField extends StatelessWidget {
  const _TagsField({
    required this.availableTags,
    required this.selectedNames,
    required this.onChanged,
  });

  final List<ContactTag> availableTags;
  final List<String> selectedNames;
  final ValueChanged<List<String>> onChanged;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: const Key('contact-tags-field'),
      borderRadius: BorderRadius.circular(6),
      onTap: () async {
        final result = await showModalBottomSheet<List<String>>(
          context: context,
          isScrollControlled: true,
          useSafeArea: true,
          builder: (sheetContext) => _TagPicker(
            availableTags: availableTags,
            selectedNames: selectedNames,
          ),
        );
        if (result != null) {
          onChanged(result);
        }
      },
      child: InputDecorator(
        decoration: _decoration(
          context,
          'Tags',
        ).copyWith(suffixIcon: const Icon(Icons.arrow_drop_down, size: 24)),
        child: selectedNames.isEmpty
            ? Text(
                'No tags',
                style: TextStyle(
                  color: AppTheme.secondaryTextOf(context),
                  fontSize: 14,
                ),
              )
            : Wrap(
                spacing: 6,
                runSpacing: 4,
                children: <Widget>[
                  for (final name in selectedNames)
                    Chip(
                      label: Text(name),
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
      ),
    );
  }
}

final class _TagPicker extends StatefulWidget {
  const _TagPicker({required this.availableTags, required this.selectedNames});

  final List<ContactTag> availableTags;
  final List<String> selectedNames;

  @override
  State<_TagPicker> createState() => _TagPickerState();
}

final class _TagPickerState extends State<_TagPicker> {
  late final Set<String> _selected = <String>{...widget.selectedNames};

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SizedBox(
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 20, 20, 8),
              child: Text('Tags', style: InternalScreen.sectionHeading),
            ),
            Expanded(
              child: widget.availableTags.isEmpty
                  ? const Center(child: Text('No tags created yet.'))
                  : ListView(
                      children: <Widget>[
                        for (final tag in widget.availableTags)
                          CheckboxListTile(
                            value: _selected.contains(tag.name),
                            title: Text(tag.name),
                            onChanged: (selected) => setState(() {
                              if (selected ?? false) {
                                _selected.add(tag.name);
                              } else {
                                _selected.remove(tag.name);
                              }
                            }),
                          ),
                      ],
                    ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: FilledButton(
                key: const Key('contact-tags-done'),
                onPressed: () => Navigator.of(context).pop(
                  widget.availableTags
                      .map((tag) => tag.name)
                      .where(_selected.contains)
                      .toList(growable: false),
                ),
                child: const Text('Done'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final class _MethodRowTile extends StatelessWidget {
  const _MethodRowTile({
    required this.row,
    required this.onLabelChanged,
    required this.onRemove,
  });

  final _MethodRow row;
  final ValueChanged<String> onLabelChanged;
  final VoidCallback onRemove;

  String get _rowKey => row.id ?? '${row.controller.hashCode}';

  String get _typeLabel => switch (row.type) {
    ContactMethodType.phone => 'Phone',
    ContactMethodType.email => 'Email',
    ContactMethodType.social => 'Social Profile',
  };

  @override
  Widget build(BuildContext context) {
    final approved = _contactMethodLabels[row.type]!;
    final selected =
        row.label ??
        (row.type == ContactMethodType.social ? approved.first : approved.last);
    final labels = <String>[
      ...approved,
      if (!approved.contains(selected) &&
          (row.type != ContactMethodType.social ||
              canonicalSocialProfileKey(selected) == null))
        selected,
    ];
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        _MethodTypeIconPicker(
          key: Key('contact-method-label-$_rowKey'),
          type: row.type,
          selected: selected,
          labels: labels,
          onSelected: onLabelChanged,
        ),
        const SizedBox(width: 4),
        Expanded(
          child: TextFormField(
            key: Key('contact-method-${row.type.name}-$_rowKey'),
            controller: row.controller,
            keyboardType: row.type == ContactMethodType.phone
                ? TextInputType.phone
                : row.type == ContactMethodType.email
                ? TextInputType.emailAddress
                : TextInputType.text,
            decoration: _methodDecoration(context, _typeLabel),
            style: const TextStyle(fontSize: 14),
            onChanged: (_) {},
          ),
        ),
        IconButton(
          key: Key('remove-method-${row.type.name}'),
          tooltip: 'Remove',
          color: ContactReferenceStyle.destructiveOf(context),
          onPressed: onRemove,
          icon: const Icon(Icons.delete_outline, size: 22),
        ),
      ],
    );
  }
}

final class _MethodTypeIconPicker extends StatelessWidget {
  const _MethodTypeIconPicker({
    required this.type,
    required this.selected,
    required this.labels,
    required this.onSelected,
    super.key,
  });

  final ContactMethodType type;
  final String selected;
  final List<String> labels;
  final ValueChanged<String> onSelected;

  String get _typeLabel => switch (type) {
    ContactMethodType.phone => 'Phone',
    ContactMethodType.email => 'Email',
    ContactMethodType.social => 'Social Profile',
  };

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label:
          '$_typeLabel type: ${type == ContactMethodType.social ? socialProfileDisplayLabel(selected) : selected}',
      button: true,
      child: PopupMenuButton<String>(
        tooltip:
            '$_typeLabel type: ${type == ContactMethodType.social ? socialProfileDisplayLabel(selected) : selected}',
        initialValue: selected,
        onSelected: onSelected,
        itemBuilder: (context) => <PopupMenuEntry<String>>[
          for (final label in labels)
            PopupMenuItem<String>(
              value: label,
              child: Row(
                children: <Widget>[
                  if (type == ContactMethodType.social && label == 'X')
                    const Text('𝕏', style: TextStyle(fontSize: 18, height: 1))
                  else
                    contactMethodVisual(
                      type: type,
                      label: label,
                      color: _contactFormActionColor(context),
                      size: 18,
                    ),
                  const SizedBox(width: 12),
                  Text(
                    type == ContactMethodType.social
                        ? socialProfileDisplayLabel(label)
                        : label,
                  ),
                ],
              ),
            ),
        ],
        child: SizedBox(
          width: 46,
          height: 46,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              if (type == ContactMethodType.social && selected == 'X')
                ExcludeSemantics(
                  child: Text(
                    '𝕏',
                    style: TextStyle(
                      color: _contactFormActionColor(context),
                      fontSize: 23,
                      fontWeight: FontWeight.w700,
                      height: 1,
                    ),
                  ),
                )
              else
                contactMethodVisual(
                  type: type,
                  label: selected,
                  color: _contactFormActionColor(context),
                  size: 24,
                ),
              Icon(
                Icons.arrow_drop_down,
                color: _contactFormActionColor(context),
                size: 18,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _AvailabilityTile extends StatelessWidget {
  const _AvailabilityTile({
    required this.windows,
    required this.onEdit,
    required this.onRemove,
  });

  final List<ContactAvailability> windows;
  final VoidCallback onEdit;
  final ValueChanged<ContactAvailability> onRemove;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            const Icon(Icons.schedule_outlined, size: 18),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                'Availability',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
            ),
            TextButton(
              onPressed: onEdit,
              child: const Text('Edit', style: TextStyle(fontSize: 13)),
            ),
          ],
        ),
        for (final window in windows)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.schedule, size: 18),
            title: Text(
              '${_weekdayName(window.weekday)}  '
              '${_formatMinute(window.startMinute)} – ${_formatMinute(window.endMinute)}',
              style: const TextStyle(fontSize: 14),
            ),
            trailing: IconButton(
              icon: const Icon(Icons.close, size: 18),
              onPressed: () => onRemove(window),
            ),
          ),
      ],
    );
  }

  static String _weekdayName(int weekday) {
    const names = <String>[
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    return names[weekday - 1];
  }

  static String _formatMinute(int minute) {
    final hour24 = minute ~/ 60;
    final hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12;
    final minuteText = (minute % 60).toString().padLeft(2, '0');
    final period = hour24 < 12 ? 'AM' : 'PM';
    return '$hour12:$minuteText $period';
  }
}

final class _AvailabilityEditor extends StatefulWidget {
  const _AvailabilityEditor({required this.initial});

  final List<ContactAvailability> initial;

  @override
  State<_AvailabilityEditor> createState() => _AvailabilityEditorState();
}

final class _AvailabilityEditorState extends State<_AvailabilityEditor> {
  late final List<ContactAvailability> _windows = <ContactAvailability>[
    ...widget.initial,
  ];
  int _weekday = DateTime.monday;
  TimeOfDay _start = const TimeOfDay(hour: 18, minute: 0);
  TimeOfDay _end = const TimeOfDay(hour: 21, minute: 0);

  Future<void> _pickTime({required bool isStart}) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: isStart ? _start : _end,
    );
    if (picked != null && mounted) {
      setState(() {
        if (isStart) {
          _start = picked;
        } else {
          _end = picked;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const Text(
              'Availability',
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              key: const Key('availability-weekday'),
              initialValue: _weekday,
              decoration: _decoration(context, 'Day'),
              items: <DropdownMenuItem<int>>[
                for (var day = DateTime.monday; day <= DateTime.sunday; day++)
                  DropdownMenuItem<int>(
                    value: day,
                    child: Text(_weekdayName(day)),
                  ),
              ],
              onChanged: (value) =>
                  setState(() => _weekday = value ?? _weekday),
            ),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                Expanded(
                  child: InkWell(
                    onTap: () => _pickTime(isStart: true),
                    child: InputDecorator(
                      decoration: _decoration(context, 'From'),
                      child: Text(
                        _formatMinute(_start.hour * 60 + _start.minute),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: InkWell(
                    onTap: () => _pickTime(isStart: false),
                    child: InputDecorator(
                      decoration: _decoration(context, 'To'),
                      child: Text(_formatMinute(_end.hour * 60 + _end.minute)),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            FilledButton(
              key: const Key('availability-add-window'),
              onPressed: () {
                final startMinute = _start.hour * 60 + _start.minute;
                final endMinute = _end.hour * 60 + _end.minute;
                if (endMinute <= startMinute) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('End time must be after start time.'),
                    ),
                  );
                  return;
                }
                setState(() {
                  _windows.add(
                    ContactAvailability(
                      weekday: _weekday,
                      startMinute: startMinute,
                      endMinute: endMinute,
                    ),
                  );
                });
              },
              child: const Text('Add window'),
            ),
            if (_windows.isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              for (final window in _windows)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    '${_weekdayName(window.weekday)}  '
                    '${_formatMinute(window.startMinute)} – ${_formatMinute(window.endMinute)}',
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => setState(() => _windows.remove(window)),
                  ),
                ),
            ],
            const SizedBox(height: 8),
            FilledButton(
              key: const Key('availability-done'),
              onPressed: () => Navigator.of(context).pop(_windows),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
  }

  static String _weekdayName(int weekday) {
    const names = <String>[
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    return names[weekday - 1];
  }

  static String _formatMinute(int minute) {
    final hour24 = minute ~/ 60;
    final hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12;
    final minuteText = (minute % 60).toString().padLeft(2, '0');
    final period = hour24 < 12 ? 'AM' : 'PM';
    return '$hour12:$minuteText $period';
  }
}
