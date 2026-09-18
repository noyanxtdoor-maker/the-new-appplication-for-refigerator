import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:rmplanner/app/router/route_names.dart';
import 'package:rmplanner/app/theme/app_theme.dart';
import 'package:rmplanner/app/theme/contact_reference_style.dart';
import 'package:rmplanner/app/theme/internal_screen.dart';
import 'package:rmplanner/features/contacts/application/contact_providers.dart';
import 'package:rmplanner/features/contacts/domain/contact.dart';
import 'package:rmplanner/features/contacts/presentation/address_map_editor.dart';
import 'package:rmplanner/features/contacts/presentation/availability_editor.dart';
import 'package:rmplanner/features/contacts/presentation/contact_groups_editor.dart';
import 'package:rmplanner/features/contacts/presentation/contact_information_editor.dart';
import 'package:rmplanner/features/contacts/presentation/contact_method_visuals.dart';
import 'package:rmplanner/features/contacts/presentation/external_handoff.dart';
import 'package:rmplanner/features/contacts/presentation/notes_editor.dart';
import 'package:rmplanner/features/contacts/presentation/widgets/contact_timeline_view.dart';
import 'package:rmplanner/features/maps/application/map_coordinate_repository.dart';
import 'package:rmplanner/features/maps/application/map_providers.dart';
import 'package:rmplanner/features/maps/domain/map_coordinate.dart';
import 'package:rmplanner/features/notifications/domain/contact_follow_up_creation_intent.dart';
import 'package:rmplanner/features/planner/application/event_type_providers.dart';

final contactProfileMapCoordinateProvider =
    FutureProvider.family<MapCoordinate?, String>((ref, contactId) {
      return ref
          .read(mapCoordinateRepositoryProvider)
          .readCoordinate(
            profileId: ref.read(contactProfileIdProvider),
            owner: MapCoordinateOwner.contact,
            recordId: contactId,
          );
    });

/// Contact Profile + Timeline (two tabs only, no Progress). Profile holds
/// factual Contact information; follow-up stays a Task or Calendar Event,
/// never a third entity.
final class ContactDetailScreen extends ConsumerStatefulWidget {
  const ContactDetailScreen({required this.contactId, super.key});

  final String contactId;

  @override
  ConsumerState<ContactDetailScreen> createState() =>
      _ContactDetailScreenState();
}

