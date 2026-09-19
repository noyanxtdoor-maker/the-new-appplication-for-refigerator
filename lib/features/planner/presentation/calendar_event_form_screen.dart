import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:rmplanner/app/router/route_names.dart';
import 'package:rmplanner/app/theme/app_theme.dart';
import 'package:rmplanner/app/theme/internal_screen.dart';
import 'package:rmplanner/features/contacts/application/contact_providers.dart';
import 'package:rmplanner/features/contacts/domain/contact.dart';
import 'package:rmplanner/features/contacts/presentation/add_people_screen.dart';
import 'package:rmplanner/features/contacts/presentation/widgets/contact_widgets.dart';
import 'package:rmplanner/features/goals/application/goal_providers.dart';
import 'package:rmplanner/features/goals/domain/goal.dart';
import 'package:rmplanner/features/goals/presentation/widgets/goal_icon.dart';
import 'package:rmplanner/features/indicators/domain/life_indicator.dart';
import 'package:rmplanner/features/maps/application/map_coordinate_repository.dart';
import 'package:rmplanner/features/maps/application/map_providers.dart';
import 'package:rmplanner/features/maps/domain/map_coordinate.dart';
import 'package:rmplanner/features/maps/presentation/map_location_picker_screen.dart';
import 'package:rmplanner/features/maps/presentation/map_pin_section.dart';
import 'package:rmplanner/features/notifications/application/notification_providers.dart';
import 'package:rmplanner/features/notifications/domain/reminder_policy.dart';
import 'package:rmplanner/features/notifications/domain/reminder_policy_label.dart';
import 'package:rmplanner/features/notifications/presentation/reminder_time_picker.dart';
import 'package:rmplanner/features/planner/application/calendar_event_creation_draft_provider.dart';
import 'package:rmplanner/features/planner/application/calendar_event_providers.dart';
import 'package:rmplanner/features/planner/application/event_type_creation_providers.dart';
import 'package:rmplanner/features/planner/application/event_type_providers.dart';
import 'package:rmplanner/features/planner/application/outcome_reporting_providers.dart';
import 'package:rmplanner/features/planner/application/outcome_reporting_repository.dart';
import 'package:rmplanner/features/planner/application/planner_providers.dart';
import 'package:rmplanner/features/planner/application/task_event_link_providers.dart';
import 'package:rmplanner/features/planner/data/calendar_event_time_zones.dart';
import 'package:rmplanner/features/planner/domain/calendar_event.dart';
import 'package:rmplanner/features/planner/domain/event_type.dart';
import 'package:rmplanner/features/planner/domain/event_type_creation_choice.dart';
import 'package:rmplanner/features/planner/domain/outcome_reporting.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/task_event_link.dart';
import 'package:rmplanner/features/planner/presentation/calendar_event_custom_repeat_screen.dart';
import 'package:rmplanner/features/planner/presentation/event_type_picker_dialog.dart';
import 'package:rmplanner/features/planner/presentation/widgets/event_current_status_controls.dart';
import 'package:rmplanner/features/planner/presentation/widgets/planner_slide_down_date_picker.dart';
import 'package:rmplanner/features/planner/presentation/widgets/repeating_event_scope_choices.dart';
import 'package:rmplanner/features/startup/application/startup_providers.dart';
import 'package:rmplanner/features/startup/domain/startup_state.dart';

enum CalendarEventFormMode { create, edit, reschedule }

enum _CalendarEventRepeatChoice { none, daily, weekly, monthly, yearly, custom }

final class CalendarEventFormScreen extends ConsumerStatefulWidget {
  const CalendarEventFormScreen.create({
    required this.initialDate,
    this.initialCoordinate,
    this.initialEventType,
    this.initialStartMinute,
    this.initialIndicatorKey,
    this.initialEventTypeId,
    this.initialDraftId,
    this.initialDurationMinutes,
    this.onClose,
    this.initialContactIds = const <String>[],
    this.followUpContactId,
    this.sheetPresentation = false,
    this.sheetScrollController,
    this.sheetController,
    this.sheetMinChildSize = 0.36,
    this.sheetMaxChildSize = 0.94,
    super.key,
  }) : mode = CalendarEventFormMode.create,
       eventId = null,
       originalDate = null,
       scope = null,
       deferRecurrenceScopeToSave = false,
       sourceTaskId = null,
       initialTitle = null,
       initialEventTypeLabel = null,
       initialStatusIntent = null;

  const CalendarEventFormScreen.createFromTask({
    required this.sourceTaskId,
    required this.initialDate,
    this.initialEventType,
    this.initialStartMinute,
    this.initialIndicatorKey,
    this.initialEventTypeId,
    this.initialContactIds = const <String>[],
    this.sheetPresentation = false,
    this.sheetScrollController,
    this.sheetController,
    this.sheetMinChildSize = 0.36,
    this.sheetMaxChildSize = 0.94,
    super.key,
  }) : mode = CalendarEventFormMode.create,
       eventId = null,
       originalDate = null,
       scope = null,
       deferRecurrenceScopeToSave = false,
       initialDraftId = null,
       initialDurationMinutes = null,
       initialCoordinate = null,
       onClose = null,
       initialTitle = null,
       initialEventTypeLabel = null,
       initialStatusIntent = null,
       // A Task->Event link is an ordinary creation, never a follow-up entry.
       followUpContactId = null;

  const CalendarEventFormScreen.edit({
    required this.eventId,
    required this.originalDate,
    required this.scope,
    this.deferRecurrenceScopeToSave = false,
    this.sheetPresentation = false,
    this.sheetScrollController,
    this.sheetController,
    this.sheetMinChildSize = 0.36,
    this.sheetMaxChildSize = 0.94,
    // NX-06: known identity seeds from the detail sheet (which already holds
    // the loaded occurrence). When set, the loading shell shows the truthful
    // 'Edit <label> Event' heading + seeded title instead of a blank pause.
    this.initialTitle,
    this.initialEventTypeLabel,
    this.initialStatusIntent,
    super.key,
  }) : mode = CalendarEventFormMode.edit,
       initialDate = null,
       initialCoordinate = null,
       initialEventType = null,
       initialStartMinute = null,
       initialIndicatorKey = null,
       initialEventTypeId = null,
       initialDraftId = null,
       initialDurationMinutes = null,
       onClose = null,
       sourceTaskId = null,
       initialContactIds = const <String>[],
       // M7 adds no general UI for purpose reassignment: only the chooser
       // establishes provenance, so edit never seeds it (section 9).
       followUpContactId = null;

  const CalendarEventFormScreen.reschedule({
    required this.eventId,
    required this.originalDate,
    required this.scope,
    this.sheetPresentation = false,
    this.sheetScrollController,
    this.sheetController,
    this.sheetMinChildSize = 0.36,
    this.sheetMaxChildSize = 0.94,
    super.key,
  }) : mode = CalendarEventFormMode.reschedule,
       initialDate = null,
       initialCoordinate = null,
       initialEventType = null,
       initialStartMinute = null,
       initialIndicatorKey = null,
       initialEventTypeId = null,
       initialDraftId = null,
       initialDurationMinutes = null,
       onClose = null,
       sourceTaskId = null,
       deferRecurrenceScopeToSave = false,
       initialContactIds = const <String>[],
       initialTitle = null,
       initialEventTypeLabel = null,
       initialStatusIntent = null,
       followUpContactId = null;

  final CalendarEventFormMode mode;
  final PlannerDate? initialDate;
  final MapCoordinate? initialCoordinate;
  final EventType? initialEventType;
  final int? initialStartMinute;
  final String? initialIndicatorKey;
  final String? initialEventTypeId;
  final String? initialDraftId;

  /// Delta 4.2R R9: the configured Planner default Event duration for
  /// timeline creation. When set, the create form opens with exactly this
  /// duration (matching the tap placeholder and the provisional draft); the
  /// Event Type's own default is used when this is null.
  final int? initialDurationMinutes;
  final ValueChanged<bool>? onClose;
  final String? eventId;
  final PlannerDate? originalDate;
  final CalendarEventEditScope? scope;

  /// Delta 4.1 edit flow: when true (opened from an Event preview on a
  /// repeating Event), the form opens immediately and the recurrence scope
  /// chooser is shown ONLY when the user commits a change on Save.  The
  /// passed [scope] is then a placeholder that is ignored for recurring
  /// Events; a non-recurring Event still saves with occurrence scope.
  final bool deferRecurrenceScopeToSave;
  final String? sourceTaskId;
  final List<String> initialContactIds;

  /// M7 section 8 — the ONE Contact explicitly chosen in the Contact Detail
  /// follow-up chooser.  Null on every ordinary creation path; never seeded by
  /// edit or reschedule, because M7 adds no general purpose-reassignment UI.
  final String? followUpContactId;

  /// NX-06: identity seeds for the Edit Event loading shell (known from the
  /// detail sheet at open time). Null keeps the previous blank-pause behavior
  /// for deep-link/direct edit entries.
  final String? initialTitle;
  final String? initialEventTypeLabel;

  /// A Current Status choice is merely staged when Event Detail opens Edit.
  /// The canonical occurrence report is written only by this form's Save.
  final CalendarEventStatus? initialStatusIntent;
  final bool sheetPresentation;
  final ScrollController? sheetScrollController;
  final DraggableScrollableController? sheetController;
  final double sheetMinChildSize;
  final double sheetMaxChildSize;

  @override
  ConsumerState<CalendarEventFormScreen> createState() =>
      _CalendarEventFormScreenState();
}

