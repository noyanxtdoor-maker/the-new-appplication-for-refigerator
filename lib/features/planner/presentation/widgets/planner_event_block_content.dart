import 'package:flutter/material.dart';
import 'package:rmplanner/features/planner/domain/planner_day.dart';
import 'package:rmplanner/features/planner/presentation/widgets/planner_event_block_layout_policy.dart';
import 'package:rmplanner/features/planner/presentation/widgets/planner_event_report_status.dart';

String formatPlannerEventMinute(int minute, bool use24HourTime) {
  final hour = minute ~/ 60;
  final normalizedMinute = minute % 60;
  if (use24HourTime) {
    return '${hour.toString().padLeft(2, '0')}:${normalizedMinute.toString().padLeft(2, '0')}';
  }
  final displayHour = hour == 0
      ? 12
      : hour > 12
      ? hour - 12
      : hour;
  return '$displayHour:${normalizedMinute.toString().padLeft(2, '0')} '
      '${hour >= 12 ? 'PM' : 'AM'}';
}

String formatPlannerEventRange(
  int startMinute,
  int endMinute,
  bool use24HourTime,
) {
  return '${formatPlannerEventMinute(startMinute, use24HourTime)} - '
      '${formatPlannerEventMinute(endMinute, use24HourTime)}';
}

/// Shared visible content for centered and read-only adjacent Event blocks.
///
/// The caller supplies the density calculated from the exact visible block
/// height. This keeps the centered interactive card and the pager preview on
/// the same compact-content policy without giving either widget a visual
/// minimum height that would falsify Event duration.
final class PlannerEventBlockContentView extends StatelessWidget {
  const PlannerEventBlockContentView({
    super.key,
    required this.event,
    required this.use24HourTime,
    required this.displayStartMinute,
    required this.displayEndMinute,
    required this.awaitingReport,
    required this.content,
    this.accentColor,
    this.surfaceColor,
    this.textColorOverride,
    this.titleKey,
    this.timeKey,
    this.recurrenceKey,
    this.statusKey,
  });

  final PlannerCalendarItem event;
  final bool use24HourTime;
  final int displayStartMinute;
  final int displayEndMinute;
  final bool awaitingReport;
  final PlannerEventBlockContent content;
  final Color? accentColor;
  final Color? surfaceColor;

  /// Optional override for the block text color.  Saved Events keep the
  /// locked white-text rule; only the pink unsaved draft surface opts into
  /// dark text so the time range stays legible on the light pink fill.
  final Color? textColorOverride;
  final Key? titleKey;
  final Key? timeKey;
  final Key? recurrenceKey;
  final Key? statusKey;

