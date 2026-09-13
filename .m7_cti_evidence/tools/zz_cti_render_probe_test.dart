// TEMPORARY DIAGNOSTIC PROBE — not a product test.
// Renders the real PlannerScreen with the timeline scrolled to the
// current-time indicator, at device-like geometry, and dumps the
// indicator geometry + a PNG. Delete after the forensic audit concludes.

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
import 'package:rmplanner/features/privacy/application/privacy_providers.dart';
import 'package:rmplanner/features/startup/application/startup_providers.dart';
import 'package:rmplanner/features/startup/data/drift_startup_repository.dart';

import '../../../support/test_dependencies.dart';

const String _tz = 'Asia/Manila';
const Key _boundaryKey = Key('cti-probe-boundary');

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

void _dump(WidgetTester tester, String label, Finder f) {
  if (f.evaluate().isEmpty) {
    // ignore: avoid_print
    print('PROBE $label = <ABSENT>');
    return;
  }
  final r = tester.getRect(f);
  // ignore: avoid_print
  print(
    'PROBE $label = L${r.left.toStringAsFixed(2)} T${r.top.toStringAsFixed(2)} '
    'R${r.right.toStringAsFixed(2)} B${r.bottom.toStringAsFixed(2)} '
    'W${r.width.toStringAsFixed(2)} H${r.height.toStringAsFixed(2)}',
  );
}

Future<void> _capture(WidgetTester tester, String name) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_boundaryKey),
  );
  final image = await boundary.toImage(pixelRatio: 1.0);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  final file = File('.m7_cti_evidence/$name.png');
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(data!.buffer.asUint8List());
  // ignore: avoid_print
  print('PROBE captured ${file.path} (${data.lengthInBytes} bytes)');
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
  testWidgets('PROBE D — device geometry, scrolled to the indicator', (
    tester,
  ) async {
    final database = openMemoryDatabase();
    addTearDown(database.close);
    final repo = _plannerRepo(database);
    const today = PlannerDate(year: 2026, month: 7, day: 31);
    final clock = ValueNotifier<DateTime>(DateTime(2026, 7, 31, 21, 21));
    addTearDown(clock.dispose);

    // Infinix X6731: 1080x2400 @ 2.625 => 411.4 x 914.3 logical.
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
    // ignore: avoid_print
    print('PROBE D viewport = ${tester.view.physicalSize} '
        '@${tester.view.devicePixelRatio} '
        'logical=${tester.view.physicalSize / tester.view.devicePixelRatio}');

    _dump(tester, 'D.grid(pre-scroll)', find.byKey(const Key('planner-time-grid')));
    _dump(tester, 'D.indicator(pre-scroll)', indicator);
    _dump(tester, 'D.label(pre-scroll)', find.byKey(const Key('planner-current-time-label')));

    // Scroll the timeline so the indicator is inside the viewport.
    if (indicator.evaluate().isNotEmpty) {
      await Scrollable.ensureVisible(
        tester.element(indicator),
        alignment: 0.5,
        duration: Duration.zero,
      );
      await tester.pumpAndSettle();
    }

    _dump(tester, 'D.grid(post-scroll)', find.byKey(const Key('planner-time-grid')));
    _dump(tester, 'D.indicator(post-scroll)', indicator);
    _dump(tester, 'D.label(post-scroll)', find.byKey(const Key('planner-current-time-label')));
    _dump(tester, 'D.dot(post-scroll)', find.byKey(const Key('planner-current-time-dot')));
    _dump(tester, 'D.line(post-scroll)', find.byKey(const Key('planner-current-time-line')));

    final lf = find.byKey(const Key('planner-current-time-label'));
    if (lf.evaluate().isNotEmpty) {
      final t = tester.widget<Text>(lf);
      // ignore: avoid_print
      print('PROBE D label text = "${t.data}" color=${t.style?.color} size=${t.style?.fontSize}');
    } else {
      // ignore: avoid_print
      print('PROBE D label ABSENT');
    }

    // Is the label rect inside the visible viewport?
    final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    if (lf.evaluate().isNotEmpty) {
      final r = tester.getRect(lf);
      // ignore: avoid_print
      print('PROBE D label fully on-screen? '
          'left>=0:${r.left >= 0} top>=0:${r.top >= 0} '
          'right<=${screen.width}:${r.right <= screen.width} '
          'bottom<=${screen.height}:${r.bottom <= screen.height}');
    }

    await _capture(tester, 'probe_d_device_scrolled');
  });
}