final class _ContactDetailScreenState
    extends ConsumerState<ContactDetailScreen> {
  int _tab = 0;
  bool _viewRecorded = false;

  @override
  Widget build(BuildContext context) {
    final detailAsync = ref.watch(contactDetailProvider(widget.contactId));
    // POLISH-07: retain the last valid Contact content while a refresh is in
    // flight.  A side-effecting read used to re-invalidate this provider
    // repeatedly, flashing the near-blank loading Scaffold between populated
    // frames; the loading/error frames now only appear when there is nothing
    // to show (first open / genuine failure).
    final detail = detailAsync.value;
    if (detail == null) {
      return detailAsync.hasError
          ? Scaffold(
              appBar: InternalAppBar(title: const Text('Contact')),
              body: const Center(child: Text('Contact could not be opened.')),
            )
          : Scaffold(
              appBar: InternalAppBar(title: const Text('Contact')),
              body: const Center(child: CircularProgressIndicator()),
            );
    }
    if (!_viewRecorded) {
      _viewRecorded = true;
      // The provider has delivered a real Contact, so the detail route opened
      // successfully. The route-local guard prevents rebuild/write loops.
      unawaited(_recordContactView(detail.contact.id));
    }
    return _build(detail);
  }

  Future<void> _recordContactView(String contactId) {
    return ref
        .read(contactRepositoryProvider)
        .markContactViewed(
          profileId: ref.read(contactProfileIdProvider),
          contactId: contactId,
        );
  }

  Widget _build(ContactDetail detail) {
    final contact = detail.contact;
    final primaryGroup = detail.groups.cast<ContactGroup?>().firstWhere(
      (group) => group?.id == detail.primaryGroupId,
      orElse: () => null,
    );
    final favoriteColor = contact.isFavorite
        ? primaryGroup == null
              ? AppTheme.secondaryTextOf(context)
              : Color(primaryGroup.colorValue)
        : AppTheme.secondaryTextOf(context);
    return Scaffold(
      backgroundColor: ContactReferenceStyle.canvasOf(context),
      appBar: AppBar(
        toolbarHeight: 56,
        backgroundColor: ContactReferenceStyle.canvasOf(context),
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        title: Text(
          contact.displayName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: ContactReferenceStyle.onCanvasOf(context),
            fontSize: 22,
            fontWeight: FontWeight.w600,
          ),
        ),
        actions: <Widget>[
          IconButton(
            key: const Key('contact-detail-favorite'),
            tooltip: contact.isFavorite ? 'Remove favorite' : 'Add favorite',
            onPressed: () => _setFavorite(contact),
            icon: Icon(
              contact.isFavorite ? Icons.star : Icons.star_border,
              size: 25,
              color: favoriteColor,
            ),
          ),
          PopupMenuButton<String>(
            key: const Key('contact-detail-overflow'),
            tooltip: 'More options',
            onSelected: (value) => _handleOverflow(value, detail),
            itemBuilder: (context) => <PopupMenuEntry<String>>[
              PopupMenuItem<String>(value: 'edit', child: Text('Edit contact')),
              PopupMenuItem<String>(
                value: 'merge',
                child: const Text('Find duplicates'),
              ),
              PopupMenuDivider(),
              if (contact.isArchived)
                PopupMenuItem<String>(value: 'restore', child: Text('Restore'))
              else
                PopupMenuItem<String>(value: 'archive', child: Text('Archive')),
            ],
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          _TabBar(
            selectedIndex: _tab,
            onChanged: (index) => setState(() => _tab = index),
          ),
          Expanded(
            child: _tab == 0
                ? _ProfileTab(
                    detail: detail,
                    onFullEdit: () =>
                        context.push(RoutePaths.contactEdit(contact.id)),
                    onEditContactInformation: () =>
                        _editContactInformation(detail),
                    onEditAddressAndMap: () => _editAddressAndMap(detail),
                    onEditGroups: () => _editGroups(detail),
                    onEditAvailability: () => _editAvailability(detail),
                    onEditNotes: () => _editNotes(detail),
                    onSeeMoreUpcoming: () => setState(() => _tab = 1),
                  )
                : _TimelineTab(contactId: contact.id),
          ),
        ],
      ),
    );
  }

  void _setFavorite(Contact contact) {
    unawaited(
      ref
          .read(contactRepositoryProvider)
          .setFavorite(
            profileId: ref.read(contactProfileIdProvider),
            contactId: contact.id,
            favorite: !contact.isFavorite,
          ),
    );
  }

  Future<void> _editContactInformation(ContactDetail detail) async {
    final profileId = ref.read(contactProfileIdProvider);
    final result = await Navigator.of(context)
        .push<ContactInformationEditResult>(
          MaterialPageRoute<ContactInformationEditResult>(
            builder: (_) => ContactInformationEditor(detail: detail),
          ),
        );
    if (result == null || !mounted) {
      return;
    }
    await ref
        .read(contactRepositoryProvider)
        .updateContactIdentityAndMethods(
          profileId: profileId,
          contactId: detail.contact.id,
          firstName: result.firstName,
          lastName: result.lastName,
          displayName: result.displayName,
          preferredContactMethod: result.preferredContactMethod,
          methods: result.methods,
        );
  }

  Future<void> _editAddressAndMap(ContactDetail detail) async {
    final profileId = ref.read(contactProfileIdProvider);
    final initialCoordinate = await ref.read(
      contactProfileMapCoordinateProvider(detail.contact.id).future,
    );
    if (!mounted) {
      return;
    }
    final result = await Navigator.of(context).push<AddressMapEditResult>(
      MaterialPageRoute<AddressMapEditResult>(
        builder: (_) => AddressMapEditor(
          displayName: detail.contact.displayName,
          initialAddress: detail.contact.addressText,
          initialCoordinate: initialCoordinate,
        ),
      ),
    );
    if (result == null || !mounted) {
      return;
    }
    await ref
        .read(contactRepositoryProvider)
        .updateContactAddress(
          profileId: profileId,
          contactId: detail.contact.id,
          addressText: result.address,
        );
    if (result.coordinateChanged) {
      final maps = ref.read(mapCoordinateRepositoryProvider);
      if (result.coordinate == null) {
        await maps.clearCoordinate(
          profileId: profileId,
          owner: MapCoordinateOwner.contact,
          recordId: detail.contact.id,
        );
      } else {
        await maps.setCoordinate(
          profileId: profileId,
          owner: MapCoordinateOwner.contact,
          recordId: detail.contact.id,
          coordinate: result.coordinate!,
        );
      }
      ref.invalidate(contactProfileMapCoordinateProvider(detail.contact.id));
    }
  }

  Future<void> _editGroups(ContactDetail detail) async {
    final profileId = ref.read(contactProfileIdProvider);
    final groups = await ref
        .read(contactRepositoryProvider)
        .readGroups(profileId);
    if (!mounted) {
      return;
    }
    final result = await Navigator.of(context).push<ContactGroupsEditResult>(
      MaterialPageRoute<ContactGroupsEditResult>(
        builder: (_) => ContactGroupsEditor(
          groups: groups,
          initialPrimaryGroupId: detail.primaryGroupId,
        ),
      ),
    );
    if (result == null || !mounted) {
      return;
    }
    await ref
        .read(contactRepositoryProvider)
        .setContactGroups(
          profileId: profileId,
          contactId: detail.contact.id,
          groupIds: result.primaryGroupId == null
              ? const <String>[]
              : <String>[result.primaryGroupId!],
          primaryGroupId: result.primaryGroupId,
        );
  }

  Future<void> _editAvailability(ContactDetail detail) async {
    final result = await Navigator.of(context).push<AvailabilityEditResult>(
      MaterialPageRoute<AvailabilityEditResult>(
        builder: (_) => AvailabilityEditor(initialWindows: detail.availability),
      ),
    );
    if (result == null || !mounted) return;
    await ref
        .read(contactRepositoryProvider)
        .setAvailability(
          profileId: ref.read(contactProfileIdProvider),
          contactId: detail.contact.id,
          windows: result.windows,
        );
  }

  Future<void> _editNotes(ContactDetail detail) async {
    final result = await Navigator.of(context).push<NotesEditResult>(
      MaterialPageRoute<NotesEditResult>(
        builder: (_) => NotesEditor(initialNotes: detail.notes),
      ),
    );
    if (result == null || !mounted) {
      return;
    }
    final repository = ref.read(contactRepositoryProvider);
    final profileId = ref.read(contactProfileIdProvider);
    for (final noteId in result.deletions) {
      await repository.deleteNote(profileId: profileId, noteId: noteId);
    }
    for (final entry in result.updates.entries) {
      await repository.updateNote(
        profileId: profileId,
        noteId: entry.key,
        text: entry.value,
      );
    }
    for (final text in result.additions) {
      await repository.addNote(
        profileId: profileId,
        contactId: detail.contact.id,
        text: text,
      );
    }
  }

  void _handleOverflow(String value, ContactDetail detail) {
    switch (value) {
      case 'edit':
        unawaited(context.push(RoutePaths.contactEdit(detail.contact.id)));
      case 'merge':
        unawaited(context.push(RoutePaths.mergeContacts));
      case 'archive':
        unawaited(_archive(detail.contact));
      case 'restore':
        unawaited(_restore(detail.contact));
    }
  }

  Future<void> _archive(Contact contact) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Archive contact?'),
        content: Text(
          '${contact.displayName} will disappear from active lists and '
          'selectors, but every Event, Task, and Timeline record stays '
          'intact and can be restored later.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Keep'),
          ),
          FilledButton(
            key: const Key('confirm-archive-contact'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Archive'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    final repository = ref.read(contactRepositoryProvider);
    final profileId = ref.read(contactProfileIdProvider);
    await repository.archiveContact(
      profileId: profileId,
      contactId: contact.id,
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${contact.displayName} archived.')),
      );
      unawaited(Navigator.of(context).maybePop());
    }
  }

  Future<void> _restore(Contact contact) async {
    final repository = ref.read(contactRepositoryProvider);
    final profileId = ref.read(contactProfileIdProvider);
    await repository.restoreContact(
      profileId: profileId,
      contactId: contact.id,
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${contact.displayName} restored.')),
      );
    }
  }
}