  @override
  Widget build(BuildContext context) {
    final density = content.density;
    final base = Color(event.activityTypeColorValue ?? 0xFFE91E63);
    final accent = accentColor ?? base;
    final surface =
        surfaceColor ?? PlannerEventBlockColorPolicy.surfaceColor(base);
    final textColor =
        textColorOverride ??
        PlannerEventBlockColorPolicy.textColor(
          surface,
          Theme.of(context).brightness,
        );
    final titleStyle = TextStyle(
      color: textColor,
      fontWeight: FontWeight.w500,
      fontSize: PlannerEventBlockLayoutPolicy.titleFontSize(density),
      height: PlannerEventBlockLayoutPolicy.titleLineHeightForHeight(
        content.liveHeight,
      ),
    );
    final timeStyle = TextStyle(
      color: textColor.withValues(alpha: 0.92),
      fontWeight: FontWeight.w400,
      fontSize: PlannerEventBlockLayoutPolicy.timeFontSize(density),
      height: 1.1,
    );
    final timeText = formatPlannerEventRange(
      displayStartMinute,
      displayEndMinute,
      use24HourTime,
    );
    final inlineText = '${event.displayTitle}  $timeText';
    // Approved provisional draft (Delta 4.1 D4.1-04): the unsaved pink block
    // renders TIME ONLY, centered, in a slightly larger dark text so it reads
    // as a pure provisional surface without the Event Type title.  Saved
    // Events keep their normal title/time content and white-text rule.
    if (content.showTimeOnly) {
      return Center(
        key: const Key('planner-provisional-time-only'),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text(
            timeText,
            key: timeKey,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            softWrap: false,
            style: TextStyle(
              color: textColor,
              fontWeight: FontWeight.w600,
              fontSize: 15,
              height: 1.2,
            ),
          ),
        ),
      );
    }
    final verticalPadding =
        PlannerEventBlockLayoutPolicy.verticalPaddingForHeight(
          content.liveHeight,
        );
    // The trailing report-status badge reserves its own right gutter so the
    // title/time never run underneath it. The gutter covers the badge
    // diameter (15) plus its right inset per the combined delta PMG target
    // (14-16 dp icon, 18-20 dp reserved region, ~19 dp), so text can never
    // paint under the icon. Recurring Events keep their wider top-right
    // recurrence gutter, whichever is larger.
    const statusBadgeGutter = 19.0;
    // The trailing report-status badge is resolved at every block density:
    // an eligible elapsed report-required Event must always show its status
    // icon, truncating title/time first. Backup stripes and linked Tasks keep
    // their accepted bottom text row (only when the block has room), so no
    // report semantics are fabricated and the Pack 1A linked-task contract
    // stays intact.
    final contactEvent =
        event.activityTypeLabel?.toLowerCase().contains('contact') == true;
    final reportStatusKind = PlannerEventReportStatus.kindFor(
      state: event.state,
      requiresReport: event.requiresReport,
      awaitingReport: awaitingReport,
      isBackupAppointment: event.isBackupAppointment,
      hasLinkedTasks: event.linkedTaskIds.isNotEmpty,
      isContactEvent: contactEvent,
    );
    final reportBadge = switch (reportStatusKind) {
      null ||
      PlannerReportStatusKind.backup ||
      PlannerReportStatusKind.linked => null,
      _ => reportStatusKind,
    };
    // Combined-delta PMG scale: ~15 dp visible diameter on the device
    // (14-16 dp target band) so the badge reads as a small secondary
    // indicator beside the title/time. In very-short blocks it shrinks
    // further so the block's hard edge never clips it while it stays
    // vertically centered.
    final badgeDiameter =
        PlannerEventBlockLayoutPolicy.statusBadgeDiameterForHeight(
          content.liveHeight,
        );
    final nonReportText = switch (reportStatusKind) {
      PlannerReportStatusKind.backup when content.showStatusIcons => 'Backup',
      PlannerReportStatusKind.linked when content.showStatusIcons =>
        '${event.linkedTaskIds.length} linked',
      _ => null,
    };
    // R5-02 resolves compact content from the card's ACTUAL constraints. A
    // dense 2-4 card overlap can make the lane narrower while zoom changes
    // its height independently, so neither axis may assume the other has
    // spare room. Fixed icons stay bounded; text and gaps yield first.
    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : double.infinity;
        final availableHeight = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : double.infinity;
        final horizontalPadding = availableWidth < 48
            ? 4.0
            : PlannerEventBlockLayoutPolicy.contentHorizontalPadding;
        final baseRightPadding = event.isRecurring && content.showRecurrence
            ? PlannerEventBlockLayoutPolicy.recurringContentRightPadding
            : horizontalPadding;
        final rightPadding =
            reportBadge != null && baseRightPadding < statusBadgeGutter
            ? statusBadgeGutter
            : baseRightPadding;
        // Title (18) + time (14) + their gap (1) + compact status (11) +
        // status gap (2) + the production 4+4 vertical padding = 54 dp. The
        // previous density-only gate exposed the status Row in 45-53 dp cards
        // and produced the owner-observed 2-4 px RenderFlex overflow.
        final nonReportStatusFits =
            nonReportText != null && availableHeight >= 54;

