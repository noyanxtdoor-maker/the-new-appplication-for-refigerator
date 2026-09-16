import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rmplanner/app/theme/app_theme.dart';
import 'package:rmplanner/app/theme/internal_screen.dart';
import 'package:rmplanner/features/contacts/application/contact_providers.dart';
import 'package:rmplanner/features/contacts/domain/contact.dart';
import 'package:rmplanner/features/privacy/application/privacy_providers.dart';
import 'package:rmplanner/features/privacy/domain/permission_summary.dart';

/// Reads device contacts as lightweight drafts.  Injectable so tests can
/// drive the whole import flow without a real address book.
typedef DeviceContactsReader = Future<List<DeviceContactDraft>> Function();

/// Asks for device-contacts access (real Android prompt when the OS will still
/// show one).  Injectable so tests can drive every outcome.
typedef DeviceContactsPermissionRequester =
    Future<OperatingSystemPermissionState> Function();

/// Reads device-contacts access WITHOUT prompting.  Used only on resume, so
/// returning from Android Settings can recover silently and never triggers a
/// second permission dialog.
typedef DeviceContactsPermissionChecker =
    Future<OperatingSystemPermissionState> Function();

/// Opens this app's Android Settings page.  Injectable for tests.
typedef DeviceContactsSettingsOpener = Future<bool> Function();

/// Default reader backed by flutter_contacts. It keeps the source phone label
/// solely so import can preserve an explicit mobile/fixed-line capability;
/// unknown labels remain unknown and no number is classified from its digits.
Future<List<DeviceContactDraft>> _readDeviceContacts() async {
  final contacts = await FlutterContacts.getAll(
    properties: const {
      ContactProperty.name,
      ContactProperty.phone,
      ContactProperty.email,
    },
  );
  return <DeviceContactDraft>[
    for (final contact in contacts)
      if ((contact.displayName ?? '').trim().isNotEmpty)
        DeviceContactDraft(
          displayName: contact.displayName!.trim(),
          firstName: contact.name?.first,
          lastName: contact.name?.last,
          phoneDetails: <DeviceContactPhone>[
            for (final phone in contact.phones)
              if (phone.number.trim().isNotEmpty)
                DeviceContactPhone(
                  value: phone.number.trim(),
                  sourceLabel: phone.label.label.name,
                ),
          ],
          emails: <String>[
            for (final email in contact.emails)
              if (email.address.trim().isNotEmpty) email.address.trim(),
          ],
        ),
  ];
}

/// Selected-only device contact import.
///
/// Permission is requested just in time, on an explicit user tap.  A denied
/// permission keeps every manual workflow fully functional.  Even with
/// permission granted, only the Contacts the user checks are imported; the
/// repository flags duplicates by normalized phone/email and never merges
/// silently.  Imported records stay in the local profile.
final class DeviceContactImportScreen extends ConsumerStatefulWidget {
  const DeviceContactImportScreen({
    this.deviceReader = _readDeviceContacts,
    this.permissionRequester,
    this.permissionChecker,
    this.settingsOpener,
    super.key,
  });

  final DeviceContactsReader deviceReader;

  /// Test seams.  Production resolves all three from the ONE canonical
  /// permission gateway ([PermissionHandlerGateway] via
  /// `permissionGatewayProvider`), so this screen never grows a second
  /// permission infrastructure.
  final DeviceContactsPermissionRequester? permissionRequester;
  final DeviceContactsPermissionChecker? permissionChecker;
  final DeviceContactsSettingsOpener? settingsOpener;

  @override
  ConsumerState<DeviceContactImportScreen> createState() =>
      _DeviceContactImportScreenState();
}

enum _ImportPhase {
  explain,
  loading,
  denied,
  permanentlyDenied,
  failed,
  select,
  importing,
  result,
}

