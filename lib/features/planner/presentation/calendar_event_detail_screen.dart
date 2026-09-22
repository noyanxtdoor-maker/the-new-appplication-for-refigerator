import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:rmplanner/app/router/route_names.dart';
import 'package:rmplanner/app/theme/internal_screen.dart';
import 'package:rmplanner/features/contacts/application/contact_providers.dart';
import 'package:rmplanner/features/contacts/domain/contact.dart';
import 'package:rmplanner/features/maps/application/map_coordinate_repository.dart';
import 'package:rmplanner/features/maps/application/map_providers.dart';
import 'package:rmplanner/features/maps/domain/map_coordinate.dart';
import 'package:rmplanner/features/maps/presentation/map_pin_section.dart';
import 'package:rmplanner/features/planner/application/calendar_event_providers.dart';
import 'package:rmplanner/features/planner/application/outcome_reporting_providers.dart';
import 'package:rmplanner/features/planner/application/planner_providers.dart';
import 'package:rmplanner/features/planner/domain/calendar_event.dart';
import 'package:rmplanner/features/planner/domain/event_type.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/presentation/widgets/anchored_top_bar_popup.dart';
import 'package:rmplanner/features/planner/presentation/widgets/event_contact_channel_visuals.dart';
import 'package:rmplanner/features/planner/presentation/widgets/planner_current_status_controls.dart';
import 'package:rmplanner/features/planner/presentation/widgets/planner_detail_primitives.dart';
import 'package:rmplanner/features/planner/presentation/widgets/planner_event_report_status.dart';
import 'package:rmplanner/features/planner/presentation/widgets/planner_top_bar_icons.dart';
import 'package:rmplanner/features/planner/presentation/widgets/repeating_event_scope_choices.dart';

enum _CalendarEventDetailAction { duplicate, delete }

final class _EventDetailMapSection extends ConsumerWidget {
  const _EventDetailMapSection({
    required this.profileId,
    required this.eventId,
    required this.occurrenceId,
    required this.originalDate,
    required this.renderedDate,
  });

