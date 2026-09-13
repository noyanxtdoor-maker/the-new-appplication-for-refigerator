// TEMPORARY DIAGNOSTIC PROBE — not a product test. DELETE before the final run.
//
// Purpose: explain, with measurement, why the owner reports "dot + line visible,
// current-time readout not visibly present" on the physical device.
//
// The whole indicator (label + dot + line) is behind ONE gate
// (`indicatorVisible`), so the gate cannot explain a label-only absence. This
// probe therefore measures the LABEL's actual rendered size, the FittedBox scale
// actually applied, and the neighbouring hour labels for comparison.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/app/next_transfer_app.dart' show appEnvironmentProvider;
import 'package:rmplanner/core/database/app_database.dart';
import 'package:rmplanner/core/diagnostics/sanitized_diagnostics.dart';
import 'package:rmplanner/core/ids/identifier_source.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/core/security/auth_token_store.dart';
import 'package:rmplanner/features/contacts/application/contact_providers.dart';
import 'package:rmplanner/features/contacts/data/drift_contact_repository.dart';
import 'package:rmplanner/features/planner/application/calendar_event_providers.dart';
import 'package:rmplanner/features/planner/application/event_type_providers.dart';
import 'package:rmplanner/features/planner/application/outcome_reporting_providers.dart';
import 'package:rmplanner/features/planner/application/planner_providers.dart';
import 'package:rmplanner/features/planner/application/task_event_link_providers.dart';
import 'package:rmplanner/features/planner/data/calendar_event_time_zones.dart';
import 'package:rmplanner/features/planner/data/drift_calendar_event_repository.dart';
import 'package:rmplanner/features/planner/data/drift_event_type_repository.dart';
import 'package:rmplanner/features/planner/data/drift_outcome_reporting_repository.dart';
import 'package:rmplanner/features/planner/data/drift_planner_repository.dart';
import 'package:rmplanner/features/planner/data/drift_task_event_link_repository.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/presentation/planner_screen.dart';
import 'package:rmplanner/features/planner/presentation/widgets/planner_interactive_day_pager.dart';
import 'package:rmplanner/features/privacy/application/privacy_providers.dart';
import 'package:rmplanner/features/startup/application/startup_providers.dart';
import 'package:rmplanner/features/startup/data/drift_startup_repository.dart';

import '../../../support/test_dependencies.dart';

const String _tz = 'Asia/Manila';
const Key _boundaryKey = Key('cti-readout-probe-boundary');

List<Override> _overrides({
  required AppDatabase database,
  required TestPrivacyDependencies privacy,
  required DriftPlannerRepository plannerRepository,
  required PlannerDate selected,
  required DriftStartupRepository startup,
}) {
  final link = DriftTaskEventLinkRepository(
    database: database,
    clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
  );
  final outcome = DriftOutcomeReportingRepository(
    database: database,
    clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
  );
  final calendar = DriftCalendarEventRepository(
    database: database,
    clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
    timeZones: IanaCalendarEventTimeZones(displayTimeZoneId: _tz),
    taskContextSource: link,
    linkContextTransfer: link,
    reportSource: outcome,
  );
  return <Override>[
    appEnvironmentProvider.overrideWithValue(
      const AppEnvironment(
        name: AppEnvironmentName.production,
        label: 'PRODUCTION',
      ),
    ),
    diagnosticsProvider.overrideWithValue(SanitizedDiagnostics()),
    startupRepositoryProvider.overrideWithValue(startup),
    privacyRepositoryProvider.overrideWithValue(privacy.repository),
    privacyGateProvider.overrideWithValue(privacy.gate),
    deviceAuthenticatorProvider.overrideWithValue(privacy.authenticator),
    permissionGatewayProvider.overrideWithValue(privacy.permissionGateway),
    authTokenStoreProvider.overrideWithValue(
      SecureAuthTokenStore(privacy.secureStorage),
    ),
    calendarEventRepositoryProvider.overrideWithValue(calendar),
    eventTypeRepositoryProvider.overrideWithValue(
      DriftEventTypeRepository(
        database: database,
        clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
      ),
    ),
    outcomeReportingRepositoryProvider.overrideWithValue(outcome),
    plannerRepositoryProvider.overrideWithValue(plannerRepository),
    contactRepositoryProvider.overrideWithValue(
      DriftContactRepository(
        database: database,
        clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
        identifiers: const UuidIdentifierSource(),
      ),
    ),
    taskEventLinkRepositoryProvider.overrideWithValue(link),
    plannerDateSourceProvider.overrideWithValue(
      FixedPlannerDateSource(selected),
    ),
  ];
}

