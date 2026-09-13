import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:rmplanner/app/router/route_names.dart';
import 'package:rmplanner/features/maps/domain/map_coordinate.dart';
import 'package:rmplanner/features/notifications/domain/contact_follow_up_creation_intent.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/presentation/calendar_event_creation.dart';
import 'package:rmplanner/features/planner/presentation/event_type_picker_dialog.dart';

final class CalendarEventCreateGateScreen extends ConsumerStatefulWidget {
  const CalendarEventCreateGateScreen({
    required this.initialDate,
    this.initialCoordinate,
    this.initialStartMinute,
    this.initialIndicatorKey,
    this.initialEventTypeId,
    this.sourceTaskId,
    this.initialContactIds = const <String>[],
    this.followUpContactId,
    super.key,
  });

  final PlannerDate initialDate;
  final MapCoordinate? initialCoordinate;
  final int? initialStartMinute;
  final String? initialIndicatorKey;
  final String? initialEventTypeId;
  final String? sourceTaskId;
  final List<String> initialContactIds;

  /// M7 section 8 — the ONE Contact explicitly chosen in the Contact Detail
  /// follow-up chooser, forwarded through the picker into the form.  Null for
  /// every ordinary creation path.
  final String? followUpContactId;

  @override
  ConsumerState<CalendarEventCreateGateScreen> createState() =>
      _CalendarEventCreateGateScreenState();
}

final class _CalendarEventCreateGateScreenState
    extends ConsumerState<CalendarEventCreateGateScreen> {
  var _pickerScheduled = false;

  @override
  Widget build(BuildContext context) {
    if (!_pickerScheduled) {
      _pickerScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_selectType());
      });
    }
    return const Scaffold(
      body: SafeArea(
        child: Center(
          child: CircularProgressIndicator(
            semanticsLabel: 'Opening Select Event Type',
          ),
        ),
      ),
    );
  }

  Future<void> _selectType() async {
    final selected = await showEventTypePicker(
      context: context,
      ref: ref,
      recommendedIndicatorKey: widget.initialIndicatorKey,
      recommendedEventTypeId: widget.initialEventTypeId,
    );
    if (!mounted) {
      return;
    }
    if (selected == null) {
      if (context.canPop()) {
        context.pop(false);
      } else {
        context.go(RoutePaths.planner);
      }
      return;
    }
    final router = GoRouter.of(context);
    // M7 section 8 — the typed follow-up provenance survives whichever create
    // path the picker resolves to, so choosing Task from this Event gate keeps
    // the SAME explicitly selected Contact as the follow-up target.
    final followUp = widget.followUpContactId;
    final intent = followUp == null
        ? null
        : ContactFollowUpCreationIntent(contactId: followUp);
    final saved = switch (selected) {
      EventTypePickerEvent(:final eventType) =>
        await showCalendarEventFormSheet<bool>(
          context: context,
          eventType: eventType,
          date: widget.initialDate,
          startMinute: widget.initialStartMinute,
          indicatorKey: widget.initialIndicatorKey,
          sourceTaskId: widget.sourceTaskId,
          initialContactIds: widget.initialContactIds,
          initialCoordinate: widget.initialCoordinate,
          followUpContactId: followUp,
        ),
      EventTypePickerTask() => await router.push<bool>(
        Uri(
          path: RoutePaths.taskCreate,
          queryParameters: <String, String>{
            'date': widget.initialDate.iso8601,
            // Preserve the Contact preselection already established by the
            // follow-up chooser's `contacts=` argument.
            if (widget.initialContactIds.isNotEmpty)
              'contacts': widget.initialContactIds.join(','),
          },
        ).toString(),
        extra: intent,
      ),
    };
    if (!mounted) {
      return;
    }
    if (context.canPop()) {
      context.pop(saved == true);
    } else {
      context.go(RoutePaths.planner);
    }
  }
}