final class _TabBar extends StatelessWidget {
  const _TabBar({required this.selectedIndex, required this.onChanged});

  final int selectedIndex;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 48,
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: ContactReferenceStyle.lineOf(context),
            width: 1,
          ),
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final tabWidth = constraints.maxWidth / 2;
          return Stack(
            children: <Widget>[
              Row(
                children: <Widget>[
                  _TabItem(
                    key: const Key('profile-tab'),
                    label: 'Profile',
                    selected: selectedIndex == 0,
                    onTap: () => onChanged(0),
                  ),
                  _TabItem(
                    key: const Key('timeline-tab'),
                    label: 'Timeline',
                    selected: selectedIndex == 1,
                    onTap: () => onChanged(1),
                  ),
                ],
              ),
              AnimatedPositioned(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOutCubic,
                left: selectedIndex * tabWidth + (tabWidth - 56) / 2,
                bottom: 0,
                width: 56,
                height: 2,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: ContactReferenceStyle.actionOf(context),
                    borderRadius: BorderRadius.circular(1.5),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

final class _TabItem extends StatelessWidget {
  const _TabItem({
    required this.label,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Semantics(
        button: true,
        selected: selected,
        child: InkWell(
          onTap: onTap,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Text(
                label,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: selected
                      ? ContactReferenceStyle.actionOf(context)
                      : ContactReferenceStyle.onCanvasOf(context),
                ),
              ),
              const SizedBox(height: 4),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Profile tab
// ---------------------------------------------------------------------------

final class _ProfileTab extends ConsumerWidget {
  const _ProfileTab({
    required this.detail,
    required this.onFullEdit,
    required this.onEditContactInformation,
    required this.onEditAddressAndMap,
    required this.onEditGroups,
    required this.onEditAvailability,
    required this.onEditNotes,
    required this.onSeeMoreUpcoming,
  });

  final ContactDetail detail;
  final VoidCallback onFullEdit;
  final VoidCallback onEditContactInformation;
  final VoidCallback onEditAddressAndMap;
  final VoidCallback onEditGroups;
  final VoidCallback onEditAvailability;
  final VoidCallback onEditNotes;
  final VoidCallback onSeeMoreUpcoming;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final contact = detail.contact;
    final patterns =
        ref.watch(commonEventPatternsProvider(contact.id)).value ??
        const <CommonEventPattern>[];
    final timeline = ref.watch(contactTimelineProvider(contact.id)).value;
    final coordinate = ref
        .watch(contactProfileMapCoordinateProvider(contact.id))
        .value;
    final upcoming =
        timeline?.profileUpcoming ?? const <ContactTimelineEntry>[];

    return ListView(
      key: const Key('contact-profile-tab'),
      padding: const EdgeInsets.only(bottom: 24),
      children: <Widget>[
        _SectionHeader(
          title: 'Contact Information',
          action: _EditAction(label: 'Edit', onTap: onEditContactInformation),
        ),
        _ContactInformation(detail: detail),
        _SectionHeader(
          title: 'Address & Map',
          action: _EditAction(label: 'Edit', onTap: onEditAddressAndMap),
        ),
        _AddressMapSection(
          address: contact.addressText,
          coordinate: coordinate,
          onMapPreviewTap: coordinate == null
              ? null
              : () {
                  ref
                      .read(mapTransientFocusProvider.notifier)
                      .focusContact(
                        contactId: contact.id,
                        coordinate: coordinate,
                      );
                  context.go(RoutePaths.maps);
                },
        ),
        _SectionHeader(
          title: 'Groups',
          action: _EditAction(label: 'Edit', onTap: onEditGroups),
        ),
        _GroupsSection(
          groups: detail.groups,
          primaryGroupId: detail.primaryGroupId,
        ),
        _SectionHeader(
          title: 'Upcoming / Follow-Up',
          action: _SectionIconAction(
            tooltip: 'Create follow-up',
            onTap: () => _createFollowUp(context),
          ),
        ),
        _UpcomingSection(upcoming: upcoming, onSeeMore: onSeeMoreUpcoming),
        _SectionHeader(
          title: 'Availability',
          action: _EditAction(
            actionKey: const Key('profile-availability-edit'),
            label: 'Edit',
            onTap: onEditAvailability,
          ),
        ),
        _AvailabilitySection(windows: detail.availability, patterns: patterns),
        _SectionHeader(
          title: 'Notes',
          action: _EditAction(
            actionKey: const Key('profile-notes-edit'),
            label: 'Edit',
            onTap: onEditNotes,
          ),
        ),
        _NotesSection(notes: detail.notes),
        _SectionHeader(title: 'Record Details'),
        _RecordDetails(contact: contact),
      ],
    );
  }

  void _createFollowUp(BuildContext context) {
    final contact = detail.contact;
    unawaited(
      showModalBottomSheet<String>(
        context: context,
        builder: (sheetContext) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Create Follow-Up',
                  style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
                ),
              ),
              ListTile(
                key: const Key('follow-up-event'),
                leading: const Icon(Icons.event_outlined),
                title: const Text('Calendar Event'),
                onTap: () => Navigator.of(sheetContext).pop('event'),
              ),
              ListTile(
                key: const Key('follow-up-task'),
                leading: const Icon(Icons.task_alt),
                title: const Text('Task'),
                onTap: () => Navigator.of(sheetContext).pop('task'),
              ),
            ],
          ),
        ),
      ).then((value) async {
        if (value == null || !context.mounted) {
          return;
        }
        final intent = ContactFollowUpCreationIntent(contact.id);
        if (value == 'event') {
          await context.push(
            '${RoutePaths.calendarEventCreate}?contacts=${contact.id}',
            extra: intent,
          );
        } else {
          await context.push(
            '${RoutePaths.taskCreate}?contacts=${contact.id}',
            extra: intent,
          );
        }
      }),
    );
  }
}

final class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.action});

  final String title;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  title.toUpperCase(),
                  style: TextStyle(
                    color: ContactReferenceStyle.onCanvasOf(context),
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              ?action,
            ],
          ),
          const SizedBox(height: 8),
          Container(height: 1, color: ContactReferenceStyle.lineOf(context)),
        ],
      ),
    );
  }
}

