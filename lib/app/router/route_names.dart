import 'package:rmplanner/features/maps/domain/map_coordinate.dart';
import 'package:rmplanner/features/planner/domain/calendar_event.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';

/// Optional, typed navigation context for an Event Detail opened from one
/// Contact's Timeline. It lets the detail route return to the already-mounted
/// Contact shell instead of pushing a second ShellRoute with the same
/// Navigator key.
final class CalendarEventDetailRouteExtra {
  const CalendarEventDetailRouteExtra({required this.timelineOriginContactId});

  final String timelineOriginContactId;
}

/// Maps-origin Add Contact seam: the chosen map coordinate is pre-populated
/// into the canonical Add Contact form's Map draft field without fabricating
/// an address or adding a second Contact form.
final class AddContactMapExtra {
  const AddContactMapExtra({required this.coordinate});

  final MapCoordinate coordinate;
}

abstract final class RouteNames {
  static const String startup = 'startup';
  static const String onboarding = 'onboarding';
  static const String recovery = 'recovery';
  static const String protectedContent = 'protected-content';
  static const String home = 'home';
  static const String planner = 'planner';
  static const String more = 'more';
  static const String settings = 'settings';
  static const String colors = 'colors';
  static const String startOfWeek = 'start-of-week';
  static const String appearance = 'appearance';
  static const String mapsSettings = 'maps-settings';
  static const String notificationsSettings = 'notifications-settings';
  static const String plannerEventColors = 'planner-event-colors';
  static const String taskCreate = 'task-create';
  static const String taskDetail = 'task-detail';
  static const String taskEdit = 'task-edit';
  static const String taskLinkEvent = 'task-link-event';
  static const String taskCreateEvent = 'task-create-event';
  static const String calendarEventCreate = 'calendar-event-create';
  static const String calendarEventDetail = 'calendar-event-detail';
  static const String calendarEventEdit = 'calendar-event-edit';
  static const String calendarEventReschedule = 'calendar-event-reschedule';
  static const String calendarEventLinkTask = 'calendar-event-link-task';
  static const String activityHistory = 'activity-history';
  static const String plannerSettings = 'planner-settings';
  static const String eventTypes = 'event-types';
  static const String eventTypeCreate = 'event-type-create';
  static const String eventTypeEdit = 'event-type-edit';
  static const String indicatorDetail = 'indicator-detail';
  static const String indicatorList = 'indicator-list';
  static const String indicatorEdit = 'indicator-edit';
  static const String weeklyPlanning = 'weekly-planning';
  static const String weeklyPlanningTargets = 'weekly-planning-targets';
  static const String weeklyPlanningHistory = 'weekly-planning-history';
  static const String goalCreate = 'goal-create';
  static const String starterGoals = 'starter-goals';
  static const String goalCreateIconPicker = 'goal-create-icon-picker';
  static const String goalEdit = 'goal-edit';
  static const String goalEditIconPicker = 'goal-edit-icon-picker';
  static const String goalArchive = 'goal-archive';
  static const String goalIconPicker = 'goal-icon-picker';
  static const String privacyCenter = 'privacy-center';
  static const String permissions = 'permissions';
  static const String diagnosticPreview = 'diagnostic-preview';
  static const String messages = 'messages';
  static const String about = 'about';
  static const String contacts = 'contacts';
  static const String maps = 'maps';
  static const String mapSearch = 'map-search';
  static const String mapPicker = 'map-picker';
  static const String contactSearch = 'contact-search';
  static const String contactCreate = 'contact-create';
  static const String contactEdit = 'contact-edit';
  static const String contactDetail = 'contact-detail';
  static const String contactGroups = 'contact-groups';
  static const String contactGroupDetail = 'contact-group-detail';
  static const String contactLifecycle = 'contact-lifecycle';
  static const String savedFilters = 'saved-filters';
  static const String filterBuilder = 'filter-builder';
  static const String multiSelect = 'multi-select';
  static const String mergeContacts = 'merge-contacts';
  static const String deviceImport = 'device-import';
  static const String addPeople = 'add-people';
}

