// TEMPORARY DIAGNOSTIC PROBE — NOT a product test. DELETE before the final run.
//
// Purpose (VS16 M7 continuation, Planner current-time readout):
// prove the EXACT runtime cause of the owner's physical symptom
//     "dot visible + horizontal line visible + time text apparently absent"
// on the Infinix X6731 geometry (1080x2400 @ DPR 2.625 ~= 411.4 x 914.3 logical).
//
// The probe:
//   1. loads the REAL Roboto metrics (the production theme family) so glyph
//      widths/heights match the device instead of the flutter_test fallback
//      font (which renders every glyph at ~fontSize width);
//   2. pumps the REAL production PlannerScreen (not an isolated indicator);
//   3. walks the ENTIRE render-ancestor chain above the label and reports every
//      clip-producing ancestor with its global rect;
//   4. intersects them into the label's EFFECTIVE visible rect;
//   5. renders the frame twice (indicator ON vs indicator OFF) and pixel-diffs
//      the label band, so "did the label's pixels survive final compositing"
//      is answered with pixels, not with an assertion that merely finds the
//      widget in the tree.

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
import 'package:rmplanner/features/planner/presentation/widgets/planner_interactive_day_pager.dart';
import 'package:rmplanner/features/privacy/application/privacy_providers.dart';
import 'package:rmplanner/features/startup/application/startup_providers.dart';
import 'package:rmplanner/features/startup/data/drift_startup_repository.dart';

import '../../../support/test_dependencies.dart';

const String _tz = 'Asia/Manila';
const Key _boundaryKey = Key('cti-clip-probe-boundary');

/// Owner device: Infinix X6731.
const Size _ownerPhysical = Size(1080, 2400);
const double _ownerDpr = 2.625;

void _log(String line) {
  // ignore: avoid_print
  print(line);
}

/// Load the REAL production font family (the theme declares `Roboto`).
Future<void> _loadRealRoboto() async {
  final root =
      Platform.environment['FLUTTER_ROOT'] ??
      r'C:\Users\sherl\AppData\Local\NextTransferFlutter\flutter';
  final dir = Directory('$root/bin/cache/artifacts/material_fonts');
  if (!dir.existsSync()) {
    _log('FONT: material_fonts cache NOT FOUND at ${dir.path} — '
        'falling back to the flutter_test font (metrics will be pessimistic)');
    return;
  }
  final regular = File('${dir.path}/roboto-regular.ttf');
  final bold = File('${dir.path}/roboto-bold.ttf');
  final loader = FontLoader('Roboto');
  var loaded = 0;
  for (final f in <File>[regular, bold]) {
    if (f.existsSync()) {
      final bytes = f.readAsBytesSync();
      loader.addFont(
        Future<ByteData>.value(ByteData.sublistView(Uint8List.fromList(bytes))),
      );
      loaded++;
    }
  }
  if (loaded == 0) {
    _log('FONT: no roboto ttf found — using the flutter_test font');
    return;
  }
  await loader.load();
  _log('FONT: loaded $loaded real Roboto face(s) as family "Roboto" '
      '(production theme family)');
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

Future<ProviderContainer> _pumpPlanner(
  WidgetTester tester, {
  required AppDatabase database,
  required DriftPlannerRepository plannerRepository,
  required PlannerDate selected,
  required ValueNotifier<DateTime> clock,
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
        // Production theme (Rose dark == the shipped default family/weights).
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

  await tester.pumpWidget(app(PlannerScreen(currentTimeListenable: clock)));
  await tester.pumpAndSettle();

  final plannerElement = tester.element(find.byType(PlannerScreen));
  final container = ProviderScope.containerOf(plannerElement);
  await container.read(plannerControllerProvider.notifier).selectDate(selected);
  await tester.pumpAndSettle();
  return container;
}

/// Walk the full render ancestor chain above [start], reporting every ancestor
/// and flagging the ones that introduce a clip.
List<Rect> _dumpAncestors(WidgetTester tester, Finder start) {
  _log('');
  _log('--- RENDER ANCESTOR CHAIN ABOVE THE LABEL TEXT (label -> root) ---');
  final element = start.evaluate().first;
  final clips = <Rect>[];
  RenderObject? ro = element.renderObject;
  var depth = 0;
  while (ro != null) {
    final name = ro.runtimeType.toString();
    Rect? global;
    Rect? clipRect;
    if (ro is RenderBox && ro.hasSize) {
      global = ro.localToGlobal(Offset.zero) & ro.size;
    }
    // Which ancestors actually clip?
    if (ro is RenderClipRect || ro is RenderClipRRect || ro is RenderClipPath ||
        ro is RenderClipOval) {
      final c = ro is RenderBox ? (ro as RenderBox) : null;
      if (c != null && c.hasSize) {
        clipRect = c.localToGlobal(Offset.zero) & c.size;
        clips.add(clipRect!);
      }
    } else if (ro is RenderViewport || name.contains('SingleChildViewport')) {
      if (ro is RenderBox && ro.hasSize) {
        clipRect = ro.localToGlobal(Offset.zero) & ro.size;
        clips.add(clipRect!);
      }
    }
    final tag = clipRect != null
        ? '  <== CLIPS to ${_rect(clipRect)}'
        : (ro is RenderFittedBox ? '  (FittedBox: applies a paint scale)' : '');
    _log(
      '  ${' ' * depth}$name  ${_rect(global)}$tag',
    );
    ro = ro.parent;
    depth += 1;
  }
  _log('--- END ANCESTOR CHAIN (${clips.length} clipping ancestors) ---');
  return clips;
}

Rect _intersectAll(Rect base, List<Rect> clips) {
  var out = base;
  for (final c in clips) {
    out = out.intersect(c);
  }
  return out;
}

Future<Uint8List> _capture(WidgetTester tester) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_boundaryKey),
  );
  final image = await boundary.toImage(pixelRatio: 2.0);
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();
  return data!.buffer.asUint8List();
}