final class _EditAction extends StatelessWidget {
  const _EditAction({required this.label, required this.onTap, this.actionKey});

  final String label;
  final VoidCallback onTap;
  final Key? actionKey;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      key: actionKey,
      onPressed: onTap,
      style: TextButton.styleFrom(
        minimumSize: const Size(48, 40),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        foregroundColor: ContactReferenceStyle.actionOf(context),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
      ),
      child: Text(label),
    );
  }
}

final class _SectionIconAction extends StatelessWidget {
  const _SectionIconAction({required this.tooltip, required this.onTap});

  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      key: const Key('create-follow-up'),
      tooltip: tooltip,
      onPressed: onTap,
      color: ContactReferenceStyle.actionOf(context),
      icon: const Icon(Icons.add, size: 24),
    );
  }
}

final class _ContactInformation extends StatelessWidget {
  const _ContactInformation({required this.detail});

  final ContactDetail detail;

  @override
  Widget build(BuildContext context) {
    final methods = detail.methods;
    final phone = methods
        .where((m) => m.type == ContactMethodType.phone)
        .toList();
    final email = methods
        .where((m) => m.type == ContactMethodType.email)
        .toList();
    final social = methods
        .where((m) => m.type == ContactMethodType.social)
        .toList();
    final rows = <Widget>[
      for (final method in phone)
        _InfoRow(
          primary: method.rawValue,
          secondary: _methodLabel(method.label ?? 'Phone', method.isPrimary),
          showBottomDivider: false,
          trailing: _HandoffButtons(
            onCall: _isValidPhone(method.rawValue)
                ? () => _handoff(context, 'call', method.rawValue)
                : null,
            onMessage:
                method.receivesTexts == true && _isValidPhone(method.rawValue)
                ? () => _handoff(context, 'message', method.rawValue)
                : null,
            showWhatsApp:
                method.hasWhatsApp == true && _isValidPhone(method.rawValue),
            onWhatsApp:
                method.hasWhatsApp == true && _isValidPhone(method.rawValue)
                ? () => _handoff(context, 'whatsapp', method.rawValue)
                : null,
          ),
        ),
      for (final method in email)
        _InfoRow(
          primary: method.rawValue,
          secondary: _methodLabel(method.label ?? 'Email', method.isPrimary),
          showBottomDivider: false,
          trailing: _HandoffButtons(
            onEmail: _isValidEmail(method.rawValue)
                ? () => _handoff(context, 'email', method.rawValue)
                : null,
          ),
        ),
      for (final method in social)
        _InfoRow(
          primary: method.rawValue,
          secondary: _methodLabel(
            socialProfileDisplayLabel(method.label),
            method.isPrimary,
          ),
          showBottomDivider: false,
          onTap: ExternalHandoff.isSupportedSocialPlatform(method.label)
              ? () => _handoff(
                  context,
                  'social',
                  method.rawValue,
                  platform: method.label,
                )
              : null,
          trailing: SizedBox(
            key: Key('social-trailing-action-${method.label ?? 'Other'}'),
            width: 48,
            height: 48,
            child: Center(
              child: _SocialIcon(
                label: method.label,
                // A recognised Social platform keeps its theme-primary icon
                // even if the native app is absent. The factual availability
                // prompt is shown only after the user taps it.
                active: ExternalHandoff.isSupportedSocialPlatform(method.label),
              ),
            ),
          ),
        ),
    ];
    if (rows.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Text('No contact methods added.'),
      );
    }
    return Column(children: rows);
  }

  static String _methodLabel(String label, bool preferred) =>
      preferred ? '$label · Preferred' : label;

  Future<void> _handoff(
    BuildContext context,
    String kind,
    String rawValue, {
    String? platform,
  }) async {
    bool launched;
    if (kind == 'whatsapp') {
      final localDigits = ExternalHandoff.philippineLocalWhatsAppDigits(
        rawValue,
      );
      if (localDigits != null) {
        final continueHandoff = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Open in WhatsApp?'),
            content: Text(
              '${rawValue.trim()} will be used as:\n'
              '${ExternalHandoff.displayInternationalDigits(localDigits)}',
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                key: const Key('whatsapp-local-continue'),
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('Continue'),
              ),
            ],
          ),
        );
        if (continueHandoff != true || !context.mounted) {
          return;
        }
        launched = await ExternalHandoff.launchWhatsAppDigits(localDigits);
      } else {
        launched = await ExternalHandoff.launchWhatsApp(rawValue);
        if (!launched && context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Use an international number for WhatsApp, or a Philippine '
                '09XXXXXXXXX mobile number.',
              ),
            ),
          );
          return;
        }
      }
    } else if (kind == 'social') {
      final result = await ExternalHandoff.launchSocialProfile(
        platform: platform,
        rawValue: rawValue,
      );
      if (!context.mounted) {
        return;
      }
      switch (result) {
        case SocialNativeAppLaunchResult.launched:
          launched = true;
        case SocialNativeAppLaunchResult.appRequired:
          await showDialog<void>(
            context: context,
            builder: (dialogContext) => AlertDialog(
              title: Text(ExternalHandoff.appRequiredTitle(platform)),
              content: Text(ExternalHandoff.appRequiredMessage(platform)),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('OK'),
                ),
              ],
            ),
          );
          return;
        case SocialNativeAppLaunchResult.unsupportedProfile:
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                '${ExternalHandoff.socialPlatformName(platform)} is not an '
                'active supported Social app.',
              ),
            ),
          );
          return;
      }
    } else {
      launched = switch (kind) {
        'call' => await ExternalHandoff.launchCall(rawValue),
        'message' => await ExternalHandoff.launchSms(rawValue),
        _ => await ExternalHandoff.launchEmail(rawValue),
      };
    }
    if (!launched) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No app is available for this handoff.'),
          ),
        );
      }
      return;
    }
    if (!context.mounted) {
      return;
    }
    // Returning from an external app creates NO factual outcome.  The only
    // record offered is an explicit user-typed note.
    await ExternalHandoff.showReturnSheet(
      context,
      contactDisplayName: detail.contact.displayName,
    );
  }

  static bool _isValidPhone(String value) =>
      value.replaceAll(RegExp(r'[^0-9]'), '').isNotEmpty;

  static bool _isValidEmail(String value) =>
      RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(value.trim());
}

