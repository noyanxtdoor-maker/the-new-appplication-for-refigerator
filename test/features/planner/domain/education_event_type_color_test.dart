import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/core/colors/vs11_color_system.dart';
import 'package:rmplanner/features/planner/domain/event_color_math.dart';
import 'package:rmplanner/features/planner/domain/event_color_preferences.dart';
import 'package:rmplanner/features/planner/domain/event_type.dart';
import 'package:rmplanner/features/planner/domain/recommended_event_colors.dart';

void main() {
  group('T04 Education color identity', () {
    // M7 reconciliation (2026-09-16): the approved Education pair is P22
    // (Prompt-P46, documented verbatim in `event_color_preferences.dart`):
    // accent P22 Steel blue + its locked P22 surface partner. The retired
    // expectation was the superseded VS-11 P24 Deep blue assignment.
    test('P22 accent constant and exact light/dark pair', () {
      expect(Vs11ColorSystem.p22SteelBlue, 0xFF64B1E6);
      expect(
        PlannerEventColorDefaults.education.accentArgb,
        Vs11ColorSystem.p22SteelBlue,
      );
      expect(PlannerEventColorDefaults.education.surfaceArgb, 0xFF484F56);
    });

    test('locked surface equality through recommendedSurfaceArgbForAccent', () {
      expect(
        recommendedSurfaceArgbForAccent(Vs11ColorSystem.p22SteelBlue),
        0xFF484F56,
      );
    });

    test('stable-key default registered; label-based entry never exists', () {
      expect(
        PlannerEventColorDefaults.pmgStableKeyDefaults[SystemEventTypeKeys
            .education],
        PlannerEventColorDefaults.education,
      );
      // A custom row merely named "Education" must keep the accepted
      // fallback behavior: no label-keyed default side door exists.
      expect(
        PlannerEventColorDefaults.pmgStableKeyDefaults.containsKey('Education'),
        isFalse,
      );
    });

    test('opaque accent is unique against all other stable-key defaults', () {
      final educationAccent = Vs11ColorSystem.p22SteelBlue & 0x00FFFFFF;
      PlannerEventColorDefaults.pmgStableKeyDefaults.forEach((
        stableKey,
        preference,
      ) {
        if (stableKey == SystemEventTypeKeys.education) return;
        expect(
          (preference.accentArgb & 0x00FFFFFF) == educationAccent,
          isFalse,
          reason: 'Education must not duplicate $stableKey',
        );
      });
    });

    test('no near-duplicate with neighboring Study or Plan and Service', () {
      final education = Vs11ColorSystem.p22SteelBlue;
      final studyOrPlan = PlannerEventColorDefaults
          .pmgStableKeyDefaults[SystemEventTypeKeys.studyOrPlan]!
          .accentArgb;
      final service = PlannerEventColorDefaults
          .pmgStableKeyDefaults[SystemEventTypeKeys.service]!
          .accentArgb;
      expect(
        EventColorMath.okLabDistance(education, studyOrPlan),
        greaterThanOrEqualTo(0.05),
      );
      expect(
        EventColorMath.okLabDistance(education, service),
        greaterThanOrEqualTo(0.05),
      );
      expect(EventColorMath.isNearDuplicate(education, studyOrPlan), isFalse);
      expect(EventColorMath.isNearDuplicate(education, service), isFalse);
    });
  });
}
