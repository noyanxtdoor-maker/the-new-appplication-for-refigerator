import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rmplanner/app/theme/internal_screen.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/features/notifications/application/background_diagnostic_rows.dart';
import 'package:rmplanner/features/notifications/application/background_diagnostics_provider.dart';
import 'package:rmplanner/features/notifications/application/notification_providers.dart';
import 'package:rmplanner/features/startup/application/startup_providers.dart';
import 'package:rmplanner/features/startup/domain/startup_state.dart';

final class DiagnosticPreviewScreen extends ConsumerStatefulWidget {
  const DiagnosticPreviewScreen({super.key});

  @override
  ConsumerState<DiagnosticPreviewScreen> createState() =>
      _DiagnosticPreviewScreenState();
}

final class _DiagnosticPreviewScreenState
    extends ConsumerState<DiagnosticPreviewScreen> {
  bool _includeOptionalContext = false;
  DiagnosticExportPreview? _preview;
  BackgroundDiagnosticSnapshot? _background;
  bool _backgroundUnavailable = false;

  @override
  Widget build(BuildContext context) {
    final background = _background;
    return Scaffold(
      appBar: InternalAppBar(title: const Text('Diagnostic export preview')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: <Widget>[
            const Text(
              'Nothing is exported automatically. Raw calendar imports, '
              'private text, precise locations, document references, and '
              'authentication secrets are never included.',
            ),
            const SizedBox(height: 16),
            CheckboxListTile(
              key: const Key('diagnostic-context-checkbox'),
              value: _includeOptionalContext,
              onChanged: (value) {
                setState(() {
                  _includeOptionalContext = value ?? false;
                  _preview = null;
                  _background = null;
                  _backgroundUnavailable = false;
                });
              },
              title: const Text('Include approved operational details'),
              subtitle: const Text(
                'Limited to allow-listed scalar fields such as database state '
                'and schema version. Review the preview below.',
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              key: const Key('prepare-diagnostic-preview-button'),
              onPressed: () {
                setState(() {
                  _preview = ref
                      .read(diagnosticsProvider)
                      .prepareExportPreview(
                        includeOptionalContext: _includeOptionalContext,
                      );
                  _background = null;
                  _backgroundUnavailable = false;
                });
                if (_includeOptionalContext) {
                  unawaited(_prepareBackground());
                }
              },
              icon: const Icon(Icons.preview_outlined),
              label: const Text('Prepare review preview'),
            ),
            const SizedBox(height: 20),
            if (_preview == null)
              const Text('Prepare a preview to review sanitized event codes.')
            else ...[
              Semantics(
                liveRegion: true,
                child: Text(
                  '${_preview!.events.length} sanitized events ready for review',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              if (_preview!.events.isEmpty)
                const Text('No diagnostic events are currently recorded.')
              else
                for (final event in _preview!.events)
                  Card(
                    child: ListTile(
                      title: Text(event.code),
                      subtitle: event.safeContext.isEmpty
                          ? const Text('No optional details included')
                          : Text(event.safeContext.toString()),
                    ),
                  ),
              const SizedBox(height: 12),
              const Text(
                'Preview only — no file or message has been created or shared.',
              ),
            ],
            // Background operational details appear ONLY after an explicit
            // Prepare AND the applicable operational-details choice.  They are
            // typed technical facts (enums, counts, booleans, UTC timestamps)
            // and never contain owner source content or identifiers.
            if (_includeOptionalContext && _backgroundUnavailable) ...[
              const SizedBox(height: 20),
              _backgroundHeading(context),
              const SizedBox(height: 8),
              const Text('Background details unavailable.'),
            ],
            if (_includeOptionalContext && background != null) ...[
              const SizedBox(height: 20),
              _backgroundHeading(context),
              const SizedBox(height: 8),
              for (final row in _backgroundRows(background))
                Card(
                  child: ListTile(title: Text(row.$1), subtitle: Text(row.$2)),
                ),
            ],
          ],
        ),
      ),
    );
  }

  static Widget _backgroundHeading(BuildContext context) => Text(
    'Background work',
    style: Theme.of(
      context,
    ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
  );

  Future<void> _prepareBackground() async {
    try {
      final startup = ref.read(startupControllerProvider);
      final profileId =
          ref.read(reminderRuntimeProfileIdProvider) ??
          (startup is StartupReady ? startup.profile.id : null);
      if (profileId == null) {
        if (!mounted) return;
        setState(() => _backgroundUnavailable = true);
        return;
      }
      final snapshot = await ref
          .read(backgroundDiagnosticsProvider)
          .snapshot(profileId: profileId);
      if (!mounted) return;
      setState(() {
        _background = snapshot;
        _backgroundUnavailable = false;
      });
    } on Object {
      // Never surface a raw error string; the operational details simply are
      // not available right now.
      if (!mounted) return;
      setState(() {
        _background = null;
        _backgroundUnavailable = true;
      });
    }
  }

  /// The privacy-safe projection lives in ONE place so the exact text this
  /// screen renders is the text the privacy contract can be asserted against.
  List<(String, String)> _backgroundRows(BackgroundDiagnosticSnapshot s) =>
      BackgroundDiagnosticRows.of(s);
}