        return Stack(
          clipBehavior: Clip.hardEdge,
          children: <Widget>[
            Positioned.fill(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  horizontalPadding,
                  verticalPadding,
                  rightPadding,
                  verticalPadding,
                ),
                child: Column(
                  key: const Key('planner-event-block-content'),
                  mainAxisSize: MainAxisSize.min,
                  // Zoom-out alignment (Delta 4.1 D4.1-05): at compressed
                  // card heights the title/time stack is centered naturally.
                  mainAxisAlignment: density == Density.tall
                      ? MainAxisAlignment.start
                      : MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    if (content.showTitle)
                      Text(
                        content.showTimeInline
                            ? inlineText
                            : event.displayTitle,
                        key: titleKey,
                        style: titleStyle,
                        maxLines: content.titleMaxLines,
                        overflow: TextOverflow.ellipsis,
                        softWrap: false,
                      ),
                    if (content.showTime && !content.showTimeInline)
                      Padding(
                        padding: EdgeInsets.only(
                          top: density == Density.tall ? 2 : 1,
                        ),
                        child: Text(
                          timeText,
                          key: timeKey,
                          style: timeStyle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          softWrap: false,
                        ),
                      ),
                    if (nonReportStatusFits)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: LayoutBuilder(
                          builder: (context, statusConstraints) {
                            final compact = statusConstraints.maxWidth < 40;
                            final iconSize = compact ? 9.0 : 11.0;
                            final iconGap = compact ? 2.0 : 4.0;
                            final textFits =
                                statusConstraints.maxWidth >= iconSize + 10;
                            return Row(
                              key: const Key(
                                'planner-event-block-non-report-status',
                              ),
                              mainAxisSize: MainAxisSize.max,
                              children: <Widget>[
                                SizedBox.square(
                                  dimension: iconSize,
                                  child: FittedBox(
                                    child: Icon(
                                      PlannerEventReportStatus.iconFor(
                                        reportStatusKind!,
                                      ),
                                      color: textColor,
                                    ),
                                  ),
                                ),
                                if (textFits) ...<Widget>[
                                  SizedBox(width: iconGap),
                                  Expanded(
                                    child: Text(
                                      nonReportText,
                                      style: TextStyle(
                                        color: textColor,
                                        fontSize: 10,
                                        fontWeight: FontWeight.w600,
                                        height: 1.1,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      softWrap: false,
                                    ),
                                  ),
                                ],
                              ],
                            );
                          },
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (event.isRecurring && content.showRecurrence)
              Positioned(
                key: recurrenceKey,
                top: PlannerEventBlockLayoutPolicy.recurrenceTopForHeight(
                  content.liveHeight,
                ),
                right: PlannerEventBlockLayoutPolicy.recurrenceRightInset,
                child: Icon(
                  Icons.repeat,
                  size: PlannerEventBlockLayoutPolicy.recurrenceIconSizeForHeight(
                    content.liveHeight,
                  ),
                  color: accent.withValues(alpha: 0.92),
                ),
              ),
            if (reportBadge != null)
              Positioned(
                key: statusKey,
                top: 0,
                bottom: 0,
                right: (statusBadgeGutter - badgeDiameter) / 2,
                child: Center(
                  child: PlannerEventStatusBadge(
                    kind: reportBadge,
                    diameter: badgeDiameter,
                    isContactEvent: contactEvent,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Domain-neutral Task content rendered with the Event-family Day-block
/// density, padding, typography, truncation, and status-gutter rules.
///
/// It deliberately accepts presentation facts rather than a Calendar Event or
/// a Task domain object. The Task wrapper remains the sole owner of Task tap,
/// drag, recurrence, status, and no-resize behavior; this primitive owns only
/// the visual content that must stay in parity with Event-family blocks.
final class PlannerTaskEventFamilyBlockContentView extends StatelessWidget {
  const PlannerTaskEventFamilyBlockContentView({
    super.key,
    required this.title,
    required this.time,
    required this.textColor,
    required this.status,
    required this.content,
    this.contentKey,
    this.titleKey,
    this.timeKey,
    this.statusKey,
  });

  final String title;
  final String time;
  final Color textColor;
  final PlannerReportStatusKind status;
  final PlannerEventBlockContent content;
  final Key? contentKey;
  final Key? titleKey;
  final Key? timeKey;
  final Key? statusKey;

  @override
  Widget build(BuildContext context) {
    final density = content.density;
    final titleStyle = TextStyle(
      color: textColor,
      fontWeight: FontWeight.w500,
      fontSize: PlannerEventBlockLayoutPolicy.titleFontSize(density),
      height: PlannerEventBlockLayoutPolicy.titleLineHeightForHeight(
        content.liveHeight,
      ),
    );
    final timeStyle = TextStyle(
      color: textColor.withValues(alpha: 0.92),
      fontWeight: FontWeight.w400,
      fontSize: PlannerEventBlockLayoutPolicy.timeFontSize(density),
      height: 1.1,
    );
    final inlineText = '$title  $time';
    const statusBadgeGutter = 19.0;
    final badgeDiameter =
        PlannerEventBlockLayoutPolicy.statusBadgeDiameterForHeight(
          content.liveHeight,
        );
    final verticalPadding =
        PlannerEventBlockLayoutPolicy.verticalPaddingForHeight(
          content.liveHeight,
        );
    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : double.infinity;
        final horizontalPadding = availableWidth < 48
            ? 4.0
            : PlannerEventBlockLayoutPolicy.contentHorizontalPadding;
        return Stack(
          clipBehavior: Clip.hardEdge,
          children: <Widget>[
            Positioned.fill(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  horizontalPadding,
                  verticalPadding,
                  statusBadgeGutter,
                  verticalPadding,
                ),
                child: Column(
                  key: contentKey,
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: density == Density.tall
                      ? MainAxisAlignment.start
                      : MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    if (content.showTitle)
                      Text(
                        content.showTimeInline ? inlineText : title,
                        key: titleKey,
                        style: titleStyle,
                        maxLines: content.titleMaxLines,
                        overflow: TextOverflow.ellipsis,
                        softWrap: false,
                      ),
                    if (content.showTime && !content.showTimeInline)
                      Padding(
                        padding: EdgeInsets.only(
                          top: density == Density.tall ? 2 : 1,
                        ),
                        child: Text(
                          time,
                          key: timeKey,
                          style: timeStyle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          softWrap: false,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            Positioned(
              key: statusKey,
              top: 0,
              bottom: 0,
              right: (statusBadgeGutter - badgeDiameter) / 2,
              child: Center(
                child: PlannerEventStatusBadge(
                  kind: status,
                  diameter: badgeDiameter,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
