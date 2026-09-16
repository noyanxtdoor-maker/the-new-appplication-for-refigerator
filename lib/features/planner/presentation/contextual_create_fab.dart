import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

enum CreateActionDestination { home, planner, pathways, contacts, more }

enum ContextualCreateAction { task, event }

extension ContextualCreateActionLabel on ContextualCreateAction {
  String get label => switch (this) {
    ContextualCreateAction.task => 'Task',
    ContextualCreateAction.event => 'Event',
  };

  IconData get icon => switch (this) {
    ContextualCreateAction.task => Icons.task_alt_outlined,
    ContextualCreateAction.event => Icons.event_outlined,
  };
}

/// POST-M7 CLOSURE: the one canonical surface for an app-owned floating
/// control.  The expanded create pills and the close circle are part of the FAB
/// family, so they resolve the FAB role rather than reaching for
/// `colorScheme.primary` (which is a brighter tonal step in Dark).  The
/// fallback only exists so a theme without a FAB role still renders.
Color _floatingControlSurface(BuildContext context) =>
    Theme.of(context).floatingActionButtonTheme.backgroundColor ??
    Theme.of(context).colorScheme.primary;

/// The shared create control expands in place, leaving the current screen
/// visible while a transparent barrier protects the rest of the app from
/// accidental taps. Only the already-supported Event and Task flows are
/// exposed here.
final class ContextualCreateFab extends StatefulWidget {
  const ContextualCreateFab({
    required this.destination,
    required this.onSelected,
    this.buttonKey = const Key('contextual-create-fab'),
    super.key,
  });

  final CreateActionDestination destination;
  final ValueChanged<ContextualCreateAction> onSelected;
  final Key buttonKey;

  @override
  State<ContextualCreateFab> createState() => _ContextualCreateFabState();
}

final class _ContextualCreateFabState extends State<ContextualCreateFab> {
  OverlayEntry? _entry;
  final GlobalKey<_ContextualCreateOverlayState> _overlayKey =
      GlobalKey<_ContextualCreateOverlayState>();
  final GlobalKey _fabRenderKey = GlobalKey();
  bool _expanded = false;

  @override
  void dispose() {
    _entry?.remove();
    _entry = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(
      key: widget.buttonKey,
      child: Opacity(
        opacity: _expanded ? 0 : 1,
        child: FloatingActionButton(
          key: _fabRenderKey,
          tooltip: _expanded ? 'Close create actions' : 'Create',
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
          onPressed: _expanded ? _dismissMenu : _openMenu,
          child: Icon(_expanded ? Icons.close : Icons.add, size: 30),
        ),
      ),
    );
  }

  void _openMenu() {
    if (_entry != null) {
      return;
    }
    final renderBox =
        _fabRenderKey.currentContext?.findRenderObject() as RenderBox?;
    final overlay = Overlay.of(context, rootOverlay: true);
    final overlayBox = overlay.context.findRenderObject() as RenderBox?;
    if (renderBox == null || overlayBox == null) {
      return;
    }
    final topLeft = renderBox.localToGlobal(Offset.zero, ancestor: overlayBox);
    final anchorRect = topLeft & renderBox.size;
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (entryContext) => _ContextualCreateOverlay(
        key: _overlayKey,
        anchorRect: anchorRect,
        actions: _orderFor(widget.destination),
        onDismissed: () => _onOverlayDismissed(entry),
        onSelected: widget.onSelected,
      ),
    );
    setState(() => _expanded = true);
    _entry = entry;
    overlay.insert(entry);
  }

  void _dismissMenu() {
    // The overlay owns its reverse animation. Calling its state through the
    // key keeps outside taps, Back, the X, and the original FAB on one path.
    _overlayKey.currentState?.dismiss();
  }

  void _onOverlayDismissed(OverlayEntry entry) {
    if (!identical(_entry, entry)) {
      return;
    }
    entry.remove();
    _entry = null;
    if (mounted) {
      setState(() => _expanded = false);
    }
  }

  static List<ContextualCreateAction> _orderFor(
    CreateActionDestination destination,
  ) {
    return const <ContextualCreateAction>[
      ContextualCreateAction.event,
      ContextualCreateAction.task,
    ];
  }
}

final class _ContextualCreateOverlay extends StatefulWidget {
  const _ContextualCreateOverlay({
    required this.anchorRect,
    required this.actions,
    required this.onDismissed,
    required this.onSelected,
    super.key,
  });

  final Rect anchorRect;
  final List<ContextualCreateAction> actions;
  final VoidCallback onDismissed;
  final ValueChanged<ContextualCreateAction> onSelected;

  @override
  State<_ContextualCreateOverlay> createState() =>
      _ContextualCreateOverlayState();
}

