import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/colors/vs11_color_system.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/features/planner/data/drift_event_type_repository.dart';
import 'package:rmplanner/features/planner/domain/event_type.dart';

import '../../../support/test_dependencies.dart';

void main() {
  late AppDatabase database;
  late DriftEventTypeRepository repository;
  late String profileId;
  final clock = FixedClock(DateTime.utc(2026, 9, 9, 12));

  setUp(() async {
    database = openMemoryDatabase();
    profileId = (await buildTestRepository(
      database: database,
    ).completeOnboarding()).id;
    repository = DriftEventTypeRepository(database: database, clock: clock);
  });

  tearDown(() => database.close());

  test(
    'fresh single profile seeds 20 system rows with Education position 19',
    () async {
      final types = await repository.readEventTypes(profileId: profileId);
      expect(types, hasLength(20));
      final education = types.singleWhere(
        (type) => type.stableKey == SystemEventTypeKeys.education,
      );
      expect(education.id, SystemEventTypeIds.education);
      expect(education.label, 'Education');
      expect(education.position, 19);
      expect(education.isSystem, isTrue);
      expect(education.isArchived, isFalse);
      expect(education.reportRequiredDefault, isFalse);
      expect(education.defaultDurationMinutes, 60);
      expect(education.defaultReminderMinutes, isNull);
      expect(education.mappingVersion, 1);
      expect(education.indicatorKeys, isEmpty);
      // M7 reconciliation (2026-09-16): the approved Education pair is P22
      // Steel blue (Prompt-P46), the value the repository seed writes.
      expect(education.colorValue, Vs11ColorSystem.p22SteelBlue);
      // Approved creation order: after Study or Plan, before Service.
      final order = SystemEventTypeKeys.approvedCreationOrder;
      expect(order.indexOf(SystemEventTypeKeys.education), 9);
      expect(
        order[order.indexOf(SystemEventTypeKeys.education) - 1],
        SystemEventTypeKeys.studyOrPlan,
      );
      expect(
        order[order.indexOf(SystemEventTypeKeys.education) + 1],
        SystemEventTypeKeys.service,
      );
      // M7 reconciliation (2026-09-16): the frozen schema law is 47 (M6); this
      // literal still carried the retired v46. The database stays consistent.
      expect(
        (await database.customSelect('PRAGMA user_version').getSingle())
            .data
            .values
            .single,
        47,
      );
      expect(
        (await database.customSelect('PRAGMA integrity_check').getSingle())
            .data
            .values
            .single,
        'ok',
      );
    },
  );

  test(
    'repeat reads are idempotent with no timestamp churn or row growth',
    () async {
      await repository.readEventTypes(profileId: profileId);
      Future<List<ActivityTypeRow>> snapshot() =>
          database.select(database.activityTypes).get();
      final before = await snapshot();
      await repository.readEventTypes(profileId: profileId);
      await repository.readEventTypes(profileId: profileId);
      await repository.readEventTypes(profileId: profileId);
      final after = await snapshot();
      expect(after.length, before.length);
      expect(after.length, 20);
      for (var i = 0; i < after.length; i++) {
        expect(
          after[i].updatedAtUtc,
          before[i].updatedAtUtc,
          reason: 'idempotent backfill must not churn timestamps',
        );
      }
    },
  );

  test('backfill writes no mappings, preferences, or Goal tables', () async {
    // First read performs the canonical seeding AND the Education backfill;
    // every subsequent read must be write-neutral (T03 singleton isolation).
    await repository.readEventTypes(profileId: profileId);
    Future<int> count(String table) async =>
        (await database
                    .customSelect('SELECT COUNT(*) c FROM $table')
                    .getSingle())
                .data['c']
            as int;
    final typesBefore = await count('activity_types');
    final mappingsBefore = await count('activity_type_indicator_mappings');
    final prefsBefore = await count('planner_preferences');
    final goalsBefore = await count('goals');
    await repository.readEventTypes(profileId: profileId);
    await repository.readEventTypes(profileId: profileId);
    expect(await count('activity_types'), typesBefore);
    expect(await count('activity_type_indicator_mappings'), mappingsBefore);
    expect(await count('planner_preferences'), prefsBefore);
    expect(await count('goals'), goalsBefore);
    final education = (await repository.readEventTypes(
      profileId: profileId,
    )).singleWhere((type) => type.stableKey == SystemEventTypeKeys.education);
    expect(education.indicatorKeys, isEmpty);
  });

  test('a pre-existing custom row labeled Education is never merged', () async {
    // Simulate a user-created custom row that predates the Education seed:
    // direct insert so the unique-active-label guard (a saveCustomType law)
    // does not apply to the historical fixture. The backfill must insert the
    // system row alongside it — never merge, rename, or recolor either row.
    await database
        .into(database.activityTypes)
        .insert(
          ActivityTypesCompanion.insert(
            id: 'b2000000-0000-4000-8000-000000000002',
            profileId: profileId,
            stableKey: 'custom_education_like',
            label: 'Education',
            iconKey: EventTypeIcon.calendar.name,
            colorValue: 0xFF123456,
            isSystem: false,
            position: 100,
            createdAtUtc: clock.value,
            updatedAtUtc: clock.value,
          ),
        );
    final types = await repository.readEventTypes(profileId: profileId);
    final educationLike = types.singleWhere(
      (type) => type.id == 'b2000000-0000-4000-8000-000000000002',
    );
    expect(educationLike.label, 'Education');
    expect(educationLike.isSystem, isFalse);
    expect(educationLike.stableKey, 'custom_education_like');
    final system = types.singleWhere(
      (type) => type.stableKey == SystemEventTypeKeys.education,
    );
    expect(system.id, SystemEventTypeIds.education);
    expect(system.isSystem, isTrue);
  });
}