abstract final class RoutePaths {
  static const String startup = '/startup';
  static const String onboarding = '/onboarding';
  static const String recovery = '/recovery';
  static const String protectedContent = '/protected';
  static const String home = '/home';
  static const String planner = '/planner';
  static const String more = '/more';
  static const String settings = '/more/settings';
  static const String colors = '/more/settings/colors';
  static const String startOfWeek = '/more/settings/start-of-week';
  static const String appearance = '/more/settings/appearance';
  static const String mapsSettings = '/more/settings/maps';
  static const String notificationsSettings = '/more/settings/notifications';
  static const String plannerEventColors =
      '/more/settings/colors/planner-event-colors';
  static const String tasks = '/tasks';
  static const String taskCreate = '/tasks/new';
  static const String calendarEvents = '/events';
  static const String calendarEventCreate = '/events/new';
  static const String activityHistory = '/activity-history';
  static const String plannerSettings = '/planner/settings';
  static const String eventTypes = '/planner/settings/event-types';
  static const String eventTypeCreate = '/planner/settings/event-types/new';
  static const String progress = '/progress';
  static const String weeklyPlanning = '/planner/weekly-planning';
  static const String weeklyPlanningTargetsPath =
      '/planner/weekly-planning/targets';
  static const String weeklyPlanningHistory =
      '/planner/weekly-planning-history';
  static const String goalCreate = '/planner/weekly-planning/create';
  static const String starterGoals = '/planner/weekly-planning/starter-goals';
  static const String goalCreateIconPicker =
      '/planner/weekly-planning/create/icon';
  static const String goalArchive = '/planner/weekly-planning/archive';
  static const String goalIconPicker = '/planner/weekly-planning/goals/icon';
  static const String goalEditPath = '/planner/weekly-planning/goals';
  static const String privacyCenter = '/privacy';
  static const String permissions = '/privacy/permissions';
  static const String diagnosticPreview = '/privacy/diagnostics';
  static const String messages = '/messages';
  static const String about = '/about';
  static const String contacts = '/contacts';
  static const String maps = '/maps';
  static const String mapSearch = '/maps/search';
  static const String mapPicker = '/maps/picker';
  static const String contactSearch = '/contacts/search';
  static const String contactCreate = '/contacts/new';
  static const String contactDetailPath = '/contacts/contact';
  static const String contactGroups = '/contacts/groups';
  static const String contactGroupDetailPath = '/contacts/groups/group';
  static const String contactLifecycle = '/contacts/lifecycle';
  static const String savedFilters = '/contacts/filters';
  static const String filterBuilder = '/contacts/filter-builder';
  static const String multiSelect = '/contacts/select';
  static const String mergeContacts = '/contacts/merge';
  static const String deviceImport = '/contacts/import';
  static const String addPeople = '/contacts/add-people';

  static String contactDetail(String contactId) =>
      '$contactDetailPath/$contactId';

  static String contactGroupDetail(String groupId) =>
      '$contactGroupDetailPath/$groupId';

  static String contactEdit(String contactId) =>
      '$contactDetailPath/$contactId/edit';

  static String calendarEventDetail(String eventId, PlannerDate originalDate) {
    return '$calendarEvents/$eventId/${originalDate.iso8601}';
  }

  static String calendarEventEdit(
    String eventId,
    PlannerDate originalDate,
    CalendarEventEditScope scope, {
    bool deferScopeToSave = false,
    CalendarEventStatus? statusIntent,
    // NX-06: known identity seeds for the Edit loading shell.
    String? title,
    String? eventTypeLabel,
  }) {
    final params = <String>['scope=${scope.name}'];
    if (deferScopeToSave) {
      params.add('deferScope=1');
    }
    if (statusIntent != null) {
      params.add('status=${statusIntent.name}');
    }
    if (title != null && title.trim().isNotEmpty) {
      params.add('title=${Uri.encodeQueryComponent(title)}');
    }
    if (eventTypeLabel != null && eventTypeLabel.trim().isNotEmpty) {
      params.add('eventTypeLabel=${Uri.encodeQueryComponent(eventTypeLabel)}');
    }
    return '${calendarEventDetail(eventId, originalDate)}/edit'
        '?${params.join('&')}';
  }

  static String calendarEventReschedule(
    String eventId,
    PlannerDate originalDate,
    CalendarEventEditScope scope,
  ) {
    return '${calendarEventDetail(eventId, originalDate)}/reschedule'
        '?scope=${scope.name}';
  }

  static String indicatorDetail(String indicatorKey, PlannerDate periodStart) {
    return '$progress/metric/$indicatorKey?week=${periodStart.iso8601}';
  }

  static String indicatorEdit(String indicatorKey, PlannerDate periodStart) {
    return '$progress/metric/$indicatorKey/edit?week=${periodStart.iso8601}';
  }

  static String weeklyPlanningTargets(
    PlannerDate periodStart, {
    String? indicatorKey,
  }) {
    final indicator = indicatorKey == null ? '' : '&indicator=$indicatorKey';
    return '$weeklyPlanningTargetsPath?week=${periodStart.iso8601}$indicator';
  }

  static String weeklyPlanningFor(PlannerDate periodStart) {
    return '$weeklyPlanning?week=${periodStart.iso8601}';
  }

  static String goalEdit(String goalId) {
    return '$goalEditPath/$goalId/edit';
  }

  static String goalEditIconPicker(String goalId) {
    return '${goalEdit(goalId)}/icon';
  }
}
