// P1 (2026-09-21) — configured Visible Start/End Hours contract.
//
// SCOPE NOTE (important): the owner-approved P1-B law says the configured
// visible hours must define the DEFAULT Planner canvas, ruler, scroll extent,
// initial focus, current-time coordinates and pinch extent. The CANVAS-EXTENT
// half of that law is NOT implemented (the canvas still spans the full civil
// day), so nothing here asserts a bounded canvas — doing so would be false.
//
// What IS locked here is the range model that the canvas rework must consume:
// the single effective range origin, its boundary semantics (12 AM / 12 PM /
// next-day 12 AM), the full set of valid 1-24 hour windows, rejection of
// invalid/reversed ranges, persistence across a restart, and the initial-focus
// clamp. These are the preconditions P1-B depends on.

import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/features/planner/data/drift_event_type_repository.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/domain/planner_settings.dart';
import 'package:rmplanner/features/planner/domain/planner_timeline_layout.dart';

import '../../../support/test_dependencies.dart';

PlannerSettings _range(int startHour, int endHour) =>
    const PlannerSettings.defaults().copyWith(
      visibleStartHour: startHour,
      visibleEndHour: endHour,
    );

void main() {
  group('effective visible range origin', () {
    test('6 AM - 6 PM is a 12-hour window with inclusive boundaries', () {
      final settings = _range(6, 18);

      // 6 AM first boundary.
      expect(settings.visibleStartHour, 6);
      expect(settings.visibleStartMinute, 6 * 60);
      // 6 PM final boundary.
      expect(settings.visibleEndHour, 18);
      expect(settings.visibleEndMinute, 18 * 60);
      expect(settings.visibleSpanMinutes, 12 * 60);
      expect(settings.visibleSpanHours, 12);
    });

    test('0, 12 and 24 keep midnight / noon / next-day-midnight semantics', () {
      final fullDay = _range(0, 24);
      expect(fullDay.visibleStartMinute, 0, reason: '12 AM');
      expect(fullDay.visibleEndMinute, 24 * 60, reason: 'next-day 12 AM');
      expect(fullDay.visibleSpanHours, 24);

      // Noon is the 12th hour boundary; it is neither midnight.
      final noonStart = _range(12, 24);
      expect(noonStart.visibleStartMinute, 12 * 60, reason: '12 PM');
      expect(noonStart.visibleSpanHours, 12);
      expect(noonStart.visibleStartMinute, isNot(fullDay.visibleStartMinute));
    });

    test('every permitted 1-24 hour window is a positive in-day span', () {
      for (var start = 0; start <= 23; start++) {
        for (var end = start + 1; end <= 24; end++) {
          final settings = _range(start, end);
          final reason = 'start=$start end=$end';
          expect(settings.visibleStartMinute, start * 60, reason: reason);
          expect(settings.visibleEndMinute, end * 60, reason: reason);
          expect(settings.visibleSpanMinutes, greaterThan(0), reason: reason);
          expect(
            settings.visibleSpanMinutes,
            lessThanOrEqualTo(24 * 60),
            reason: reason,
          );
          expect(settings.visibleSpanHours, end - start, reason: reason);
          // A 1-hour window is legal and must survive copyWith unchanged.
          expect(
            settings.visibleEndHour - settings.visibleStartHour,
            end - start,
          );
        }
      }
    });

    test('invalid and reversed ranges are rejected, not silently repaired', () {
      expect(() => _range(18, 6).validate(), throwsArgumentError);
      expect(() => _range(6, 6).validate(), throwsArgumentError);
      expect(() => _range(24, 24).validate(), throwsArgumentError);
    });

    test('the 12/24-hour display preference is independent of the range', () {
      final twentyFour = _range(6, 18).copyWith(use24HourTime: true);
      final twelve = _range(6, 18).copyWith(use24HourTime: false);

      expect(twentyFour.use24HourTime, isTrue);
      expect(twelve.use24HourTime, isFalse);
      // The range is identical either way.
      expect(twentyFour.visibleStartMinute, twelve.visibleStartMinute);
      expect(twentyFour.visibleEndMinute, twelve.visibleEndMinute);
    });

    test('a corrupt zoom does not disturb the range origin', () {
      final settings = _range(6, 18).copyWith(timelineHourHeight: 9999);
      expect(settings.timelineHourHeight, 320);
      expect(settings.visibleStartMinute, 6 * 60);
      expect(settings.visibleEndMinute, 18 * 60);
    });
  });

  group('range persistence and initial focus', () {
    late AppDatabase database;
    late String profileId;

    setUp(() async {
      database = openMemoryDatabase();
      profileId = (await buildTestRepository(
        database: database,
      ).completeOnboarding()).id;
    });

    tearDown(() => database.close());

    DriftEventTypeRepository repositoryAt() => DriftEventTypeRepository(
      database: database,
      clock: FixedClock(DateTime.utc(2026, 9, 21, 12)),
    );

    test('a configured range survives a restart', () async {
      await repositoryAt().savePlannerSettings(
        profileId: profileId,
        settings: _range(6, 18),
      );

      // A fresh repository instance over the same database models a restart.
      final restored = await repositoryAt().readPlannerSettings(
        profileId: profileId,
      );

      expect(restored.visibleStartHour, 6);
      expect(restored.visibleEndHour, 18);
      expect(restored.visibleStartMinute, 360);
      expect(restored.visibleEndMinute, 1080);
      expect(restored.visibleSpanHours, 12);
    });

    test('a deliberately changed range is what a restart reads back', () async {
      await repositoryAt().savePlannerSettings(
        profileId: profileId,
        settings: _range(6, 18),
      );
      await repositoryAt().savePlannerSettings(
        profileId: profileId,
        settings: _range(5, 19),
      );

      final restored = await repositoryAt().readPlannerSettings(
        profileId: profileId,
      );
      expect(restored.visibleStartHour, 5);
      expect(restored.visibleEndHour, 19);
    });

    test('the full-day preset persists as 0-24', () async {
      await repositoryAt().savePlannerSettings(
        profileId: profileId,
        settings: _range(6, 18),
      );
      await repositoryAt().savePlannerSettings(
        profileId: profileId,
        settings: _range(0, 24),
      );

      final restored = await repositoryAt().readPlannerSettings(
        profileId: profileId,
      );
      expect(restored.visibleStartMinute, 0);
      expect(restored.visibleEndMinute, 1440);
    });

    test('initial focus honours the configured start', () {
      final settings = _range(6, 18).copyWith(
        initialScrollBehavior: PlannerInitialScrollBehavior.visibleStart,
      );
      final target = plannerInitialScrollMinute(
        settings: settings,
        selectedDate: PlannerDate(year: 2026, month: 9, day: 21),
        now: DateTime(2026, 9, 21, 12),
      );

      expect(target, 6 * 60);
    });

    test('initial focus stays inside the civil day for every window', () {
      for (var start = 0; start <= 23; start++) {
        for (final behavior in PlannerInitialScrollBehavior.values) {
          final settings = _range(
            start,
            start + 1,
          ).copyWith(initialScrollBehavior: behavior);
          final target = plannerInitialScrollMinute(
            settings: settings,
            selectedDate: PlannerDate(year: 2026, month: 9, day: 21),
            now: DateTime(2026, 9, 21, 12),
          );
          expect(
            target,
            inInclusiveRange(0, 1439),
            reason: 'start=$start behavior=$behavior',
          );
        }
      }
    });

    test('impossible stored boundaries are rejected by validate', () async {
      await expectLater(
        repositoryAt().savePlannerSettings(
          profileId: profileId,
          settings: _range(18, 6),
        ),
        throwsArgumentError,
      );
    });
  });
}
