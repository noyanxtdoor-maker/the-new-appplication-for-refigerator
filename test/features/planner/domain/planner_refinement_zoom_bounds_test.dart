// P1 (2026-09-21) — Planner zoom bounds contract.
//
// Astra's forensic audit proved an arithmetic counterexample in the pre-P1
// `PlannerZoomPolicy.clampForViewport`: for a VALID 1-hour visible window on a
// ~700 dp viewport the derived minimum (700/1 clamped up to the absolute
// ceiling, 320) exceeded the derived maximum (700/2.75 ≈ 254.55). Dart's
// `num.clamp` throws `ArgumentError` when lowerLimit > upperLimit, so a valid
// stored 6 AM–7 AM visible window was a reachable crash path.
//
// These tests pin the ordered-bounds law for EVERY permitted 1–24-hour window
// and assert the accepted preset/dead-zone geometry is unchanged.

import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/features/planner/domain/planner_view.dart';

void main() {
  group('PlannerZoomPolicy.zoomBoundsFor — ordered bounds', () {
    test('every permitted 1–24-hour window yields minimum <= maximum', () {
      for (final viewportHeight in <double>[320, 480, 700, 812, 1024, 1600]) {
        for (var hours = 1; hours <= 24; hours++) {
          final bounds = PlannerZoomPolicy.zoomBoundsFor(
            viewportHeight: viewportHeight,
            configuredHours: hours,
          );
          final reason = 'viewport=$viewportHeight hours=$hours';
          expect(
            bounds.minimum,
            lessThanOrEqualTo(bounds.maximum),
            reason: 'inverted bounds for $reason',
          );
          expect(
            bounds.minimum,
            greaterThanOrEqualTo(PlannerZoomPolicy.absoluteMinimumHourHeight),
            reason: 'floor below absolute minimum for $reason',
          );
          expect(
            bounds.maximum,
            lessThanOrEqualTo(PlannerZoomPolicy.absoluteMaximumHourHeight),
            reason: 'ceiling above absolute maximum for $reason',
          );
        }
      }
    });

    test('the audited counterexample no longer throws', () {
      // The exact reproduction from the audit: viewport 700, configuredHours 1.
      // Pre-P1 this called value.clamp(320, 254.5454...) and threw.
      expect(
        () => PlannerZoomPolicy.clampForViewport(
          60,
          viewportHeight: 700,
          configuredHours: 1,
        ),
        returnsNormally,
      );
    });

    test('a clamped window collapses to a single permitted value', () {
      final bounds = PlannerZoomPolicy.zoomBoundsFor(
        viewportHeight: 700,
        configuredHours: 1,
      );
      // The fit-the-whole-window floor wins, so both ends are the absolute
      // ceiling: showing the entire configured window stays mandatory.
      expect(bounds.minimum, PlannerZoomPolicy.absoluteMaximumHourHeight);
      expect(bounds.maximum, PlannerZoomPolicy.absoluteMaximumHourHeight);
      expect(
        PlannerZoomPolicy.clampForViewport(
          60,
          viewportHeight: 700,
          configuredHours: 1,
        ),
        PlannerZoomPolicy.absoluteMaximumHourHeight,
      );
    });

    test('the default 16-hour window keeps its accepted fit bounds', () {
      final bounds = PlannerZoomPolicy.zoomBoundsFor(
        viewportHeight: 700,
        configuredHours: 16,
      );
      expect(bounds.minimum, closeTo(700 / 16, 1e-9));
      expect(bounds.maximum, closeTo(700 / 2.75, 1e-9));
    });

    test('clampForViewport never throws across the whole matrix', () {
      for (var hours = 1; hours <= 24; hours++) {
        for (final value in <double>[
          0,
          20,
          44,
          60,
          88,
          254.54545454545456,
          320,
          10000,
        ]) {
          for (final viewportHeight in <double>[0, 320, 700, 1024]) {
            expect(
              () => PlannerZoomPolicy.clampForViewport(
                value,
                viewportHeight: viewportHeight,
                configuredHours: hours,
              ),
              returnsNormally,
              reason: 'hours=$hours value=$value viewport=$viewportHeight',
            );
          }
        }
      }
    });

    test('clampForViewport respects the derived min and max', () {
      // Below the fit floor clamps up; above the zoom-in ceiling clamps down.
      expect(
        PlannerZoomPolicy.clampForViewport(
          10,
          viewportHeight: 700,
          configuredHours: 16,
        ),
        closeTo(700 / 16, 1e-9),
      );
      expect(
        PlannerZoomPolicy.clampForViewport(
          10000,
          viewportHeight: 700,
          configuredHours: 16,
        ),
        closeTo(700 / 2.75, 1e-9),
      );
      // A value already inside the range is preserved exactly.
      expect(
        PlannerZoomPolicy.clampForViewport(
          88,
          viewportHeight: 700,
          configuredHours: 16,
        ),
        88,
      );
    });

    test('an unknown viewport falls back to the absolute safety range', () {
      for (final viewportHeight in <double>[0, -1]) {
        final bounds = PlannerZoomPolicy.zoomBoundsFor(
          viewportHeight: viewportHeight,
          configuredHours: 12,
        );
        expect(bounds.minimum, PlannerZoomPolicy.absoluteMinimumHourHeight);
        expect(bounds.maximum, PlannerZoomPolicy.absoluteMaximumHourHeight);
        expect(
          PlannerZoomPolicy.clampForViewport(
            5000,
            viewportHeight: viewportHeight,
            configuredHours: 12,
          ),
          PlannerZoomPolicy.absoluteMaximumHourHeight,
        );
      }
    });

    test('configuredHours is clamped to the permitted 1–24 range', () {
      final low = PlannerZoomPolicy.zoomBoundsFor(
        viewportHeight: 700,
        configuredHours: 0,
      );
      final one = PlannerZoomPolicy.zoomBoundsFor(
        viewportHeight: 700,
        configuredHours: 1,
      );
      expect(low.minimum, one.minimum);
      expect(low.maximum, one.maximum);

      final high = PlannerZoomPolicy.zoomBoundsFor(
        viewportHeight: 700,
        configuredHours: 99,
      );
      final day = PlannerZoomPolicy.zoomBoundsFor(
        viewportHeight: 700,
        configuredHours: 24,
      );
      expect(high.minimum, day.minimum);
      expect(high.maximum, day.maximum);
    });
  });

  group('PlannerZoomPolicy — accepted geometry is unchanged', () {
    test('clampAbsolute guards corrupt persisted values', () {
      expect(
        PlannerZoomPolicy.clampAbsolute(0),
        PlannerZoomPolicy.absoluteMinimumHourHeight,
      );
      expect(
        PlannerZoomPolicy.clampAbsolute(9999),
        PlannerZoomPolicy.absoluteMaximumHourHeight,
      );
      // A legitimate pinch-reachable value passes through untouched.
      expect(PlannerZoomPolicy.clampAbsolute(44), 44);
      expect(PlannerZoomPolicy.clampAbsolute(60), 60);
      expect(PlannerZoomPolicy.clampAbsolute(88), 88);
      expect(PlannerZoomPolicy.clampAbsolute(120.5), 120.5);
    });

    test('the 44/60/88 preset anchors are unchanged', () {
      expect(PlannerZoomPreset.compact.hourHeight, 44);
      expect(PlannerZoomPreset.normal.hourHeight, 60);
      expect(PlannerZoomPreset.expanded.hourHeight, 88);
      expect(PlannerZoomPolicy.compactHourHeight, 44);
      expect(PlannerZoomPolicy.normalHourHeight, 60);
      expect(PlannerZoomPolicy.expandedHourHeight, 88);
    });

    test('the pinch dead-zone stays symmetric and narrow', () {
      // Inside the dead zone, tiny pointer noise is a no-op. Values are kept
      // clearly inside the 0.012 band rather than exactly on it, so the
      // assertion cannot hinge on binary floating-point rounding.
      expect(PlannerZoomPolicy.applyDeadZone(1.0), 1.0);
      expect(PlannerZoomPolicy.applyDeadZone(1.005), 1.0);
      expect(PlannerZoomPolicy.applyDeadZone(0.995), 1.0);
      // Outside it, the scale is preserved exactly (no added smoothing).
      expect(PlannerZoomPolicy.applyDeadZone(1.5), 1.5);
      expect(PlannerZoomPolicy.applyDeadZone(0.5), 0.5);
      // Symmetry: equal-magnitude pinch-in and pinch-out behave identically.
      const delta = 0.05;
      expect(
        PlannerZoomPolicy.applyDeadZone(1 + delta),
        closeTo(1 + delta, 1e-12),
      );
      expect(
        PlannerZoomPolicy.applyDeadZone(1 - delta),
        closeTo(1 - delta, 1e-12),
      );
    });
  });
}
