import 'package:flutter/material.dart';

import 'package:rmplanner/app/theme/app_theme.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';

/// The ONE shared planning timeline (owner law, 2026-09-20).
///
/// Tasks and Unreported both render a flat, date-grouped timeline: no
/// per-item rounded card, a sticky uppercase date header, a 2 dp rail with a
/// marker on it, then the time line and the title.  The structure follows the
/// accepted Contacts sticky-header primitive
/// (`SliverMainAxisGroup` + `SliverPersistentHeader(pinned: true)`), so the
/// app gains no second sticky-header framework.
///
/// This file owns the geometry only.  Every screen supplies its own canonical
/// marker, text and tap destination, so Task and Event semantics stay in their
/// own features.

/// Uppercase 3-letter month abbreviations, matching the convention already
/// used by the Planner date label and the recurrence summary label.
const List<String> _monthLabels = <String>[
  'JAN',
  'FEB',
  'MAR',
  'APR',
  'MAY',
  'JUN',
  'JUL',
  'AUG',
  'SEP',
  'OCT',
  'NOV',
  'DEC',
];

/// `SEP 19, 2026` — the canonical timeline date-section label.
///
/// Deliberately absolute (no "Today"/"Yesterday" arithmetic) so a header can
/// never change meaning between two builds of the same list.
String planningDateSectionLabel(PlannerDate date) {
  final month = _monthLabels[(date.month - 1).clamp(0, 11)];
  return '$month ${date.day}, ${date.year}';
}

/// `9:45 AM` from a planner minute-of-day. Null minutes render nothing, so a
/// date-only record never gains a fabricated time.
String? planningMinuteLabel(int? minute) {
  if (minute == null) {
    return null;
  }
  final hour = minute ~/ 60;
  final displayHour = hour % 12 == 0 ? 12 : hour % 12;
  return '$displayHour:${(minute % 60).toString().padLeft(2, '0')} '
      '${hour >= 12 ? 'PM' : 'AM'}';
}

/// `9:45 AM` from a local DateTime (Event occurrence times).
String planningClockLabel(DateTime value) {
  final hour = value.hour;
  final displayHour = hour % 12 == 0 ? 12 : hour % 12;
  return '$displayHour:${value.minute.toString().padLeft(2, '0')} '
      '${hour >= 12 ? 'PM' : 'AM'}';
}

/// One date group: a pinned header followed by its rows, contained in a
/// `SliverMainAxisGroup` so the next group pushes the header out instead of
/// stacking headers in the sticky zone (the accepted Contacts law).
final class PlanningTimelineSection {
  const PlanningTimelineSection({
    required this.label,
    required this.keyPrefix,
    required this.children,
  });

  final String label;

  /// Stable, unique-in-screen prefix so section/header keys never collide.
  final String keyPrefix;

  final List<Widget> children;

  Widget buildSliver(BuildContext context) {
    return SliverMainAxisGroup(
      key: Key('planning-timeline-group-$keyPrefix'),
      slivers: <Widget>[
        SliverPersistentHeader(
          pinned: true,
          delegate: PlanningTimelineHeaderDelegate(
            label: label,
            keyPrefix: keyPrefix,
            backgroundColor: AppTheme.surfaceOf(context),
            dividerColor: AppTheme.sectionDividerOf(context),
            labelColor: AppTheme.secondaryTextOf(context),
          ),
        ),
        SliverList.list(children: children),
      ],
    );
  }
}

/// The pinned date header.  Geometry mirrors the accepted Contacts timeline
/// header (fixed extent, surface fill, 1 px divider, `Semantics(header)`).
final class PlanningTimelineHeaderDelegate
    extends SliverPersistentHeaderDelegate {
  const PlanningTimelineHeaderDelegate({
    required this.label,
    required this.keyPrefix,
    required this.backgroundColor,
    required this.dividerColor,
    required this.labelColor,
  });

  final String label;
  final String keyPrefix;
  final Color backgroundColor;
  final Color dividerColor;
  final Color labelColor;

  static const double extent = 44;

  @override
  double get minExtent => extent;

  @override
  double get maxExtent => extent;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return Material(
      key: Key('planning-timeline-header-$keyPrefix'),
      color: backgroundColor,
      child: Semantics(
        header: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 7),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: 'Roboto',
                  fontSize: 13,
                  height: 18 / 13,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                  color: labelColor,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Divider(height: 1, thickness: 1, color: dividerColor),
            ),
          ],
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(covariant PlanningTimelineHeaderDelegate oldDelegate) =>
      label != oldDelegate.label ||
      keyPrefix != oldDelegate.keyPrefix ||
      backgroundColor != oldDelegate.backgroundColor ||
      dividerColor != oldDelegate.dividerColor ||
      labelColor != oldDelegate.labelColor;
}

