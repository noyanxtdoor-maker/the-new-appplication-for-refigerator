// VS16 M7 — PLANNER CURRENT-TIME READOUT: FULL-SCREEN PRODUCTION RENDER.
//
// Purpose: produce a DIRECTLY COMPARABLE visual of what the production
// PlannerScreen paints at the owner's exact device geometry, so the owner's
// "dot + line visible, time text not visible" report can be settled against a
// real rendering of the shipped widget rather than an inference.
//
// Faithfulness rules:
//   * the REAL `PlannerScreen` is pumped (no reimplementation);
//   * the production theme is used — `AppTheme.dark(ThemeColorMode.rose)`,
//     the shipped default;
//   * real Roboto is loaded from the Flutter material_fonts cache, because the
//     theme declares `fontFamily: 'Roboto'` and the flutter_test fallback font
//     has pessimistic (wider) metrics;
//   * the owner device geometry is reproduced exactly: 1080x2400 physical at
//     DPR 2.625 (= 411.43 x 914.29 logical), captured at pixelRatio 2.625 so
//     the emitted PNG is 1080x2400 — the device's own pixel grid;
//   * the planning window is widened to 0..24 (owner-reachable via the
//     "Show full 24 hours" preset, key `planner-full-day-preset`) so the
//     indicator is present regardless of the real wall-clock hour. The shipped
//     default window is 6..22 and the gate is `hour < visibleEndHour`.
//
// This file writes ONLY evidence PNGs under `.m7_cti_evidence/`. It is a
// temporary diagnostic and is removed from `test/` after the evidence is
// captured; the repository tree is otherwise untouched.

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:rmplanner/app/next_transfer_app.dart' show appEnvironmentProvider;
import 'package:rmplanner/app/theme/app_theme.dart';
import 'package:rmplanner/app/theme/theme_color_mode.dart';
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
const Key _boundaryKey = Key('cti-fullscreen-boundary');

/// Owner device: Infinix X6731.
const Size _ownerPhysical = Size(1080, 2400);
const double _ownerDpr = 2.625;

void _log(String line) {
  // ignore: avoid_print
  print(line);
}

Future<void> _loadRealRoboto() async {
  final root =
      Platform.environment['FLUTTER_ROOT'] ??
      r'C:\Users\sherl\AppData\Local\NextTransferFlutter\flutter';
  final dir = Directory('$root/bin/cache/artifacts/material_fonts');
  if (!dir.existsSync()) {
    _log('FONT: material_fonts cache NOT FOUND — using the flutter_test font');
    return;
  }
  final loader = FontLoader('Roboto');
  var loaded = 0;
  for (final name in <String>['roboto-regular.ttf', 'roboto-bold.ttf']) {
    final f = File('${dir.path}/$name');
    if (f.existsSync()) {
      loader.addFont(
        Future<ByteData>.value(
          ByteData.sublistView(Uint8List.fromList(f.readAsBytesSync())),
        ),
      );
      loaded++;
    }
  }
  if (loaded == 0) {
    _log('FONT: no roboto ttf found — using the flutter_test font');
    return;
  }
  await loader.load();
  _log('FONT: loaded $loaded real Roboto face(s) as family "Roboto"');
}

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

String _rect(Rect? r) {
  if (r == null) return '<ABSENT>';
  return 'L${r.left.toStringAsFixed(2)} T${r.top.toStringAsFixed(2)} '
      'R${r.right.toStringAsFixed(2)} B${r.bottom.toStringAsFixed(2)} '
      'W${r.width.toStringAsFixed(2)} H${r.height.toStringAsFixed(2)}';
}

Rect? _finderRect(WidgetTester tester, Finder f) =>
    f.evaluate().isEmpty ? null : tester.getRect(f);

class _Prewarm extends ConsumerWidget {
  const _Prewarm();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(startupControllerProvider);
    return const SizedBox.shrink();
  }
}