final class _CalendarEventFormScreenState
    extends ConsumerState<CalendarEventFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _eventTypeAnchorKey = GlobalKey();
  final _titleController = TextEditingController();
  final _notesController = TextEditingController();
  final _notesFocusNode = FocusNode();
  final _locationController = TextEditingController();
  final _timeZoneController = TextEditingController();
  final _countController = TextEditingController(text: '2');
  late final String _draftId;
  late final String _operationId;
  CalendarEventEditScope? _committedEditScope;
  String? _linkId;
  late PlannerDate _date;
  CalendarEventTiming _timing = CalendarEventTiming.timed;
  CalendarEventStatus _currentStatus = CalendarEventStatus.scheduled;
  CalendarEventStatus _loadedReportStatus = CalendarEventStatus.scheduled;
  bool _reportEligible = false;
  TimeOfDay _localStart = const TimeOfDay(hour: 9, minute: 0);
  TimeOfDay _localEnd = const TimeOfDay(hour: 10, minute: 0);
  bool _requiresReport = false;
  ReminderPolicyMode _reminderMode = ReminderPolicyMode.inherit;
  int? _reminderOffsetMinutes;

  /// True only when the user actually chose a reminder on this visit.
  ///
  /// OWNER HOTFIX (2026-09-19): an Edit/Reschedule save persists a reminder policy
  /// ONLY when this is true. Re-saving an Event without touching its reminder used
  /// to write a row under the occurrence key built from the form's own (resolved)
  /// state, which could shadow a series override the user had set elsewhere. A save
  /// that did not change the reminder must never author a policy row.
  bool _reminderSelectionChanged = false;
  String? _loadedEventTypeStableKey;
  String? _loadedEventTypeLabel;
  // Raw type ID loaded with an existing Event (edit/reschedule). Used to
  // distinguish "same-type preservation" (no new-selection gate) from an
  // explicit type change (must pass current eligibility) per contract E.
  String? _loadedTypeId;

  /// O9 (section 66): an explicit user selection flag.  Comparing the selected
  /// id with the master [_loadedTypeId] is insufficient — re-selecting the
  /// original type in the picker still counts as a deliberate selection and
  /// must use the canonical current label, not the loaded snapshot.
  bool _eventTypeSelectionChanged = false;
  bool _isBackupAppointment = false;
  String? _backupForEventId;
  String? _backupRelationshipProvenance;
  _CalendarEventRepeatChoice _repeatChoice = _CalendarEventRepeatChoice.none;
  CalendarRecurrenceFrequency _frequency = CalendarRecurrenceFrequency.none;
  CalendarRecurrencePattern? _recurrencePattern;
  // Delta 4.1 edit flow: the recurrence frequency of the loaded source
  // (master) draft, captured BEFORE the user edits the Repeat field.  Used to
  // decide whether a Save on a deferred-scope edit needs the recurrence
  // scope chooser at all.
  CalendarRecurrenceFrequency _sourceFrequency =
      CalendarRecurrenceFrequency.none;
  CalendarRecurrenceEndMode _endMode = CalendarRecurrenceEndMode.never;
  PlannerDate? _recurrenceEndDate;
  bool _legacyRecurrenceEndControls = false;
  bool _recurrenceEndDateCustomized = false;
  bool _loading = false;
  bool _saving = false;
  bool _configurationLoading = true;
  bool _initializing = true;
  bool _durationWasEntered = false;
  EventType? _selectedEventType;
  List<IndicatorOption> _indicatorOptions = const <IndicatorOption>[];
  String? _linkedIndicatorKey;
  bool _indicatorLinkTouched = false;
  String? _selectedGoalId;
  // Locally-loaded active Goals for the Goal link picker.  Loaded once in
  // [initState] with error handling so the form never hard-fails when no
  // ready profile or Goal repository is available (tests, recovery flows).
  List<Goal> _availableGoals = const <Goal>[];
  // Tracks the in-flight (or completed) Goal load so the picker can await a
  // load that is still running instead of showing a misleading empty state.
  Future<void>? _goalsLoad;
  bool _locationExpanded = false;
  bool _addressExpanded = false;
  MapCoordinate? _mapCoordinate;
  MapCoordinate? _initialMapCoordinate;
  TaskEventCanonicalSource _canonicalSource = TaskEventCanonicalSource.task;
  // Contact people linked to this Event draft.  Saved through the Contacts
  // repository after the Event itself persists, keyed by [_draftId] (the
  // same id survives `thisAndFuture` edits), so the Event draft stays fully
  // intact across the Add People round trip.  Edit and reschedule modes
  // load the existing series People so a save never erases saved links.
  late List<String> _peopleContactIds;
  Set<String> _initialPeopleContactIds = const <String>{};
  bool _peopleSelectionModified = false;
  Future<void>? _peopleLoad;

  @override
  void initState() {
    super.initState();
    _goalsLoad = _loadAvailableGoals();
    unawaited(_goalsLoad!);
    final initialEventType = widget.initialEventType;
    if (widget.mode == CalendarEventFormMode.create &&
        initialEventType != null) {
      _selectedEventType = initialEventType;
      _linkedIndicatorKey = initialEventType.isLockedWliType
          ? initialEventType.exactIndicatorKey
          : widget.initialIndicatorKey ?? initialEventType.exactIndicatorKey;
      _configurationLoading = false;
    }
    _notesFocusNode.addListener(_notesFocusChanged);
    final ids = ref.read(plannerIdentifierSourceProvider);
    _operationId = ids.nextUuid();
    if (widget.sourceTaskId != null) {
      _linkId = ids.nextUuid();
    }
    _draftId = switch (widget.mode) {
      CalendarEventFormMode.create || CalendarEventFormMode.reschedule =>
        widget.initialDraftId ?? ids.nextUuid(),
      CalendarEventFormMode.edit
          when widget.scope == CalendarEventEditScope.thisAndFuture =>
        ids.nextUuid(),
      CalendarEventFormMode.edit => widget.eventId!,
    };
    _peopleContactIds = List<String>.from(widget.initialContactIds);
    _initialPeopleContactIds = _peopleContactIds.toSet();
    _titleController.addListener(_publishProvisionalTitle);
    if (widget.mode == CalendarEventFormMode.edit ||
        widget.mode == CalendarEventFormMode.reschedule) {
      _peopleLoad = _loadExistingPeople();
      unawaited(_peopleLoad);
    }
    _date = widget.initialDate ?? widget.originalDate!;
    final initialStartMinute = widget.initialStartMinute;
    if (initialStartMinute != null) {
      _start = _timeFromMinute(initialStartMinute);
      // Delta 4.2R R9: seed the end with the configured Planner default when
      // provided (timeline creation) so the form never flashes a different
      // duration than the placeholder/draft before configuration loads.
      final initialDuration =
          widget.initialDurationMinutes ??
          widget.initialEventType?.defaultDurationMinutes ??
          60;
      _end = _timeFromMinute(
        (initialStartMinute + initialDuration).clamp(1, 1439),
      );
    }
    if (widget.mode == CalendarEventFormMode.create) {
      if (widget.initialCoordinate case final coordinate?) {
        _mapCoordinate = coordinate;
      }
    }
    if (_selectedEventType != null) {
      _applyEventTypeDefaults(
        _selectedEventType!,
        durationMinutes: _selectedEventType!.defaultDurationMinutes,
      );
    }
    _timeZoneController.text = ref
        .read(calendarEventControllerProvider.notifier)
        .displayTimeZoneId;
    if (widget.mode != CalendarEventFormMode.create) {
      _loading = true;
      unawaited(Future<void>.microtask(_loadExisting));
    } else if (widget.sourceTaskId != null) {
      unawaited(Future<void>.microtask(_loadSourceTask));
    }
    _initializing = false;
    unawaited(Future<void>.microtask(_loadConfiguration));
  }

  Future<void> _loadConfiguration() async {
    final controller = ref.read(eventTypeControllerProvider.notifier);
    // O1/O10: a warm same-profile successful load is reused rather than forced
    // through a redundant reload; a cold or foreign-profile state still waits
    // truthfully here.  The narrow readiness gate below stays the authority on
    // whether the data may seed creation eligibility.
    await controller.ensureLoaded();
    if (!mounted) {
      return;
    }
    final eventTypeState = ref.read(eventTypeControllerProvider);
    List<IndicatorOption> indicatorOptions = const <IndicatorOption>[];
    try {
      indicatorOptions = await ref
          .read(outcomeReportingControllerProvider.notifier)
          .readIndicatorOptions();
    } on Object {
      // The link remains optional if the existing indicator repository cannot
      // be read. The event form itself must still be usable.
    }
    if (!mounted) {
      return;
    }
    CalendarEventDraft? existingDraft;
    EventType? selected;
    var preferTypeDuration = false;
    // Contract E: current creation eligibility, resolved once here. Create
    // mode resolves EVERY initial source (object, ID, indicator, default)
    // through it, including objects passed before an archive. Edit mode
    // keeps the raw existing type (the raw list may omit hidden/retired
    // types) and its occurrence snapshot; only a NEW selection is gated.
    List<EventTypeCreationChoice> eligibleChoices = const <
        EventTypeCreationChoice>[];
    var eligibilityReady = false;
    if (widget.mode == CalendarEventFormMode.create) {
      try {
        final rawState = ref.read(eventTypeControllerProvider);
        if (!rawState.isLoading && rawState.message == null) {
          eligibleChoices = await ref.read(
            eventTypeCreationChoicesProvider.future,
          );
          eligibilityReady = true;
        }
      } on Object {
        // Fail closed below: unknown eligibility means no stale selection.
        eligibilityReady = false;
      }
    }
    EventType? eligibleTypeById(String? id) {
      if (id == null) {
        return null;
      }
      for (final choice in eligibleChoices) {
        if (choice.type.id == id) {
          return choice.type;
        }
      }
      return null;
    }

    if (widget.mode != CalendarEventFormMode.create) {
      existingDraft = await ref
          .read(calendarEventControllerProvider.notifier)
          .readEventDraft(widget.eventId!);
      final eventTypeId = existingDraft?.activityTypeId;
      if (eventTypeId != null) {
        selected = eventTypeState.eventTypes
            .where((type) => type.id == eventTypeId)
            .firstOrNull;
      }
    } else if (widget.initialEventType != null && eligibilityReady) {
      preferTypeDuration = true;
      selected = eligibleTypeById(widget.initialEventType!.id);
    } else if (widget.initialEventTypeId != null && eligibilityReady) {
      preferTypeDuration = true;
      selected = eligibleTypeById(widget.initialEventTypeId);
    } else if (widget.initialIndicatorKey != null && eligibilityReady) {
      preferTypeDuration = true;
      selected = eligibleTypeById(
        (await controller.exactTypeForIndicator(widget.initialIndicatorKey!))
            ?.id,
      );
    } else if (eventTypeState.settings.defaultEventTypeId != null &&
        eligibilityReady) {
      selected = eligibleTypeById(eventTypeState.settings.defaultEventTypeId);
    }
    // Eligible Other fallback (contract E), without any preference write.
    // When eligibility never resolved, fall back to raw Other so the form
    // stays usable without advertising an unvalidated slot type.
    //
    // O9 (section 66): for an EXISTING Event whose occurrence snapshot is the
    // only truthful label, the Other slot must never be advertised as this
    // Event's type.  A persisted `activityTypeId` that no longer resolves is
    // unmapped, not "Other": the form keeps a null selection (honest
    // "Edit Event" heading, raw label as the last-resort field wording) rather
    // than claiming a semantic type the Event never had.
    final loadedTypeIdentity =
        existingDraft?.activityTypeId ?? widget.initialEventTypeId;
    final suppressOtherFallback =
        widget.mode != CalendarEventFormMode.create &&
        loadedTypeIdentity != null &&
        selected == null &&
        (_loadedEventTypeLabel?.trim().isNotEmpty ?? false);
    selected ??= suppressOtherFallback
        ? null
        : eligibilityReady
        ? eligibleChoices
              .where(
                (choice) =>
                    choice.type.stableKey == SystemEventTypeKeys.other,
              )
              .firstOrNull
              ?.type
        : eventTypeState.eventTypes
              .where(
                (type) =>
                    type.stableKey == SystemEventTypeKeys.other &&
                    type.isCreationVisible,
              )
              .firstOrNull;
    final existingRule = ScheduledPotentialRule.tryParse(
      existingDraft?.contributionRuleKey,
    );
    final initialLink = selected?.isLockedWliType == true
        ? selected?.exactIndicatorKey
        : existingRule?.indicatorKey ??
              widget.initialIndicatorKey ??
              selected?.exactIndicatorKey;
    if (mounted) {
      setState(() {
        _configurationLoading = false;
        _selectedEventType = selected;
        _indicatorOptions = indicatorOptions;
        _linkedIndicatorKey = initialLink;
        if (selected?.isLockedWliType == true) {
          _requiresReport = true;
          _linkedIndicatorKey = selected!.exactIndicatorKey;
        } else if (selected?.stableKey == SystemEventTypeKeys.contact) {
          // Delta 2: Contact Events are always Report Required.
          _requiresReport = true;
        }
        if (widget.mode == CalendarEventFormMode.create &&
            selected != null &&
            widget.initialEventType == null) {
          _applyEventTypeDefaults(
            selected,
            durationMinutes: preferTypeDuration
                ? widget.initialDurationMinutes ??
                      selected.defaultDurationMinutes
                : eventTypeState.settings.defaultDurationMinutes,
          );
        }
        if (widget.mode == CalendarEventFormMode.create &&
            selected != null &&
            widget.initialEventType != null &&
            widget.initialDurationMinutes != null) {
          // Delta 4.2R R9: the timeline draft sheet must open with the
          // configured Planner default (not the Event Type default) so the
          // form, the placeholder, and the draft block never disagree.
          _applyEventTypeDefaults(
            selected,
            durationMinutes: widget.initialDurationMinutes,
          );
        }
      });
    }
  }

  void _applyEventTypeDefaults(EventType type, {int? durationMinutes}) {
    // Planner Polish Delta 2: the Contact Event Type always requires a
    // Current Status report, independent of Life Goal linkage.
    _requiresReport =
        type.isLockedWliType || type.stableKey == SystemEventTypeKeys.contact
        ? true
        : type.reportRequiredDefault;
    if (type.isLockedWliType) {
      _linkedIndicatorKey = type.exactIndicatorKey;
      _indicatorLinkTouched = false;
    }
    if (_durationWasEntered) {
      return;
    }
    final startMinute = _start.hour * 60 + _start.minute;
    final minimumEnd = (startMinute + 15).clamp(1, 1439);
    _end = _timeFromMinute(
      (startMinute + (durationMinutes ?? type.defaultDurationMinutes)).clamp(
        minimumEnd,
        1439,
      ),
    );
  }

  Future<void> _changeEventType() async {
    final selected = await showEventTypeDropdown(
      context: context,
      ref: ref,
      anchorKey: _eventTypeAnchorKey,
      selectedEventTypeId: _selectedEventType?.id,
      recommendedIndicatorKey: widget.initialIndicatorKey,
    );
    if (!mounted || selected == null) {
      return;
    }
    // Delta 2: a manually-enabled Report Required preference survives a type
    // change away from a mandatory Contact type instead of being silently
    // reset by the new type's default.
    final manualReport =
        _requiresReport &&
        _selectedGoalId == null &&
        _selectedEventType?.isLockedWliType != true &&
        _selectedEventType?.stableKey != SystemEventTypeKeys.contact;
    ref
        .read(plannerEventCreationDraftProvider.notifier)
        .updateEventType(selected);
    setState(() {
      _selectedEventType = selected;
      // A deliberate picker decision, even reselecting the original type.
      _eventTypeSelectionChanged = true;
      _applyEventTypeDefaults(selected);
      if (selected.isLockedWliType) {
        _linkedIndicatorKey = selected.exactIndicatorKey;
      } else if (!_indicatorLinkTouched) {
        _linkedIndicatorKey = selected.exactIndicatorKey;
      }
      if (manualReport &&
          !selected.isLockedWliType &&
          selected.stableKey != SystemEventTypeKeys.contact) {
        _requiresReport = true;
      }
    });
  }

  Future<void> _loadSourceTask() async {
    final task = await ref
        .read(plannerControllerProvider.notifier)
        .readTask(widget.sourceTaskId!);
    if (mounted && task != null && _titleController.text.isEmpty) {
      setState(() => _titleController.text = task.title);
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _notesController.dispose();
    _notesFocusNode.dispose();
    _locationController.dispose();
    _timeZoneController.dispose();
    _countController.dispose();
    super.dispose();
  }

  TimeOfDay get _start {
    final provisional = ref.read(plannerEventCreationDraftProvider);
    if (!_initializing &&
        provisional != null &&
        provisional.id == widget.initialDraftId) {
      return _timeFromMinute(provisional.startMinute);
    }
    return _localStart;
  }

  set _start(TimeOfDay value) {
    _localStart = value;
    final provisional = ref.read(plannerEventCreationDraftProvider);
    if (!_initializing &&
        provisional != null &&
        provisional.id == widget.initialDraftId) {
      final startMinute = value.hour * 60 + value.minute;
      ref
          .read(plannerEventCreationDraftProvider.notifier)
          .updateTimes(
            startMinute: startMinute,
            endMinute: math.max(provisional.endMinute, startMinute + 15),
          );
    }
  }

  TimeOfDay get _end {
    final provisional = ref.read(plannerEventCreationDraftProvider);
    if (provisional != null && provisional.id == widget.initialDraftId) {
      return _timeFromMinute(
        provisional.endMinute == 1440 ? 0 : provisional.endMinute,
      );
    }
    return _localEnd;
  }

  set _end(TimeOfDay value) {
    _localEnd = value;
    final provisional = ref.read(plannerEventCreationDraftProvider);
    if (_initializing ||
        provisional == null ||
        provisional.id != widget.initialDraftId) {
      return;
    }
    final localEndMinute = value.hour * 60 + value.minute;
    final endMinute = localEndMinute == 0 && provisional.startMinute > 0
        ? 1440
        : localEndMinute;
    ref
        .read(plannerEventCreationDraftProvider.notifier)
        .updateTimes(
          startMinute: provisional.startMinute,
          endMinute: endMinute,
        );
  }

  void _publishProvisionalTitle() {
    final provisional = ref.read(plannerEventCreationDraftProvider);
    if (provisional != null && provisional.id == widget.initialDraftId) {
      ref
          .read(plannerEventCreationDraftProvider.notifier)
          .updateTitle(_titleController.text);
    }
  }

  void _notesFocusChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  /// Contract E display label: a NEW selection renders the current
  /// Goal-title alias through the live creation choices; an existing edit
  /// keeps its loaded occurrence/master snapshot label until the user
  /// explicitly changes the type. Resolver unavailability falls back to the
  /// raw label — display only, identity stays on the raw type.
  /// O9 (section 66): resolves the display label for this Event's type.
  ///
  /// Before any deliberate picker change the form must show the label of the
  /// occurrence it ACTUALLY opened — the freshly loaded effective occurrence
  /// label and identity — not the raw master row, whose `activityTypeId` can be
  /// a retired/Other binding while the occurrence carries a truthful exception.
  /// The master snapshot is only a fallback when the occurrence is unavailable,
  /// and [widget.initialEventTypeLabel] stays a loading seed rather than an
  /// eternal override of newer reads.
  String _formTypeDisplayLabel() {
    final selected = _selectedEventType;
    if (selected == null) {
      return 'Not selected';
    }
    // A deliberate selection always wins: it is the user's current intent, and
    // its label comes from the canonical creation choice.
    if (widget.mode == CalendarEventFormMode.create || _eventTypeSelectionChanged) {
      final resolved = _creationChoiceLabelOf(selected.id);
      if (resolved != null) {
        return resolved;
      }
      return selected.label;
    }
    // Unchanged Edit: prefer the effective occurrence label captured at load.
    final loaded = _loadedEventTypeLabel?.trim();
    if (loaded != null && loaded.isNotEmpty) {
      return loaded;
    }
    final resolved = _creationChoiceLabelOf(selected.id);
    if (resolved != null) {
      return resolved;
    }
    return selected.label;
  }

  /// The canonical creation-choice display label for [typeId], when the
  /// provider currently exposes an eligible choice for it.
  String? _creationChoiceLabelOf(String typeId) {
    final choices = ref.read(eventTypeCreationChoicesProvider).value;
    if (choices == null) {
      return null;
    }
    for (final choice in choices) {
      if (choice.type.id == typeId) {
        return choice.displayLabel;
      }
    }
    return null;
  }

  Widget _buildEventTypeField() {
    return Material(
      key: const Key('event-type-field'),
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: _changeEventType,
        child: SizedBox(
          key: _eventTypeAnchorKey,
          height: 52,
          child: InputDecorator(
            decoration: _measuredInputDecoration(
              context,
              labelText: _isContactEvent ? 'Contact Type' : 'Event Type',
              suffixIcon: const KeyedSubtree(
                key: Key('change-event-type-button'),
                child: Icon(Icons.arrow_drop_down, size: 24),
              ),
            ),
            child: Text(
              _formTypeDisplayLabel(),
              key: const Key('selected-event-type-label'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTypography.body.copyWith(
                color: AppTheme.onFillTextOf(context, 1.0),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRepeatField() {
    return DropdownButtonFormField<_CalendarEventRepeatChoice>(
      key: const Key('event-recurrence-frequency'),
      initialValue: _repeatChoice,
      isExpanded: true,
      icon: const Icon(Icons.keyboard_arrow_down, size: 24),
      decoration: _measuredInputDecoration(context, labelText: 'Repeat')
          .copyWith(
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            filled: false,
            contentPadding: EdgeInsets.zero,
          ),
      items: <DropdownMenuItem<_CalendarEventRepeatChoice>>[
        for (final value in _CalendarEventRepeatChoice.values)
          DropdownMenuItem<_CalendarEventRepeatChoice>(
            value: value,
            child: Text(_repeatChoiceLabel(value), style: AppTypography.body),
          ),
      ],
      onChanged: (value) {
        if (value == null) {
          return;
        }
        final previous = _repeatChoice;
        if (value == _CalendarEventRepeatChoice.custom) {
          setState(() => _repeatChoice = value);
          unawaited(_openCustomRepeat(previous));
          return;
        }
        setState(() => _configureRepeatChoice(value));
      },
    );
  }

  void _configureRepeatChoice(_CalendarEventRepeatChoice choice) {
    _repeatChoice = choice;
    _recurrencePattern = null;
    _legacyRecurrenceEndControls = false;
    _recurrenceEndDateCustomized = false;
    _frequency = switch (choice) {
      _CalendarEventRepeatChoice.none => CalendarRecurrenceFrequency.none,
      _CalendarEventRepeatChoice.daily => CalendarRecurrenceFrequency.daily,
      _CalendarEventRepeatChoice.weekly => CalendarRecurrenceFrequency.weekly,
      _CalendarEventRepeatChoice.monthly => CalendarRecurrenceFrequency.monthly,
      _CalendarEventRepeatChoice.yearly => CalendarRecurrenceFrequency.yearly,
      _CalendarEventRepeatChoice.custom => _frequency,
    };
    if (_frequency == CalendarRecurrenceFrequency.none) {
      _endMode = CalendarRecurrenceEndMode.never;
      _recurrenceEndDate = null;
      return;
    }
    _endMode = CalendarRecurrenceEndMode.onDate;
    _recurrenceEndDate = calendarDefaultRecurrenceEndDate(_date, _frequency);
  }

  Future<void> _openCustomRepeat(
    _CalendarEventRepeatChoice previousChoice,
  ) async {
    final editingCustom =
        previousChoice == _CalendarEventRepeatChoice.custom &&
        _recurrencePattern != null;
    final previousFrequency = _frequency;
    final result = await Navigator.of(context).push<CalendarCustomRepeatResult>(
      MaterialPageRoute<CalendarCustomRepeatResult>(
        builder: (_) => CalendarEventCustomRepeatScreen(
          startDate: _date,
          initialFrequency: editingCustom
              ? _frequency
              : CalendarRecurrenceFrequency.weekly,
          initialPattern: editingCustom ? _recurrencePattern : null,
        ),
      ),
    );
    if (!mounted) {
      return;
    }
    if (result == null) {
      setState(() => _repeatChoice = previousChoice);
      return;
    }
    final preserveConcreteEnd =
        editingCustom &&
        previousFrequency == result.frequency &&
        !_legacyRecurrenceEndControls &&
        _endMode == CalendarRecurrenceEndMode.onDate &&
        _recurrenceEndDate != null;
    setState(() {
      _repeatChoice = _CalendarEventRepeatChoice.custom;
      _frequency = result.frequency;
      _recurrencePattern = result.pattern;
      _legacyRecurrenceEndControls = false;
      _endMode = CalendarRecurrenceEndMode.onDate;
      if (!preserveConcreteEnd) {
        _recurrenceEndDate = calendarDefaultRecurrenceEndDate(
          _date,
          _frequency,
        );
        _recurrenceEndDateCustomized = false;
      }
    });
  }

  Future<void> _loadExisting() async {
    final controller = ref.read(calendarEventControllerProvider.notifier);
    final draft = await controller.readEventDraft(widget.eventId!);
    final occurrence = await controller.readOccurrence(
      eventId: widget.eventId!,
      originalDate: widget.originalDate!,
    );
    final startup = ref.read(startupControllerProvider);
    ReminderPolicy? reminderPolicy;
    if (startup is StartupReady) {
      final occurrenceId = widget.scope == CalendarEventEditScope.occurrence
          ? CalendarEventOccurrenceIdentity.forDate(
              eventId: widget.eventId!,
              originalDate: widget.originalDate!,
            )
          : ReminderPolicy.seriesOccurrenceId;
      final policies = await ref
          .read(notificationFoundationRepositoryProvider)
          .readPolicies(
            profileId: startup.profile.id,
            sourceKind: ReminderSourceKind.calendarEvent,
            sourceId: widget.eventId!,
          );
      // OWNER HOTFIX (2026-09-19) — resolve EXACTLY as ReminderReconciler does:
      // the occurrence policy first, then the SERIES policy.
      //
      // Before this the form looked at the occurrence key alone. The create path
      // and an "All events" edit both store the reminder at series scope, so the
      // form could not see the user's own choice, fell back to `inherit`, and
      // rendered the global default ("Default (10 min before)") instead of the
      // offset the user had just set — and the next save then wrote an occurrence
      // `inherit` row that shadowed the real series override, silently reverting
      // the reminder to the default.
      reminderPolicy = policies.resolveForOccurrence(occurrenceId);
    }
    if (!mounted) {
      return;
    }
    if (draft == null) {
      setState(() => _loading = false);
      return;
    }
    _titleController.text = draft.title;
    _notesController.text = draft.notes ?? '';
    _locationController.text = draft.locationText ?? '';
    _locationExpanded = _locationController.text.trim().isNotEmpty;
    _addressExpanded = _locationExpanded;
    if (widget.mode == CalendarEventFormMode.edit ||
        widget.mode == CalendarEventFormMode.reschedule) {
      MapCoordinate? coordinate;
      try {
        coordinate = await ref
            .read(mapCoordinateRepositoryProvider)
            .readCoordinate(
              profileId: ref.read(mapProfileIdProvider),
              owner: MapCoordinateOwner.event,
              recordId: widget.eventId!,
            );
      } on Object {
        // Maps layer unavailable: edit still works without a pin.
        coordinate = null;
      }
      _mapCoordinate = coordinate;
      _initialMapCoordinate = coordinate;
    }
    _timeZoneController.text =
        occurrence?.timeZoneId ??
        draft.timeZoneId ??
        ref.read(calendarEventControllerProvider.notifier).displayTimeZoneId;
    // Editing must round-trip the event's source-zone wall time. The
    // occurrence display values are intentionally converted for the planner
    // viewer and can represent a different local date/time when the device
    // zone differs from the event zone.
    final occurrenceStart = _sourceWallTime(occurrence, occurrence?.startUtc);
    final occurrenceEnd = _sourceWallTime(occurrence, occurrence?.endUtc);
    final occurrenceDate = occurrenceStart == null
        ? occurrence?.displayDate
        : PlannerDate.fromDateTime(occurrenceStart);
    _date =
        occurrenceDate ??
        (widget.mode == CalendarEventFormMode.reschedule
            ? widget.originalDate!
            : draft.startDate);
    _timing = draft.timing;
    _currentStatus = occurrence?.status ?? draft.status;
    _loadedReportStatus = _currentStatus;
    final startWall = occurrenceStart ?? occurrence?.startDisplay;
    final endWall = occurrenceEnd ?? occurrence?.endDisplay;
    _start = startWall == null
        ? _timeFromMinute(draft.startMinute ?? 9 * 60)
        : TimeOfDay.fromDateTime(startWall);
    _end = endWall == null
        // A stored 24:00 end (final-hour 11 PM-12 AM slot) displays as
        // 12:00 AM; it is saved back as minute 1440 via [_endMinuteOfDay].
        ? _timeFromMinute(
            (draft.endMinute ?? 10 * 60) == 1440
                ? 0
                : draft.endMinute ?? 10 * 60,
          )
        : TimeOfDay.fromDateTime(endWall);
    _durationWasEntered = true;
    _requiresReport = draft.requiresReport;
    _loadedEventTypeStableKey =
        occurrence?.activityTypeStableKey ??
        draft.activityTypeStableKeySnapshot;
    _loadedEventTypeLabel =
        occurrence?.activityTypeLabel ?? draft.activityTypeLabelSnapshot;
    _loadedTypeId = draft.activityTypeId;
    // O9: a fresh load is not a deliberate selection.  The displayed label
    // follows the loaded effective occurrence until the user picks a type.
    _eventTypeSelectionChanged = false;
    // Owner fix: prefill Backup from the effective occurrence (which merges
    // occurrence-scoped overrides) so a Backup set via "This event only" —
    // or by an earlier edit — still shows ON when the form is reopened.
    // Reading the master draft alone would show OFF and a save would
    // silently drop the Backup state.
    _isBackupAppointment =
        occurrence?.isBackupAppointment ?? draft.isBackupAppointment;
    _backupForEventId = occurrence?.backupForEventId ?? draft.backupForEventId;
    _backupRelationshipProvenance =
        occurrence?.backupRelationshipProvenance ??
        draft.backupRelationshipProvenance;
    _reportEligible =
        widget.mode == CalendarEventFormMode.edit &&
        occurrence != null &&
        _requiresReport &&
        !_isFutureOccurrence(occurrence) &&
        !_isBackupAppointment;
    final statusIntent = widget.initialStatusIntent;
    if (_reportEligible &&
        statusIntent != null &&
        _isSelectableStatus(statusIntent)) {
      _currentStatus = statusIntent;
    }
    _frequency =
        widget.mode == CalendarEventFormMode.reschedule &&
            widget.scope == CalendarEventEditScope.occurrence
        ? CalendarRecurrenceFrequency.none
        : draft.recurrence.frequency;
    _recurrencePattern = _frequency == CalendarRecurrenceFrequency.none
        ? null
        : draft.recurrence.pattern;
    _repeatChoice = _repeatChoiceFor(_frequency, _recurrencePattern);
    if (widget.mode == CalendarEventFormMode.edit) {
      _sourceFrequency = draft.recurrence.frequency;
    }
    _endMode = _frequency == CalendarRecurrenceFrequency.none
        ? CalendarRecurrenceEndMode.never
        : draft.recurrence.endMode;
    _recurrenceEndDate = draft.recurrence.endDate;
    _legacyRecurrenceEndControls =
        _frequency != CalendarRecurrenceFrequency.none &&
        _endMode != CalendarRecurrenceEndMode.onDate;
    _recurrenceEndDateCustomized = _recurrenceEndDate != null;
    _countController.text = (draft.recurrence.occurrenceCount ?? 2).toString();
    _selectedGoalId = draft.goalId;
    _reminderMode = reminderPolicy?.mode ?? ReminderPolicyMode.inherit;
    _reminderOffsetMinutes = reminderPolicy?.offsetMinutes;
    // A fresh load is not a deliberate reminder choice.
    _reminderSelectionChanged = false;
    setState(() => _loading = false);
  }

  DateTime? _sourceWallTime(
    CalendarEventOccurrence? occurrence,
    DateTime? instant,
  ) {
    final timeZoneId = occurrence?.timeZoneId;
    if (instant == null || timeZoneId == null) {
      return null;
    }
    try {
      return IanaCalendarEventTimeZones(
        displayTimeZoneId: timeZoneId,
      ).utcToWall(value: instant, timeZoneId: timeZoneId);
    } on Object {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.initialDraftId != null) {
      ref.watch(plannerEventCreationDraftProvider);
    }
    final message =
        ref.watch(calendarEventControllerProvider) ??
        ref.watch(taskEventLinkControllerProvider);
    final lockedWli = _selectedEventType?.isLockedWliType == true;
    // One canonical Life Goal relationship: a manual Goal link or the
    // automatic fixed Goal assignment of a locked Event Type both count as
    // linked, and both force Report Required ON (locked invariant).
    // Planner Polish Delta 2: the Contact Event Type is also always Report
    // Required and locks the toggle while selected.
    final lifeIndicatorLinked = _selectedGoalId != null || lockedWli;
    final contactMandatory =
        _selectedEventType?.stableKey == SystemEventTypeKeys.contact;
    final reportingLocked = lifeIndicatorLinked || contactMandatory;
    // The pencil opens an ordinary Event edit.  Only the explicit Current
    // Status action carries a reporting intent and exposes the staged status
    // controls in this form.
    final showStatusSection =
        widget.initialStatusIntent != null &&
        widget.mode == CalendarEventFormMode.edit &&
        _reportEligible &&
        _requiresReport;
    final bottomPadding = widget.sheetPresentation
        ? 24.0 + MediaQuery.of(context).viewInsets.bottom
        : 120.0;
    final content = _loading || _configurationLoading
        ? _loadingShell(context)
        : SafeArea(
            top: !widget.sheetPresentation,
            child: GestureDetector(
              key: const Key('event-form-blank-space-dismiss'),
              behavior: HitTestBehavior.translucent,
              onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
              child: Form(
                key: _formKey,
                child: ListView(
                  key: const Key('calendar-event-form-scroll'),
                  controller: widget.sheetScrollController,
                  padding: EdgeInsets.fromLTRB(
                    16,
                    widget.sheetPresentation ? 14 : 12,
                    16,
                    bottomPadding,
                  ),
                  children: <Widget>[
                    if (widget.sourceTaskId != null) ...<Widget>[
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: <Widget>[
                              const _FormSectionLabel(
                                icon: Icons.link_outlined,
                                label: 'Task link',
                              ),
                              const SizedBox(height: 8),
                              DropdownButtonFormField<TaskEventCanonicalSource>(
                                key: const Key('create-event-canonical-source'),
                                initialValue: _canonicalSource,
                                decoration: const InputDecoration(
                                  labelText: 'Planning source',
                                ),
                                items: TaskEventCanonicalSource.values
                                    .map(
                                      (value) => DropdownMenuItem(
                                        value: value,
                                        child: Text(
                                          taskEventCanonicalSourceLabel(value),
                                        ),
                                      ),
                                    )
                                    .toList(),
                                onChanged: (value) =>
                                    setState(() => _canonicalSource = value!),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                    if (message != null) ...<Widget>[
                      _ErrorBanner(message: message),
                      const SizedBox(height: 16),
                    ],
                    if (showStatusSection) ...<Widget>[
                      _buildCurrentStatusSection(),
                      const SizedBox(height: 22),
                    ],
                    _buildEventTypeField(),
                    const SizedBox(height: 22),
                    TextFormField(
                      key: const Key('event-title-field'),
                      controller: _titleController,
                      decoration: _measuredInputDecoration(
                        context,
                        labelText: 'Title',
                      ),
                      maxLines: 1,
                      textInputAction: TextInputAction.next,
                    ),
                    const SizedBox(height: 22),
                    TextFormField(
                      key: const Key('event-notes-field'),
                      controller: _notesController,
                      focusNode: _notesFocusNode,
                      decoration: _measuredInputDecoration(
                        context,
                        hintText: _notesPromptText,
                        hintMaxLines: _usesNormalNotesBodyHint ? 3 : null,
                        alignLabelWithHint: true,
                      ),
                      minLines: _usesNormalNotesBodyHint
                          ? 4
                          : _notesFocusNode.hasFocus
                          ? 4
                          : 1,
                      maxLines: _usesNormalNotesBodyHint
                          ? 6
                          : _notesFocusNode.hasFocus
                          ? 6
                          : 1,
                    ),
                    const SizedBox(height: 12),
                    const _MeasuredFormSeparator(
                      key: Key('event-form-scheduling-separator'),
                    ),
                    const SizedBox(height: 12),
                    const _MeasuredFormSectionHeader(
                      label: 'Scheduling Details',
                    ),
                    const SizedBox(height: 20),
                    _DateTile(
                      key: const Key('event-date-field'),
                      label: 'Date',
                      date: _date,
                      onTap: () => _selectDate(
                        initial: _date,
                        onSelected: _setEventDate,
                      ),
                    ),
                    if (_timing == CalendarEventTiming.timed) ...<Widget>[
                      const SizedBox(height: 8),
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: _TimeTile(
                              key: const Key('event-start-time'),
                              label: 'From',
                              value: _start,
                              onTap: () => _selectTime(
                                initial: _start,
                                onSelected: _setStartTime,
                              ),
                            ),
                          ),
                          const SizedBox(width: 32),
                          Expanded(
                            child: _TimeTile(
                              key: const Key('event-end-time'),
                              label: 'To',
                              value: _end,
                              onTap: () => _selectTime(
                                initial: _end,
                                onSelected: _setEndTime,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      ListTile(
                        key: const Key('event-reminder-policy'),
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Reminder'),
                        trailing: Text(_reminderLabel()),
                        onTap: _selectReminderPolicy,
                      ),
                    ],
                    if (_timing == CalendarEventTiming.allDay)
                      const Padding(
                        padding: EdgeInsets.only(top: 12),
                        child: Text(
                          'All day event',
                          style: AppTypography.secondary,
                        ),
                      ),
                    const SizedBox(height: 16),
                    _buildRepeatField(),
                    if (_frequency !=
                        CalendarRecurrenceFrequency.none) ...<Widget>[
                      const SizedBox(height: 20),
                      if (_legacyRecurrenceEndControls) ...<Widget>[
                        DropdownButtonFormField<CalendarRecurrenceEndMode>(
                          key: const Key('event-recurrence-end-mode'),
                          initialValue: _endMode,
                          decoration: _measuredInputDecoration(
                            context,
                            labelText: 'Recurrence end',
                          ),
                          items:
                              const <
                                DropdownMenuItem<CalendarRecurrenceEndMode>
                              >[
                                DropdownMenuItem<CalendarRecurrenceEndMode>(
                                  value: CalendarRecurrenceEndMode.never,
                                  child: Text('No end'),
                                ),
                                DropdownMenuItem<CalendarRecurrenceEndMode>(
                                  value: CalendarRecurrenceEndMode.onDate,
                                  child: Text('End on date'),
                                ),
                                DropdownMenuItem<CalendarRecurrenceEndMode>(
                                  value: CalendarRecurrenceEndMode.afterCount,
                                  child: Text('End after count'),
                                ),
                              ],
                          onChanged: (value) => setState(() {
                            _endMode = value ?? CalendarRecurrenceEndMode.never;
                            if (_endMode == CalendarRecurrenceEndMode.onDate &&
                                _recurrenceEndDate == null) {
                              _recurrenceEndDate =
                                  calendarDefaultRecurrenceEndDate(
                                    _date,
                                    _frequency,
                                  );
                            }
                          }),
                        ),
                        if (_endMode == CalendarRecurrenceEndMode.onDate)
                          _DateTile(
                            key: const Key('event-recurrence-legacy-end-date'),
                            label: 'Last occurrence',
                            date: _recurrenceEndDate ?? _date,
                            onTap: () => _selectDate(
                              initial: _recurrenceEndDate ?? _date,
                              onSelected: (value) => setState(() {
                                _recurrenceEndDate = value;
                                _recurrenceEndDateCustomized = true;
                              }),
                            ),
                          ),
                        if (_endMode == CalendarRecurrenceEndMode.afterCount)
                          TextFormField(
                            key: const Key('event-recurrence-count'),
                            controller: _countController,
                            decoration: const InputDecoration(
                              labelText: 'Number of occurrences',
                            ),
                            keyboardType: TextInputType.number,
                            validator: (value) {
                              final parsed = int.tryParse(value ?? '');
                              return parsed == null || parsed < 1
                                  ? 'Enter at least 1'
                                  : null;
                            },
                          ),
                      ] else
                        _DateTile(
                          key: const Key('event-recurrence-end-date'),
                          label: 'End repeat',
                          date:
                              _recurrenceEndDate ??
                              calendarDefaultRecurrenceEndDate(
                                _date,
                                _frequency,
                              ),
                          onTap: () => _selectDate(
                            initial:
                                _recurrenceEndDate ??
                                calendarDefaultRecurrenceEndDate(
                                  _date,
                                  _frequency,
                                ),
                            onSelected: (value) => setState(() {
                              _recurrenceEndDate = value;
                              _recurrenceEndDateCustomized = true;
                            }),
                          ),
                        ),
                    ],
                    const SizedBox(height: 16),
                    SwitchListTile(
                      key: const Key('event-backup-appointment-switch'),
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Backup Event'),
                      value: _isBackupAppointment,
                      onChanged: (value) {
                        FocusScope.of(context).unfocus();
                        setState(() => _isBackupAppointment = value);
                      },
                    ),
                    const SizedBox(height: 16),
                    _buildAddressLocationSection(),
                    const SizedBox(height: 12),
                    const _MeasuredFormSeparator(
                      key: Key('event-form-people-separator'),
                    ),
                    const SizedBox(height: 12),
                    _buildPeopleSection(),
                    const SizedBox(height: 12),
                    const _MeasuredFormSeparator(
                      key: Key('event-form-indicator-separator'),
                    ),
                    const SizedBox(height: 12),
                    _buildLifeIndicatorSection(),
                    const SizedBox(height: 24),
                    _FormSectionLabel(
                      icon: Icons.fact_check_outlined,
                      label: 'Reporting & progress context',
                      color: reportingLocked ? const Color(0xFF8E9295) : null,
                      iconColor: reportingLocked
                          ? const Color(0xFF85898C)
                          : null,
                    ),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: reportingLocked
                            ? (Theme.of(context).brightness == Brightness.dark
                                  ? const Color(0xFF26282A)
                                  : Theme.of(
                                      context,
                                    ).colorScheme.surfaceContainerHighest)
                            : Colors.transparent,
                      ),
                      child: SwitchListTile(
                        key: const Key('event-requires-report-switch'),
                        contentPadding: reportingLocked
                            ? const EdgeInsets.symmetric(horizontal: 12)
                            : EdgeInsets.zero,
                        activeThumbColor: reportingLocked
                            ? (Theme.of(context).brightness == Brightness.dark
                                  ? const Color(0xFF777B7E)
                                  : const Color(0xFF8E9295))
                            : null,
                        activeTrackColor: reportingLocked
                            ? (Theme.of(context).brightness == Brightness.dark
                                  ? const Color(0xFF4B4F52)
                                  : Theme.of(
                                      context,
                                    ).colorScheme.outlineVariant)
                            : null,
                        inactiveThumbColor: reportingLocked
                            ? (Theme.of(context).brightness == Brightness.dark
                                  ? const Color(0xFF777B7E)
                                  : const Color(0xFF8E9295))
                            : null,
                        inactiveTrackColor: reportingLocked
                            ? const Color(0xFF4B4F52)
                            : null,
                        title: Text(
                          reportingLocked
                              ? 'Report Required'
                              : 'Optional — Report Required',
                          style: reportingLocked
                              ? const TextStyle(color: Color(0xFF8E9295))
                              : null,
                        ),
                        subtitle: lifeIndicatorLinked
                            ? const Text(
                                'Required because this Event is linked to a '
                                'Life Goal.',
                                style: TextStyle(color: Color(0xFF6F7376)),
                              )
                            : contactMandatory
                            ? const Text(
                                'Required for Contact Events.',
                                style: TextStyle(color: Color(0xFF6F7376)),
                              )
                            : null,
                        value: _requiresReport,
                        onChanged: reportingLocked
                            ? null
                            : (value) {
                                FocusScope.of(context).unfocus();
                                setState(() => _requiresReport = value);
                              },
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ),
          );
    if (!widget.sheetPresentation) {
      return Scaffold(
        appBar: InternalAppBar(
          title: Text(_formHeading),
          actions: <Widget>[_buildSaveButton()],
        ),
        body: content,
      );
    }
    return Material(
      key: const Key('calendar-event-detail-sheet'),
      color: Theme.of(context).scaffoldBackgroundColor,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: <Widget>[
          GestureDetector(
            key: const Key('calendar-event-sheet-header'),
            behavior: HitTestBehavior.opaque,
            onVerticalDragUpdate: _handleSheetDragUpdate,
            child: Column(
              children: <Widget>[
                const SizedBox(height: 8),
                Container(
                  key: const Key('calendar-event-sheet-handle'),
                  width: 32,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Theme.of(context).brightness == Brightness.dark
                        ? Colors.white38
                        : Theme.of(
                            context,
                          ).colorScheme.onSurface.withValues(alpha: 0.38),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: <Widget>[
                      IconButton(
                        key: const Key('calendar-event-sheet-close'),
                        tooltip: 'Close',
                        constraints: const BoxConstraints(
                          minWidth: 48,
                          minHeight: 48,
                        ),
                        padding: EdgeInsets.zero,
                        iconSize: 28,
                        onPressed: () => _closeForm(false),
                        icon: const Icon(Icons.close),
                      ),
                      const Spacer(),
                      _buildSaveButton(),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Expanded(child: content),
        ],
      ),
    );
  }

  void _handleSheetDragUpdate(DragUpdateDetails details) {
    final controller = widget.sheetController;
    if (controller == null || !controller.isAttached) {
      return;
    }
    final delta = details.primaryDelta;
    if (delta == null) {
      return;
    }
    final viewportHeight = MediaQuery.sizeOf(context).height;
    final nextSize = (controller.size - delta / viewportHeight)
        .clamp(widget.sheetMinChildSize, widget.sheetMaxChildSize)
        .toDouble();
    if ((nextSize - controller.size).abs() > 0.0001) {
      controller.jumpTo(nextSize);
    }
  }

  String get _notesPromptText {
    // Status-tap navigation marks the canonical staged Event reporting flow.
    // Normal Event create/edit retains its general Notes prompt even though an
    // ordinary edit may display the status section for context.
    if (widget.initialStatusIntent == null) {
      return 'Notes: What do you need to remember about this?';
    }
    return switch (_currentStatus) {
      CalendarEventStatus.didNotHappen => "Notes: Why wasn't this attempted?",
      CalendarEventStatus.partiallyCompleted => 'Notes: Why was this missed?',
      CalendarEventStatus.completedHappened =>
        'Notes: What happened? What went well?',
      _ => 'Notes: What do you need to remember about this?',
    };
  }

  bool get _usesNormalNotesBodyHint => widget.initialStatusIntent == null;

  Widget _buildSaveButton() {
    final colorScheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: 'Save event',
      child: Semantics(
        button: true,
        label: 'Save event',
        child: FilledButton(
          key: const Key('save-event-button'),
          onPressed: _saving || _loading || _configurationLoading
              ? null
              : _save,
          style: FilledButton.styleFrom(
            minimumSize: const Size(48, 48),
            padding: EdgeInsets.zero,
            shape: const CircleBorder(),
            backgroundColor: colorScheme.primary,
            foregroundColor: colorScheme.onPrimary,
            disabledBackgroundColor: colorScheme.primary.withValues(
              alpha: 0.35,
            ),
          ),
          child: _saving
              ? SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: colorScheme.onPrimary,
                  ),
                )
              : Icon(Icons.check, size: 26, color: colorScheme.onPrimary),
        ),
      ),
    );
  }

  Widget _buildAddressLocationSection() {
    return Column(
      key: const Key('event-address-location-section'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const Text(
          'Address',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        if (!_addressExpanded)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const Key('add-address-button'),
              onPressed: () => setState(() {
                _addressExpanded = true;
                _locationExpanded = false;
              }),
              style: _compactFormActionStyle(),
              icon: const Icon(Icons.add, size: 24),
              label: const Text('Address'),
            ),
          )
        else ...<Widget>[
          TextFormField(
            key: const Key('event-location-field'),
            controller: _locationController,
            decoration: _measuredInputDecoration(context, labelText: 'Address'),
            textInputAction: TextInputAction.next,
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              key: const Key('collapse-address-location-button'),
              onPressed: () => setState(() {
                _locationController.clear();
                _addressExpanded = false;
                _locationExpanded = false;
              }),
              style: _compactFormActionStyle(),
              icon: const Icon(Icons.close),
              label: const Text('Remove'),
            ),
          ),
        ],
        const SizedBox(height: 16),
        const Text(
          'Map',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        if (_mapCoordinate == null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const Key('add-map-button'),
              onPressed: _openEventMapPicker,
              style: _compactFormActionStyle(),
              icon: const Icon(Icons.add, size: 24),
              label: const Text('Map'),
            ),
          )
        else ...<Widget>[
          InkWell(
            key: const Key('event-map-preview'),
            onTap: _openEventMapPicker,
            borderRadius: BorderRadius.circular(8),
            child: Semantics(
              button: true,
              label: 'Change map location',
              child: ContactLocationPreview(coordinate: _mapCoordinate!),
            ),
          ),
          const SizedBox(height: 2),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              key: const Key('event-map-remove'),
              onPressed: () => setState(() => _mapCoordinate = null),
              style: _compactFormActionStyle(),
              child: const Text('Remove map'),
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _openEventMapPicker() async {
    final result = await context.push<MapCoordinate>(
      RoutePaths.mapPicker,
      extra: MapPickerArgs(
        displayName: _titleController.text.trim().isEmpty
            ? 'Event'
            : _titleController.text.trim(),
        initialCoordinate: _mapCoordinate,
      ),
    );
    if (result != null && mounted) {
      setState(() => _mapCoordinate = result);
    }
  }

  Widget _buildPeopleSection() {
    final csv = _peopleContactIds.join(',');
    return Column(
      key: const Key('event-people-section'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const _MeasuredFormSectionHeader(
          key: Key('people-section-header'),
          label: 'Contacts',
        ),
        const SizedBox(height: 12),
        if (_peopleContactIds.isEmpty)
          const Padding(
            padding: EdgeInsets.only(bottom: 4),
            child: Text(
              'No contacts linked yet.',
              style: TextStyle(color: Color(0xFF9CA0A6), fontSize: 14),
            ),
          )
        else
          ref
              .watch(contactSummariesByCsvProvider(csv))
              .when(
                loading: () => const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Center(
                    child: SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                ),
                error: (error, stack) => const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    'People could not be loaded.',
                    style: TextStyle(color: Color(0xFF9CA0A6)),
                  ),
                ),
                data: (byId) => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    for (final id in _peopleContactIds)
                      _PeopleChip(
                        id: id,
                        summary: byId[id],
                        onRemove: () => setState(() {
                          _peopleSelectionModified = true;
                          _peopleContactIds.remove(id);
                        }),
                      ),
                  ],
                ),
              ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            key: const Key('add-people-button'),
            onPressed: () => unawaited(_openAddPeople()),
            style: _rightAlignedFormActionStyle(),
            icon: const Icon(Icons.add, size: 24),
            label: const Text('Contact'),
          ),
        ),
      ],
    );
  }

  Future<void> _openAddPeople() async {
    final result = await context.push<List<String>>(
      RoutePaths.addPeople,
      extra: AddPeopleArgs(initialIds: _peopleContactIds),
    );
    if (result != null && mounted) {
      setState(() {
        _peopleSelectionModified = true;
        _peopleContactIds = List<String>.from(result);
      });
    }
  }

  /// Loads the exact occurrence People when one exists, otherwise the
  /// canonical series People inherited by that occurrence.
  Future<void> _loadExistingPeople() async {
    try {
      final occurrenceId = widget.originalDate == null
          ? 'series'
          : CalendarEventOccurrenceIdentity.forDate(
              eventId: widget.eventId!,
              originalDate: widget.originalDate!,
            );
      final summaries = await ref.read(
        eventPeopleProvider((
          eventId: widget.eventId!,
          occurrenceId: occurrenceId,
        )).future,
      );
      if (!mounted) {
        return;
      }
      final loadedIds = summaries.map((summary) => summary.contact.id).toSet();
      setState(() {
        _initialPeopleContactIds = loadedIds;
        if (!_peopleSelectionModified) {
          _peopleContactIds = loadedIds.toList();
        }
      });
    } on Object {
      // No ready Contacts profile/repository: keep the draft list untouched.
    }
  }

  IndicatorOption? _indicatorOption(String? key) {
    if (key == null) {
      return null;
    }
    return _indicatorOptions.where((option) => option.key == key).firstOrNull;
  }

  Future<void> _loadAvailableGoals() async {
    try {
      final goals = await ref.read(activeGoalsProvider.future);
      if (mounted) {
        setState(() => _availableGoals = goals);
      }
    } on Object {
      // No ready Local Profile / Goal repository in this environment: the
      // Goal section simply shows as unavailable instead of failing the form.
    }
  }

  /// Link to Life Indicator picker (approved selector).
  ///
  /// Selecting a Life Indicator turns Report Required ON immediately;
  /// removing the link keeps Report Required ON (an intentional user
  /// preference is never silently erased) but returns control of the toggle.
  /// A locked Event Type auto-assigns its fixed Life Indicator, so the picker
  /// is read-only for those types.
  Future<void> _chooseLifeIndicator() async {
    // The Goal list loads asynchronously after [initState]; if the user taps
    // before it settles, await the in-flight load (or re-read) so the empty
    // check below is truthful and no misleading snackbar is shown.
    if (_goalsLoad != null) {
      await _goalsLoad;
      if (!mounted) {
        return;
      }
    }
    final goals = _availableGoals;
    if (goals.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No Life Goals are available.')),
        );
      }
      return;
    }
    final type = _selectedEventType;
    final fixed = type?.isLockedWliType == true;
    Goal? fixedGoal;
    if (fixed) {
      fixedGoal = goals
          .where((goal) => goal.indicatorKey == type?.exactIndicatorKey)
          .firstOrNull;
    }
    final linkedId = _selectedGoalId ?? fixedGoal?.id;
    final selected = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) {
        final colorScheme = Theme.of(sheetContext).colorScheme;
        return SafeArea(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 560),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 4),
                  child: Text(
                    'Link to Life Goal',
                    style: TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w700,
                      color: colorScheme.onSurface,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                  child: Text(
                    'Choose the goal this Event should contribute to.',
                    style: TextStyle(
                      color: colorScheme.onSurfaceVariant,
                      fontSize: 13,
                    ),
                  ),
                ),
                Flexible(
                  child: ListView.builder(
                    key: const Key('life-indicator-picker'),
                    shrinkWrap: true,
                    itemCount: goals.length,
                    itemBuilder: (context, index) {
                      final goal = goals[index];
                      final isSelected = goal.id == linkedId;
                      return Container(
                        margin: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: isSelected
                                ? colorScheme.primary
                                : Colors.transparent,
                          ),
                        ),
                        child: Material(
                          color: isSelected
                              ? colorScheme.primaryContainer
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(12),
                          child: ListTile(
                            key: Key('life-indicator-option-${goal.id}'),
                            leading: GoalIcon(
                              iconId: goal.iconId,
                              // GI-02: exactly 2x (24 -> 48).
                              size: 48,
                              semanticLabel: goal.title,
                              // Step 8 (R01): fallback uses the Goal
                              // artwork-family blue (#5CAEC9).
                              color: AppTheme.goalIconFallbackBlue,
                            ),
                            title: Text(
                              goal.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: isSelected
                                ? Icon(
                                    Icons.check,
                                    color: colorScheme.primary,
                                    size: 20,
                                  )
                                : null,
                            onTap: fixed
                                ? null
                                : () => Navigator.of(sheetContext).pop(goal.id),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                if (!fixed && linkedId != null) ...<Widget>[
                  const Divider(height: 1),
                  ListTile(
                    key: const Key('life-indicator-remove-link'),
                    leading: Icon(
                      Icons.delete_outline,
                      color: colorScheme.primary,
                      size: 20,
                    ),
                    title: Text(
                      'Remove Life Goal link',
                      style: TextStyle(color: colorScheme.primary),
                    ),
                    onTap: () => Navigator.of(sheetContext).pop('__none__'),
                  ),
                ],
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Center(
                    child: TextButton(
                      key: const Key('life-indicator-picker-cancel'),
                      onPressed: () => Navigator.of(sheetContext).pop(),
                      child: const Text('Cancel'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (!mounted || selected == null) {
      return;
    }
    setState(() {
      if (selected == '__none__') {
        _selectedGoalId = null;
        return;
      }
      final goal = goals
          .where((candidate) => candidate.id == selected)
          .firstOrNull;
      _selectedGoalId = selected;
      // A Life Indicator link forces Report Required ON (locked invariant)
      // and drives the canonical contribution rule through its indicator key.
      _requiresReport = true;
      if (goal?.indicatorKey != null) {
        _linkedIndicatorKey = goal!.indicatorKey;
      }
    });
  }

  /// Unified Life Indicator section (approved design).
  ///
  /// The Event has exactly ONE Life Indicator relationship.  A locked Event
  /// Type auto-assigns its fixed Life Indicator (read-only row); otherwise
  /// the row opens the Link to Life Indicator picker.  The linked state locks
  /// the Report Required toggle below.
  Widget _buildLifeIndicatorSection() {
    final goals = _availableGoals;
    final type = _selectedEventType;
    final wliLocked = type?.isLockedWliType == true;
    // Resolve the linked Life Indicator by its stable ID.  Active indicators
    // come from the loaded list; a link to an archived indicator is resolved
    // by ID so the archived name/icon still renders on existing Events while
    // archived indicators stay hidden from new linking.
    final linkedGoalId =
        _selectedGoalId ??
        (wliLocked
            ? goals
                  .where((goal) => goal.indicatorKey == type?.exactIndicatorKey)
                  .firstOrNull
                  ?.id
            : null);
    Goal? linkedGoal;
    if (linkedGoalId != null) {
      linkedGoal ??= goals.where((goal) => goal.id == linkedGoalId).firstOrNull;
      linkedGoal ??= ref.watch(goalByIdProvider(linkedGoalId)).value;
    }
    final linked = linkedGoalId != null || wliLocked;
    final subtitle = linked
        ? (wliLocked
              ? 'Linked automatically by Event Type'
              : 'Linked to this Event')
        : 'No Life Goal linked';
    return Column(
      key: const Key('event-life-indicator-section'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const _MeasuredFormSectionHeader(
          key: Key('life-indicator-section-header'),
          label: 'Life Goal',
        ),
        const SizedBox(height: 12),
        Container(
          decoration: BoxDecoration(
            // POLISH-04: Light uses the semantic near-white surface + outline
            // (never a gray container slab); Dark keeps its fill.
            color: Theme.of(context).brightness == Brightness.dark
                ? const Color(0xFF1C1E21)
                : Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: Theme.of(context).brightness == Brightness.dark
                  ? const Color(0xFF2A2D31)
                  : Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              key: const Key('life-indicator-link-section'),
              onTap: wliLocked ? null : _chooseLifeIndicator,
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 14,
                ),
                child: Row(
                  children: <Widget>[
                    GoalIcon(
                      iconId: linkedGoal?.iconId,
                      // GI-02: exactly 2x (26 -> 52).
                      size: 52,
                      semanticLabel: linkedGoal?.title,
                      fallbackIcon: Icons.track_changes_outlined,
                      // Step 8 (R01): the linked-Goal fallback uses the Goal
                      // artwork-family blue (#5CAEC9).
                      color: AppTheme.goalIconFallbackBlue,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            linkedGoal?.title ?? 'Life Goal',
                            key: const Key('life-indicator-link-value'),
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 3),
                          Text(
                            subtitle,
                            key: const Key('life-indicator-link-subtitle'),
                            style: const TextStyle(
                              color: Color(0xFF8E9295),
                              fontSize: 13,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    if (wliLocked)
                      const Icon(
                        Icons.lock_outline,
                        size: 16,
                        color: Color(0xFF6F7376),
                      )
                    else
                      const Icon(
                        Icons.chevron_right,
                        size: 20,
                        color: Color(0xFF8E9295),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  bool get _isContactEvent {
    final stableKey =
        _loadedEventTypeStableKey ?? _selectedEventType?.stableKey;
    if (stableKey == SystemEventTypeKeys.meaningfulConnection ||
        stableKey == SystemEventTypeKeys.contact) {
      return true;
    }
    final value =
        _loadedEventTypeLabel ??
        _selectedEventType?.label ??
        widget.initialEventTypeLabel;
    final normalized = value?.trim().toLowerCase();
    return normalized != null && normalized.contains('contact');
  }

  static bool _isFutureOccurrence(CalendarEventOccurrence occurrence) {
    final nowUtc = DateTime.now().toUtc();
    final today = PlannerDate.fromDateTime(DateTime.now());
    return occurrence.timing == CalendarEventTiming.allDay
        ? occurrence.displayDate.compareTo(today) > 0
        : occurrence.startUtc?.isAfter(nowUtc) ?? false;
  }

  bool _isSelectableStatus(CalendarEventStatus status) => switch (status) {
    CalendarEventStatus.scheduled ||
    CalendarEventStatus.didNotHappen ||
    CalendarEventStatus.partiallyCompleted ||
    CalendarEventStatus.completedHappened => true,
    CalendarEventStatus.cancelled || CalendarEventStatus.rescheduled => false,
  };

  Widget _buildCurrentStatusSection() => Column(
    key: const Key('event-status-section'),
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      EventCurrentStatusControlRow(
        currentStatus: _currentStatus,
        isContactEvent: _isContactEvent,
        saving: _saving,
        onSelect: (status) {
          FocusScope.of(context).unfocus();
          if (!_isSelectableStatus(status)) {
            return;
          }
          setState(() => _currentStatus = status);
        },
      ),
    ],
  );

  /// O9 (section 66): the Edit heading must agree with the type field, so it
  /// resolves through the SAME effective display label rather than the raw
  /// master row.  When no trustworthy label exists the form keeps the plain
  /// "Edit Event" wording instead of inventing a semantic type.
  String get _formHeading => switch (widget.mode) {
    CalendarEventFormMode.create when widget.sourceTaskId != null =>
      'Create Event from Task',
    CalendarEventFormMode.create =>
      _selectedEventType == null
          ? 'Create Event'
          : 'Create ${_resolvedHeadingLabel()}',
    CalendarEventFormMode.edit =>
      _selectedEventType == null
          ? widget.initialEventTypeLabel?.trim().isNotEmpty == true
                ? 'Edit ${widget.initialEventTypeLabel} Event'
                : 'Edit Event'
          : _trustworthyTypeLabel() == null
          ? 'Edit Event'
          : 'Edit ${_resolvedHeadingLabel()} Event',
    CalendarEventFormMode.reschedule => 'Reschedule Event',
  };

  /// The heading label, resolved exactly like [_formTypeDisplayLabel] so the
  /// heading and the type field can never disagree about the same Event.
  String _resolvedHeadingLabel() {
    final label = _formTypeDisplayLabel();
    return label == 'Not selected' ? 'Event' : label;
  }

  /// The type label for heading purposes, or null when the only available
  /// wording would be an untrustworthy raw fallback for an existing type.
  String? _trustworthyTypeLabel() {
    if (widget.mode == CalendarEventFormMode.create ||
        _eventTypeSelectionChanged) {
      return _formTypeDisplayLabel();
    }
    final loaded = _loadedEventTypeLabel?.trim();
    if (loaded != null && loaded.isNotEmpty) {
      return loaded;
    }
    return _creationChoiceLabelOf(_selectedEventType!.id);
  }

  /// NX-06: truthful Edit loading shell. When the detail sheet has already
  /// seeded the known identity, the loading state shows the seeded title
  /// above the spinner instead of a bare blank pause; entries with no seeds
  /// (deep-link / direct edit) keep the plain centered spinner.
  Widget _loadingShell(BuildContext context) {
    final seededTitle = widget.initialTitle?.trim().isNotEmpty == true
        ? widget.initialTitle
        : null;
    final hasSeeds =
        widget.mode == CalendarEventFormMode.edit &&
        (seededTitle != null ||
            widget.initialEventTypeLabel?.trim().isNotEmpty == true);
    if (!hasSeeds) {
      return const Center(child: CircularProgressIndicator());
    }
    return SafeArea(
      top: !widget.sheetPresentation,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
        children: <Widget>[
          if (seededTitle != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 18),
              child: Text(
                seededTitle,
                key: const Key('edit-loading-seed-title'),
                style: Theme.of(context).textTheme.titleMedium,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          const Center(child: CircularProgressIndicator()),
        ],
      ),
    );
  }

  ButtonStyle _compactFormActionStyle() {
    return TextButton.styleFrom(
      minimumSize: const Size(0, 48),
      padding: EdgeInsets.zero,
      alignment: Alignment.centerLeft,
      foregroundColor: Theme.of(context).colorScheme.primary,
      textStyle: AppTypography.button,
    );
  }

  ButtonStyle _rightAlignedFormActionStyle() {
    return TextButton.styleFrom(
      minimumSize: const Size(0, 48),
      padding: EdgeInsets.zero,
      alignment: Alignment.centerRight,
      foregroundColor: Theme.of(context).colorScheme.primary,
      textStyle: AppTypography.button,
    );
  }

  String? _scheduledPotentialRule() {
    final indicatorKey = _linkedIndicatorKey;
    if (indicatorKey == null) {
      return null;
    }
    final unit = _indicatorOption(indicatorKey)?.unit ?? 'count';
    return ScheduledPotentialRule(
      indicatorKey: indicatorKey,
      value: IndicatorAmount(scaledValue: 1, scale: 0, unit: unit),
    ).encode();
  }

  /// Contract E save guard: a NEW selection (create, or an explicit type
  /// change in edit mode) is re-resolved through current eligibility BEFORE
  /// any write. The transactional repository rechecks inside its own
  /// transaction too, so a Goal archived/reoccupied between this check and
  /// the write is still rejected there. A stale source falls back to the
  /// eligible Other type without touching the user's saved default or typed
  /// title; the user's input is preserved.
  Future<bool> _validateSelectionBeforeWrite() async {
    final selected = _selectedEventType;
    if (selected == null) {
      return true;
    }
    try {
      final choice = await findCreationChoiceById(ref, selected.id);
      if (choice == null) {
        await _fallbackToEligibleOther();
        return false;
      }
      return true;
    } on Object {
      await _fallbackToEligibleOther();
      return false;
    }
  }

  /// Falls back to the eligible Other type for the type field only. No
  /// preference write and no user text is touched.
  Future<void> _fallbackToEligibleOther() async {
    EventType? other;
    try {
      final choice = await findCreationChoiceById(
        ref,
        SystemEventTypeIds.other,
      );
      other = choice?.type;
    } on Object {
      other = null;
    }
    other ??= ref
        .read(eventTypeControllerProvider)
        .eventTypes
        .where(
          (type) =>
              type.stableKey == SystemEventTypeKeys.other &&
              type.isCreationVisible,
        )
        .firstOrNull;
    if (other != null && mounted) {
      setState(() => _selectedEventType = other);
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'This Event Type is no longer available. Choose another Event Type.',
          ),
        ),
      );
    }
  }

  Future<void> _save() async {
    ref.read(calendarEventControllerProvider.notifier).clearMessage();
    ref.read(taskEventLinkControllerProvider.notifier).clearMessage();
    final peopleLoad = _peopleLoad;
    if (peopleLoad != null) {
      await peopleLoad;
      if (!mounted) return;
    }
    if (!_formKey.currentState!.validate()) {
      return;
    }
    final startMinute = _start.hour * 60 + _start.minute;
    final endMinute = _endMinuteOfDay;
    if (_timing == CalendarEventTiming.timed && endMinute < startMinute + 15) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('End time must be at least 15 minutes after start.'),
        ),
      );
      return;
    }
    // Contract E: new-selection validation BEFORE any state mutation. Edit
    // keeps the loaded type when its raw ID is unchanged; an explicit change
    // in edit mode is a new selection and must pass the gate. Reschedule
    // keeps its loaded type (preservation path is not a new selection).
    final isNewSelection =
        widget.mode == CalendarEventFormMode.create ||
        (widget.mode == CalendarEventFormMode.edit &&
            (_loadedTypeId == null ||
                _selectedEventType?.id != _loadedTypeId));
    if (isNewSelection && !await _validateSelectionBeforeWrite()) {
      if (mounted) {
        setState(() => _saving = false);
      }
      return;
    }
    final selectedType = _selectedEventType;
    if (selectedType?.isLockedWliType == true) {
      _requiresReport = true;
      _linkedIndicatorKey = selectedType!.exactIndicatorKey;
    }
    if (selectedType?.stableKey == SystemEventTypeKeys.contact) {
      // Delta 2: Contact Events always require a report on every save path.
      _requiresReport = true;
    }
    if (_selectedGoalId != null) {
      // Locked invariant: a Life Indicator-linked Event is always Report
      // Required, and its contribution rule follows the linked Goal.  The
      // Goal is resolved by stable ID so an Event linked to an archived
      // Life Indicator still derives the correct contribution rule.
      _requiresReport = true;
      var linkedGoal = _availableGoals
          .where((goal) => goal.id == _selectedGoalId)
          .firstOrNull;
      if (linkedGoal == null) {
        try {
          linkedGoal = await ref.read(
            goalByIdProvider(_selectedGoalId!).future,
          );
        } on Object {
          // No ready profile/repository: keep the current indicator key.
        }
      }
      if (linkedGoal?.indicatorKey != null) {
        _linkedIndicatorKey = linkedGoal!.indicatorKey;
      }
    }
    if (selectedType != null &&
        selectedType.indicatorKeys.length > 1 &&
        !await _confirmMultipleMappings(selectedType)) {
      return;
    }
    setState(() => _saving = true);
    final showStatusSection =
        widget.initialStatusIntent != null &&
        widget.mode == CalendarEventFormMode.edit &&
        _reportEligible &&
        _requiresReport;
    final draft = CalendarEventDraft(
      id: _draftId,
      title: _titleController.text,
      notes: _notesController.text,
      timing: _timing,
      startDate: _date,
      status: showStatusSection
          ? CalendarEventStatus.scheduled
          : _currentStatus,
      startMinute: _timing == CalendarEventTiming.timed ? startMinute : null,
      endMinute: _timing == CalendarEventTiming.timed ? endMinute : null,
      timeZoneId: _timing == CalendarEventTiming.timed
          ? _timeZoneController.text
          : null,
      locationText: _locationController.text,
      requiresReport: _requiresReport,
      activityTypeId: _selectedEventType?.id,
      activityTypeMappingVersion: _selectedEventType?.mappingVersion,
      contributionRuleKey: _scheduledPotentialRule(),
      goalId: _selectedGoalId,
      isBackupAppointment: _isBackupAppointment,
      backupForEventId: _isBackupAppointment ? _backupForEventId : null,
      backupRelationshipProvenance: _isBackupAppointment
          ? _backupRelationshipProvenance ?? 'user-classified'
          : null,
      recurrence: CalendarRecurrenceRule(
        frequency: _frequency,
        endMode: _frequency == CalendarRecurrenceFrequency.none
            ? CalendarRecurrenceEndMode.never
            : _endMode,
        endDate: _endMode == CalendarRecurrenceEndMode.onDate
            ? _recurrenceEndDate ?? _date
            : null,
        occurrenceCount: _endMode == CalendarRecurrenceEndMode.afterCount
            ? int.tryParse(_countController.text)
            : null,
        pattern: _frequency == CalendarRecurrenceFrequency.none
            ? null
            : _recurrencePattern,
      ),
    );
    final controller = ref.read(calendarEventControllerProvider.notifier);
    // The create path reports a three-state truth outcome (saved /
    // saved-with-auxiliary-warning / not saved) so a committed Event is never
    // presented as a failure. The remaining paths report bool and are
    // normalized to the same outcome here.
    final saveOutcome = switch (widget.mode) {
      CalendarEventFormMode.create when widget.sourceTaskId != null =>
        await ref
                .read(taskEventLinkControllerProvider.notifier)
                .createEventFromTask(
                  taskId: widget.sourceTaskId!,
                  event: draft,
                  linkId: _linkId!,
                  operationId: _operationId,
                  canonicalSource: _canonicalSource,
                )
            ? CalendarEventSaveResult.saved
            : CalendarEventSaveResult.notSaved,
      CalendarEventFormMode.create => await controller.saveEvent(
        draft,
        awaitPlannerRefresh: false,
        reminderMode: _reminderMode,
        reminderOffsetMinutes: _reminderOffsetMinutes,
        // M7 section 8: the explicit Contact follow-up path withholds the
        // controller's early scheduling until People + purpose have committed.
        deferReminderReconciliation: widget.followUpContactId != null,
      ),
      CalendarEventFormMode.edit => await _saveEdit(draft, controller)
          ? CalendarEventSaveResult.saved
          : CalendarEventSaveResult.notSaved,
      CalendarEventFormMode.reschedule => await controller.rescheduleEvent(
            eventId: widget.eventId!,
            originalDate: widget.originalDate!,
            scope: widget.scope!,
            replacement: draft,
            operationId: _operationId,
            reminderMode: _reminderModeToPersist,
            reminderOffsetMinutes: _reminderOffsetToPersist,
          )
          ? CalendarEventSaveResult.saved
          : CalendarEventSaveResult.notSaved,
    };
    if (!mounted) {
      return;
    }
    setState(() => _saving = false);
    if (saveOutcome == CalendarEventSaveResult.notSaved) {
      return;
    }
    if (saveOutcome == CalendarEventSaveResult.savedAwaitingAuxiliary &&
        mounted) {
      // The Event is committed; surface the auxiliary warning once without
      // keeping the form open (which would invite a duplicate re-save).
      final warning =
          ref.read(calendarEventControllerProvider) ??
          'Event saved, but its reminder needs attention.';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(warning)));
      // One-shot truth (2026-09-18): the warning belongs to THIS save. The
      // form's own banner and the Event detail screen read the same controller
      // state, so leaving it set would show a stale "saved, but..." message on
      // the next Event form about an Event the user is no longer editing.
      controller.clearMessage();
    }
    if (saveOutcome.closesForm) {
      if (!mounted) {
        return;
      }
      if (widget.mode == CalendarEventFormMode.create &&
          widget.sourceTaskId != null) {
        final startup = ref.read(startupControllerProvider);
        if (startup is StartupReady) {
          await controller.saveReminderPolicyAndReconcile(
            sourceId: _draftId,
            occurrenceId: ReminderPolicy.seriesOccurrenceId,
            mode: _reminderMode,
            offsetMinutes: _reminderOffsetMinutes,
          );
        }
      }
      // The Event field write retains the lifecycle status as `scheduled`.
      // A changed staged outcome is committed only after that canonical edit
      // succeeds, through the existing outcome-reporting transaction.
      if (showStatusSection &&
          _currentStatus != CalendarEventStatus.scheduled &&
          _currentStatus != _loadedReportStatus) {
        final outcome = switch (_currentStatus) {
          CalendarEventStatus.completedHappened =>
            OutcomeKind.completedHappened,
          CalendarEventStatus.partiallyCompleted =>
            OutcomeKind.partiallyCompleted,
          CalendarEventStatus.didNotHappen => OutcomeKind.didNotHappen,
          _ => null,
        };
        if (outcome != null) {
          final reported = await ref
              .read(outcomeReportingControllerProvider.notifier)
              .submitEventStatus(
                eventId: widget.eventId!,
                originalDate: widget.originalDate!,
                outcome: outcome,
                operationId: ref
                    .read(plannerIdentifierSourceProvider)
                    .nextUuid(),
                contributionRuleKey: _scheduledPotentialRule(),
              );
          if (reported == null) {
            if (mounted) {
              setState(() => _saving = false);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    ref.read(outcomeReportingControllerProvider) ??
                        'Event status could not be saved.',
                  ),
                ),
              );
            }
            return;
          }
        }
      }
      // Persist People with the exact scope that the Event write committed.
      // Occurrence identity always uses the canonical original date, even
      // when that occurrence was moved to a different effective date.
      try {
        final editScope = _committedEditScope;
        final occurrenceOnly =
            widget.mode == CalendarEventFormMode.edit &&
            editScope == CalendarEventEditScope.occurrence;
        final peopleEventId =
            widget.mode == CalendarEventFormMode.edit &&
                editScope != CalendarEventEditScope.thisAndFuture
            ? widget.eventId!
            : _draftId;
        final peopleOriginalDate = occurrenceOnly ? widget.originalDate! : null;
        final peopleOccurrenceId = occurrenceOnly
            ? CalendarEventOccurrenceIdentity.forDate(
                eventId: peopleEventId,
                originalDate: peopleOriginalDate!,
              )
            : 'series';
        final explicitlyRemovedSeriesContactIds =
            widget.mode == CalendarEventFormMode.edit &&
                editScope == CalendarEventEditScope.series
            ? _initialPeopleContactIds
                  .difference(_peopleContactIds.toSet())
                  .toList(growable: false)
            : const <String>[];
        await ref
            .read(contactRepositoryProvider)
            .setEventPeople(
              profileId: ref.read(contactProfileIdProvider),
              eventId: peopleEventId,
              occurrenceId: peopleOccurrenceId,
              originalDate: peopleOriginalDate,
              contactIds: _peopleContactIds,
              explicitlyRemovedSeriesContactIds:
                  explicitlyRemovedSeriesContactIds,
            );
        ref.invalidate(
          eventPeopleProvider((
            eventId: peopleEventId,
            occurrenceId: peopleOccurrenceId,
          )),
        );
      } on Object {
        // The Event itself is already saved; never fail the save silently.
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Event saved, but People could not be updated. Edit the '
                'event to retry.',
              ),
            ),
          );
        }
      }
      // M7 section 8 step 4/5: apply the explicit source-level purpose to the
      // SERIES policy (preserving its timing) and then reconcile that source.
      // This runs only for the chooser-created follow-up; every ordinary save
      // already scheduled inside its own controller call above.
      if (!await _finalizeFollowUp()) {
        return;
      }
      if (!mounted) {
        return;
      }
      await _persistMapPin();
      if (!mounted) {
        return;
      }
      _closeForm(true);
    }
  }

  /// M7 section 8 step 1/4/5 — finalize an explicit Contact follow-up.
  ///
  /// Returns `true` when the save may continue closing the form.  Returns
  /// `false` only when the follow-up could not be applied AFTER the canonical
  /// Event commit: the form stays open with the exact truthful copy, its stable
  /// ids are kept, and the user can retry the same source id idempotently.
  ///
  /// The Contact is validated against CURRENT canonical truth here, not against
  /// the intent captured when the chooser opened.  If it is no longer an active
  /// member of this profile the normal source save stands and the pending
  /// follow-up intent is dropped with the exact "Saved without follow-up."
  /// copy — no phantom Contact is created and no valid history is rolled back.
  Future<bool> _finalizeFollowUp() async {
    final contactId = widget.followUpContactId;
    if (contactId == null) {
      return true;
    }
    final profileId = ref.read(contactProfileIdProvider);
    var contactIsActive = false;
    try {
      final detail = await ref
          .read(contactRepositoryProvider)
          .readContactDetail(profileId: profileId, contactId: contactId);
      contactIsActive = detail.contact.isActive;
    } on Object {
      contactIsActive = false;
    }
    if (!mounted) {
      return false;
    }
    if (!contactIsActive) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Saved without follow-up.')),
      );
      return true;
    }
    try {
      final controller = ref.read(calendarEventControllerProvider.notifier);
      await controller.applySeriesReminderPurpose(
        sourceId: _draftId,
        purpose: ReminderPurpose.contactFollowUp,
        contactId: contactId,
      );
      await controller.reconcileEventHorizon(eventId: _draftId);
      return true;
    } on Object {
      // The Event and its People links are committed; we must NOT claim the
      // source was not saved.  Keep the stable id so a retry is idempotent.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Saved, but follow-up could not be applied. Try again.',
            ),
          ),
        );
      }
      return false;
    }
  }

  Future<void> _persistMapPin() async {
    try {
      final maps = ref.read(mapCoordinateRepositoryProvider);
      final profileId = ref.read(mapProfileIdProvider);
      final current = _mapCoordinate;
      if (current != null) {
        await maps.setCoordinate(
          profileId: profileId,
          owner: MapCoordinateOwner.event,
          recordId: _draftId,
          coordinate: current,
        );
      } else if (_initialMapCoordinate != null) {
        await maps.clearCoordinate(
          profileId: profileId,
          owner: MapCoordinateOwner.event,
          recordId: _draftId,
        );
      }
    } on Object {
      // A missing/offline Maps layer must never block saving the Event.
    }
  }

  /// Delta 4.1 edit flow: commit an Edit-mode save, resolving the recurrence
  /// scope only when the user actually commits a change.
  ///
  /// When the form was opened with deferred scope from an Event preview on a
  /// repeating Event:
  ///  * a non-recurring source saves directly with occurrence scope;
  ///  * a repeat-rule removal (e.g. Daily -> Does not repeat) is inherently a
  ///    series-level operation and the repository resolves it to series
  ///    scope, so no chooser is needed;
  ///  * any other recurring save shows the recurrence scope chooser (This
  ///    event only / All events / Cancel).  Cancel returns to the form with
  ///    the draft values intact and persists nothing.
  Future<bool> _saveEdit(
    CalendarEventDraft draft,
    CalendarEventController controller,
  ) async {
    // The normal Edit form opts into the background Planner refresh: the
    // durable Event write is the truth gate, so the editor can begin closing
    // while the selected-day reload runs in the background. Create,
    // reschedule, duplicate, and timeline-drag edits keep the awaited
    // default (see CalendarEventController._runMutation).
    if (!widget.deferRecurrenceScopeToSave) {
      final saved = await controller.editEvent(
        eventId: widget.eventId!,
        originalDate: widget.originalDate!,
        scope: widget.scope!,
        draft: draft,
        operationId: _operationId,
        awaitPlannerRefresh: false,
        reminderMode: _reminderModeToPersist,
        reminderOffsetMinutes: _reminderOffsetToPersist,
      );
      if (saved) _committedEditScope = widget.scope!;
      return saved;
    }
    final sourceRecurring =
        _sourceFrequency != CalendarRecurrenceFrequency.none;
    if (!sourceRecurring) {
      final saved = await controller.editEvent(
        eventId: widget.eventId!,
        originalDate: widget.originalDate!,
        scope: CalendarEventEditScope.occurrence,
        draft: draft,
        operationId: _operationId,
        awaitPlannerRefresh: false,
        reminderMode: _reminderModeToPersist,
        reminderOffsetMinutes: _reminderOffsetToPersist,
      );
      if (saved) _committedEditScope = CalendarEventEditScope.occurrence;
      return saved;
    }
    if (!draft.recurrence.isRecurring) {
      // Repeat-rule removal stays a series-level operation; the repository
      // already resolves it to series scope, so no chooser is shown.
      final saved = await controller.editEvent(
        eventId: widget.eventId!,
        originalDate: widget.originalDate!,
        scope: CalendarEventEditScope.occurrence,
        draft: draft,
        operationId: _operationId,
        awaitPlannerRefresh: false,
        reminderMode: _reminderModeToPersist,
        reminderOffsetMinutes: _reminderOffsetToPersist,
      );
      if (saved) _committedEditScope = CalendarEventEditScope.series;
      return saved;
    }
    final scope = await _selectSaveScope();
    if (scope == null || !mounted) {
      // The user canceled the scope chooser: keep the form and its draft
      // values; nothing is persisted.
      return false;
    }
    final saved = await controller.editEvent(
      eventId: widget.eventId!,
      originalDate: widget.originalDate!,
      scope: scope,
      draft: draft,
      operationId: _operationId,
      awaitPlannerRefresh: false,
      reminderMode: _reminderModeToPersist,
      reminderOffsetMinutes: _reminderOffsetToPersist,
    );
    if (saved) _committedEditScope = scope;
    return saved;
  }

  /// Recurrence scope chooser shown only when the user commits a Save on a
  /// repeating Event (Delta 4.1 edit flow).  Reuses the owner-approved
  /// chooser design from the Event preview.
  Future<CalendarEventEditScope?> _selectSaveScope() {
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
                originalDate: widget.originalDate!,
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

  void _closeForm(bool saved) {
    final onClose = widget.onClose;
    if (onClose != null) {
      onClose(saved);
      return;
    }
    Navigator.of(context).pop(saved);
  }

  Future<bool> _confirmMultipleMappings(EventType type) async {
    final labels =
        type.indicatorKeys.map(_indicatorLabel).toList(growable: false)..sort();
    return await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Confirm Life Goal mappings'),
            content: Text(
              '${type.label} is mapped to ${labels.join(', ')}. Continue?',
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Review'),
              ),
              FilledButton(
                key: const Key('confirm-multiple-indicator-mappings'),
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('Confirm and save'),
              ),
            ],
          ),
        ) ??
        false;
  }

  void _setEventDate(PlannerDate value) {
    setState(() {
      _date = value;
      if (_frequency != CalendarRecurrenceFrequency.none &&
          !_legacyRecurrenceEndControls &&
          !_recurrenceEndDateCustomized) {
        _recurrenceEndDate = calendarDefaultRecurrenceEndDate(
          value,
          _frequency,
        );
      }
      ref.read(plannerEventCreationDraftProvider.notifier).updateDate(value);
    });
  }

  Future<void> _selectDate({
    required PlannerDate initial,
    required ValueChanged<PlannerDate> onSelected,
  }) async {
    final value = await showSharedPlannerDatePicker(
      context: context,
      initialDate: initial.asLocalDate,
      firstDate: DateTime(1900),
      lastDate: DateTime(2200, 12, 31),
      helpText: 'Select Calendar Event date',
    );
    if (value != null) {
      onSelected(PlannerDate.fromDateTime(value));
    }
  }

  Future<void> _selectTime({
    required TimeOfDay initial,
    required ValueChanged<TimeOfDay> onSelected,
  }) async {
    final value = await showTimePicker(
      context: context,
      initialTime: initial,
      // Work around a framework assertion in the stock time picker: in
      // text-input mode the dialog hard-codes a 216 dp minimum height but
      // lets the keyboard shrink its maximum below that, which yields
      // non-normalized BoxConstraints and a debug-mode red banner. Stripping
      // viewInsets keeps the dialog at full size so the constraint is always
      // valid and the final-hour 11 PM-12 AM slot stays reachable.
      builder: (context, child) => MediaQuery.removeViewInsets(
        context: context,
        removeBottom: true,
        child: child!,
      ),
    );
    if (value != null) {
      final minute = _snapMinute(value.hour * 60 + value.minute);
      onSelected(_timeFromMinute(minute));
    }
  }

  /// Owner-approved clarification: the inherit row shows the ACTUAL
  /// currently-inherited category default (Events use
  /// PlannerPreferences.defaultReminderMinutes, owned by Planner settings).
  /// No second default is persisted; ReminderPolicy inheritance stays the
  /// storage law.
  String _reminderLabel() {
    switch (_reminderMode) {
      case ReminderPolicyMode.inherit:
        final inherited = ref
            .watch(eventTypeControllerProvider)
            .settings
            .defaultReminderMinutes;
        if (inherited == null) {
          return 'Default (Off)  ›';
        }
        return 'Default (${ReminderPolicyLabel.inheritedOffsetMinutes(inherited)})  ›';
      case ReminderPolicyMode.off:
        return 'Off  ›';
      case ReminderPolicyMode.offset:
        return '${ReminderPolicyLabel.offsetMinutes(_reminderOffsetMinutes ?? 0)}  ›';
    }
  }

  /// The reminder policy to persist from an EDIT/RESCHEDULE save: null when the
  /// user did not change it, so the save cannot create or shadow a policy row.
  ReminderPolicyMode? get _reminderModeToPersist =>
      _reminderSelectionChanged ? _reminderMode : null;

  int? get _reminderOffsetToPersist =>
      _reminderSelectionChanged ? _reminderOffsetMinutes : null;

  Future<void> _selectReminderPolicy() async {
    final selected = await showReminderTimePicker(context);
    if (!mounted) return;
    setState(() {
      _reminderSelectionChanged = true;
      if (selected == null) {
        _reminderMode = ReminderPolicyMode.inherit;
      } else if (selected == -1) {
        _reminderMode = ReminderPolicyMode.off;
      } else {
        _reminderMode = ReminderPolicyMode.offset;
        _reminderOffsetMinutes = selected;
      }
    });
  }

  void _setStartTime(TimeOfDay value) {
    final startMinute = value.hour * 60 + value.minute;
    final endMinute = _endMinuteOfDay;
    setState(() {
      _start = value;
      if (endMinute < startMinute + 15) {
        _end = _timeFromMinute((startMinute + 15).clamp(1, 1439));
      }
    });
  }

  void _setEndTime(TimeOfDay value) {
    final startMinute = _start.hour * 60 + _start.minute;
    // Final-hour 11 PM-12 AM support: a picked end of 12:00 AM is the
    // next-day midnight boundary (minute 1440) whenever the Event starts
    // after 00:00.  The display keeps 12:00 AM; saving maps it to 1440 so
    // the Event never collapses or disappears.
    final isMidnightEnd =
        value.hour == 0 && value.minute == 0 && startMinute > 0;
    final resolvedEnd = isMidnightEnd ? 1440 : value.hour * 60 + value.minute;
    setState(() {
      _end = resolvedEnd < startMinute + 15
          ? _timeFromMinute((startMinute + 15).clamp(1, 1439))
          : value;
      _durationWasEntered = true;
    });
  }

  /// The end minute of day as a valid 1..1440 range, treating a displayed
  /// 12:00 AM end as the final-hour 24:00 boundary when the Event starts
  /// after 00:00.  Used by validation and every save path so an 11 PM-12 AM
  /// Event is persisted with `endMinute == 1440` and never drops below the
  /// 15-minute minimum.
  int get _endMinuteOfDay {
    final startMinute = _start.hour * 60 + _start.minute;
    final endMinute = _end.hour * 60 + _end.minute;
    if (endMinute == 0 && startMinute > 0) {
      return 1440;
    }
    return endMinute;
  }

  static int _snapMinute(int minute) {
    return ((minute / 5).round() * 5).clamp(0, 1439);
  }

  static TimeOfDay _timeFromMinute(int value) {
    return TimeOfDay(hour: value ~/ 60, minute: value % 60);
  }

  static _CalendarEventRepeatChoice _repeatChoiceFor(
    CalendarRecurrenceFrequency frequency,
    CalendarRecurrencePattern? pattern,
  ) {
    if (pattern != null) {
      return _CalendarEventRepeatChoice.custom;
    }
    return switch (frequency) {
      CalendarRecurrenceFrequency.none => _CalendarEventRepeatChoice.none,
      CalendarRecurrenceFrequency.daily => _CalendarEventRepeatChoice.daily,
      CalendarRecurrenceFrequency.weekly => _CalendarEventRepeatChoice.weekly,
      CalendarRecurrenceFrequency.monthly => _CalendarEventRepeatChoice.monthly,
      CalendarRecurrenceFrequency.yearly => _CalendarEventRepeatChoice.yearly,
    };
  }

  static String _repeatChoiceLabel(_CalendarEventRepeatChoice value) {
    return switch (value) {
      _CalendarEventRepeatChoice.none => 'Does not repeat',
      _CalendarEventRepeatChoice.daily => 'Every day',
      _CalendarEventRepeatChoice.weekly => 'Every week',
      _CalendarEventRepeatChoice.monthly => 'Every month',
      _CalendarEventRepeatChoice.yearly => 'Every year',
      _CalendarEventRepeatChoice.custom => 'Custom...',
    };
  }

  static String _indicatorLabel(String key) {
    return switch (key) {
      'temple_visit' => 'Temple Visit',
      'scripture_study' => 'Scripture Study',
      'exercise' => 'Exercise',
      'budget_review' => 'Budget Review',
      'job_applications' => 'Job Applications',
      'meaningful_connections' => 'Meaningful Connections',
      _ => key,
    };
  }
}

final class _MeasuredFormSeparator extends StatelessWidget {
  const _MeasuredFormSeparator({super.key});

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

final class _MeasuredFormSectionHeader extends StatelessWidget {
  const _MeasuredFormSectionHeader({required this.label, super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(label, style: InternalScreen.sectionHeading),
        const SizedBox(height: 5),
        const Divider(height: 1, thickness: 1),
      ],
    );
  }
}

final class _FormSectionLabel extends StatelessWidget {
  const _FormSectionLabel({
    required this.icon,
    required this.label,
    this.color,
    this.iconColor,
  });

  final IconData icon;
  final String label;
  final Color? color;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Icon(
          icon,
          size: 18,
          color: iconColor ?? Theme.of(context).colorScheme.primary,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            label,
            style: InternalScreen.sectionHeading.copyWith(
              color: color ?? Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
      ],
    );
  }
}

final class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.error.withValues(alpha: 0.12),
        border: Border.all(color: Theme.of(context).colorScheme.error),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(message),
    );
  }
}

