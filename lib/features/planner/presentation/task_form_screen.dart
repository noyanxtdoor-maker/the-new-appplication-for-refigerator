import 'dart:async';

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
import 'package:rmplanner/features/notifications/application/notification_providers.dart';
import 'package:rmplanner/features/notifications/domain/reminder_policy.dart';
import 'package:rmplanner/features/notifications/presentation/reminder_time_picker.dart';
import 'package:rmplanner/features/planner/application/event_type_providers.dart';
import 'package:rmplanner/features/planner/application/planner_providers.dart';
import 'package:rmplanner/features/planner/application/planner_task_creation_draft_provider.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_task.dart';
import 'package:rmplanner/features/planner/presentation/widgets/planner_slide_down_date_picker.dart';
import 'package:rmplanner/features/privacy/application/privacy_providers.dart';
import 'package:rmplanner/features/privacy/domain/permission_summary.dart';
import 'package:rmplanner/features/startup/application/startup_providers.dart';
import 'package:rmplanner/features/startup/domain/startup_state.dart';

final class TaskFormScreen extends ConsumerStatefulWidget {
  const TaskFormScreen.create({
    required this.initialDueDate,
    this.addToPlanner = false,
    this.initialDueMinute,
    this.initialDraftId,
    this.initialContactIds = const <String>[],
    this.initialFollowUpContactId,
    this.initialTitle,
    this.initialDescription,
    this.initialPeople = const <String>[],
    this.initialRecurrence = PlannerTaskRecurrence.none,
    this.initialGoalId,
    this.sheetPresentation = false,
    this.onClose,
    this.sheetScrollController,
    this.sheetController,
    this.sheetMinChildSize = 0.2,
    this.sheetMaxChildSize = 0.9,
    super.key,
  }) : taskId = null;

  const TaskFormScreen.edit({
    required this.taskId,
    this.addToPlanner = false,
    this.initialDraftId,
    this.sheetPresentation = false,
    this.onClose,
    this.sheetScrollController,
    this.sheetController,
    this.sheetMinChildSize = 0.2,
    this.sheetMaxChildSize = 0.9,
    super.key,
  }) : initialDueDate = null,
       initialDueMinute = null,
       initialContactIds = const <String>[],
       initialFollowUpContactId = null,
       initialTitle = null,
       initialDescription = null,
       initialPeople = const <String>[],
       initialRecurrence = PlannerTaskRecurrence.none,
       initialGoalId = null;

  const TaskFormScreen.addToPlanner({required String taskId, Key? key})
    : this.edit(taskId: taskId, addToPlanner: true, key: key);

  final String? taskId;
  final bool addToPlanner;
  final PlannerDate? initialDueDate;
  final int? initialDueMinute;
  final String? initialDraftId;
  final List<String> initialContactIds;

  /// VS16 M7: the Contact explicitly chosen through the existing
  /// "Create Follow-Up" chooser.  Null for ordinary creation.
  final String? initialFollowUpContactId;
  final String? initialTitle;
  final String? initialDescription;
  final List<String> initialPeople;
  final PlannerTaskRecurrence initialRecurrence;
  final String? initialGoalId;
  final bool sheetPresentation;
  final ValueChanged<bool>? onClose;
  final ScrollController? sheetScrollController;
  final DraggableScrollableController? sheetController;
  final double sheetMinChildSize;
  final double sheetMaxChildSize;

  @override
  ConsumerState<TaskFormScreen> createState() => _TaskFormScreenState();
}