/// Render the production Planner at the owner's geometry and write the PNGs.
Future<void> _renderAt(
  WidgetTester tester, {
  required AppDatabase database,
  required DriftPlannerRepository plannerRepository,
  required PlannerDate selected,
  required DateTime now,
  required String tag,
}) async {
  tester.view.physicalSize = _ownerPhysical;
  tester.view.devicePixelRatio = _ownerDpr;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final privacy = TestPrivacyDependencies(database: database);
  final startup = buildTestRepository(
    database: database,
    privacyGate: privacy.gate,
  );
  await startup.completeOnboarding();

  final clock = ValueNotifier<DateTime>(now);
  addTearDown(clock.dispose);

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
      child: MaterialApp(
        // Production theme: Rose dark is the shipped default.
        theme: AppTheme.dark(ThemeColorMode.rose),
        home: child,
      ),
    ),
  );

  await tester.pumpWidget(app(const _Prewarm()));
  final element = tester.element(find.byType(_Prewarm));
  await ProviderScope.containerOf(
    element,
  ).read(startupControllerProvider.notifier).initialize();
  await tester.pumpAndSettle();

  // The PRODUCTION screen; the clock is injected only so the rendered minute is
  // deterministic — the layout, theme, fonts and widget tree are the shipped
  // ones.
  await tester.pumpWidget(app(PlannerScreen(currentTimeListenable: clock)));
  await tester.pumpAndSettle();

  final plannerElement = tester.element(find.byType(PlannerScreen));
  final container = ProviderScope.containerOf(plannerElement);
  await container.read(plannerControllerProvider.notifier).selectDate(selected);
  await tester.pumpAndSettle();

  // Widen the planning window to the full civil day (owner-reachable).
  await container
      .read(eventTypeControllerProvider.notifier)
      .saveSettings(
        container
            .read(eventTypeControllerProvider)
            .settings
            .copyWith(visibleStartHour: 0, visibleEndHour: 24),
      );
  await tester.pumpAndSettle();

  _log('');
  _log('================ $tag ================');
  _log('device geometry : 1080x2400 physical @ DPR $_ownerDpr '
      '=> ${(1080 / _ownerDpr).toStringAsFixed(2)} x '
      '${(2400 / _ownerDpr).toStringAsFixed(2)} logical');
  _log('clock           : $now');

  var indicator = find.byKey(const Key('planner-current-time-indicator'));
  if (indicator.evaluate().isEmpty) {
    _log('INDICATOR = <ABSENT> (visibility gate false for this sample)');
    return;
  }

  // ---- reproduce the owner's viewing position ----------------------------
  // The day timeline is a 24-hour canvas (1440 logical px at normal zoom) inside
  // an ~804 px viewport, so a late-evening indicator starts BELOW the visible
  // area and the owner must scroll to it. Scroll so the indicator sits in the
  // middle of the viewport, exactly as the owner would see it.
  final scrollable = find.descendant(
    of: find.byKey(const Key('planner-day-scroll')),
    matching: find.byType(Scrollable),
  );
  expect(scrollable, findsWidgets, reason: 'the day timeline must be scrollable');
  final scrollState = tester.state<ScrollableState>(scrollable.first);
  final position = scrollState.position;
  final beforeTop = tester.getRect(indicator).top;
  final viewportTop = tester.getRect(scrollable.first).top;
  final viewportH = tester.getRect(scrollable.first).height;
  final wantTop = viewportTop + (viewportH / 2) - 60;
  final delta = beforeTop - wantTop;
  _log('scroll: indicator global top before = '
      '${beforeTop.toStringAsFixed(1)}, viewport top = '
      '${viewportTop.toStringAsFixed(1)} h = ${viewportH.toStringAsFixed(1)}');
  position.jumpTo(
    (position.pixels + delta).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    ),
  );
  await tester.pumpAndSettle();
  indicator = find.byKey(const Key('planner-current-time-indicator'));
  _log('scroll: offset = ${position.pixels.toStringAsFixed(1)} '
      '(range ${position.minScrollExtent.toStringAsFixed(1)}..'
      '${position.maxScrollExtent.toStringAsFixed(1)}), indicator global top '
      'after = ${tester.getRect(indicator).top.toStringAsFixed(1)}');

  final textRect = _finderRect(
    tester,
    find.byKey(const Key('planner-current-time-label')),
  );
  final dotRect = _finderRect(
    tester,
    find.byKey(const Key('planner-current-time-dot')),
  );
  final lineRect = _finderRect(
    tester,
    find.byKey(const Key('planner-current-time-line')),
  );
  _log('label rect      : ${_rect(textRect)}');
  _log('dot   rect      : ${_rect(dotRect)}');
  _log('line  rect      : ${_rect(lineRect)}');

  final hourLabel = _finderRect(
    tester,
    find.byKey(Key('planner-time-label-${now.hour}')),
  );
  _log('ambient hour label rect (hour ${now.hour}) : ${_rect(hourLabel)}');

  final text = tester.widget<Text>(
    find.byKey(const Key('planner-current-time-label')),
  );
  _log('label text      : "${text.data}"');
  _log('declared fontSize: ${text.style?.fontSize}  '
      'weight: ${text.style?.fontWeight}  '
      'color: ${text.style?.color}');

  // ---- full-screen render at the DEVICE pixel grid -------------------------
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_boundaryKey),
  );
  final image = await boundary.toImage(pixelRatio: _ownerDpr);
  final imgW = image.width;
  final imgH = image.height;
  final raster = (await image.toByteData(
    format: ui.ImageByteFormat.rawRgba,
  ))!.buffer.asUint8List();
  _log('FULL RENDER = ${imgW}x${imgH} px  (device pixel grid)');
  image.dispose();

  final full = img.Image.fromBytes(
    width: imgW,
    height: imgH,
    bytes: raster.buffer,
    numChannels: 4,
    order: img.ChannelOrder.rgba,
  );

  final fullOut = File('.m7_cti_evidence/cti_fullscreen_$tag.png');
  fullOut.parent.createSync(recursive: true);
  fullOut.writeAsBytesSync(img.encodePng(full));
  _log('wrote ${fullOut.path} '
      '(${fullOut.lengthSync()} bytes, ${imgW}x${imgH})');

  // ---- native-pixel band + x6 nearest-neighbour zoom ----------------------
  if (dotRect != null) {
    final bandTop = (dotRect.center.dy - 30).clamp(0.0, double.infinity);
    final bandH = 60.0;
    final bandW = 220.0;
    final crop = img.copyCrop(
      full,
      x: 0,
      y: (bandTop * _ownerDpr).round(),
      width: (bandW * _ownerDpr).round().clamp(1, imgW),
      height: (bandH * _ownerDpr).round(),
    );
    final nativeOut = File('.m7_cti_evidence/cti_band_native_$tag.png');
    nativeOut.writeAsBytesSync(img.encodePng(crop));
    _log('wrote ${nativeOut.path} (native device pixels, '
        '${crop.width}x${crop.height})');

    final zoom = img.copyResize(
      crop,
      width: crop.width * 6,
      height: crop.height * 6,
      interpolation: img.Interpolation.nearest,
    );
    final zoomOut = File('.m7_cti_evidence/cti_band_zoom6_$tag.png');
    zoomOut.writeAsBytesSync(img.encodePng(zoom));
    _log('wrote ${zoomOut.path} (x6 nearest-neighbour zoom, '
        '${zoom.width}x${zoom.height})');
    _log('band covers logical y ${bandTop.toStringAsFixed(1)}..'
        '${(bandTop + bandH).toStringAsFixed(1)}, '
        'logical x 0..$bandW');
  }
}

void main() {
  testWidgets('CTI FULLSCREEN — production render at the owner geometry', (
    tester,
  ) async {
    await _loadRealRoboto();

    final database = openMemoryDatabase();
    addTearDown(database.close);
    final plannerRepository = _plannerRepo(database);

    final selected = PlannerDate.fromDateTime(DateTime(2026, 9, 13, 22, 59));

    // The exact minute the owner reported, plus the neighbouring minute so the
    // readout is visible at two different x-offsets.
    for (final now in <DateTime>[
      DateTime(2026, 9, 13, 22, 59),
      DateTime(2026, 9, 13, 9, 5),
    ]) {
      final tag =
          '${now.hour.toString().padLeft(2, '0')}'
          '${now.minute.toString().padLeft(2, '0')}';
      await _renderAt(
        tester,
        database: database,
        plannerRepository: plannerRepository,
        selected: selected,
        now: now,
        tag: tag,
      );
    }
  });
}