  final String profileId;
  final String eventId;
  final String occurrenceId;
  final PlannerDate originalDate;
  final PlannerDate renderedDate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FutureBuilder<MapCoordinate?>(
      future: ref
          .read(mapCoordinateRepositoryProvider)
          .readCoordinate(
            profileId: profileId,
            owner: MapCoordinateOwner.event,
            recordId: eventId,
          ),
      builder: (context, snapshot) {
        final coordinate = snapshot.data;
        if (coordinate == null) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(top: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text(
                'Map',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Semantics(
                button: true,
                label: 'Show this Event occurrence on Maps',
                child: InkWell(
                  key: const Key('event-map-focus'),
                  borderRadius: BorderRadius.circular(12),
                  onTap: () {
                    ref
                        .read(mapTransientFocusProvider.notifier)
                        .focusEventOccurrence(
                          eventId: eventId,
                          occurrenceId: occurrenceId,
                          originalDate: originalDate,
                          renderedDate: renderedDate,
                          coordinate: coordinate,
                        );
                    context.go(RoutePaths.maps);
                  },
                  child: ContactLocationPreview(coordinate: coordinate),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

final class _EventDetailContactsSection extends ConsumerWidget {
  const _EventDetailContactsSection({
    required this.profileId,
    required this.eventId,
    required this.occurrenceId,
    required this.historical,
    this.timelineOriginContactId,
  });

  final String profileId;
  final String eventId;
  final String occurrenceId;
  final bool historical;
  final String? timelineOriginContactId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FutureBuilder<List<EventParticipantPresentation>>(
      future: ref
          .read(contactRepositoryProvider)
          .readEventParticipantPresentation(
            profileId: profileId,
            eventId: eventId,
            occurrenceId: occurrenceId,
            historical: historical,
          ),
      builder: (context, snapshot) {
        final people = snapshot.data;
        if (people == null || people.isEmpty) return const SizedBox.shrink();
        final summaries = ref.watch(
          contactSummariesByCsvProvider(
            people.map((person) => person.contactId).join(','),
          ),
        );
        final summariesById =
            summaries.asData?.value ?? const <String, ContactSummary>{};
        return Padding(
          padding: const EdgeInsets.only(top: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text(
                'Contacts',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              for (final person in people)
                PlannerPreviewContactLink(
                  key: Key('event-preview-contact-${person.contactId}'),
                  contactId: person.contactId,
                  name: person.displayName,
                  contact: summariesById[person.contactId],
                  timelineOriginContactId: timelineOriginContactId,
                ),
            ],
          ),
        );
      },
    );
  }
}

final class CalendarEventDetailScreen extends ConsumerStatefulWidget {
  const CalendarEventDetailScreen({
    required this.eventId,
    required this.originalDate,
    this.sheetPresentation = false,
    this.initialHeading,
    this.timelineOriginContactId,
    super.key,
  });

  final String eventId;
  final PlannerDate originalDate;
  final bool sheetPresentation;
  final String? timelineOriginContactId;

  /// NX-05: identity the caller already knows at open time (the tapped
  /// planner item's activity-type label / display title).  When set, the
  /// heading is truthful from the FIRST rendered frame so the sheet never
  /// morphs from the generic 'Calendar Event'.  Deep-link entries with no
  /// synchronous label keep the generic default and resolve after load.
  final String? initialHeading;

  @override
  ConsumerState<CalendarEventDetailScreen> createState() =>
      _CalendarEventDetailScreenState();
}

final class _CalendarEventDetailScreenState
    extends ConsumerState<CalendarEventDetailScreen> {
  late Future<CalendarEventOccurrence?> _load;
  late Future<_EventReportingSnapshot> _reporting;
  late String _detailHeading;
  bool? _isStructurallyCancelled;
  final GlobalKey _overflowAnchorKey = GlobalKey();
  _EventReportingSnapshot _reportingSnapshot =
      const _EventReportingSnapshot.empty();

  @override
  void initState() {
    super.initState();
    // NX-05: the heading starts as the caller-known identity when provided
    // (never the generic 'Calendar Event' morph); otherwise the truthful
    // deep-link fallback resolves after the occurrence load.
    _detailHeading = widget.initialHeading?.trim().isNotEmpty == true
        ? widget.initialHeading!
        : 'Calendar Event';
    _reload();
  }

  void _reload() {
    final future = ref
        .read(calendarEventControllerProvider.notifier)
        .readOccurrence(
          eventId: widget.eventId,
          originalDate: widget.originalDate,
        );
    _load = future;
    final reporting = _readEventReporting(
      eventId: widget.eventId,
      originalDate: widget.originalDate,
    );
    _reporting = reporting;
    unawaited(
      reporting.then((value) {
        if (mounted) {
          setState(() => _reportingSnapshot = value);
        }
      }),
    );
    unawaited(
      future.then((occurrence) {
        if (!mounted || occurrence == null) {
          return;
        }
        final nextHeading =
            occurrence.activityTypeLabel?.trim().isNotEmpty == true
            ? occurrence.activityTypeLabel!
            : occurrence.displayTitle;
        final nextCancelled = occurrence.isStructurallyCancelled;
        if ((nextHeading.isNotEmpty && nextHeading != _detailHeading) ||
            nextCancelled != _isStructurallyCancelled) {
          setState(() {
            if (nextHeading.isNotEmpty) {
              _detailHeading = nextHeading;
            }
            _isStructurallyCancelled = nextCancelled;
          });
        }
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final message = ref.watch(calendarEventControllerProvider);
    final content = FutureBuilder<CalendarEventOccurrence?>(
      future: _load,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final occurrence = snapshot.data;
        if (occurrence == null) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'This Calendar Event occurrence is no longer available. '
                'No local record was changed.',
                textAlign: TextAlign.center,
              ),
            ),
          );
        }
        final nowUtc = DateTime.now().toUtc();
        final displayToday = PlannerDate.fromDateTime(DateTime.now());
        final isFuture = occurrence.timing == CalendarEventTiming.allDay
            ? occurrence.displayDate.compareTo(displayToday) > 0
            : occurrence.startUtc?.isAfter(nowUtc) ?? false;
        final isHistorical = occurrence.timing == CalendarEventTiming.allDay
            ? occurrence.displayDate.compareTo(displayToday) < 0
            : occurrence.endUtc?.isBefore(nowUtc) ?? false;
        final showStatus =
            occurrence.requiresReport &&
            !isFuture &&
            !occurrence.isStructurallyCancelled;
        final eventTypeLabel = occurrence.activityTypeLabel;
        final isContactEvent = _isContactEvent(
          occurrence.activityTypeStableKey,
          eventTypeLabel,
        );
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
          children: <Widget>[
            if (occurrence.isStructurallyCancelled) ...<Widget>[
              Container(
                key: const Key('cancelled-event-read-only-banner'),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Row(
                  children: <Widget>[
                    Icon(Icons.cancel_outlined, size: 18),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Cancelled Event · Read only',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ),
              if (occurrence.reportedStatus
                  case final reportedStatus?) ...<Widget>[
                const SizedBox(height: 8),
                _DetailField(
                  key: const Key('cancelled-event-reported-outcome'),
                  icon: Icons.fact_check_outlined,
                  label: 'Reported outcome',
                  value: calendarEventStatusLabel(reportedStatus),
                ),
              ],
              const SizedBox(height: 12),
              const Divider(height: 1),
              const SizedBox(height: 12),
            ],
            // The compact four-state status row sits immediately below the
            // app bar: the current status label on the left and the four
            // direct-selection controls on the right. Details begin directly
            // beneath it. There is deliberately no Schedule Next Appointment,
            // Reschedule, or other hero/action CTA in this area.
            if (showStatus)
              FutureBuilder<_EventReportingSnapshot>(
                future: _reporting,
                builder: (context, reporting) => _EventStatusControlRow(
                  currentStatus: occurrence.status,
                  hasReportedHistory:
                      occurrence.status != CalendarEventStatus.scheduled ||
                      reporting.connectionState != ConnectionState.done ||
                      (reporting.data ?? _reportingSnapshot).hasReportedHistory,
                  isContactEvent: isContactEvent,
                  onSelect: (selected) =>
                      _handleStatusTap(occurrence, selected),
                ),
              ),
            if (showStatus) ...<Widget>[
              const SizedBox(height: 12),
              const Divider(height: 1),
              const SizedBox(height: 12),
            ],
            if (message != null) ...<Widget>[
              Card(
                color: Theme.of(
                  context,
                ).colorScheme.error.withValues(alpha: 0.12),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(message),
                ),
              ),
              const SizedBox(height: 8),
            ],
            _DetailField(
              key: const Key('event-detail-title'),
              icon: Icons.title_outlined,
              label: 'Title',
              value: occurrence.displayTitle,
            ),
            const SizedBox(height: 8),
            if (occurrence.isBackupAppointment)
              const Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  Chip(
                    key: Key('event-detail-backup-badge'),
                    avatar: Icon(Icons.layers_outlined, size: 18),
                    label: Text('Backup Appointment'),
                  ),
                ],
              ),
            const SizedBox(height: 8),
            _DetailField(
              icon: Icons.calendar_today_outlined,
              label: 'Date',
              value: occurrence.displayDate.iso8601,
            ),
            if (occurrence.timing == CalendarEventTiming.timed)
              _DetailField(
                icon: Icons.schedule,
                label: 'Time',
                value:
                    '${_time(occurrence.startDisplay)} – '
                    '${_time(occurrence.endDisplay)}',
              ),
            // Delta 3: recurrence is persisted and must be VISIBLE.  The row
            // sits between Time and Event Type (Date, Time, Repeats, Event
            // Type order) and reads e.g. 'Daily' or 'Weekly • Until Aug 31,
            // 2026'.  A This-Event-Only occurrence exception stays
            // series-linked and therefore still shows its Repeats row.
            if (occurrence.isRecurring)
              _DetailField(
                key: const Key('event-detail-repeats'),
                icon: Icons.repeat,
                label: 'Repeats',
                value: calendarRecurrenceRuleLabel(occurrence.recurrence),
              ),
            if (eventTypeLabel != null)
              // P2-A: this row is the EVENT TYPE and is always labelled as such.
              // "Contact Type" is now its own independently persisted value and
              // is shown in the dedicated row below.
              _DetailField(
                icon: Icons.category_outlined,
                label: 'Event Type',
                value: eventTypeLabel,
              ),
            // P2-A, revised by the owner on 2026-09-22: the independent Contact
            // Type. A Contact Event that never stored a channel — a legacy
            // schema-49 NULL row — presents as the default, In Person; "Not
            // set" is no longer a user-facing Contact Type. This is a READ-only
            // presentation rule and writes nothing to the row.
            if (isContactEvent)
              _DetailField(
                key: const Key('event-detail-contact-type'),
                // The row uses the same channel visual convention as the form
                // and the picker, through the one shared mapper.
                iconWidget: KeyedSubtree(
                  key: const Key('event-detail-contact-type-visual'),
                  child: eventContactChannelVisual(
                    channel: occurrence.contactChannel,
                    color:
                        Theme.of(context).iconTheme.color ??
                        Theme.of(context).colorScheme.onSurface,
                  ),
                ),
                label: 'Contact Type',
                value: eventContactChannelDisplayLabel(
                  occurrence.contactChannel,
                ),
              ),
            if (occurrence.timing == CalendarEventTiming.allDay)
              const _DetailRow(icon: Icons.today_outlined, label: 'All day'),
            // Delta 3: the user-facing 'Original time zone' row is REMOVED.
            // The internal IANA time-zone identity (occurrence.timeZoneId /
            // displayTimeZoneId) remains stored and is still used by
            // recurrence, DST, occurrence generation, and export — only the
            // preview row is gone.
            if (occurrence.locationText != null)
              _DetailRow(
                icon: Icons.place_outlined,
                label: occurrence.locationText!,
              ),
            if (occurrence.notes != null)
              _DetailRow(icon: Icons.notes, label: occurrence.notes!),
            if (occurrence.createdAtUtc != null)
              _DetailField(
                icon: Icons.add_circle_outline,
                label: 'Created',
                value: _metadataTime(occurrence.createdAtUtc!),
              ),
            if (occurrence.updatedAtUtc != null)
              _DetailField(
                icon: Icons.update_outlined,
                label: 'Updated',
                value: _metadataTime(occurrence.updatedAtUtc!),
              ),
            if (occurrence.contributionRuleKey != null)
              const _DetailField(
                icon: Icons.track_changes_outlined,
                label: 'Life Goal',
                value: 'Linked for completion reporting',
              ),
            if (occurrence.linkedTaskIds.isNotEmpty)
              _DetailRow(
                icon: Icons.link,
                label:
                    '${occurrence.linkedTaskIds.length} linked Task(s); '
                    'statuses remain independent',
              ),
            if (occurrence.replacementEventId != null)
              _DetailRow(
                icon: Icons.redo,
                label: 'Replacement Event: ${occurrence.replacementEventId}',
              ),
            _EventDetailMapSection(
              profileId: occurrence.profileId,
              eventId: occurrence.eventId,
              occurrenceId: occurrence.id,
              originalDate: occurrence.originalDate,
              renderedDate: occurrence.displayDate,
            ),
            _EventDetailContactsSection(
              profileId: occurrence.profileId,
              eventId: occurrence.eventId,
              occurrenceId: occurrence.id,
              historical: isHistorical,
              timelineOriginContactId: widget.timelineOriginContactId,
            ),
            const Divider(height: 28),
            ListTile(
              key: const Key('event-activity-history-button'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.history_outlined),
              title: const Text('Activity History'),
              subtitle: const Text('Read-only status and activity records'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push(RoutePaths.activityHistory),
            ),
            const SizedBox(height: 24),
          ],
        );
      },
    );
    final Widget detailContent;
    if (!widget.sheetPresentation) {
      detailContent = Scaffold(
        appBar: InternalAppBar(
          title: Text(_detailHeading),
          actions: _isStructurallyCancelled == false
              ? <Widget>[
                  PlannerTopBarIconButton(
                    key: const Key('event-detail-edit-icon'),
                    tooltip: 'Edit Event',
                    onPressed: _openTopEdit,
                    icon: const Icon(Icons.edit_outlined),
                  ),
                  KeyedSubtree(
                    key: _overflowAnchorKey,
                    child: PlannerTopBarIconButton(
                      key: const Key('event-detail-overflow-icon'),
                      tooltip: 'Event actions',
                      onPressed: _openTopOverflow,
                      icon: const Icon(Icons.more_vert),
                    ),
                  ),
                ]
              : const <Widget>[],
        ),
        body: content,
      );
    } else {
      detailContent = SharedPlannerPreviewSheet(
        key: const Key('calendar-event-existing-detail-sheet'),
        title: _detailHeading,
        closeKey: const Key('event-detail-sheet-close'),
        closeTooltip: 'Close Calendar Event details',
        onClose: () => Navigator.of(context).pop(),
        actions: _isStructurallyCancelled == false
            ? <Widget>[
                PlannerTopBarIconButton(
                  key: const Key('event-detail-sheet-edit-icon'),
                  tooltip: 'Edit Event',
                  onPressed: _openTopEdit,
                  icon: const Icon(Icons.edit_outlined),
                ),
                KeyedSubtree(
                  key: _overflowAnchorKey,
                  child: PlannerTopBarIconButton(
                    key: const Key('event-detail-sheet-overflow-icon'),
                    tooltip: 'Event actions',
                    onPressed: _openTopOverflow,
                    icon: const Icon(Icons.more_vert),
                  ),
                ),
              ]
            : const <Widget>[],
        child: content,
      );
    }
    return detailContent;
  }

  Future<CalendarEventOccurrence?> _readCurrentOccurrence() {
    return ref
        .read(calendarEventControllerProvider.notifier)
        .readOccurrence(
          eventId: widget.eventId,
          originalDate: widget.originalDate,
        );
  }

  Future<void> _openTopEdit() async {
    final occurrence = await _readCurrentOccurrence();
    if (!mounted || occurrence == null || occurrence.isStructurallyCancelled) {
      return;
    }
    await _openForm(occurrence: occurrence);
  }

  Future<void> _openTopOverflow() async {
    final occurrence = await _readCurrentOccurrence();
    if (!mounted || occurrence == null || occurrence.isStructurallyCancelled) {
      return;
    }
    _CalendarEventDetailAction? action;
    await showAnchoredTopBarPopup(
      context: context,
      triggerKey: _overflowAnchorKey,
      width: 228,
      maxHeight: 220,
      builder: (popupContext) => Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          PlannerPreviewOverflowItem(
            key: const Key('event-overflow-duplicate'),
            icon: Icons.copy_outlined,
            label: 'Duplicate',
            onTap: () {
              action = _CalendarEventDetailAction.duplicate;
              anchoredTopBarPopupController.dismiss();
            },
          ),
          PlannerPreviewOverflowItem(
            key: const Key('event-overflow-delete'),
            icon: Icons.delete_outline,
            label: 'Delete',
            destructive: true,
            onTap: () {
              action = _CalendarEventDetailAction.delete;
              anchoredTopBarPopupController.dismiss();
            },
          ),
        ],
      ),
    );
    final selectedAction = action;
    if (!mounted || selectedAction == null) {
      return;
    }
    switch (selectedAction) {
      case _CalendarEventDetailAction.duplicate:
        await _duplicate(occurrence);
      case _CalendarEventDetailAction.delete:
        await _cancel(occurrence, delete: true);
    }
  }

  /// Event status always stages inside the canonical Event editor. Preview
  /// owns neither a parallel draft nor persistence boundary.
  Future<void> _handleStatusTap(
    CalendarEventOccurrence occurrence,
    CalendarEventStatus selected,
  ) async {
    if (occurrence.isStructurallyCancelled || selected == occurrence.status) {
      return;
    }
    await _openForm(occurrence: occurrence, statusIntent: selected);
  }

  Future<_EventReportingSnapshot> _readEventReporting({
    required String eventId,
    required PlannerDate originalDate,
  }) async {
    final controller = ref.read(outcomeReportingControllerProvider.notifier);
    final source = await controller.readEventSource(
      eventId: eventId,
      originalDate: originalDate,
    );
    if (source == null) return const _EventReportingSnapshot.empty();
    final history = await controller.readHistory();
    return _EventReportingSnapshot(
      hasReportedHistory: history.any(
        (report) =>
            report.outcome != null && report.source.slotKey == source.slotKey,
      ),
    );
  }

  Future<void> _duplicate(CalendarEventOccurrence occurrence) async {
    final saved = await ref
        .read(calendarEventControllerProvider.notifier)
        .duplicateEvent(
          eventId: occurrence.eventId,
          originalDate: occurrence.originalDate,
          duplicateId: ref.read(plannerIdentifierSourceProvider).nextUuid(),
          operationId: ref.read(plannerIdentifierSourceProvider).nextUuid(),
        );
    if (saved && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Calendar Event duplicated.')),
      );
    }
  }

  Future<void> _openForm({
    required CalendarEventOccurrence occurrence,
    CalendarEventStatus? statusIntent,
  }) async {
    if (occurrence.isStructurallyCancelled) {
      return;
    }
    // Delta 4.1 edit flow: Edit ALWAYS opens the Edit Event form first — for
    // normal, repeating, Backup, Contact, reported, and unreported Events
    // alike.  For a repeating Event the recurrence scope chooser must not
    // appear before the user reaches the form; it is shown only when the
    // user commits a change on Save (the form defers the scope decision via
    // [RoutePaths.calendarEventEdit]'s `deferScope` flag).  The passed
    // occurrence scope is a placeholder that the form ignores when deferral
    // is active.
    final path = RoutePaths.calendarEventEdit(
      occurrence.eventId,
      occurrence.originalDate,
      CalendarEventEditScope.occurrence,
      deferScopeToSave: occurrence.isRecurring,
      // NX-06: seed the Edit loading shell with the identity this sheet
      // already holds, so the form never shows a blank pause.
      title: occurrence.displayTitle,
      eventTypeLabel: occurrence.activityTypeLabel,
      statusIntent: statusIntent,
    );
    final changed = await context.push<bool>(path);
    if (changed == true && mounted) {
      setState(_reload);
    }
  }

  Future<void> _cancel(
    CalendarEventOccurrence occurrence, {
    bool delete = false,
  }) async {
    if (delete) {
      final operationId = ref.read(plannerIdentifierSourceProvider).nextUuid();
      if (occurrence.isRecurring) {
        // One clear destructive dialog: the scope is part of the dialog
        // itself (Delete This Event / Delete All Events), so no
        // informational scope sheet plus a second confirmation is ever
        // shown.
        final scope = await _selectRecurringDeleteScope();
        if (!mounted || scope == null) {
          return;
        }
        await _performCancel(
          occurrence,
          scope: scope,
          operationId: operationId,
        );
        return;
      }
      // Non-recurring Events keep the canonical simple confirmation dialog.
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Delete Calendar Event?'),
          content: const Text('Historical records and reports will remain.'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Keep Event'),
            ),
            FilledButton(
              key: const Key('confirm-delete-event'),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Delete Event'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) {
        return;
      }
      await _performCancel(
        occurrence,
        scope: CalendarEventEditScope.occurrence,
        operationId: operationId,
      );
      return;
    }
    final scope = await _selectScope(occurrence);
    if (!mounted || scope == null) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Cancel Calendar Event?'),
        content: Text(
          'Scope: ${_scopeLabel(scope)}. Historical records '
          'and reports will be preserved.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Keep Event'),
          ),
          FilledButton(
            key: const Key('confirm-cancel-event'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Cancel Event'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    final operationId = ref.read(plannerIdentifierSourceProvider).nextUuid();
    await _performCancel(occurrence, scope: scope, operationId: operationId);
  }

  Future<void> _performCancel(
    CalendarEventOccurrence occurrence, {
    required CalendarEventEditScope scope,
    required String operationId,
  }) async {
    final result = await ref
        .read(calendarEventControllerProvider.notifier)
        .cancelEvent(
          eventId: occurrence.eventId,
          originalDate: occurrence.originalDate,
          scope: scope,
          operationId: operationId,
        );
    if (!mounted) {
      return;
    }
    if (result ==
        CalendarEventCancellationResult.deletedAwaitingPlannerRefresh) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Event deleted. Planner is refreshing.')),
      );
      Navigator.of(context).pop(true);
    } else if (result ==
        CalendarEventCancellationResult.deletionStateUncertain) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Event deletion status is being confirmed. Planner is refreshing.',
          ),
        ),
      );
      Navigator.of(context).pop(true);
    } else if (result.closesDetail) {
      Navigator.of(context).pop(true);
    } else {
      setState(_reload);
    }
  }

  /// Single destructive dialog for a recurring Event deletion. The scope is
  /// chosen inside the dialog itself, so the previous two-step scope sheet +
  /// confirmation flow is gone. Keep Event changes nothing. Non-recurring
  /// Events never route through this dialog.
  Future<CalendarEventEditScope?> _selectRecurringDeleteScope() {
    return showDialog<CalendarEventEditScope>(
      context: context,
      builder: (dialogContext) {
        final colorScheme = Theme.of(dialogContext).colorScheme;
        return AlertDialog(
          key: const Key('recurring-delete-dialog'),
          title: const Text('Delete Repeating Event?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                'Selected occurrence: ${widget.originalDate.iso8601}\n\n'
                'Choose what to delete. Historical reports and activity '
                'records will remain.',
              ),
              const SizedBox(height: 14),
              FilledButton(
                key: const Key('recurring-delete-this-event'),
                style: FilledButton.styleFrom(
                  backgroundColor: colorScheme.errorContainer,
                  foregroundColor: colorScheme.onErrorContainer,
                ),
                onPressed: () => Navigator.of(
                  dialogContext,
                ).pop(CalendarEventEditScope.occurrence),
                child: const Text('Delete This Event'),
              ),
              const SizedBox(height: 8),
              FilledButton(
                key: const Key('recurring-delete-all-events'),
                style: FilledButton.styleFrom(
                  backgroundColor: colorScheme.errorContainer,
                  foregroundColor: colorScheme.onErrorContainer,
                ),
                onPressed: () => Navigator.of(
                  dialogContext,
                ).pop(CalendarEventEditScope.series),
                child: const Text('Delete Entire Series'),
              ),
            ],
          ),
          actionsAlignment: MainAxisAlignment.center,
          actions: <Widget>[
            TextButton(
              key: const Key('recurring-delete-keep-event'),
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Keep Event'),
            ),
          ],
        );
      },
    );
  }

  Future<CalendarEventEditScope?> _selectScope(
    CalendarEventOccurrence occurrence,
  ) {
    if (!occurrence.isRecurring) {
      return Future<CalendarEventEditScope?>.value(
        CalendarEventEditScope.occurrence,
      );
    }
    return showModalBottomSheet<CalendarEventEditScope>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                'Change repeating event',
                style: Theme.of(
                  sheetContext,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 10),
              RepeatingEventScopeChoices(
                originalDate: occurrence.originalDate,
                keyPrefix: 'event-scope',
                onSelected: (scope) => Navigator.of(sheetContext).pop(scope),
              ),
              const SizedBox(height: 6),
              TextButton(
                key: const Key('event-scope-cancel'),
                onPressed: () => Navigator.of(sheetContext).pop(),
                child: const Text('Cancel'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _scopeLabel(CalendarEventEditScope scope) {
    return switch (scope) {
      CalendarEventEditScope.occurrence => 'This event only',
      CalendarEventEditScope.series => 'All events',
      CalendarEventEditScope.thisAndFuture => 'This event only',
    };
  }

  static String _time(DateTime? value) {
    if (value == null) {
      return 'Time not set';
    }
    final hour = value.hour == 0
        ? 12
        : value.hour > 12
        ? value.hour - 12
        : value.hour;
    return '$hour:${value.minute.toString().padLeft(2, '0')} '
        '${value.hour >= 12 ? 'PM' : 'AM'}';
  }

  static String _metadataTime(DateTime value) {
    final local = value.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')} '
        '${_time(local)}';
  }

  static bool _isContactEvent(String? stableKey, String? label) {
    if (stableKey == SystemEventTypeKeys.meaningfulConnection) {
      return true;
    }
    final normalized = label?.trim().toLowerCase();
    return normalized != null && normalized.contains('contact');
  }
}

final class _EventReportingSnapshot {
  const _EventReportingSnapshot({required this.hasReportedHistory});

  const _EventReportingSnapshot.empty() : hasReportedHistory = false;

  final bool hasReportedHistory;
}

/// Compact status row for the Calendar Event preview.
///
/// The current status label sits on the left and the direct-selection
/// controls sit on the right, immediately below the app bar. Tapping a
/// reported outcome opens the canonical Event editor with that status staged;
/// Preview itself does not write a report. The selected control uses a filled
/// treatment while the unselected ones use a neutral outline.
///
/// Planner Polish Delta 2 status matrix:
///   Contact Events  → Unreported / Did Not Attempt / Missed - Attempted /
///                     Completed (four controls);
///   generic Events  → Unreported / Missed / Completed (three controls;
///                     Did Not Attempt is no longer offered).  Legacy
///                     non-Contact Did Not Attempt records remain readable
///                     through the label but are not re-selectable.
final class _EventStatusControlRow extends StatelessWidget {
  const _EventStatusControlRow({
    required this.currentStatus,
    required this.hasReportedHistory,
    required this.isContactEvent,
    required this.onSelect,
  });

  final CalendarEventStatus currentStatus;
  final bool hasReportedHistory;
  final bool isContactEvent;
  final ValueChanged<CalendarEventStatus> onSelect;

  @override
  Widget build(BuildContext context) {
    final effective = currentStatus;
    final currentKind = PlannerEventReportStatus.kindForStatus(
      effective,
      isContactEvent: isContactEvent,
    );
    return PlannerCurrentStatusControlRow(
      currentLabel: calendarEventOutcomeLabel(
        status: effective,
        isContactEvent: isContactEvent,
      ),
      currentKind: currentKind,
      selectedId: effective.name,
      options: _selectableStatuses()
          .map(
            (status) => PlannerPreviewStatusOption(
              id: status.name,
              label: calendarEventOutcomeLabel(
                status: status,
                isContactEvent: isContactEvent,
              ),
              kind: PlannerEventReportStatus.kindForStatus(
                status,
                isContactEvent: isContactEvent,
              ),
              enabled:
                  status != CalendarEventStatus.scheduled ||
                  !(currentStatus != CalendarEventStatus.scheduled ||
                      hasReportedHistory),
            ),
          )
          .toList(growable: false),
      saving: false,
      onSelect: (id) => onSelect(CalendarEventStatus.values.byName(id)),
      controlKey: const Key('event-status-control'),
      currentLabelKey: const Key('event-status-current-label'),
      optionKeyPrefix: 'event-status-option-',
    );
  }

  /// Unreported remains visible in-place after reporting starts but becomes
  /// non-tappable; this preserves the control geometry and reporting history.
  static List<CalendarEventStatus> _selectableStatuses() {
    return <CalendarEventStatus>[
      CalendarEventStatus.scheduled,
      CalendarEventStatus.didNotHappen,
      CalendarEventStatus.partiallyCompleted,
      CalendarEventStatus.completedHappened,
    ];
  }
}

Future<T?> showCalendarEventDetailSheet<T>({
  required BuildContext context,
  required String eventId,
  required PlannerDate originalDate,
  String? initialHeading,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    constraints: const BoxConstraints(maxWidth: kPlannerPreviewSheetMaxWidth),
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.62),
    builder: (sheetContext) => FractionallySizedBox(
      heightFactor: 0.92,
      child: CalendarEventDetailScreen(
        eventId: eventId,
        originalDate: originalDate,
        sheetPresentation: true,
        initialHeading: initialHeading,
      ),
    ),
  );
}

final class DetailOverflowItemLegacy extends StatelessWidget {
  const DetailOverflowItemLegacy({
    required this.icon,
    required this.label,
    required this.onTap,
    this.destructive = false,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final color = destructive
        ? Theme.of(context).colorScheme.error
        : Theme.of(context).colorScheme.onSurface;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: <Widget>[
            Icon(icon, size: 20, color: color),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: TextStyle(color: color, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

typedef _DetailRow = PlannerDetailRow;
typedef _DetailField = PlannerDetailField;