DriftPlannerRepository _plannerRepo(AppDatabase database) {
  final link = DriftTaskEventLinkRepository(
    database: database,
    clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
  );
  final outcome = DriftOutcomeReportingRepository(
    database: database,
    clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
  );
  final calendar = DriftCalendarEventRepository(
    database: database,
    clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
    timeZones: IanaCalendarEventTimeZones(displayTimeZoneId: _tz),
    taskContextSource: link,
    linkContextTransfer: link,
    reportSource: outcome,
  );
  return DriftPlannerRepository(
    database: database,
    clock: FixedClock(DateTime.utc(2026, 7, 27, 12)),
    calendarSource: calendar,
    taskContextSource: link,
    historicalEffectReader: outcome,
  );
}

String _rect(WidgetTester tester, Finder f) {
  if (f.evaluate().isEmpty) return '<ABSENT>';
  final r = tester.getRect(f);
  return 'L${r.left.toStringAsFixed(2)} T${r.top.toStringAsFixed(2)} '
      'R${r.right.toStringAsFixed(2)} B${r.bottom.toStringAsFixed(2)} '
      'W${r.width.toStringAsFixed(2)} H${r.height.toStringAsFixed(2)}';
}

/// The scale actually applied by the FittedBox that wraps the label.
///
/// NOTE: `getTransformTo(null)` on the FittedBox returns only the ANCESTOR
/// transform, not the FittedBox's own paint scale. The reliable way to read the
/// applied scale is to measure the sized child (the `Container` carrying
/// `height: capsuleHeight`) and divide by its declared height.
double? _fittedScale(WidgetTester tester) {
  final anc = find.ancestor(
    of: find.byKey(const Key('planner-current-time-label')),
    matching: find.byType(Container),
  );
  if (anc.evaluate().isEmpty) return null;
  final rendered = tester.getRect(anc.first).height;
  return rendered / PlannerCurrentTimeHorizontalGeometry.capsuleHeight;
}

class _Prewarm extends ConsumerWidget {
  const _Prewarm();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(startupControllerProvider);
    return const SizedBox.shrink();
  }
}

