import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/planner/application/event_type_providers.dart';
import 'package:rmplanner/features/planner/application/event_type_repository.dart';
import 'package:rmplanner/features/planner/data/drift_event_type_repository.dart';
import 'package:rmplanner/features/planner/domain/event_color_preferences.dart';
import 'package:rmplanner/features/planner/domain/event_type.dart';
import 'package:rmplanner/features/planner/domain/planner_settings.dart';
import 'package:rmplanner/features/planner/presentation/event_type_form_screen.dart';
import 'package:rmplanner/features/startup/application/startup_providers.dart';
import 'package:rmplanner/features/startup/domain/startup_state.dart';

import '../../../support/gated_event_type_repository.dart';
import '../../../support/test_dependencies.dart';

final class _MemoryEventTypeRepository implements EventTypeRepository {
  _MemoryEventTypeRepository()
    : _types = <EventType>[
        const EventType(
          id: SystemEventTypeIds.exercise,
          stableKey: SystemEventTypeKeys.exercise,
          label: 'Exercise',
          icon: EventTypeIcon.exercise,
          colorValue: 0xFF26A69A,
          isSystem: true,
          isArchived: false,
          reportRequiredDefault: true,
          defaultDurationMinutes: 60,
          position: 2,
          mappingVersion: 1,
          indicatorKeys: <String>{'exercise'},
        ),
      ];

  final List<EventType> _types;
  PlannerSettings _settings = const PlannerSettings.defaults();
  Map<String, EventColorPreference> _colors = <String, EventColorPreference>{};
  Map<String, int> _groups = <String, int>{};

  @override
  Future<List<EventType>> readEventTypes({
    required String profileId,
    bool includeArchived = false,
  }) async => List<EventType>.unmodifiable(
    _types.where((type) => includeArchived || !type.isArchived),
  );

  @override
  Future<EventType?> readEventType({
    required String profileId,
    required String eventTypeId,
  }) async => _types.where((type) => type.id == eventTypeId).firstOrNull;

  @override
  Future<EventType?> readExactTypeForIndicator({
    required String profileId,
    required String indicatorKey,
  }) async => _types
      .where((type) => type.exactIndicatorKey == indicatorKey)
      .firstOrNull;

  @override
  Future<EventType> saveCustomType({
    required String profileId,
    required EventTypeDraft draft,
  }) async {
    final index = _types.indexWhere((type) => type.id == draft.id);
    final previous = index == -1 ? null : _types[index];
    final saved = EventType(
      id: draft.id,
      stableKey: previous?.stableKey ?? 'custom:${draft.id}',
      label: draft.label.trim(),
      icon: draft.icon,
      colorValue: draft.colorValue,
      isSystem: false,
      isArchived: false,
      reportRequiredDefault: draft.reportRequiredDefault,
      defaultDurationMinutes: draft.defaultDurationMinutes,
      defaultReminderMinutes: draft.defaultReminderMinutes,
      position: previous?.position ?? 100,
      mappingVersion: (previous?.mappingVersion ?? 0) + 1,
      indicatorKeys: Set<String>.unmodifiable(draft.indicatorKeys),
    );
    if (index == -1) {
      _types.add(saved);
    } else {
      _types[index] = saved;
    }
    return saved;
  }

  @override
  Future<void> renameSystemType({
    required String profileId,
    required String eventTypeId,
    required String label,
  }) async {
    final index = _types.indexWhere((type) => type.id == eventTypeId);
    final current = _types[index];
    _types[index] = _withLabel(current, label.trim());
  }

  @override
  Future<void> setCustomTypeArchived({
    required String profileId,
    required String eventTypeId,
    required bool archived,
  }) async {}

  @override
  Future<void> restoreSystemDefaults({required String profileId}) async {}

  @override
  Future<PlannerSettings> readPlannerSettings({
    required String profileId,
  }) async => _settings;

  @override
  Future<PlannerSettings> savePlannerSettings({
    required String profileId,
    required PlannerSettings settings,
  }) async {
    _settings = settings;
    return settings;
  }

  @override
  Future<Map<String, EventColorPreference>> readEventColorPreferences({
    required String profileId,
  }) async => Map<String, EventColorPreference>.unmodifiable(_colors);

  @override
  Future<Map<String, EventColorPreference>> saveEventColorPreference({
    required String profileId,
    required String eventTypeStableKey,
    required EventColorPreference preference,
  }) async {
    _colors = <String, EventColorPreference>{
      ..._colors,
      eventTypeStableKey: preference,
    };
    return Map<String, EventColorPreference>.unmodifiable(_colors);
  }