final class _TaskFormScreenState extends ConsumerState<TaskFormScreen>
    with WidgetsBindingObserver {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();
  late final String _stableTaskId;
  PlannerDate? _dueDate;
  int? _dueMinute;
  ReminderPolicyMode _reminderMode = ReminderPolicyMode.inherit;
  int? _reminderOffsetMinutes;
  PlannerTaskRecurrence _recurrence = PlannerTaskRecurrence.none;
  List<String> _people = <String>[];
  // Contact records linked to this Task (VS-11).  Distinct from the legacy
  // free-text [_people] list; follow-up creation pre-links a Contact here.
  late List<String> _contactIds;
  bool _setDueDate = false;
  bool _notificationsUnavailable = false;
  bool _remindersUnavailable = false;
  bool _loading = false;
  bool _saving = false;
  String? _error;
  bool _dateNeedsSelectionForPlanner = false;
  bool _timeNeedsSelectionForPlanner = false;
  // TF-01: legacy Event-Type metadata is INVISIBLE read-through data.  The
  // Task UX no longer exposes EVENT TYPE — OPTIONAL; these values are loaded
  // from the stored Task and forwarded unchanged on save so legacy metadata
  // survives edit/save/backup byte-for-byte (never editable from the UI).
  String? _linkedActivityTypeId;
  String? _linkedActivityTypeStableKey;
  String? _linkedActivityTypeLabelSnapshot;
  // B3.2 (D2): the explicit DIRECT Life Goal link.  The ONLY Goal resolver
  // for Tasks; Event-Type fields are independent classification metadata.
  String? _goalId;
  ProviderSubscription<PlannerTaskCreationDraft?>? _draftSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // A Planner provisional draft owns the eventual canonical Task id. This
    // keeps the visible draft and the saved Task one identity; direct create
    // routes (without a draft) still allocate a fresh id.
    _stableTaskId =
        widget.taskId ??
        widget.initialDraftId ??
        ref.read(plannerIdentifierSourceProvider).nextUuid();
    _contactIds = List<String>.from(widget.initialContactIds);
    _titleController.text = widget.initialTitle ?? '';
    _descriptionController.text = widget.initialDescription ?? '';
    _people = List<String>.from(widget.initialPeople);
    _goalId = widget.initialGoalId;
    if (widget.taskId != null) {
      unawaited(_loadTaskContacts());
    }
    _dueDate = widget.initialDueDate;
    _setDueDate = widget.initialDueDate != null;
    _dueMinute = widget.initialDueDate == null
        ? null
        : widget.initialDueMinute ?? 18 * 60;
    _recurrence = widget.initialDueDate == null
        ? PlannerTaskRecurrence.none
        : widget.initialRecurrence;
    _titleController.addListener(_publishDraftTitle);
    final draftId = widget.initialDraftId;
    if (draftId != null) {
      _draftSubscription = ref.listenManual<PlannerTaskCreationDraft?>(
        plannerTaskCreationDraftProvider,
        (_, next) => _synchronizeFromPlannerDraft(draftId, next),
        fireImmediately: true,
      );
    }
    unawaited(_refreshCapabilities());
    if (widget.taskId != null) {
      _loading = true;
      unawaited(_loadExisting());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted && _setDueDate) {
      unawaited(_refreshCapabilities());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _draftSubscription?.close();
    _titleController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  PlannerTaskCreationDraft? get _activeDraft {
    final id = widget.initialDraftId;
    if (id == null) return null;
    final draft = ref.read(plannerTaskCreationDraftProvider);
    return draft?.id == id ? draft : null;
  }

  void _publishDraftTitle() {
    if (_activeDraft != null) {
      ref
          .read(plannerTaskCreationDraftProvider.notifier)
          .updateTitle(_titleController.text);
    }
  }

  void _publishDraftSchedule() {
    final draft = _activeDraft;
    final date = _dueDate;
    final minute = _dueMinute;
    if (!_setDueDate || draft == null || date == null || minute == null) {
      return;
    }
    final controller = ref.read(plannerTaskCreationDraftProvider.notifier);
    controller.updateDate(date);
    controller.updateMinute(minute);
  }

  /// A Day-canvas drag owns the provisional schedule until the form is saved.
  /// Mirror that single Task draft back into this open form so the visible due
  /// fields, canvas block, and eventual canonical Task stay synchronized.
  void _synchronizeFromPlannerDraft(
    String draftId,
    PlannerTaskCreationDraft? draft,
  ) {
    if (!mounted || draft?.id != draftId) return;
    final titleChanged = _titleController.text != draft!.title;
    // With Due Date OFF, the Planner block is intentionally only a
    // provisional placement. Moving it must not silently make the saved Task
    // dated. Once the owner has deliberately enabled Due Date, that same
    // canonical draft becomes the bidirectional schedule source.
    final scheduleChanged =
        _setDueDate && (_dueDate != draft.date || _dueMinute != draft.minute);
    if (!titleChanged && !scheduleChanged) return;
    setState(() {
      if (titleChanged) {
        _titleController.value = _titleController.value.copyWith(
          text: draft.title,
          selection: TextSelection.collapsed(offset: draft.title.length),
          composing: TextRange.empty,
        );
      }
      if (scheduleChanged) {
        _dueDate = draft.date;
        _dueMinute = draft.minute;
      }
    });
  }

  void _close(bool saved) {
    final onClose = widget.onClose;
    if (onClose != null) {
      onClose(saved);
    } else {
      Navigator.of(context).pop(saved);
    }
  }

  Future<void> _refreshCapabilities() async {
    final status = await ref
        .read(permissionGatewayProvider)
        .status(OptionalPermission.notifications);
    if (!mounted) {
      return;
    }
    final unavailable = status != OperatingSystemPermissionState.granted;
    setState(() {
      _notificationsUnavailable = unavailable;
      // The current release has no independent reminder scheduler. Until one
      // is introduced, reminder capability follows notification capability.
      _remindersUnavailable = unavailable;
    });
  }

  Future<void> _loadExisting() async {
    final task = await ref
        .read(plannerControllerProvider.notifier)
        .readTask(_stableTaskId);
    if (!mounted) {
      return;
    }
    if (task == null) {
      setState(() {
        _loading = false;
        _error = 'This Task no longer exists.';
      });
      return;
    }
    _titleController.text = task.title;
    _descriptionController.text = task.notes ?? '';
    final startup = ref.read(startupControllerProvider);
    ReminderPolicy? reminderPolicy;
    if (startup is StartupReady && task.dueDate != null) {
      final occurrenceId = 'task:${task.id}:${task.dueDate!.iso8601}';
      final policies = await ref
          .read(notificationFoundationRepositoryProvider)
          .readPolicies(
            profileId: startup.profile.id,
            sourceKind: ReminderSourceKind.task,
            sourceId: task.id,
          );
      reminderPolicy = policies
          .where((policy) => policy.occurrenceId == occurrenceId)
          .firstOrNull;
    }
    if (!mounted) return;
    setState(() {
      _dueDate = task.dueDate;
      _dueMinute = widget.addToPlanner
          ? task.dueMinute
          : task.dueMinute ?? (task.dueDate == null ? null : 18 * 60);
      _recurrence = task.recurrence;
      _people = List<String>.unmodifiable(task.people);
      _setDueDate = widget.addToPlanner || task.dueDate != null;
      _dateNeedsSelectionForPlanner =
          widget.addToPlanner && task.dueDate == null;
      _timeNeedsSelectionForPlanner =
          widget.addToPlanner && task.dueMinute == null;
      _linkedActivityTypeId = task.linkedActivityTypeId;
      _linkedActivityTypeStableKey = task.linkedActivityTypeStableKey;
      _linkedActivityTypeLabelSnapshot = task.linkedActivityTypeLabelSnapshot;
      _goalId = task.goalId;
      _reminderMode = reminderPolicy?.mode ?? ReminderPolicyMode.inherit;
      _reminderOffsetMinutes = reminderPolicy?.offsetMinutes;
      _loading = false;
    });
    _publishDraftSchedule();
    _publishDraftTitle();
    if (_setDueDate) {
      await _refreshCapabilities();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.initialDraftId != null) {
      ref.watch(plannerTaskCreationDraftProvider);
    }
    final use24HourTime = ref
        .watch(eventTypeControllerProvider)
        .settings
        .use24HourTime;
    final formSurface = SafeArea(
      child: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: <Widget>[
                GestureDetector(
                  key: const Key('task-form-sheet-header'),
                  behavior: HitTestBehavior.opaque,
                  // The header owns the only upper-sheet blank surface.
                  // Child controls keep their own gestures; a tap on bare
                  // header background simply dismisses the active keyboard.
                  onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
                  onVerticalDragUpdate: _handleSheetDragUpdate,
                  child: Column(
                    children: <Widget>[
                      const SizedBox(height: 8),
                      Container(
                        key: const Key('task-form-drag-handle'),
                        width: 32,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Theme.of(context).brightness == Brightness.dark
                              ? Colors.white70
                              : Theme.of(
                                  context,
                                ).colorScheme.onSurface.withValues(alpha: 0.70),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                        child: Row(
                          children: <Widget>[
                            IconButton(
                              key: const Key('task-form-close'),
                              tooltip: 'Close',
                              onPressed: () => _close(false),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                minWidth: 48,
                                minHeight: 48,
                              ),
                              icon: const Icon(Icons.close, size: 28),
                            ),
                            const Spacer(),
                            _buildSaveButton(),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: GestureDetector(
                    key: const Key('task-form-blank-space-dismiss'),
                    behavior: HitTestBehavior.translucent,
                    onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
                    child: Form(
                      key: _formKey,
                      child: ListView(
                        key: const Key('task-form-scroll'),
                        controller: widget.sheetScrollController,
                        padding: EdgeInsets.fromLTRB(
                          16,
                          6,
                          16,
                          20 + MediaQuery.of(context).viewInsets.bottom,
                        ),
                        children: <Widget>[
                          if (_error != null) ...<Widget>[
                            Text(
                              _error!,
                              key: const Key('task-form-error'),
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                            const SizedBox(height: 12),
                          ],
                          TextFormField(
                            key: const Key('task-title-field'),
                            controller: _titleController,
                            autofocus: widget.taskId == null,
                            textInputAction: TextInputAction.next,
                            maxLines: 1,
                            decoration: _inputDecoration(label: 'Title'),
                            validator: (value) {
                              return value == null || value.trim().isEmpty
                                  ? 'Enter a Task title.'
                                  : null;
                            },
                          ),
                          const SizedBox(height: 18),
                          if (widget.addToPlanner)
                            ..._buildAddToPlannerFields(context, use24HourTime)
                          else ...<Widget>[
                            TextFormField(
                              key: const Key('task-notes-field'),
                              controller: _descriptionController,
                              minLines: 3,
                              maxLines: 5,
                              keyboardType: TextInputType.multiline,
                              decoration: _inputDecoration(
                                hintText:
                                    'Notes: What do you need to remember about this?',
                              ),
                            ),
                            const SizedBox(height: 18),
                            SwitchListTile(
                              key: const Key('task-set-due-date-switch'),
                              contentPadding: EdgeInsets.zero,
                              title: const Text('Set Due Date'),
                              value: _setDueDate,
                              onChanged: _toggleDueDate,
                            ),
                            if (_setDueDate) ...<Widget>[
                              const SizedBox(height: 12),
                              _TaskValueField(
                                key: const Key('task-due-date-field'),
                                label: 'Due Date',
                                value: _dueDate?.iso8601 ?? 'Choose date',
                                icon: Icons.calendar_month_outlined,
                                onTap: _pickDueDate,
                              ),
                              const SizedBox(height: 16),
                              _TaskValueField(
                                key: const Key('task-due-time-field'),
                                label: 'Time',
                                value: _formatTime(context, use24HourTime),
                                onTap: _pickDueTime,
                              ),
                              if (_dueMinute != null) ...<Widget>[
                                const SizedBox(height: 12),
                                _TaskValueField(
                                  key: const Key('task-reminder-policy'),
                                  label: 'Reminder',
                                  value: _reminderLabel(),
                                  onTap: () =>
                                      unawaited(_selectReminderPolicy()),
                                ),
                              ],
                              const SizedBox(height: 12),
                              _TaskRepeatField(
                                key: const Key('task-repeat-field'),
                                value: _recurrence,
                                onTap: _pickRecurrence,
                              ),
                              if (_notificationsUnavailable) ...<Widget>[
                                const SizedBox(height: 18),
                                _CapabilityNotice(
                                  key: const Key('task-notifications-notice'),
                                  message: 'Notifications are disabled',
                                  supportingText:
                                      'Enabling notifications in the app will allow you to be notified of new referrals, upcoming events, tasks due, and other important notifications',
                                  onEnable: _openSettings,
                                ),
                              ],
                              if (_remindersUnavailable) ...<Widget>[
                                const SizedBox(height: 18),
                                _CapabilityNotice(
                                  key: const Key('task-reminders-notice'),
                                  message:
                                      'Cannot show reminders: Alarms & reminders is disabled',
                                  onEnable: _openSettings,
                                ),
                              ],
                            ],
                            const SizedBox(height: 26),
                            const _TaskSectionHeader(label: 'Contacts'),
                            const SizedBox(height: 12),
                            Align(
                              alignment: Alignment.centerRight,
                              child: TextButton.icon(
                                key: const Key('task-add-people-button'),
                                onPressed: () => unawaited(_openAddContacts()),
                                style: _rightAlignedActionStyle(),
                                icon: const Icon(Icons.add, size: 24),
                                label: const Text('Contacts'),
                              ),
                            ),
                            if (_people.isNotEmpty) ...<Widget>[
                              const SizedBox(height: 8),
                              const Text(
                                'Historical names',
                                style: TextStyle(
                                  fontFamily: 'Roboto',
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFF9CA0A6),
                                ),
                              ),
                              const SizedBox(height: 6),
                              for (final person in _people)
                                _TaskLegacyPersonChip(person: person),
                              const SizedBox(height: 12),
                            ],
                            const SizedBox(height: 4),
                            if (_contactIds.isEmpty && _people.isEmpty)
                              const Padding(
                                padding: EdgeInsets.symmetric(vertical: 4),
                                child: Text(
                                  'No Contacts linked yet.',
                                  style: TextStyle(
                                    color: Color(0xFF9CA0A6),
                                    fontSize: 14,
                                  ),
                                ),
                              )
                            else if (_contactIds.isNotEmpty)
                              ref
                                  .watch(
                                    contactSummariesByCsvProvider(
                                      _contactIds.join(','),
                                    ),
                                  )
                                  .when(
                                    loading: () => const Padding(
                                      padding: EdgeInsets.symmetric(
                                        vertical: 12,
                                      ),
                                      child: Center(
                                        child: SizedBox.square(
                                          dimension: 20,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        ),
                                      ),
                                    ),
                                    error: (error, stack) => const Padding(
                                      padding: EdgeInsets.symmetric(
                                        vertical: 8,
                                      ),
                                      child: Text(
                                        'Contacts could not be loaded.',
                                        style: TextStyle(
                                          color: Color(0xFF9CA0A6),
                                        ),
                                      ),
                                    ),
                                    data: (byId) => Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: <Widget>[
                                        for (final id in _contactIds)
                                          _TaskContactChip(
                                            id: id,
                                            summary: byId[id],
                                            onRemove: () => setState(() {
                                              _contactIds.remove(id);
                                            }),
                                          ),
                                      ],
                                    ),
                                  ),
                            const SizedBox(height: 26),
                            // TF-01: Life Goal sits BELOW Contacts.
                            _buildLifeGoalSection(),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
    if (!widget.sheetPresentation) {
      return Scaffold(body: formSurface);
    }
    return Material(
      key: const Key('task-detail-sheet'),
      color: Theme.of(context).scaffoldBackgroundColor,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      clipBehavior: Clip.antiAlias,
      child: formSurface,
    );
  }

  List<Widget> _buildAddToPlannerFields(
    BuildContext context,
    bool use24HourTime,
  ) {
    return <Widget>[
      const Text(
        'Add to Planner',
        key: Key('task-add-to-planner-title'),
        style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 8),
      const Text(
        'Choose a date and time for this existing Task. This does not create '
        'another Task.',
      ),
      const SizedBox(height: 20),
      _TaskValueField(
        key: const Key('task-due-date-field'),
        label: 'Due Date',
        value: _dueDate?.iso8601 ?? 'Choose date',
        icon: Icons.calendar_month_outlined,
        onTap: _pickDueDate,
      ),
      const SizedBox(height: 16),
      _TaskValueField(
        key: const Key('task-due-time-field'),
        label: 'Time',
        value: _dueMinute == null
            ? 'Choose time'
            : _formatTime(context, use24HourTime),
        onTap: _pickDueTime,
      ),
      if (_dueMinute != null) ...<Widget>[
        const SizedBox(height: 12),
        _TaskValueField(
          key: const Key('task-reminder-policy'),
          label: 'Reminder',
          value: _reminderLabel(),
          onTap: () => unawaited(_selectReminderPolicy()),
        ),
      ],
      const SizedBox(height: 24),
    ];
  }

  void _handleSheetDragUpdate(DragUpdateDetails details) {
    final controller = widget.sheetController;
    if (controller == null || !controller.isAttached) return;
    final delta = details.primaryDelta;
    if (delta == null) return;
    final viewportHeight = MediaQuery.sizeOf(context).height;
    final nextSize = (controller.size - delta / viewportHeight)
        .clamp(widget.sheetMinChildSize, widget.sheetMaxChildSize)
        .toDouble();
    if ((nextSize - controller.size).abs() > 0.0001) {
      controller.jumpTo(nextSize);
    }
  }

  /// B3.2 Life Goal section (owner D2): explicit DIRECT Goal link with the
  /// Event form's approved Link-to-Life-Goal flow as the template.
  Widget _buildLifeGoalSection() {
    final goals = ref.watch(activeGoalsProvider).value ?? const <Goal>[];
    Goal? linkedGoal;
    if (_goalId != null) {
      linkedGoal ??= goals.where((goal) => goal.id == _goalId).firstOrNull;
      linkedGoal ??= ref.watch(goalByIdProvider(_goalId!)).value;
    }
    final linked = linkedGoal != null;
    final colorScheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Column(
      key: const Key('task-life-goal-section'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const _TaskSectionHeader(label: 'Life Goal'),
        const SizedBox(height: 12),
        InkWell(
          key: const Key('task-life-goal-field'),
          onTap: _chooseLifeGoal,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              // POLISH-04: Light uses the semantic near-white surface +
              // outline (never a gray container slab); Dark keeps its fill.
              color: dark ? const Color(0xFF1C1E21) : colorScheme.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: dark
                    ? const Color(0xFF2A2D31)
                    : colorScheme.outlineVariant,
              ),
            ),
            child: Row(
              children: <Widget>[
                if (linked)
                  GoalIcon(
                    iconId: linkedGoal.iconId,
                    // GI-02: exactly 2x (24 -> 48).
                    size: 48,
                    semanticLabel: linkedGoal.title,
                    // Step 8 (R01): fallback follows the Goal artwork-family
                    // blue (#5CAEC9).
                    color: AppTheme.goalIconFallbackBlue,
                  )
                else
                  Icon(
                    Icons.flag_outlined,
                    color: colorScheme.onSurfaceVariant,
                    size: 24,
                  ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    linked ? linkedGoal.title : 'Choose a Life Goal (optional)',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: linked
                        ? AppTypography.body
                        : AppTypography.secondary,
                  ),
                ),
                const Icon(Icons.arrow_drop_down),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        if (linked)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              key: const Key('task-life-goal-unlink'),
              onPressed: () => setState(() => _goalId = null),
              icon: const Icon(Icons.clear, size: 18),
              label: const Text('Unlink'),
              style: TextButton.styleFrom(
                minimumSize: const Size(48, 48),
                padding: const EdgeInsets.symmetric(horizontal: 12),
              ),
            ),
          )
        else
          const Text(
            'Optional: completing this Task will add progress to the linked '
            'Life Goal.',
            style: AppTypography.secondary,
          ),
      ],
    );
  }

  Future<void> _chooseLifeGoal() async {
    List<Goal> goals;
    try {
      goals = await ref.read(activeGoalsProvider.future);
    } on Object {
      goals = const <Goal>[];
    }
    if (!mounted) {
      return;
    }
    if (goals.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No Life Goals are available.')),
      );
      return;
    }
    final colorScheme = Theme.of(context).colorScheme;
    final selected = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) => SafeArea(
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
                  'Choose the goal this Task should contribute to.',
                  style: TextStyle(
                    color: colorScheme.onSurfaceVariant,
                    fontSize: 13,
                  ),
                ),
              ),
              Flexible(
                child: ListView.builder(
                  key: const Key('task-life-goal-picker'),
                  shrinkWrap: true,
                  itemCount: goals.length,
                  itemBuilder: (context, index) {
                    final goal = goals[index];
                    final isSelected = goal.id == _goalId;
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
                          key: Key('task-life-goal-option-${goal.id}'),
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
                          onTap: () => Navigator.of(sheetContext).pop(goal.id),
                        ),
                      ),
                    );
                  },
                ),
              ),
              if (_goalId != null) ...<Widget>[
                const Divider(height: 1),
                ListTile(
                  key: const Key('task-life-goal-remove-link'),
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
                    key: const Key('task-life-goal-picker-cancel'),
                    onPressed: () => Navigator.of(sheetContext).pop(),
                    child: const Text('Cancel'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || selected == null) {
      return;
    }
    setState(() {
      if (selected == '__none__') {
        _goalId = null;
        return;
      }
      _goalId = selected;
    });
  }

  Widget _buildSaveButton() {
    final colorScheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: 'Save',
      child: FilledButton(
        key: const Key('save-task-button'),
        onPressed: _saving ? null : _save,
        style: FilledButton.styleFrom(
          minimumSize: const Size(64, 48),
          padding: const EdgeInsets.symmetric(horizontal: 18),
          backgroundColor: colorScheme.primary,
          foregroundColor: colorScheme.onPrimary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
          ),
        ),
        child: _saving
            ? const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Text('Save', style: AppTypography.button),
      ),
    );
  }

  InputDecoration _inputDecoration({String? label, String? hintText}) {
    return InputDecoration(
      labelText: label,
      hintText: hintText,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      labelStyle: AppTypography.micro,
      floatingLabelStyle: AppTypography.micro,
      enabledBorder: OutlineInputBorder(
        borderSide: BorderSide(
          color: Theme.of(context).brightness == Brightness.dark
              ? Colors.white54
              : Theme.of(context).colorScheme.outline,
        ),
        borderRadius: BorderRadius.circular(4),
      ),
      focusedBorder: OutlineInputBorder(
        borderSide: BorderSide(
          color: Theme.of(context).colorScheme.primary,
          width: 2,
        ),
        borderRadius: BorderRadius.circular(4),
      ),
    );
  }

  ButtonStyle _rightAlignedActionStyle() {
    return TextButton.styleFrom(
      minimumSize: const Size(0, 48),
      padding: EdgeInsets.zero,
      alignment: Alignment.centerRight,
      foregroundColor: Theme.of(context).colorScheme.primary,
      textStyle: AppTypography.button,
    );
  }

  void _toggleDueDate(bool value) {
    FocusScope.of(context).unfocus();
    final provisionalPosition = _activeDraft;
    setState(() {
      _setDueDate = value;
      if (value) {
        // Enabling Due Date adopts the currently visible provisional block;
        // this is the single deliberate transition from visual placement to a
        // persisted Task schedule.  The block itself already exists while
        // the switch is OFF, so do not recreate or move it here.
        _dueDate = provisionalPosition?.date ?? _dueDate;
        _dueMinute = provisionalPosition?.minute ?? _dueMinute;
        _dueDate ??= ref.read(plannerControllerProvider).selectedDate;
        _dueDate ??= PlannerDate.fromDateTime(DateTime.now());
        _dueMinute ??= 18 * 60;
      } else {
        _dueDate = null;
        _dueMinute = null;
        _recurrence = PlannerTaskRecurrence.none;
      }
    });
    if (value) {
      unawaited(_refreshCapabilities());
      _publishDraftSchedule();
    }
  }

  Future<void> _pickDueDate() async {
    final initial = _dueDate?.asLocalDate ?? DateTime.now();
    final value = await showSharedPlannerDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(1900),
      lastDate: DateTime(2200, 12, 31),
      helpText: 'Select Task due date',
    );
    if (value != null && mounted) {
      setState(() {
        _dueDate = PlannerDate.fromDateTime(value);
        _dateNeedsSelectionForPlanner = false;
      });
      _publishDraftSchedule();
    }
  }

  Future<void> _pickDueTime() async {
    final initial = _timeFromMinute(_dueMinute ?? 18 * 60);
    // Same framework workaround as the event form: stripping viewInsets keeps
    // the stock time picker's input mode from producing non-normalized
    // BoxConstraints (216 dp hard minimum vs. keyboard-shrunk maximum).
    final value = await showTimePicker(
      context: context,
      initialTime: initial,
      builder: (context, child) => MediaQuery.removeViewInsets(
        context: context,
        removeBottom: true,
        child: child!,
      ),
    );
    if (value != null && mounted) {
      setState(() {
        _dueMinute = _snapMinute(value.hour * 60 + value.minute);
        _timeNeedsSelectionForPlanner = false;
      });
      _publishDraftSchedule();
    }
  }

  Future<void> _pickRecurrence() async {
    final value = await showModalBottomSheet<PlannerTaskRecurrence>(
      context: context,
      useSafeArea: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (final recurrence in PlannerTaskRecurrence.values)
              ListTile(
                key: Key('task-repeat-option-${recurrence.name}'),
                title: Text(_recurrenceLabel(recurrence)),
                onTap: () => Navigator.of(sheetContext).pop(recurrence),
              ),
            TextButton(
              key: const Key('task-repeat-cancel'),
              onPressed: () => Navigator.of(sheetContext).pop(),
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    );
    if (value != null && mounted) {
      setState(() => _recurrence = value);
    }
  }

  Future<void> _openSettings() async {
    await ref.read(permissionGatewayProvider).openSystemSettings();
    if (mounted) {
      await _refreshCapabilities();
    }
  }

  Future<void> _loadTaskContacts() async {
    try {
      final summaries = await ref.read(
        taskContactsProvider(_stableTaskId).future,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _contactIds = summaries
            .map((summary) => summary.contact.id)
            .toList(growable: false);
      });
    } on Object {
      // No ready Contacts profile/repository: keep the draft list empty.
    }
  }

  Future<void> _openAddContacts() async {
    final result = await context.push<List<String>>(
      RoutePaths.addPeople,
      extra: AddPeopleArgs(initialIds: _contactIds, displayLabel: 'Contacts'),
    );
    if (result != null && mounted) {
      setState(() => _contactIds = result);
    }
  }

  Future<bool> _isContactStillActive(String contactId) async {
    try {
      final detail = await ref
          .read(contactRepositoryProvider)
          .readContactDetail(
            profileId: ref.read(contactProfileIdProvider),
            contactId: contactId,
          );
      return detail.contact.isActive;
    } on Object {
      return false;
    }
  }

  String _formatTime(BuildContext context, bool use24HourTime) {
    final time = _timeFromMinute(_dueMinute ?? 18 * 60);
    if (use24HourTime) {
      return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    }
    return time.format(context);
  }

  static TimeOfDay _timeFromMinute(int minute) {
    return TimeOfDay(hour: minute ~/ 60, minute: minute % 60);
  }

  static int _snapMinute(int minute) =>
      ((minute / 5).round() * 5).clamp(0, 1439);

  static String _recurrenceLabel(PlannerTaskRecurrence recurrence) {
    return switch (recurrence) {
      PlannerTaskRecurrence.none => 'Does not repeat',
      PlannerTaskRecurrence.daily => 'Daily',
      PlannerTaskRecurrence.weekly => 'Weekly',
      PlannerTaskRecurrence.monthly => 'Monthly',
      PlannerTaskRecurrence.yearly => 'Yearly',
    };
  }

  Future<void> _save({bool confirmLinkedTypeTransfer = false}) async {
    if (widget.addToPlanner &&
        (_dueDate == null ||
            _dueMinute == null ||
            _dateNeedsSelectionForPlanner ||
            _timeNeedsSelectionForPlanner)) {
      setState(() {
        _error = 'Choose a date and time to add this Task to Planner.';
      });
      return;
    }
    if (!_formKey.currentState!.validate()) {
      return;
    }
    // A Planner-created Task already has one visible provisional placement.
    // With Set Due Date OFF, preserve that canonical draft date/minute at save
    // time so its one stable Task id replaces the draft in Day immediately.
    // Direct Task creation has no [initialDraftId], so it retains its existing
    // undated-save semantics.
    final plannerDraftPlacement = !_setDueDate && widget.taskId == null
        ? _activeDraft
        : null;
    setState(() {
      _saving = true;
      _error = null;
    });
    final saved = await ref
        .read(plannerControllerProvider.notifier)
        .saveTask(
          PlannerTaskDraft(
            id: _stableTaskId,
            title: _titleController.text,
            notes: _descriptionController.text,
            dueDate: _setDueDate ? _dueDate : plannerDraftPlacement?.date,
            dueMinute: _setDueDate ? _dueMinute : plannerDraftPlacement?.minute,
            recurrence: _setDueDate ? _recurrence : PlannerTaskRecurrence.none,
            // The persisted legacy field remains schema-compatible, but every
            // Task save normalizes it to the universal reporting law.
            requiresReport: true,
            people: _people,
            linkedActivityTypeId: _linkedActivityTypeId,
            linkedActivityTypeStableKey: _linkedActivityTypeStableKey,
            linkedActivityTypeLabelSnapshot: _linkedActivityTypeLabelSnapshot,
            goalId: _goalId,
          ),
          confirmLinkedTypeTransfer: confirmLinkedTypeTransfer,
          reminderMode: _reminderMode,
          reminderOffsetMinutes: _reminderOffsetMinutes,
          // M7 explicit follow-up withholds the early reconcile until the
          // Contacts commit and purpose write below have succeeded.
          deferReminderReconciliation: widget.initialFollowUpContactId != null,
        );
    if (!mounted) {
      return;
    }
    if (saved) {
      if (!mounted) {
        return;
      }
      if (!widget.addToPlanner) {
        try {
          await ref
              .read(contactRepositoryProvider)
              .setTaskContacts(
                profileId: ref.read(contactProfileIdProvider),
                taskId: _stableTaskId,
                contactIds: _contactIds,
              );
        } on Object {
          if (widget.initialFollowUpContactId != null) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text(
                    'Saved, but follow-up could not be applied. Try again.',
                  ),
                ),
              );
            }
            return;
          }
        }
      }
      if (!mounted) {
        return;
      }
      if (!widget.addToPlanner) {
        // M7: unlink clears explicit follow-up purpose without touching
        // ordinary Task timing or lifecycle.
        await ref
            .read(plannerControllerProvider.notifier)
            .clearUnlinkedFollowUp(
              taskId: _stableTaskId,
              currentContactIds: _contactIds.toSet(),
            );
      }
      if (!mounted) {
        return;
      }
      final followUpContactId = widget.initialFollowUpContactId;
      if (followUpContactId != null) {
        final contactStillActive = await _isContactStillActive(
          followUpContactId,
        );
        if (!contactStillActive) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Saved without follow-up.')),
            );
          }
        } else {
          try {
            await ref
                .read(plannerControllerProvider.notifier)
                .finalizeContactFollowUp(
                  taskId: _stableTaskId,
                  contactId: followUpContactId,
                );
          } on Object {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text(
                    'Saved, but follow-up could not be applied. Try again.',
                  ),
                ),
              );
            }
            return;
          }
        }
      }
      if (!mounted) {
        return;
      }
      _close(true);
      return;
    }
    final message =
        ref.read(plannerControllerProvider).message ??
        'Task could not be saved. Your input remains available.';
    if (!confirmLinkedTypeTransfer &&
        message.contains('already contributed progress')) {
      setState(() => _saving = false);
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          key: const Key('task-link-transfer-dialog'),
          title: const Text('Move Goal progress?'),
          content: const Text(
            'This completed Task already contributed progress. Changing the '
            'Life Goal will move that contribution to the new Goal.',
          ),
          actions: <Widget>[
            TextButton(
              key: const Key('task-link-transfer-cancel'),
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: const Key('task-link-transfer-confirm'),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Move progress'),
            ),
          ],
        ),
      );
      if (confirmed == true && mounted) {
        await _save(confirmLinkedTypeTransfer: true);
      }
      return;
    }
    setState(() {
      _saving = false;
      _error = message;
    });
  }

  /// Owner-approved clarification: the inherit row shows the ACTUAL
  /// currently-inherited category default (Task reminders use
  /// NotificationPreferences.defaultTaskReminderMinutes, owned by the
  /// existing Notification preference). No second default is persisted.
  String _reminderLabel() {
    switch (_reminderMode) {
      case ReminderPolicyMode.inherit:
        final inherited = ref
            .watch(notificationSettingsControllerProvider)
            .preferences
            .defaultTaskReminderMinutes;
        if (inherited == null) {
          return 'Default (Off)';
        }
        return inherited == 0
            ? 'Default (At due time)'
            : 'Default ($inherited min before)';
      case ReminderPolicyMode.off:
        return 'Off';
      case ReminderPolicyMode.offset:
        return '${_reminderOffsetMinutes ?? 0} minutes before';
    }
  }

  Future<void> _selectReminderPolicy() async {
    final selected = await showReminderTimePicker(context);
    if (!mounted) return;
    setState(() {
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
}

/// A read-only historical name chip (B3.2 O1).  Legacy free-text names stay
/// visible, are never auto-matched or auto-created, and have no remove
/// affordance in this pack.
final class _TaskLegacyPersonChip extends StatelessWidget {
  const _TaskLegacyPersonChip({required this.person});

  final String person;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      key: Key('task-legacy-person-$person'),
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: dark
            ? const Color(0xFF1C1E21)
            : Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: dark
              ? const Color(0xFF2A2D31)
              : Theme.of(context).colorScheme.outlineVariant,
        ),
      ),
      child: Row(
        children: <Widget>[
          const Icon(Icons.person_outline, size: 16, color: Color(0xFF9CA0A6)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              person,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }
}

/// A linked Contact chip in the Task form Contacts section.
final class _TaskContactChip extends StatelessWidget {
  const _TaskContactChip({
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
      key: Key('task-contact-$id'),
      margin: const EdgeInsets.only(bottom: 6),
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
            key: Key('task-remove-contact-$id'),
            tooltip: 'Remove',
            onPressed: onRemove,
            icon: const Icon(Icons.close, size: 20),
          ),
        ],
      ),
    );
  }
}