final class _HandoffButtons extends StatelessWidget {
  const _HandoffButtons({
    this.onCall,
    this.onMessage,
    this.onWhatsApp,
    this.onEmail,
    this.showWhatsApp = false,
  });

  final VoidCallback? onCall;
  final VoidCallback? onMessage;
  final VoidCallback? onWhatsApp;
  final VoidCallback? onEmail;
  final bool showWhatsApp;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (showWhatsApp)
          IconButton(
            key: const Key('handoff-whatsapp'),
            tooltip: 'WhatsApp enabled',
            onPressed: onWhatsApp,
            icon: SvgPicture.asset(
              'assets/icons/contacts/social/whatsapp-action.svg',
              width: 22,
              height: 22,
              colorFilter: ColorFilter.mode(
                ContactReferenceStyle.actionOf(context),
                BlendMode.srcIn,
              ),
            ),
          ),
        if (onMessage != null)
          IconButton(
            key: const Key('handoff-message'),
            tooltip: 'Message',
            onPressed: onMessage,
            color: ContactReferenceStyle.actionOf(context),
            icon: const Icon(Icons.chat_bubble_outline, size: 22),
          ),
        if (onCall != null)
          IconButton(
            key: const Key('handoff-call'),
            tooltip: 'Call',
            onPressed: onCall,
            icon: SvgPicture.asset(
              'assets/icons/contacts/social/phone-action.svg',
              width: 22,
              height: 22,
              colorFilter: ColorFilter.mode(
                ContactReferenceStyle.actionOf(context),
                BlendMode.srcIn,
              ),
            ),
          ),
        if (onEmail != null)
          IconButton(
            key: const Key('handoff-email'),
            tooltip: 'Email',
            onPressed: onEmail,
            color: ContactReferenceStyle.actionOf(context),
            icon: const Icon(Icons.mail_outline, size: 22),
          ),
      ],
    );
  }
}