  @override
  Future<Map<String, EventColorPreference>> restoreEventColorDefaults({
    required String profileId,
  }) async {
    _colors = <String, EventColorPreference>{};
    return const <String, EventColorPreference>{};
  }

  @override
  Future<Map<String, int>> readContactGroupColors({
    required String profileId,
  }) async => Map<String, int>.unmodifiable(_groups);

  @override
  Future<Map<String, int>> saveContactGroupColor({
    required String profileId,
    required String groupId,
    required int colorArgb,
  }) async {
    _groups = <String, int>{..._groups, groupId: colorArgb};
    return Map<String, int>.unmodifiable(_groups);
  }

  @override
  Future<Map<String, int>> restoreContactGroupColorDefaults({
    required String profileId,
  }) async {
    _groups = <String, int>{};
    return const <String, int>{};
  }

  @override
  Stream<void> watchPresentationDocument(String profileId) =>
      const Stream<void>.empty();

  @override
  Future<Map<String, GoalEventTypeNameOverride>>
  readGoalEventTypeNameOverrides(String profileId) async =>
      const <String, GoalEventTypeNameOverride>{};

  @override
  Future<LiveGoalPresentationResult> saveLiveGoalPresentation({
    required String profileId,
    required int expectedSlotIndex,
    required String expectedGoalId,
    required String expectedEventTypeId,
    required String expectedStableKey,
    required LiveGoalPresentationOriginals originalValues,
    required LiveGoalPresentationPatch patch,
  }) {
    throw UnimplementedError();
  }

  static EventType _withLabel(EventType type, String label) => EventType(
    id: type.id,
    stableKey: type.stableKey,
    label: label,
    icon: type.icon,
    colorValue: type.colorValue,
    isSystem: type.isSystem,
    isArchived: type.isArchived,
    reportRequiredDefault: type.reportRequiredDefault,
    defaultDurationMinutes: type.defaultDurationMinutes,
    defaultReminderMinutes: type.defaultReminderMinutes,
    position: type.position,
    mappingVersion: type.mappingVersion,
    indicatorKeys: type.indicatorKeys,
  );
}

Future<(GatedEventTypeRepository, ProviderContainer, String)>
_bootstrapController() async {
  final database = openMemoryDatabase();
  final startup = buildTestRepository(database: database);
  final profile = await startup.completeOnboarding();
  final repository = GatedEventTypeRepository(_MemoryEventTypeRepository());
  final container = ProviderContainer(
    overrides: [
      startupRepositoryProvider.overrideWithValue(startup),
      diagnosticsProvider.overrideWithValue(SanitizedDiagnostics()),
      eventTypeRepositoryProvider.overrideWithValue(repository),
    ],
  );
  addTearDown(() async {
    repository.releaseAll();
    container.dispose();
    await database.close();
  });

  final startupController = container.read(startupControllerProvider.notifier);
  await startupController.initialize();
  expect(container.read(startupControllerProvider), isA<StartupReady>());
  final eventTypes = container.read(eventTypeControllerProvider.notifier);
  await eventTypes.load();
  expect(container.read(eventTypeControllerProvider).isLoading, isFalse);
  return (repository, container, profile.id);
}

