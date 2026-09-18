import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rmplanner/app/theme/internal_screen.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/features/notifications/application/background_diagnostics_provider.dart';
import 'package:rmplanner/features/startup/application/startup_providers.dart';

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
  AsyncValue<BackgroundDiagnosticSnapshot>? _background;

  @override
  Widget build(BuildContext context) {
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
              onPressed: _preparePreview,
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
            if (_background != null) ...<Widget>[
              const SizedBox(height: 20),
              Text(
                'Background work',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              _background!.when(
                loading: () => const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: LinearProgressIndicator(),
                ),
                error: (_, _) => const Text('Background details unavailable.'),
                data: (snapshot) => Column(
                  children: <Widget>[
                    _BackgroundRow(
                      label: 'Notification scheduler',
                      value: snapshot.notificationAdapter.name,
                    ),
                    _BackgroundRow(
                      label: 'Background scheduler',
                      value: snapshot.backgroundAdapter.name,
                    ),
                    _BackgroundRow(
                      label: 'Pending reminders',
                      value: '${snapshot.pendingNativeReminderCount}',
                    ),
                    _BackgroundRow(
                      label: 'Recovery state',
                      value: snapshot.recoveryState,
                    ),
                    if (snapshot.recoveryAttempts != null)
                      _BackgroundRow(
                        label: 'Attempts',
                        value: '${snapshot.recoveryAttempts}',
                      ),
                    if (snapshot.lastAttemptAtUtc != null)
                      _BackgroundRow(
                        label: 'Last attempt',
                        value: _utcLabel(snapshot.lastAttemptAtUtc!),
                      ),
                    if (snapshot.nextEligibleAtUtc != null)
                      _BackgroundRow(
                        label: 'Next eligible',
                        value: _utcLabel(snapshot.nextEligibleAtUtc!),
                      ),
                    if (snapshot.completedAtUtc != null)
                      _BackgroundRow(
                        label: 'Completed',
                        value: _utcLabel(snapshot.completedAtUtc!),
                      ),
                    if (snapshot.recoveryFailureCategory != null)
                      _BackgroundRow(
                        label: 'Failure category',
                        value: snapshot.recoveryFailureCategory!,
                      ),
                    _BackgroundRow(
                      label: 'Worker state',
                      value: snapshot.workerState,
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _preparePreview() {
    final includeBackground = _includeOptionalContext;
    setState(() {
      _preview = ref
          .read(diagnosticsProvider)
          .prepareExportPreview(includeOptionalContext: includeBackground);
      // Background technical details appear only after an explicit Prepare
      // with the optional operational-details choice on.
      _background = includeBackground
          ? const AsyncLoading<BackgroundDiagnosticSnapshot>()
          : null;
    });
    if (includeBackground) {
      unawaited(_loadBackgroundSnapshot());
    }
  }

  Future<void> _loadBackgroundSnapshot() async {
    try {
      final snapshot = await ref.read(backgroundDiagnosticsProvider.future);
      if (!mounted || !_includeOptionalContext) return;
      setState(() {
        _background = AsyncData<BackgroundDiagnosticSnapshot>(snapshot);
      });
    } on Object catch (error, stackTrace) {
      if (!mounted || !_includeOptionalContext) return;
      setState(() {
        _background = AsyncError<BackgroundDiagnosticSnapshot>(
          error,
          stackTrace,
        );
      });
    }
  }

  static String _utcLabel(DateTime value) {
    final utc = value.toUtc();
    return '${utc.year.toString().padLeft(4, '0')}-'
        '${utc.month.toString().padLeft(2, '0')}-'
        '${utc.day.toString().padLeft(2, '0')} '
        '${utc.hour.toString().padLeft(2, '0')}:'
        '${utc.minute.toString().padLeft(2, '0')} UTC';
  }
}

final class _BackgroundRow extends StatelessWidget {
  const _BackgroundRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(title: Text(label), subtitle: Text(value)),
    );
  }
}