final class _DeviceContactImportScreenState
    extends ConsumerState<DeviceContactImportScreen>
    with WidgetsBindingObserver {
  _ImportPhase _phase = _ImportPhase.explain;
  List<DeviceContactDraft> _deviceContacts = <DeviceContactDraft>[];
  final Set<int> _selectedIndexes = <int>{};
  final TextEditingController _searchController = TextEditingController();
  String _query = '';
  String? _error;
  ContactImportResult? _result;

  /// True once the user has explicitly started an import.  A resume that finds
  /// access now granted can then continue the SAME intent instead of leaving a
  /// stale denied screen behind.
  bool _importIntentActive = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _searchController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !_importIntentActive) {
      return;
    }
    if (_phase != _ImportPhase.denied &&
        _phase != _ImportPhase.permanentlyDenied) {
      return;
    }
    unawaited(_recoverAfterSettings());
  }

  /// Passive recovery only — it NEVER prompts.  If the user opened Android
  /// Settings, enabled Contacts and came back, the import continues on its own.
  Future<void> _recoverAfterSettings() async {
    final state = await _checkPermission();
    if (!mounted || state != OperatingSystemPermissionState.granted) {
      return;
    }
    await _loadSelection();
  }

  Future<OperatingSystemPermissionState> _requestPermission() {
    final override = widget.permissionRequester;
    if (override != null) {
      return override();
    }
    return ref
        .read(permissionGatewayProvider)
        .request(OptionalPermission.contacts);
  }

  Future<OperatingSystemPermissionState> _checkPermission() {
    final override = widget.permissionChecker;
    if (override != null) {
      return override();
    }
    return ref
        .read(permissionGatewayProvider)
        .status(OptionalPermission.contacts);
  }

  Future<bool> _openSettings() {
    final override = widget.settingsOpener;
    if (override != null) {
      return override();
    }
    return ref.read(permissionGatewayProvider).openSystemSettings();
  }

  List<int> get _visibleIndexes {
    final query = _query.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    if (query.isEmpty) {
      return List<int>.generate(_deviceContacts.length, (i) => i);
    }
    final queryDigits = query.replaceAll(RegExp(r'[^0-9]'), '');
    return <int>[
      for (var i = 0; i < _deviceContacts.length; i++)
        if (_matches(_deviceContacts[i], query, queryDigits)) i,
    ];
  }

  bool _matches(DeviceContactDraft draft, String query, String queryDigits) {
    final name = draft.displayName.toLowerCase().replaceAll(
      RegExp(r'\s+'),
      ' ',
    );
    if (name.contains(query)) {
      return true;
    }
    if (draft.emails.any(
      (email) => email.trim().toLowerCase().contains(query),
    )) {
      return true;
    }
    return queryDigits.isNotEmpty &&
        draft.phones.any(
          (phone) =>
              phone.replaceAll(RegExp(r'[^0-9]'), '').contains(queryDigits),
        );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: InternalAppBar(title: const Text('Import from Device')),
      body: switch (_phase) {
        _ImportPhase.explain => _buildExplain(),
        _ImportPhase.loading => const Center(
          child: CircularProgressIndicator(),
        ),
        _ImportPhase.denied => _buildDenied(),
        _ImportPhase.permanentlyDenied => _buildPermanentlyDenied(),
        _ImportPhase.failed => _buildFailed(),
        _ImportPhase.select => _buildSelect(),
        _ImportPhase.importing => const Center(
          child: CircularProgressIndicator(),
        ),
        _ImportPhase.result => _buildResult(),
      },
    );
  }

  Widget _buildExplain() {
    return ListView(
      padding: InternalScreen.pagePadding,
      children: <Widget>[
        const SizedBox(height: 8),
        const Icon(Icons.contact_page_outlined, size: 56),
        const SizedBox(height: 16),
        const Text(
          'Import selected contacts from your device',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 12),
        Text(
          'Only the contacts you select are imported, and they stay on this '
          'device inside your private profile. Nothing is uploaded.',
          style: TextStyle(
            color: AppTheme.secondaryTextOf(context),
            fontSize: 14,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Next Transfer only reads names and phone/email values — never '
          'messages, call logs, or photos.',
          style: TextStyle(
            color: AppTheme.secondaryTextOf(context),
            fontSize: 14,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 24),
        FilledButton.icon(
          key: const Key('device-import-start'),
          onPressed: () => unawaited(_startImport()),
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(50),
            backgroundColor: Theme.of(context).colorScheme.primary,
            foregroundColor: Theme.of(context).colorScheme.onPrimary,
          ),
          icon: const Icon(Icons.contact_page_outlined, size: 20),
          label: const Text('Import from device'),
        ),
      ],
    );
  }

  Widget _buildDenied() {
    return ListView(
      padding: InternalScreen.pagePadding,
      children: <Widget>[
        const SizedBox(height: 8),
        const Icon(Icons.contact_page_outlined, size: 56),
        const SizedBox(height: 16),
        const Text(
          'Permission denied',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
        ),
        if (_error != null) ...<Widget>[
          const SizedBox(height: 8),
          Text(
            _error!,
            style: TextStyle(color: AppTheme.warningOf(context), fontSize: 14),
          ),
        ],
        const SizedBox(height: 12),
        Text(
          'Contacts stay in your head and your manual workflow. You can still '
          'create, edit, search, group, and link contacts by hand, and '
          'everything continues to work offline.',
          style: TextStyle(
            color: AppTheme.secondaryTextOf(context),
            fontSize: 14,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 24),
        FilledButton(
          key: const Key('device-import-denied-done'),
          onPressed: () => Navigator.of(context).maybePop(),
          child: const Text('Continue without import'),
        ),
        const SizedBox(height: 8),
        TextButton(
          key: const Key('device-import-retry'),
          onPressed: () => unawaited(_startImport()),
          child: const Text('Try again'),
        ),
      ],
    );
  }

  /// M6 FINAL CORRECTION: Android is blocking access, so the OS prompt can no
  /// longer appear.  Explain that truthfully and route the user to the one
  /// place that can change it.
  Widget _buildPermanentlyDenied() {
    return ListView(
      padding: InternalScreen.pagePadding,
      children: <Widget>[
        const SizedBox(height: 8),
        const Icon(Icons.lock_outline, size: 56),
        const SizedBox(height: 16),
        const Text(
          'Contacts access is turned off',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 12),
        Text(
          'Android is blocking contact access for Next Transfer, so the phone '
          'will not show the permission prompt again. Turn Contacts on for '
          'Next Transfer in Android Settings, then come back — this screen '
          'continues on its own. Manual contact workflows keep working '
          'without it.',
          style: TextStyle(
            color: AppTheme.secondaryTextOf(context),
            fontSize: 14,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 24),
        FilledButton(
          key: const Key('device-import-open-settings'),
          onPressed: () => unawaited(_openSettings()),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
          child: const Text('Open Android Settings'),
        ),
        const SizedBox(height: 8),
        TextButton(
          key: const Key('device-import-settings-done'),
          onPressed: () => Navigator.of(context).maybePop(),
          child: const Text('Continue without import'),
        ),
      ],
    );
  }

  Widget _buildFailed() {
    return ListView(
      padding: InternalScreen.pagePadding,
      children: <Widget>[
        const SizedBox(height: 8),
        const Icon(Icons.error_outline, size: 56),
        const SizedBox(height: 16),
        const Text(
          'Contacts could not be read',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 12),
        Text(
          _error ??
              'This device could not provide its contact list right now. '
                  'Manual contact workflows are unaffected.',
          style: TextStyle(
            color: AppTheme.secondaryTextOf(context),
            fontSize: 14,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 24),
        FilledButton(
          key: const Key('device-import-failed-done'),
          onPressed: () => Navigator.of(context).maybePop(),
          child: const Text('Continue without import'),
        ),
        const SizedBox(height: 8),
        TextButton(
          key: const Key('device-import-failed-retry'),
          onPressed: () => unawaited(_startImport()),
          child: const Text('Try again'),
        ),
      ],
    );
  }

  Widget _buildSelect() {
    final selectedCount = _selectedIndexes.length;
    final visibleIndexes = _visibleIndexes;
    final hasQuery = _query.trim().isNotEmpty;
    final allVisibleSelected =
        visibleIndexes.isNotEmpty &&
        visibleIndexes.every(_selectedIndexes.contains);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '$selectedCount of ${_deviceContacts.length} selected',
                  style: TextStyle(
                    color: AppTheme.secondaryTextOf(context),
                    fontSize: 13,
                  ),
                ),
              ),
              TextButton(
                key: const Key('device-import-select-all'),
                onPressed: () => setState(() {
                  if (allVisibleSelected) {
                    _selectedIndexes.removeAll(visibleIndexes);
                  } else {
                    _selectedIndexes.addAll(visibleIndexes);
                  }
                }),
                child: Text(
                  allVisibleSelected
                      ? 'Select None'
                      : hasQuery
                      ? 'Select visible'
                      : 'Select All',
                ),
              ),
            ],
          ),
        ),
        // POST-M7 CLOSURE: a returned-to selection screen must explain itself.
        // Previously a validation rejection landed here with no message at all.
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text(
              _error!,
              key: const Key('device-import-error'),
              style: TextStyle(
                color: AppTheme.warningOf(context),
                fontSize: 13,
                height: 1.35,
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: TextField(
            key: const Key('device-import-search'),
            controller: _searchController,
            onChanged: (value) => setState(() => _query = value),
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              labelText: 'Search contacts',
            ),
          ),
        ),
        const Divider(height: 1, thickness: 1),
        Expanded(
          child: _deviceContacts.isEmpty
              ? Center(
                  child: Text(
                    'No contacts found on this device.',
                    style: TextStyle(color: AppTheme.secondaryTextOf(context)),
                  ),
                )
              : visibleIndexes.isEmpty
              ? const Center(child: Text('No matching contacts.'))
              : ListView.builder(
                  key: const Key('device-import-list'),
                  itemCount: visibleIndexes.length,
                  itemBuilder: (context, visibleIndex) {
                    final index = visibleIndexes[visibleIndex];
                    final draft = _deviceContacts[index];
                    final methodText = <String>[
                      ...draft.resolvedPhones
                          .take(2)
                          .map((phone) => phone.value),
                      ...draft.emails.take(1),
                    ].join(' • ');
                    return CheckboxListTile(
                      key: Key('device-import-row-$index'),
                      value: _selectedIndexes.contains(index),
                      onChanged: (value) => setState(() {
                        if (value == true) {
                          _selectedIndexes.add(index);
                        } else {
                          _selectedIndexes.remove(index);
                        }
                      }),
                      activeColor: Theme.of(context).colorScheme.primary,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: Text(
                        draft.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      subtitle: methodText.isEmpty
                          ? null
                          : Text(
                              methodText,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 13),
                            ),
                    );
                  },
                ),
        ),
        const Divider(height: 1, thickness: 1),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
            child: FilledButton(
              key: const Key('device-import-confirm'),
              onPressed: selectedCount == 0 ? null : () => unawaited(_import()),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(50),
                backgroundColor: Theme.of(context).colorScheme.primary,
                foregroundColor: Theme.of(context).colorScheme.onPrimary,
                disabledBackgroundColor: AppTheme.surfaceVariantOf(context),
                disabledForegroundColor: AppTheme.disabledForegroundOf(context),
              ),
              child: Text(
                selectedCount == 0
                    ? 'Select contacts'
                    : 'Import $selectedCount',
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildResult() {
    final result = _result;
    if (result == null) {
      return const SizedBox.shrink();
    }
    return ListView(
      padding: InternalScreen.pagePadding,
      children: <Widget>[
        const SizedBox(height: 8),
        Icon(
          result.createdCount > 0
              ? Icons.check_circle_outline
              : Icons.info_outline,
          size: 56,
          color: result.createdCount > 0
              ? AppTheme.rose
              : AppTheme.secondaryTextOf(context),
        ),
        const SizedBox(height: 16),
        Text(
          result.createdCount > 0
              ? '${result.createdCount} contact'
                    '${result.createdCount == 1 ? '' : 's'} imported'
              : 'Nothing new imported',
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
        ),
        if (result.skippedCount > 0) ...<Widget>[
          const SizedBox(height: 8),
          Text(
            '${result.skippedCount} skipped — already in your contacts, or not '
            'enough information to store.',
            style: TextStyle(
              color: AppTheme.secondaryTextOf(context),
              fontSize: 14,
              height: 1.35,
            ),
          ),
        ],
        const SizedBox(height: 8),
        if (result.duplicateContactIds.isNotEmpty) ...<Widget>[
          Text(
            'Possible duplicates were NOT merged — they were left untouched:',
            style: TextStyle(
              color: AppTheme.secondaryTextOf(context),
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 8),
          for (final name in result.duplicateContactIds.take(8))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: <Widget>[
                  Icon(
                    Icons.warning_amber_outlined,
                    size: 16,
                    color: AppTheme.warningOf(context),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(name, style: const TextStyle(fontSize: 14)),
                  ),
                ],
              ),
            ),
        ],
        const SizedBox(height: 24),
        FilledButton(
          key: const Key('device-import-done'),
          onPressed: () => Navigator.of(context).maybePop(),
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(50),
            backgroundColor: Theme.of(context).colorScheme.primary,
            foregroundColor: Theme.of(context).colorScheme.onPrimary,
          ),
          child: const Text('Done'),
        ),
      ],
    );
  }

  Future<void> _startImport() async {
    _importIntentActive = true;
    setState(() {
      _phase = _ImportPhase.loading;
      _error = null;
    });
    try {
      final state = await _requestPermission();
      if (!mounted) {
        return;
      }
      switch (state) {
        case OperatingSystemPermissionState.granted:
          break;
        // Android will not show the dialog again; the user needs Settings, and
        // pretending otherwise would trap them in a retry that cannot work.
        case OperatingSystemPermissionState.permanentlyDenied:
        case OperatingSystemPermissionState.restricted:
          setState(() => _phase = _ImportPhase.permanentlyDenied);
          return;
        case OperatingSystemPermissionState.denied:
        case OperatingSystemPermissionState.unavailable:
          setState(() => _phase = _ImportPhase.denied);
          return;
      }
      await _loadSelection();
    } on Object {
      if (mounted) {
        setState(() {
          _error = 'Device contacts could not be read.';
          _phase = _ImportPhase.failed;
        });
      }
    }
  }

  /// Reads the address book and moves to selection.  Shared by the explicit
  /// start action and the no-prompt resume recovery.
  Future<void> _loadSelection() async {
    try {
      final drafts = await widget.deviceReader();
      if (!mounted) {
        return;
      }
      setState(() {
        _deviceContacts = drafts;
        _selectedIndexes.clear();
        _phase = _ImportPhase.select;
      });
    } on Object {
      if (mounted) {
        setState(() {
          _error = 'Device contacts could not be read.';
          _phase = _ImportPhase.failed;
        });
      }
    }
  }

  Future<void> _import() async {
    setState(() => _phase = _ImportPhase.importing);
    final drafts = <DeviceContactDraft>[
      for (final index in _selectedIndexes.toList()..sort())
        _deviceContacts[index],
    ];
    try {
      final result = await ref
          .read(contactRepositoryProvider)
          .importDeviceContacts(
            profileId: ref.read(contactProfileIdProvider),
            drafts: drafts,
          );
      if (!mounted) {
        return;
      }
      setState(() {
        _error = null;
        _result = result;
        _phase = _ImportPhase.result;
      });
    } on ContactValidationException catch (error) {
      if (mounted) {
        setState(() {
          _error = error.message;
          _phase = _ImportPhase.select;
        });
      }
    } on Object {
      // POST-M7 CLOSURE: an unexpected failure used to escape this handler, so
      // the spinner stayed up forever and nothing was explained.  Say what
      // happened instead, and never pretend the batch was clean.
      if (mounted) {
        setState(() {
          _error =
              'The import could not be completed. Any contacts imported '
              'before this point were kept.';
          _phase = _ImportPhase.select;
        });
      }
    }
  }
}
