import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// OWNER HOTFIX (2026-09-19) — the Planner must never stay unscrollable.
///
/// PROVEN MECHANISM (source, build 3 baseline):
///
///  * both planner scroll surfaces use
///    `physics: _pinchCoordinator.isPinchActive ? NeverScrollableScrollPhysics() : …`
///    (`planner_screen.dart` lines 1317 and 1617 — today 1330 and 1630);
///  * `isPinchActive` is `_pointerCount >= 2 && !_externalCancel`, and the count is
///    maintained ONLY by pointer-up/cancel events delivered to the timeline surface;
///  * the coordinator's documented reset — `begin()` — had **zero call sites**
///    anywhere in `lib/`, so a single missed up/cancel left the count >= 2 forever
///    and pinned BOTH scroll views to `NeverScrollableScrollPhysics`. The app stays
///    alive and tappable; drags simply stop reaching the scrollable, which is
///    exactly the reported "hanging of the app where I can't swipe it up or down".
///
/// The fix drops the unrecoverable tracking when the subtree that owned it is
/// disposed (planner refresh, loading/loaded branch swap, day-pager swap, route
/// change) and re-reads the physics on the next frame.
///
/// These are contract guards for that invariant. The physical device retest remains
/// the behavioural confirmation — see the hotfix report.
void main() {
  final source = File('lib/features/planner/presentation/planner_screen.dart');

  late String planner;

  setUpAll(() {
    expect(source.existsSync(), isTrue, reason: 'planner screen must exist');
    // The Windows worktree checks these files out with CRLF; normalise so the
    // multi-line contract assertions below describe the source, not the newlines.
    planner = source.readAsStringSync().replaceAll('\r\n', '\n');
  });

  group('D30 stale pinch suppression self-heals', () {
    test('both scroll surfaces are still gated on the pinch state', () {
      expect(
        _count(planner, 'physics: _pinchCoordinator.isPinchActive'),
        2,
        reason:
            'the day scroll and the planner scroll both swap physics; if this '
            'count changes, the reset contract below must be re-checked',
      );
      expect(
        planner.contains(
          'bool get isPinchActive => _pointerCount >= 2 && !_externalCancel;',
        ),
        isTrue,
      );
    });

    test('the tracking owner resets the coordinator when it is disposed', () {
      expect(
        planner.contains('widget.pinchCoordinator.begin();'),
        isTrue,
        reason:
            'a subtree that owns raw pointer tracking cannot keep the parent '
            'suppressed after it goes away; any missed up/cancel is unrecoverable',
      );
      // It must live in the timeline state's dispose, immediately before super.
      final disposeIndex = planner.indexOf(
        'void dispose() {\n    _pendingPinchHourHeight = null;',
      );
      expect(disposeIndex, isNot(-1));
      final body = planner.substring(disposeIndex, disposeIndex + 700);
      expect(body.contains('widget.pinchCoordinator.begin();'), isTrue);
      final resetIndex = body.indexOf('widget.pinchCoordinator.begin();');
      final superIndex = body.indexOf('super.dispose();');
      expect(
        superIndex,
        greaterThan(resetIndex),
        reason: 'the reset must happen before super.dispose()',
      );
    });

    test('begin() clears the count and restores scrolling', () {
      final beginIndex = planner.indexOf('  void begin() {\n    if (_pointerCount == 0');
      expect(
        beginIndex,
        isNot(-1),
        reason: 'begin() must exist and short-circuit an already-clean state',
      );
      final body = planner.substring(beginIndex, beginIndex + 400);
      expect(body.contains('_pointerCount = 0;'), isTrue);
      expect(body.contains('_externalCancel = false;'), isTrue);
      expect(
        body.contains('_notifyAfterFrame();'),
        isTrue,
        reason:
            'a silent reset would leave the parent rendering the old physics; the '
            'parent must be told so the scroll becomes usable again',
      );
    });

    test('the reset notification is deferred out of the build phase', () {
      expect(
        planner.contains('void _notifyAfterFrame() {'),
        isTrue,
        reason:
            'calling setState during dispose/build would throw; the notify is '
            'posted to the next frame instead',
      );
      final index = planner.indexOf('void _notifyAfterFrame() {');
      final body = planner.substring(index, index + 400);
      expect(body.contains('addPostFrameCallback'), isTrue);
    });

    test('the stale doc comment was corrected, not left as a false promise', () {
      expect(
        planner.contains('is reset on the first pointer-down of each'),
        isFalse,
        reason:
            'that sentence described a reset that did not exist and must not '
            'survive the fix as a false invariant',
      );
    });
  });
}

int _count(String haystack, String needle) {
  var count = 0;
  var index = haystack.indexOf(needle);
  while (index != -1) {
    count += 1;
    index = haystack.indexOf(needle, index + needle.length);
  }
  return count;
}