final class _TaskValueField extends StatelessWidget {
  const _TaskValueField({
    required this.label,
    required this.value,
    required this.onTap,
    this.icon,
    super.key,
  });

  final String label;
  final String value;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        height: 52,
        child: InputDecorator(
          isFocused: false,
          decoration: InputDecoration(
            labelText: label,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 12,
            ),
            labelStyle: AppTypography.micro,
            floatingLabelStyle: AppTypography.micro,
            suffixIcon: icon == null ? null : Icon(icon, size: 24),
            enabledBorder: OutlineInputBorder(
              borderSide: BorderSide(
                color: Theme.of(context).brightness == Brightness.dark
                    ? Colors.white54
                    : Theme.of(context).colorScheme.outline,
              ),
              borderRadius: BorderRadius.circular(4),
            ),
            focusedBorder: OutlineInputBorder(
              borderSide: BorderSide(
                color: Theme.of(context).colorScheme.primary,
                width: 2,
              ),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          child: Text(value, style: AppTypography.body),
        ),
      ),
    );
  }
}

final class _TaskRepeatField extends StatelessWidget {
  const _TaskRepeatField({required this.value, required this.onTap, super.key});

  final PlannerTaskRecurrence value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: const Key('task-repeat-value'),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text('Repeat', style: AppTypography.micro),
                  const SizedBox(height: 4),
                  Text(
                    _TaskFormScreenState._recurrenceLabel(value),
                    style: AppTypography.body,
                  ),
                ],
              ),
            ),
            const Icon(Icons.keyboard_arrow_down, size: 26),
          ],
        ),
      ),
    );
  }
}