final class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.primary,
    required this.secondary,
    this.trailing,
    this.onTap,
    this.showBottomDivider = true,
  });

  final String primary;
  final String secondary;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool showBottomDivider;

  @override
  Widget build(BuildContext context) {
    final row = Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.symmetric(vertical: 9),
      decoration: showBottomDivider
          ? BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: ContactReferenceStyle.lineOf(context),
                ),
              ),
            )
          : null,
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  primary.isEmpty ? '—' : primary,
                  style: TextStyle(
                    color: ContactReferenceStyle.onCanvasOf(context),
                    fontSize: 17,
                    fontWeight: FontWeight.w400,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  secondary,
                  style: TextStyle(
                    color: ContactReferenceStyle.onCanvasOf(context),
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
    if (onTap == null) {
      return row;
    }
    return Semantics(
      button: true,
      label: 'Open $secondary',
      child: InkWell(onTap: onTap, child: row),
    );
  }
}

final class _SocialIcon extends StatelessWidget {
  const _SocialIcon({required this.label, required this.active});

  final String? label;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return contactMethodVisual(
      type: ContactMethodType.social,
      label: label ?? 'Other',
      color: active
          ? ContactReferenceStyle.actionOf(context)
          : AppTheme.secondaryTextOf(context),
      size: 22,
      normalizeSocialOptics: true,
    );
  }
}

final class _UpcomingSection extends StatelessWidget {
  const _UpcomingSection({required this.upcoming, required this.onSeeMore});

  final List<ContactTimelineEntry> upcoming;
  final VoidCallback onSeeMore;