/// One timeline row: rail, marker, then time / title / optional secondary
/// line.  The whole row is the tap target when [onTap] is supplied.
///
/// [isFirst] and [isLast] trim the rail to the group's own bounds so a date
/// group reads as one spine instead of a rail that runs off both ends.
final class PlanningTimelineRow extends StatelessWidget {
  const PlanningTimelineRow({
    required this.marker,
    required this.title,
    this.rowKey,
    this.timeLine,
    this.secondary,
    this.trailing,
    this.onTap,
    this.isFirst = false,
    this.isLast = false,
    this.titleMaxLines = 2,
    super.key,
  });

  /// The canonical icon/dot for this record, rendered ON the rail.
  final Widget marker;

  final String title;

  /// Stable key for the tappable row (list keys are contracts).
  final Key? rowKey;

  /// First content line, e.g. `9:45 AM` or `10:30 AM – 11:00 AM`.
  final String? timeLine;

  /// Optional single short second line (never a long description dump).
  final Widget? secondary;

  /// Optional trailing widget, kept inside the row's tap target.
  final Widget? trailing;

  final VoidCallback? onTap;

  final bool isFirst;
  final bool isLast;
  final int titleMaxLines;

  @override
  Widget build(BuildContext context) {
    final railColor = AppTheme.sectionDividerOf(context);
    final rail = _TimelineMarkerColumn(
      marker: marker,
      railColor: railColor,
      hasRailAbove: !isFirst,
      hasRailBelow: !isLast,
    );

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (timeLine != null) ...<Widget>[
          Text(
            timeLine!,
            style: TextStyle(
              fontFamily: 'Roboto',
              fontSize: 13.5,
              height: 18 / 13.5,
              fontWeight: FontWeight.w600,
              color: AppTheme.secondaryTextOf(context),
            ),
          ),
          const SizedBox(height: 2),
        ],
        Text(
          title,
          maxLines: titleMaxLines,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontFamily: 'Roboto',
            fontSize: 16,
            height: 21 / 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        if (secondary != null) ...<Widget>[
          const SizedBox(height: 4),
          secondary!,
        ],
      ],
    );

    final row = IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const SizedBox(width: 12),
          rail,
          const SizedBox(width: 10),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  Expanded(child: content),
                  if (trailing != null) ...<Widget>[
                    const SizedBox(width: 8),
                    trailing!,
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(width: 16),
        ],
      ),
    );

    // The WHOLE row is the tap target, exactly like the card it replaced, and
    // the row key stays on that target so list keys remain contracts.
    if (onTap == null) {
      return KeyedSubtree(key: rowKey, child: row);
    }
    return Material(
      color: Colors.transparent,
      child: InkWell(key: rowKey, onTap: onTap, child: row),
    );
  }
}

/// The marker column: a 2 dp rail with the record's marker sitting on it.
final class _TimelineMarkerColumn extends StatelessWidget {
  const _TimelineMarkerColumn({
    required this.marker,
    required this.railColor,
    required this.hasRailAbove,
    required this.hasRailBelow,
  });

  final Widget marker;
  final Color railColor;
  final bool hasRailAbove;
  final bool hasRailBelow;

  static const double width = 32;
  static const double railWidth = 2;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Column(
        children: <Widget>[
          SizedBox(
            height: 14,
            child: hasRailAbove
                ? Align(
                    alignment: Alignment.bottomCenter,
                    child: Container(
                      width: railWidth,
                      height: 14,
                      color: railColor,
                    ),
                  )
                : null,
          ),
          SizedBox(
            width: width,
            child: Center(child: marker),
          ),
          if (hasRailBelow)
            Expanded(
              child: Container(width: railWidth, color: railColor),
            )
          else
            const Spacer(),
        ],
      ),
    );
  }
}

/// One muted information line at the top of a timeline (never a card, never
/// interactive).  Used by Unreported → Events.
final class PlanningTimelineInfoLine extends StatelessWidget {
  const PlanningTimelineInfoLine({required this.text, super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final muted = AppTheme.detailCaptionOf(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.info_outline, size: 16, color: muted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontFamily: 'Roboto',
                fontSize: 12.5,
                height: 17 / 12.5,
                color: muted,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Tail spacer so the create FAB never covers the last row (the accepted
/// `SizedBox(height: 96)` convention from the Contacts timeline).
const Widget planningTimelineTail = SliverToBoxAdapter(
  child: SizedBox(height: 96),
);