Future<(GatedEventTypeRepository, DriftEventTypeRepository, EventType, String)>
_openCustomTypeForm(WidgetTester tester) async {
  tester.view.physicalSize = const Size(393, 874);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final database = openMemoryDatabase();
  addTearDown(database.close);
  final startup = buildTestRepository(database: database);
  final profile = await startup.completeOnboarding();
  final delegate = DriftEventTypeRepository(
    database: database,
    clock: FixedClock(DateTime.utc(2026, 8, 14, 12)),
  );
  // Accepted M6 law: the raw Event Type form now only creates and edits CUSTOM
  // types. Canonical/system rows are never edited here — the form pops itself
  // and the live rows route to the draft-only presentation editor — so the
  // live row-then-color Save path this file proves is the custom-type path.
  await delegate.saveCustomType(
    profileId: profile.id,
    draft: const EventTypeDraft(
      id: 'a5-custom-form-latency',
      label: 'A5 Custom Form',
      icon: EventTypeIcon.personal,
      colorValue: 0xFF26A69A,
      reportRequiredDefault: false,
      defaultDurationMinutes: 45,
      indicatorKeys: <String>{},
    ),
  );
  final type = (await delegate.readEventType(
    profileId: profile.id,
    eventTypeId: 'a5-custom-form-latency',
  ))!;
  final repository = GatedEventTypeRepository(delegate);
  addTearDown(() async {
    repository.releaseAll();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
  final privacy = TestPrivacyDependencies(database: database);
  await tester.pumpWidget(
    privacy.buildApp(
      environment: const AppEnvironment(
        name: AppEnvironmentName.production,
        label: 'PRODUCTION',
      ),
      diagnostics: SanitizedDiagnostics(),
      startupRepository: startup,
      eventTypeRepository: repository,
    ),
  );
  await tester.pumpAndSettle();
  final context = tester.element(find.byType(Scaffold).first);
  unawaited(
    Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => EventTypeFormScreen.edit(
          eventTypeId: type.id,
          initialEventType: type,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(find.byType(EventTypeFormScreen), findsOneWidget);
  return (repository, delegate, type, profile.id);
}

Future<void> _pumpUntilWidget(
  WidgetTester tester,
  bool Function() condition,
) async {
  for (var attempt = 0; attempt < 40 && !condition(); attempt += 1) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _showSaveButton(WidgetTester tester) async {
  final save = find.byKey(const Key('save-custom-event-type'));
  await tester.scrollUntilVisible(
    save,
    180,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pump();
}

void _invokeSave(WidgetTester tester) {
  final save = find.byKey(const Key('save-custom-event-type'));
  final onPressed = tester.widget<FilledButton>(save).onPressed;
  expect(onPressed, isNotNull);
  onPressed!();
}

void main() {
  test(
    'A5: custom save returns canonical local state without post-save global reads',
    () async {
      final (repository, container, profileId) = await _bootstrapController();
      final readsBefore = repository.globalReadCalls;
      repository.blockGlobalReads = true;
      const draft = EventTypeDraft(
        id: 'a5-custom-latency',
        label: '  A5 Canonical Custom  ',
        icon: EventTypeIcon.personal,
        colorValue: 0xFF26A69A,
        reportRequiredDefault: true,
        defaultDurationMinutes: 45,
        indicatorKeys: <String>{'exercise'},
      );

      var completed = false;
      final operation = container
          .read(eventTypeControllerProvider.notifier)
          .saveCustomType(draft);
      unawaited(operation.then((_) => completed = true));
      final canonical = await repository.customWriteCompleted.future;
      await Future<void>.delayed(Duration.zero);
      final completedBeforeRelease = completed;
      final readsBeforeRelease = repository.globalReadCalls;
      final stateBeforeRelease = container.read(eventTypeControllerProvider);
      final locallySaved = stateBeforeRelease.eventTypes
          .where((candidate) => candidate.id == draft.id)
          .firstOrNull;

      repository.releaseAll();
      final operationResult = await operation;
      final durable = await repository.delegate.readEventType(
        profileId: profileId,
        eventTypeId: draft.id,
      );

      expect(
        completedBeforeRelease,
        isTrue,
        reason:
            'A durable row write must not wait for four unrelated global '
            'reads before the form can continue to color persistence.',
      );
      expect(operationResult, isTrue);
      expect(readsBeforeRelease, readsBefore);
      expect(locallySaved, isNotNull);
      expect(identical(locallySaved, canonical), isTrue);
      expect(locallySaved?.label, 'A5 Canonical Custom');
      expect(locallySaved?.stableKey, 'custom:${draft.id}');
      expect(locallySaved?.indicatorKeys, draft.indicatorKeys);
      expect(stateBeforeRelease.isLoading, isFalse);
      expect(durable?.label, locallySaved?.label);
    },
  );

  test(
    'A5: fixed system rename returns updated local object without global reload',
    () async {
      final (repository, container, profileId) = await _bootstrapController();
      final before = container
          .read(eventTypeControllerProvider)
          .eventTypes
          .singleWhere(
            (candidate) => candidate.id == SystemEventTypeIds.exercise,
          );
      final readsBefore = repository.globalReadCalls;
      repository.blockGlobalReads = true;

      var completed = false;
      final operation = container
          .read(eventTypeControllerProvider.notifier)
          .renameSystemType(
            eventTypeId: before.id,
            label: '  Movement Practice  ',
          );
      unawaited(operation.then((_) => completed = true));
      await repository.renameWriteCompleted.future;
      await Future<void>.delayed(Duration.zero);
      final completedBeforeRelease = completed;
      final readsBeforeRelease = repository.globalReadCalls;
      final renamedBeforeRelease = container
          .read(eventTypeControllerProvider)
          .eventTypes
          .singleWhere((candidate) => candidate.id == before.id);

      repository.releaseAll();
      final operationResult = await operation;
      final durable = await repository.delegate.readEventType(
        profileId: profileId,
        eventTypeId: before.id,
      );

      expect(
        completedBeforeRelease,
        isTrue,
        reason:
            'A durable label write must update only its confirmed local '
            'object instead of waiting for a global reload.',
      );
      expect(operationResult, isTrue);
      expect(readsBeforeRelease, readsBefore);
      final renamed = renamedBeforeRelease;
      expect(renamed.label, 'Movement Practice');
      expect(renamed.stableKey, before.stableKey);
      expect(renamed.icon, before.icon);
      expect(renamed.colorValue, before.colorValue);
      expect(renamed.isSystem, before.isSystem);
      expect(renamed.isArchived, before.isArchived);
      expect(renamed.reportRequiredDefault, before.reportRequiredDefault);
      expect(renamed.defaultDurationMinutes, before.defaultDurationMinutes);
      expect(renamed.defaultReminderMinutes, before.defaultReminderMinutes);
      expect(renamed.position, before.position);
      expect(renamed.mappingVersion, before.mappingVersion);
      expect(renamed.indicatorKeys, before.indicatorKeys);
      expect(durable?.label, renamed.label);
    },
  );

  testWidgets(
    'A5: custom form persists row then color and dismisses only after both',
    (tester) async {
      final (repository, delegate, type, profileId) = await _openCustomTypeForm(
        tester,
      );
      repository
        ..blockGlobalReads = true
        ..blockCustomSave = true
        ..blockColorSave = true;
      final readsBefore = repository.globalReadCalls;
      const savedLabel = 'A5 Sequenced Custom';
      await tester.enterText(
        find.byKey(const Key('custom-event-type-label')),
        savedLabel,
      );
      await _showSaveButton(tester);
      final save = find.byKey(const Key('save-custom-event-type'));
      _invokeSave(tester);
      await tester.pump();

      expect(repository.customSaveStarted.isCompleted, isTrue);
      expect(repository.customWriteCompleted.isCompleted, isFalse);
      expect(repository.colorSaveStarted.isCompleted, isFalse);
      expect(find.byType(EventTypeFormScreen), findsOneWidget);
      expect(tester.widget<FilledButton>(save).onPressed, isNull);

      repository.releaseCustomSave();
      await _pumpUntilWidget(
        tester,
        () => repository.colorSaveStarted.isCompleted,
      );
      expect(repository.customWriteCompleted.isCompleted, isTrue);
      expect(repository.colorSaveStarted.isCompleted, isTrue);
      expect(repository.colorWriteCompleted.isCompleted, isFalse);
      expect(find.byType(EventTypeFormScreen), findsOneWidget);
      expect(
        (await delegate.readEventType(
          profileId: profileId,
          eventTypeId: type.id,
        ))?.label,
        savedLabel,
      );

      repository.releaseColorSave();
      await tester.pumpAndSettle();
      expect(repository.colorWriteCompleted.isCompleted, isTrue);
      expect(repository.globalReadCalls, readsBefore);
      expect(find.byType(EventTypeFormScreen), findsNothing);
      expect(find.byKey(const Key('home-app-bar')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'A5: row and color failures keep the custom Event Type draft on screen',
    (tester) async {
      final (repository, delegate, type, profileId) = await _openCustomTypeForm(
        tester,
      );
      final form = find.byType(EventTypeFormScreen);
      final container = ProviderScope.containerOf(tester.element(form));
      const draftLabel = 'A5 Failure Draft';
      final labelField = find.byKey(const Key('custom-event-type-label'));
      await tester.enterText(labelField, draftLabel);
      final labelController = tester
          .widget<TextFormField>(labelField)
          .controller!;
      await _showSaveButton(tester);
      final save = find.byKey(const Key('save-custom-event-type'));

      repository.customSaveFailure = StateError('Injected row failure');
      _invokeSave(tester);
      await tester.pumpAndSettle();
      expect(form, findsOneWidget);
      expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
      expect(labelController.text, draftLabel);
      expect(repository.colorSaveStarted.isCompleted, isFalse);
      expect(
        container.read(eventTypeControllerProvider).message,
        'Event Type was not changed. Your input is still available.',
      );
      expect(
        (await delegate.readEventType(
          profileId: profileId,
          eventTypeId: type.id,
        ))?.label,
        type.label,
      );

      repository
        ..customSaveFailure = null
        ..colorSaveFailure = StateError('Injected color failure');
      _invokeSave(tester);
      await tester.pumpAndSettle();
      expect(repository.customWriteCompleted.isCompleted, isTrue);
      expect(repository.colorSaveStarted.isCompleted, isTrue);
      expect(repository.colorWriteCompleted.isCompleted, isFalse);
      expect(form, findsOneWidget);
      expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
      expect(labelController.text, draftLabel);
      expect(
        container.read(eventTypeControllerProvider).message,
        'Event color was not changed. You can safely retry.',
      );
      expect(
        (await delegate.readEventType(
          profileId: profileId,
          eventTypeId: type.id,
        ))?.label,
        draftLabel,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