  @override
  Widget build(BuildContext context) {
    if (upcoming.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Nothing scheduled yet.',
              style: TextStyle(color: AppTheme.secondaryTextOf(context)),
            ),
            const SizedBox(height: 8),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (var index = 0; index < upcoming.length && index < 3; index++)
          ListTile(
            key: upcoming[index].kind == ContactTimelineKind.plannerTask
                ? Key('profile-upcoming-task-${upcoming[index].taskId}')
                : upcoming
                      .take(index)
                      .every(
                        (entry) =>
                            entry.kind != ContactTimelineKind.eventOccurrence,
                      )
                ? const Key('profile-next-event')
                : Key('profile-upcoming-event-${upcoming[index].occurrenceId}'),
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            minTileHeight: 56,
            leading: Icon(
              upcoming[index].kind == ContactTimelineKind.plannerTask
                  ? Icons.task_alt
                  : Icons.event,
              color: upcoming[index].kind == ContactTimelineKind.plannerTask
                  ? AppTheme.warningOf(context)
                  : Theme.of(context).colorScheme.primary,
            ),
            title: Text(
              upcoming[index].title,
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
            subtitle: Text(upcoming[index].subtitle ?? ''),
            onTap: upcoming[index].kind == ContactTimelineKind.plannerTask
                ? upcoming[index].isTaskTappable
                      ? () => context.push(
                          '${RoutePaths.tasks}/${upcoming[index].taskId}',
                        )
                      : null
                : upcoming[index].isTappable
                ? () => context.push(
                    RoutePaths.calendarEventDetail(
                      upcoming[index].eventId!,
                      upcoming[index].originalDate!,
                    ),
                  )
                : null,
          ),
        if (upcoming.length > 3)
          SizedBox(
            height: 44,
            child: Center(
              child: TextButton(
                key: const Key('profile-upcoming-see-more'),
                onPressed: onSeeMore,
                child: const Text('See more →'),
              ),
            ),
          ),
      ],
    );
  }
}

final class _AvailabilitySection extends StatelessWidget {
  const _AvailabilitySection({required this.windows, required this.patterns});

  final List<ContactAvailability> windows;
  final List<CommonEventPattern> patterns;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final window in windows)
          ListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            leading: const Icon(Icons.schedule, size: 20),
            title: Text(
              '${_weekdayName(window.weekday)}  '
              '${_formatMinute(window.startMinute)} – ${_formatMinute(window.endMinute)}',
            ),
          ),
        if (windows.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
              'No availability entered.',
              style: TextStyle(color: AppTheme.secondaryTextOf(context)),
            ),
          ),
        if (patterns.isNotEmpty) ...<Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(
              'Common Event Times',
              style: TextStyle(
                color: AppTheme.secondaryTextOf(context),
                fontSize: 13,
              ),
            ),
          ),
          for (final pattern in patterns)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      pattern.title,
                      style: const TextStyle(fontSize: 14),
                    ),
                  ),
                  Text(
                    '${pattern.weekdayLabel} ${pattern.startMinuteLabel}',
                    style: TextStyle(
                      color: AppTheme.secondaryTextOf(context),
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${pattern.count}',
                    style: const TextStyle(
                      color: AppTheme.rose,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
        ],
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

final class _GroupsSection extends StatelessWidget {
  const _GroupsSection({required this.groups, required this.primaryGroupId});

  final List<ContactGroup> groups;
  final String? primaryGroupId;

  @override
  Widget build(BuildContext context) {
    final primary = groups.cast<ContactGroup?>().firstWhere(
      (group) => group?.id == primaryGroupId,
      orElse: () => null,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (primary != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: <Widget>[
                  Container(
                    width: 19,
                    height: 19,
                    decoration: BoxDecoration(
                      color: Color(primary.colorValue),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      primary.name,
                      style: const TextStyle(fontSize: 16),
                    ),
                  ),
                ],
              ),
            ),
          if (primary == null)
            Text(
              'No group',
              style: TextStyle(color: AppTheme.secondaryTextOf(context)),
            ),
        ],
      ),
    );
  }
}

final class _AddressMapSection extends StatelessWidget {
  const _AddressMapSection({
    required this.address,
    required this.coordinate,
    required this.onMapPreviewTap,
  });

  final String? address;
  final MapCoordinate? coordinate;
  final VoidCallback? onMapPreviewTap;

  @override
  Widget build(BuildContext context) {
    final hasAddress = address?.trim().isNotEmpty ?? false;
    if (!hasAddress && coordinate == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Text(
          'No address or map pin saved.',
          style: TextStyle(color: AppTheme.secondaryTextOf(context)),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (hasAddress)
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(address!, style: const TextStyle(fontSize: 16)),
                if (coordinate != null) ...<Widget>[
                  const SizedBox(height: 12),
                  _ProfileMapPreview(
                    coordinate: coordinate!,
                    onTap: onMapPreviewTap,
                  ),
                ],
              ],
            )
          else if (coordinate != null)
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                const Text('Saved map pin', style: TextStyle(fontSize: 16)),
                const SizedBox(height: 12),
                _ProfileMapPreview(
                  coordinate: coordinate!,
                  onTap: onMapPreviewTap,
                ),
              ],
            ),
        ],
      ),
    );
  }
}