void main() {
  testWidgets('CTI CLIP PROBE — owner geometry, real Roboto, 22:58/22:59/23:00', (
    tester,
  ) async {
    await _loadRealRoboto();

    final database = openMemoryDatabase();
    addTearDown(database.close);
    final repo = _plannerRepo(database);
    const today = PlannerDate(year: 2026, month: 9, day: 13);

    // 22:59 — the owner's reported case.
    final clock = ValueNotifier<DateTime>(DateTime(2026, 9, 13, 22, 59));
    addTearDown(clock.dispose);

    final container = await _pumpPlanner(
      tester,
      database: database,
      plannerRepository: repo,
      selected: today,
      clock: clock,
    );

    // The owner's late-evening case only shows the indicator when the
    // configured planning window contains hour 22; the default window is
    // 6..22, which EXCLUDES 22:59. Widen to the full civil day (an owner-
    // reachable configuration) so the owner's dot+line sighting is possible.
    final settingsController = container.read(
      eventTypeControllerProvider.notifier,
    );
    await settingsController.saveSettings(
      container
          .read(eventTypeControllerProvider)
          .settings
          .copyWith(visibleStartHour: 0, visibleEndHour: 24),
    );
    await tester.pumpAndSettle();

    _log('');
    _log('==============================================================');
    _log('OWNER GEOMETRY: 1080x2400 physical @ DPR 2.625 '
        '=> ${(1080 / 2.625).toStringAsFixed(2)} x '
        '${(2400 / 2.625).toStringAsFixed(2)} logical');
    _log('WINDOW: visibleStartHour=0 visibleEndHour=24 (owner-reachable)');
    _log('==============================================================');

    for (final sample in <DateTime>[
      DateTime(2026, 9, 13, 22, 58),
      DateTime(2026, 9, 13, 22, 59),
      DateTime(2026, 9, 13, 23, 0),
    ]) {
      clock.value = sample;
      await tester.pumpAndSettle();

      final indicator = find.byKey(const Key('planner-current-time-indicator'));
      if (indicator.evaluate().isNotEmpty) {
        await Scrollable.ensureVisible(
          tester.element(indicator),
          alignment: 0.5,
          duration: Duration.zero,
        );
        await tester.pumpAndSettle();
      }

      final hh = sample.hour.toString().padLeft(2, '0');
      final mm = sample.minute.toString().padLeft(2, '0');
      _log('');
      _log('================ SAMPLE $hh:$mm ================');

      final grid = _finderRect(
        tester,
        find.byKey(const Key('planner-time-grid')),
      );
      final label = find.byKey(const Key('planner-current-time-label'));
      final capsule = find.ancestor(
        of: label,
        matching: find.byType(Container),
      );
      final dot = find.byKey(const Key('planner-current-time-dot'));
      final line = find.byKey(const Key('planner-current-time-line'));

      _log('geometry : indicatorHeight='
          '${PlannerCurrentTimeHorizontalGeometry.indicatorHeight} '
          'capsuleHeight=${PlannerCurrentTimeHorizontalGeometry.capsuleHeight} '
          'labelWidth=${PlannerCurrentTimeHorizontalGeometry.labelWidth} '
          'labelLeft=${PlannerCurrentTimeHorizontalGeometry.labelLeft} '
          'dotLeft=${PlannerCurrentTimeHorizontalGeometry.dotLeft} '
          'lineStartX=${PlannerCurrentTimeHorizontalGeometry.lineStartX} '
          'timeColumnWidth='
          '${PlannerCurrentTimeHorizontalGeometry.timeColumnWidth}');
      _log('gridRect : ${_rect(grid)}');
      _log('labelArea: ${_rect(_finderRect(tester, capsule.first))}');
      _log('textRect : ${_rect(_finderRect(tester, label))}');
      _log('dotRect  : ${_rect(_finderRect(tester, dot))}');
      _log('lineRect : ${_rect(_finderRect(tester, line))}');

      if (label.evaluate().isNotEmpty) {
        final t = tester.widget<Text>(label);
        final areaRect = _finderRect(tester, capsule.first);
        final scale = areaRect == null
            ? null
            : areaRect.height /
                  PlannerCurrentTimeHorizontalGeometry.capsuleHeight;
        _log('declared : text="${t.data}" fontSize=${t.style?.fontSize} '
            'family=${t.style?.fontFamily} weight=${t.style?.fontWeight}');
        _log('fitted   : scale=$scale  effectiveFontSize='
            '${scale == null ? '?' : (15.0 * scale).toStringAsFixed(2)}');
      }

      // Ambient hour labels, for size comparison.
      for (final hour in <int>[sample.hour - 1, sample.hour]) {
        if (hour < 1 || hour > 23) continue;
        final f = find.byKey(Key('planner-time-label-$hour'));
        if (f.evaluate().isEmpty) continue;
        final tf = find.descendant(of: f, matching: find.byType(Text));
        _log('hourLabel($hour): box=${_rect(_finderRect(tester, f))} '
            'text=${_rect(_finderRect(tester, tf.first))} '
            'fontSize=${tester.widget<Text>(tf.first).style?.fontSize} '
            'data="${tester.widget<Text>(tf.first).data}"');
      }

      final clips = _dumpAncestors(tester, label);
      final textRect = _finderRect(tester, label);
      if (textRect != null && clips.isNotEmpty) {
        final eff = _intersectAll(textRect, clips);
        _log('EFFECTIVE VISIBLE TEXT RECT = ${_rect(eff)}');
        _log('  clipped away width  = '
            '${(textRect.width - (eff.width.isNegative ? 0 : eff.width)).toStringAsFixed(2)}'
            ' of ${textRect.width.toStringAsFixed(2)} logical px');
        _log('  clipped away height = '
            '${(textRect.height - (eff.height.isNegative ? 0 : eff.height)).toStringAsFixed(2)}'
            ' of ${textRect.height.toStringAsFixed(2)} logical px');
        if (eff.width <= 0 || eff.height <= 0) {
          _log('  => THE LABEL IS FULLY CLIPPED OUT (no pixels can survive)');
        } else {
          final pct = 100 * eff.width / textRect.width;
          _log('  => ${pct.toStringAsFixed(1)}% of the label width survives');
        }
      }
    }

    // ---------------------------------------------------------------- pixels
    _log('');
    _log('==============================================================');
    _log('PIXEL PROOF — did the readout actually rasterise at 22:59?');
    _log('==============================================================');
    clock.value = DateTime(2026, 9, 13, 22, 59);
    await tester.pump();

    final textRect = _finderRect(
      tester,
      find.byKey(const Key('planner-current-time-label')),
    )!;
    final dotRect = _finderRect(
      tester,
      find.byKey(const Key('planner-current-time-dot')),
    )!;
    final lineRect = _finderRect(
      tester,
      find.byKey(const Key('planner-current-time-line')),
    )!;
    final gridRect = _finderRect(
      tester,
      find.byKey(const Key('planner-time-grid')),
    )!;

    final primary = AppTheme.dark(ThemeColorMode.rose).colorScheme.primary;
    _log('theme primary (Rose dark) = $primary');

    const scale = 2.0;
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(_boundaryKey),
    );
    final image = await boundary.toImage(pixelRatio: scale);
    final imgW = image.width;
    final imgH = image.height;
    final raster = (await image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    ))!.buffer.asUint8List();
    _log('raster = ${imgW}x${imgH} px at pixelRatio $scale '
        '(= ${(imgW / scale).toStringAsFixed(1)} x '
        '${(imgH / scale).toStringAsFixed(1)} logical)');

    int countPrimary(Rect r) {
      var n = 0;
      final x0 = (r.left * scale).floor().clamp(0, imgW - 1);
      final x1 = (r.right * scale).ceil().clamp(0, imgW);
      final y0 = (r.top * scale).floor().clamp(0, imgH - 1);
      final y1 = (r.bottom * scale).ceil().clamp(0, imgH);
      for (var y = y0; y < y1; y++) {
        for (var x = x0; x < x1; x++) {
          final i = (y * imgW + x) * 4;
          if ((raster[i] - primary.r * 255).abs() <= 60 &&
              (raster[i + 1] - primary.g * 255).abs() <= 60 &&
              (raster[i + 2] - primary.b * 255).abs() <= 60) {
            n++;
          }
        }
      }
      return n;
    }

    final labelPx = countPrimary(textRect);
    final dotPx = countPrimary(dotRect);
    final linePx = countPrimary(lineRect);
    _log('primary-coloured raster pixels inside the TEXT rect '
        '${_rect(textRect)} = $labelPx');
    _log('primary-coloured raster pixels inside the DOT  rect '
        '${_rect(dotRect)} = $dotPx');
    _log('primary-coloured raster pixels inside the LINE rect '
        '${_rect(lineRect)} = $linePx');
    if (labelPx > 0) {
      _log('  => THE CURRENT-TIME TEXT RASTERISED. The label is painted; it '
          'is NOT clipped away and NOT hidden behind any ancestor.');
    } else {
      _log('  => NO text pixels. The label did not reach the raster.');
    }

    // Tight crop around the indicator band, x4 zoom, for visual inspection.
    // Encoded with package:image straight from the raw RGBA so the probe does
    // not depend on a PictureRecorder round-trip inside the test harness.
    final cropLeft = (gridRect.left - 6).clamp(0.0, double.infinity);
    final cropTop = (dotRect.center.dy - 24).clamp(0.0, double.infinity);
    const cropW = 120.0;
    const cropH = 48.0;
    final full = img.Image.fromBytes(
      width: imgW,
      height: imgH,
      bytes: raster.buffer,
      numChannels: 4,
      order: img.ChannelOrder.rgba,
    );
    final crop = img.copyCrop(
      full,
      x: (cropLeft * scale).round(),
      y: (cropTop * scale).round(),
      width: (cropW * scale).round(),
      height: (cropH * scale).round(),
    );
    final zoomed = img.copyResize(
      crop,
      width: (cropW * 4).round(),
      height: (cropH * 4).round(),
      interpolation: img.Interpolation.nearest,
    );
    final png = img.encodePng(zoomed);
    final cropOut = File('.m7_cti_evidence/clip_probe_indicator_crop.png');
    cropOut.parent.createSync(recursive: true);
    cropOut.writeAsBytesSync(png);
    image.dispose();
    _log('captured ${cropOut.path} (${png.length} bytes) — '
        'crop left=${cropLeft.toStringAsFixed(1)} '
        'top=${cropTop.toStringAsFixed(1)} w=$cropW h=$cropH logical, x4 zoom');
    _log('crop pixel (0,0) corresponds to logical '
        '(${cropLeft.toStringAsFixed(1)}, ${cropTop.toStringAsFixed(1)}); '
        'the dot starts at logical x=${dotRect.left.toStringAsFixed(1)}, so '
        'the dot begins at crop x='
        '${((dotRect.left - cropLeft) * 4).toStringAsFixed(0)} px');
  });
}