final class _DateTile extends StatelessWidget {
  const _DateTile({
    required this.label,
    required this.date,
    required this.onTap,
    super.key,
  });

  final String label;
  final PlannerDate date;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: key,
      borderRadius: BorderRadius.circular(4),
      onTap: onTap,
      child: SizedBox(
        height: 52,
        child: InputDecorator(
          decoration: _outlinedFormDecoration(
            context,
            labelText: label,
            suffixIcon: const Icon(Icons.calendar_month_outlined, size: 24),
          ),
          child: Text(
            _friendlyDate(date),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTypography.body,
          ),
        ),
      ),
    );
  }

  static String _friendlyDate(PlannerDate value) {
    const months = <String>[
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    final local = value.asLocalDate;
    return '${_weekday(local.weekday)}, ${months[local.month - 1]} '
        '${local.day}, ${local.year}';
  }

  static String _weekday(int value) {
    const weekdays = <String>[
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    return weekdays[value - 1];
  }
}

final class _TimeTile extends StatelessWidget {
  const _TimeTile({
    required this.label,
    required this.value,
    required this.onTap,
    super.key,
  });

  final String label;
  final TimeOfDay value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: key,
      borderRadius: BorderRadius.circular(4),
      onTap: onTap,
      child: SizedBox(
        height: 52,
        child: InputDecorator(
          decoration: _outlinedFormDecoration(context, labelText: label),
          child: Text(
            value.format(context),
            maxLines: 1,
            style: AppTypography.body,
          ),
        ),
      ),
    );
  }
}