Future<void> _pumpPlanner(
  WidgetTester tester, {
  required AppDatabase database,
  required DriftPlannerRepository plannerRepository,
  required PlannerDate selected,
  required ValueNotifier<DateTime> clock,
  required Size physical,
  required double dpr,
}) async {
  tester.view.physicalSize = physical;
  tester.view.devicePixelRatio = dpr;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final privacy = TestPrivacyDependencies(database: database);
  final startup = buildTestRepository(
    database: database,
    privacyGate: privacy.gate,
  );
  await startup.completeOnboarding();

  Widget app(Widget child) => RepaintBoundary(
    key: _boundaryKey,
    child: ProviderScope(
      overrides: _overrides(
        database: database,
        privacy: privacy,
        plannerRepository: plannerRepository,
        selected: selected,
        startup: startup,
      ),
      child: MaterialApp(home: child),
    ),
  );

  await tester.pumpWidget(app(const _Prewarm()));
  final element = tester.element(find.byType(_Prewarm));
  await ProviderScope.containerOf(
    element,
  ).read(startupControllerProvider.notifier).initialize();
  await tester.pumpAndSettle();

  await tester.pumpWidget(app(PlannerScreen(currentTimeListenable: clock)));
  await tester.pumpAndSettle();

  final plannerElement = tester.element(find.byType(PlannerScreen));
  await ProviderScope.containerOf(
    plannerElement,
  ).read(plannerControllerProvider.notifier).selectDate(selected);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('READOUT PROBE — measured size of the current-time readout', (
    tester,
  ) async {
    final database = openMemoryDatabase();
    addTearDown(database.close);
    final repo = _plannerRepo(database);
    const today = PlannerDate(year: 2026, month: 7, day: 31);

    final clock = ValueNotifier<DateTime>(DateTime(2026, 7, 31, 21, 21));
    addTearDown(clock.dispose);

    await _pumpPlanner(
      tester,
      database: database,
      plannerRepository: repo,
      selected: today,
      clock: clock,
      physical: const Size(1080, 2400),
      dpr: 2.625,
    );

    final indicator = find.byKey(const Key('planner-current-time-indicator'));
    if (indicator.evaluate().isNotEmpty) {
      await Scrollable.ensureVisible(
        tester.element(indicator),
        alignment: 0.5,
        duration: Duration.zero,
      );
      await tester.pumpAndSettle();
    }

    // ignore: avoid_print
    print('READOUT geometry: '
        'indicatorHeight=${PlannerCurrentTimeHorizontalGeometry.indicatorHeight} '
        'capsuleHeight=${PlannerCurrentTimeHorizontalGeometry.capsuleHeight} '
        'labelWidth=${PlannerCurrentTimeHorizontalGeometry.labelWidth} '
        'labelLeft=${PlannerCurrentTimeHorizontalGeometry.labelLeft} '
        'dotLeft=${PlannerCurrentTimeHorizontalGeometry.dotLeft} '
        'lineStartX=${PlannerCurrentTimeHorizontalGeometry.lineStartX} '
        'dotSize=${PlannerCurrentTimeHorizontalGeometry.dotSize} '
        'timeColumnWidth=${PlannerCurrentTimeHorizontalGeometry.timeColumnWidth}');

    final labelF = find.byKey(const Key('planner-current-time-label'));
    // ignore: avoid_print
    print('READOUT label   : ${_rect(tester, labelF)}');
    // ignore: avoid_print
    print('READOUT dot     : '
        '${_rect(tester, find.byKey(const Key('planner-current-time-dot')))}');
    // ignore: avoid_print
    print('READOUT line    : '
        '${_rect(tester, find.byKey(const Key('planner-current-time-line')))}');

    if (labelF.evaluate().isNotEmpty) {
      final t = tester.widget<Text>(labelF);
      // ignore: avoid_print
      print('READOUT declared: text="${t.data}" fontSize=${t.style?.fontSize}');
      final scale = _fittedScale(tester);
      // ignore: avoid_print
      print('READOUT fittedScale = $scale');
      if (scale != null && t.style?.fontSize != null) {
        // ignore: avoid_print
        print('READOUT effectiveFontSize = '
            '${(t.style!.fontSize! * scale).toStringAsFixed(2)} logical px '
            '(declared ${t.style!.fontSize} x scale $scale)');
      }
    }

    // Compare against the ambient hour labels the readout sits next to.
    for (final hour in <int>[21, 22]) {
      final f = find.byKey(Key('planner-time-label-$hour'));
      if (f.evaluate().isEmpty) continue;
      // ignore: avoid_print
      print('READOUT hourLabel($hour) box : ${_rect(tester, f)}');
      final tf = find.descendant(of: f, matching: find.byType(Text));
      if (tf.evaluate().isNotEmpty) {
        final t = tester.widget<Text>(tf.first);
        // ignore: avoid_print
        print('READOUT hourLabel($hour) text: ${_rect(tester, tf.first)} '
            'fontSize=${t.style?.fontSize} text="${t.data}"');
      }
    }

    // Is the label clipped by any ClipRect ancestor?
    final clipAncestors = find.ancestor(
      of: labelF,
      matching: find.byWidgetPredicate((w) => w is ClipRect),
    );
    // ignore: avoid_print
    print('READOUT ClipRect ancestors above label = '
        '${clipAncestors.evaluate().length}');
    for (final e in clipAncestors.evaluate()) {
      final ro = e.renderObject;
      if (ro is RenderBox) {
        // ignore: avoid_print
        print('READOUT   ClipRect rect = '
            '${ro.localToGlobal(Offset.zero) & ro.size}');
      }
    }

    // Widest possible label, to check the width-constrained branch.
    clock.value = DateTime(2026, 7, 31, 12, 59);
    await tester.pumpAndSettle();
    if (labelF.evaluate().isNotEmpty) {
      // ignore: avoid_print
      print('READOUT widest  : label="${tester.widget<Text>(labelF).data}" '
          'rect=${_rect(tester, labelF)} fittedScale=${_fittedScale(tester)}');
    } else {
      // ignore: avoid_print
      print('READOUT widest  : <ABSENT>');
    }

    // Narrowest label.
    clock.value = DateTime(2026, 7, 31, 1, 1);
    await tester.pumpAndSettle();
    if (labelF.evaluate().isNotEmpty) {
      // ignore: avoid_print
      print('READOUT narrow  : label="${tester.widget<Text>(labelF).data}" '
          'rect=${_rect(tester, labelF)} fittedScale=${_fittedScale(tester)}');
    } else {
      // ignore: avoid_print
      print('READOUT narrow  : <ABSENT> — current hour is OUTSIDE the '
          'visible-hour window, so the WHOLE indicator (label+dot+line) '
          'is hidden by the single indicatorVisible gate');
    }

    // Restore a mid-evening time for the capture.
    clock.value = DateTime(2026, 7, 31, 21, 21);
    await tester.pumpAndSettle();

    // Capture only the indicator strip (a tall full-screen capture at high DPR
    // stalls the tester). Crop to the row band around the indicator.
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(_boundaryKey),
    );
    final image = await boundary.toImage(pixelRatio: 2.0);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('.m7_cti_evidence/probe_readout.png');
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(data!.buffer.asUint8List());
    image.dispose();
    // ignore: avoid_print
    print('READOUT captured ${file.path} (${data.lengthInBytes} bytes)');
  });
}