final class _ContextualCreateOverlayState
    extends State<_ContextualCreateOverlay>
    with SingleTickerProviderStateMixin {
  static const double _pillMinWidth = 108;
  static const double _pillMaxWidth = 232;
  static const double _pillHeight = 56;
  static const double _pillGap = 8;
  static const double _closeSize = 56;
  static const Duration _duration = Duration(milliseconds: 240);

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _duration,
    reverseDuration: const Duration(milliseconds: 180),
  );
  late final Animation<double> _animation = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    unawaited(_controller.forward());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void dismiss() {
    if (_closing) {
      return;
    }
    _closing = true;
    unawaited(
      _controller.reverse().whenComplete(() {
        if (mounted) {
          widget.onDismissed();
        }
      }),
    );
  }

  void _select(ContextualCreateAction action) {
    if (_closing) {
      return;
    }
    _closing = true;
    unawaited(
      _controller.reverse().whenComplete(() {
        if (!mounted) {
          return;
        }
        widget.onSelected(action);
        widget.onDismissed();
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final screenSize = media.size;
    final right = (screenSize.width - widget.anchorRect.right)
        .clamp(16.0, math.max(16.0, screenSize.width - _pillMaxWidth - 16))
        .toDouble();
    final closeLeft = widget.anchorRect.left;
    final closeTop = widget.anchorRect.top;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          dismiss();
        }
      },
      child: Material(
        type: MaterialType.transparency,
        child: Stack(
          key: const Key('contextual-create-overlay'),
          children: <Widget>[
            Positioned.fill(
              child: Semantics(
                label: 'Dismiss create actions',
                button: true,
                child: GestureDetector(
                  key: const Key('contextual-create-barrier'),
                  behavior: HitTestBehavior.opaque,
                  onTap: dismiss,
                  child: const SizedBox.expand(),
                ),
              ),
            ),
            for (var index = 0; index < widget.actions.length; index++)
              Positioned(
                right: right,
                bottom:
                    screenSize.height -
                    widget.anchorRect.top +
                    10 +
                    index * (_pillHeight + _pillGap),
                child: _AnimatedActionPill(
                  animation: _animation,
                  action: widget.actions[index],
                  onTap: () => _select(widget.actions[index]),
                ),
              ),
            Positioned(
              left: closeLeft,
              top: closeTop,
              width: _closeSize,
              height: _closeSize,
              child: AnimatedBuilder(
                animation: _animation,
                builder: (context, child) => Opacity(
                  opacity: _animation.value,
                  child: Transform.scale(
                    scale: 0.86 + 0.14 * _animation.value,
                    child: child,
                  ),
                ),
                child: Material(
                  color: _floatingControlSurface(context),
                  shape: const CircleBorder(),
                  child: InkWell(
                    key: const Key('contextual-create-close'),
                    customBorder: const CircleBorder(),
                    onTap: dismiss,
                    child: Icon(
                      Icons.close,
                      // M6 FINAL CORRECTION: this used to hardcode Colors.black
                      // in dark mode — the exact "black glyph on a blue
                      // floating control" regression.  The canonical onPrimary
                      // role owns this foreground (white in BOTH themes); a
                      // local colour override here could only ever drift from
                      // the theme.
                      color: Theme.of(context).colorScheme.onPrimary,
                      size: 26,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final class _AnimatedActionPill extends StatelessWidget {
  const _AnimatedActionPill({
    required this.animation,
    required this.action,
    required this.onTap,
  });

  final Animation<double> animation;
  final ContextualCreateAction action;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        final value = animation.value;
        return Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(0, 16 * (1 - value)),
            child: child,
          ),
        );
      },
      child: Material(
        color: _floatingControlSurface(context),
        elevation: 0,
        borderRadius: BorderRadius.circular(28),
        child: InkWell(
          key: _actionKey(action),
          borderRadius: BorderRadius.circular(28),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minWidth: _ContextualCreateOverlayState._pillMinWidth,
              maxWidth: _ContextualCreateOverlayState._pillMaxWidth,
              minHeight: _ContextualCreateOverlayState._pillHeight,
              maxHeight: _ContextualCreateOverlayState._pillHeight,
            ),
            child: SizedBox(
              height: _ContextualCreateOverlayState._pillHeight,
              child: Padding(
                padding: const EdgeInsets.only(left: 18, right: 22),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(
                      action.icon,
                      // Step 10: foreground on the primary-filled pill is
                      // onPrimary, never hardcoded black.
                      color: Theme.of(context).colorScheme.onPrimary,
                      size: 24,
                    ),
                    const SizedBox(width: 12),
                    Text(
                      action.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        // Step 10: matching onPrimary foreground.
                        color: Theme.of(context).colorScheme.onPrimary,
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  static Key _actionKey(ContextualCreateAction action) {
    return switch (action) {
      ContextualCreateAction.task => const Key('create-task-action'),
      ContextualCreateAction.event => const Key('create-calendar-event-action'),
    };
  }
}