InputDecoration _outlinedFormDecoration(
  BuildContext context, {
  required String labelText,
  Widget? prefixIcon,
  Widget? suffixIcon,
}) {
  return _measuredInputDecoration(
    context,
    labelText: labelText,
    prefixIcon: prefixIcon,
    suffixIcon: suffixIcon,
  );
}

/// A selected Person chip in the Event form People section: primary-group
/// color dot + display name + remove.  Draft selection only — persisted
/// links live in the Contacts repository after the Event itself saves.
final class _PeopleChip extends StatelessWidget {
  const _PeopleChip({
    required this.id,
    required this.summary,
    required this.onRemove,
  });

  final String id;
  final ContactSummary? summary;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: Key('event-person-$id'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.dark
            ? const Color(0xFF1C1E21)
            : Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: Theme.of(context).brightness == Brightness.dark
              ? const Color(0xFF2A2D31)
              : Theme.of(context).colorScheme.outlineVariant,
        ),
      ),
      child: Row(
        children: <Widget>[
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: summary == null
                  ? const Color(0xFF9CA0A6)
                  : colorFromValue(summary!.colorValue),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              summary?.contact.displayName ?? 'Contact',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
            ),
          ),
          IconButton(
            key: Key('remove-event-person-$id'),
            tooltip: 'Remove',
            onPressed: onRemove,
            icon: const Icon(Icons.close, size: 20),
          ),
        ],
      ),
    );
  }
}

InputDecoration _measuredInputDecoration(
  BuildContext context, {
  String? labelText,
  Widget? prefixIcon,
  Widget? suffixIcon,
  String? hintText,
  int? hintMaxLines,
  bool? alignLabelWithHint,
}) {
  final border = OutlineInputBorder(
    borderRadius: BorderRadius.circular(4),
    borderSide: BorderSide(color: AppTheme.outlineOf(context), width: 1),
  );
  return InputDecoration(
    labelText: labelText,
    hintText: hintText,
    hintMaxLines: hintMaxLines,
    prefixIcon: prefixIcon,
    suffixIcon: suffixIcon,
    alignLabelWithHint: alignLabelWithHint,
    filled: true,
    fillColor: Colors.transparent,
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    labelStyle: AppTypography.micro,
    floatingLabelStyle: AppTypography.micro,
    border: border,
    enabledBorder: border,
    focusedBorder: border,
  );
}