final class _TaskSectionHeader extends StatelessWidget {
  const _TaskSectionHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(label, style: InternalScreen.sectionHeading),
        const SizedBox(height: 6),
        Divider(
          height: 1,
          color: Theme.of(context).brightness == Brightness.dark
              ? Colors.white38
              : Theme.of(context).colorScheme.outlineVariant,
        ),
      ],
    );
  }
}

final class _CapabilityNotice extends StatelessWidget {
  const _CapabilityNotice({
    required this.message,
    required this.onEnable,
    this.supportingText,
    super.key,
  });

  final String message;
  final String? supportingText;
  final VoidCallback onEnable;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            const CircleAvatar(
              radius: 16,
              backgroundColor: Color(0xFFFFB915),
              child: Text(
                'i',
                style: TextStyle(
                  color: Colors.black,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(child: Text(message, style: AppTypography.body)),
            TextButton(
              key: Key(
                'enable-${message.startsWith('Notifications') ? 'notifications' : 'reminders'}',
              ),
              onPressed: onEnable,
              style: TextButton.styleFrom(
                minimumSize: const Size(96, 48),
                foregroundColor: Theme.of(context).colorScheme.onPrimary,
                backgroundColor: Theme.of(context).colorScheme.primary,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24),
                ),
                textStyle: AppTypography.button,
              ),
              child: const Text('Enable'),
            ),
          ],
        ),
        if (supportingText != null) ...<Widget>[
          const SizedBox(height: 10),
          Text(supportingText!, style: AppTypography.secondary),
        ],
      ],
    );
  }
}