final class _ProfileMapPreview extends StatelessWidget {
  const _ProfileMapPreview({required this.coordinate, required this.onTap});

  final MapCoordinate coordinate;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      key: const Key('profile-map-pin'),
      label: 'Saved map pin preview',
      button: true,
      child: InkWell(
        key: const Key('profile-map-preview'),
        onTap: onTap,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(
            width: double.infinity,
            height: 190,
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                IgnorePointer(
                  child: GoogleMap(
                    initialCameraPosition: CameraPosition(
                      target: LatLng(coordinate.latitude, coordinate.longitude),
                      zoom: 14,
                    ),
                    markers: <Marker>{
                      Marker(
                        markerId: const MarkerId('profile-location-preview'),
                        position: LatLng(
                          coordinate.latitude,
                          coordinate.longitude,
                        ),
                      ),
                    },
                    liteModeEnabled: true,
                    mapToolbarEnabled: false,
                    myLocationButtonEnabled: false,
                    zoomControlsEnabled: false,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

final class _NotesSection extends StatelessWidget {
  const _NotesSection({required this.notes});

  final List<ContactNote> notes;

  @override
  Widget build(BuildContext context) {
    if (notes.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Text(
          'No notes yet.',
          style: TextStyle(color: AppTheme.secondaryTextOf(context)),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        children: <Widget>[
          for (final note in notes)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Icon(
                    Icons.note_alt_outlined,
                    size: 24,
                    color: ContactReferenceStyle.actionOf(context),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          note.noteText,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 16),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Updated ${_shortDate(note.updatedAtUtc.toLocal())}',
                          style: TextStyle(
                            color: AppTheme.secondaryTextOf(context),
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  static String _shortDate(DateTime value) {
    const months = <String>[
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${months[value.month - 1]} ${value.day}, ${value.year}';
  }
}

final class _RecordDetails extends StatelessWidget {
  const _RecordDetails({required this.contact});

  final Contact contact;

  @override
  Widget build(BuildContext context) {
    final created = contact.createdAtUtc.toLocal();
    final updated = contact.updatedAtUtc.toLocal();
    const months = <String>[
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final createdLabel =
        '${months[created.month - 1]} ${created.day}, ${created.year}';
    final updatedLabel =
        '${months[updated.month - 1]} ${updated.day}, ${updated.year}';
    final origin = switch (contact.source) {
      ContactSource.manual => 'Manual',
      ContactSource.deviceImport => 'Device Import',
      ContactSource.betterCalendarImport => 'BetterCalendar Import',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _detailRow(context, 'Created', createdLabel),
          _detailRow(context, 'Updated', updatedLabel),
          _detailRow(context, 'Origin', origin),
        ],
      ),
    );
  }

  Widget _detailRow(BuildContext context, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: <Widget>[
          Icon(
            label == 'Created'
                ? Icons.calendar_today_outlined
                : label == 'Updated'
                ? Icons.edit_outlined
                : Icons.download_outlined,
            size: 20,
            color: AppTheme.secondaryTextOf(context),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: AppTheme.secondaryTextOf(context),
                fontSize: 13,
              ),
            ),
          ),
          Text(value, style: const TextStyle(fontSize: 15)),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Timeline tab
// ---------------------------------------------------------------------------

final class _TimelineTab extends ConsumerWidget {
  const _TimelineTab({required this.contactId});

  final String contactId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final timelineAsync = ref.watch(contactTimelineProvider(contactId));
    final eventColorsByTypeId = ref
        .watch(eventTypeControllerProvider)
        .resolvedEventColorsByTypeId;
    final patterns =
        ref.watch(commonEventPatternsProvider(contactId)).value ??
        const <CommonEventPattern>[];
    return timelineAsync.when(
      skipLoadingOnReload: true,
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, stack) =>
          const Center(child: Text('Timeline could not be opened.')),
      data: (timeline) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          CommonEventsPanel(patterns: patterns),
          Expanded(
            child: ContactTimelineView(
              timeline: timeline,
              eventColorsByTypeId: eventColorsByTypeId,
              contactId: contactId,
              onOpenEvent: (entry, anchor) async {
                await context.push(
                  RoutePaths.calendarEventDetail(
                    entry.eventId!,
                    entry.originalDate!,
                  ),
                  extra: CalendarEventDetailRouteExtra(
                    timelineOriginContactId: contactId,
                  ),
                );
                if (!context.mounted) return;
                await ref.read(contactTimelineProvider(contactId).future);
                if (!context.mounted) return;
                await WidgetsBinding.instance.endOfFrame;
                await anchor.restore();
              },
            ),
          ),
        ],
      ),
    );
  }
}
