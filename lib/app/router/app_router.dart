import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:rmplanner/app/router/app_route_observer.dart';
import 'package:rmplanner/app/router/route_names.dart';
import 'package:rmplanner/app/router/startup_route_guard.dart';
import 'package:rmplanner/app/shell/main_shell.dart';
import 'package:rmplanner/core/time/week_period.dart';
import 'package:rmplanner/features/backup/presentation/backup_recovery_screen.dart';
import 'package:rmplanner/features/contacts/presentation/add_people_screen.dart';
import 'package:rmplanner/features/contacts/presentation/contact_detail_screen.dart';
import 'package:rmplanner/features/contacts/presentation/contact_form_screen.dart';
import 'package:rmplanner/features/contacts/presentation/contact_groups_screen.dart';
import 'package:rmplanner/features/contacts/presentation/contact_lifecycle_screen.dart';
import 'package:rmplanner/features/contacts/presentation/contact_multi_select_screen.dart';
import 'package:rmplanner/features/contacts/presentation/contact_search_screen.dart';
import 'package:rmplanner/features/contacts/presentation/contacts_screen.dart';
import 'package:rmplanner/features/contacts/presentation/device_contact_import_screen.dart';
import 'package:rmplanner/features/contacts/presentation/filter_builder_screen.dart';
import 'package:rmplanner/features/contacts/presentation/merge_contacts_screen.dart';
import 'package:rmplanner/features/contacts/presentation/saved_filters_screen.dart';
import 'package:rmplanner/features/goals/domain/goal.dart';
import 'package:rmplanner/features/goals/presentation/goal_archive_screen.dart';
import 'package:rmplanner/features/goals/presentation/goal_create_screen.dart';
import 'package:rmplanner/features/goals/presentation/goal_edit_screen.dart';
import 'package:rmplanner/features/goals/presentation/goal_icon_picker_screen.dart';
import 'package:rmplanner/features/goals/presentation/starter_goals_screen.dart';
import 'package:rmplanner/features/indicators/presentation/indicator_detail_screen.dart';
import 'package:rmplanner/features/indicators/presentation/indicator_edit_screen.dart';
import 'package:rmplanner/features/indicators/presentation/indicator_list_screen.dart';
import 'package:rmplanner/features/indicators/presentation/weekly_target_prompt_screen.dart';
import 'package:rmplanner/features/maps/domain/map_coordinate.dart';
import 'package:rmplanner/features/maps/presentation/map_location_picker_screen.dart';
import 'package:rmplanner/features/maps/presentation/maps_screen.dart';
import 'package:rmplanner/features/maps/presentation/maps_search_screen.dart';
import 'package:rmplanner/features/notifications/domain/contact_follow_up_creation_intent.dart';
import 'package:rmplanner/features/planner/application/planner_providers.dart';
import 'package:rmplanner/features/planner/domain/calendar_event.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/planner/presentation/activity_history_screen.dart';
import 'package:rmplanner/features/planner/presentation/calendar_event_create_gate_screen.dart';
import 'package:rmplanner/features/planner/presentation/calendar_event_detail_screen.dart';
import 'package:rmplanner/features/planner/presentation/calendar_event_form_screen.dart';
import 'package:rmplanner/features/planner/presentation/event_type_form_screen.dart';
import 'package:rmplanner/features/planner/presentation/event_types_screen.dart';
import 'package:rmplanner/features/planner/presentation/planner_screen.dart';
import 'package:rmplanner/features/planner/presentation/planner_settings_screen.dart';
import 'package:rmplanner/features/planner/presentation/task_detail_screen.dart';
import 'package:rmplanner/features/planner/presentation/task_event_link_screen.dart';
import 'package:rmplanner/features/planner/presentation/task_form_screen.dart';
import 'package:rmplanner/features/privacy/presentation/diagnostic_preview_screen.dart';
import 'package:rmplanner/features/privacy/presentation/permissions_screen.dart';
import 'package:rmplanner/features/privacy/presentation/privacy_center_screen.dart';
import 'package:rmplanner/features/settings/application/start_of_week_providers.dart';
import 'package:rmplanner/features/settings/presentation/appearance_screen.dart';
import 'package:rmplanner/features/settings/presentation/colors_screen.dart';
import 'package:rmplanner/features/settings/presentation/maps_settings_screen.dart';
import 'package:rmplanner/features/settings/presentation/notifications_settings_screen.dart';
import 'package:rmplanner/features/settings/presentation/planner_event_colors_screen.dart';
import 'package:rmplanner/features/settings/presentation/settings_screen.dart';
import 'package:rmplanner/features/settings/presentation/start_of_week_screen.dart';
import 'package:rmplanner/features/shell/about_screen.dart';
import 'package:rmplanner/features/shell/message_detail_screen.dart';
import 'package:rmplanner/features/shell/messages_screen.dart';
import 'package:rmplanner/features/startup/application/startup_providers.dart';
import 'package:rmplanner/features/startup/domain/startup_state.dart';
import 'package:rmplanner/features/startup/presentation/home_screen.dart';
import 'package:rmplanner/features/startup/presentation/link_recovery_screen.dart';
import 'package:rmplanner/features/startup/presentation/onboarding_screen.dart';
import 'package:rmplanner/features/startup/presentation/protected_content_screen.dart';
import 'package:rmplanner/features/startup/presentation/recovery_screen.dart';
import 'package:rmplanner/features/startup/presentation/startup_screen.dart';
import 'package:rmplanner/features/weekly_planning/presentation/weekly_plan_history_screen.dart';
import 'package:rmplanner/features/weekly_planning/presentation/weekly_planning_screen.dart';

// Exposed so notification OPEN routing can present the canonical Planner
// preview over the shell root after landing on the Planner tab.
final GlobalKey<NavigatorState> appRootNavigatorKey = GlobalKey<NavigatorState>(
  debugLabel: 'root',
);
final _rootNavigatorKey = appRootNavigatorKey;
final _shellNavigatorKey = GlobalKey<NavigatorState>(debugLabel: 'shell');

final appRouterProvider = Provider<GoRouter>((ref) {
  late final GoRouter router;
  ref.listen<StartupState>(startupControllerProvider, (previous, next) {
    if (_StartupRouterRefresh.requiresRefresh(previous, next)) {
      router.refresh();
    }
  });
  router = GoRouter(
    navigatorKey: _rootNavigatorKey,
    initialLocation: RoutePaths.startup,
    redirect: (context, state) {
      return StartupRouteGuard.redirect(
        state: ref.read(startupControllerProvider),
        currentLocation: state.matchedLocation,
      );
    },
    routes: <RouteBase>[
      GoRoute(
        name: RouteNames.startup,
        path: RoutePaths.startup,
        builder: (context, state) => const StartupScreen(),
      ),
      GoRoute(
        name: RouteNames.onboarding,
        path: RoutePaths.onboarding,
        builder: (context, state) => const OnboardingScreen(),
      ),
      GoRoute(
        name: RouteNames.recovery,
        path: RoutePaths.recovery,
        builder: (context, state) => const RecoveryScreen(),
      ),
      GoRoute(
        name: RouteNames.protectedContent,
        path: RoutePaths.protectedContent,
        builder: (context, state) => const ProtectedContentScreen(),
      ),
      ShellRoute(
        navigatorKey: _shellNavigatorKey,
        observers: <NavigatorObserver>[shellRouteObserver],
        builder: (context, state, child) => MainShell(child: child),
        routes: <RouteBase>[
          GoRoute(
            name: RouteNames.home,
            path: RoutePaths.home,
            builder: (context, state) => const HomeScreen(),
          ),
          GoRoute(
            name: RouteNames.planner,
            path: RoutePaths.planner,
            builder: (context, state) => const PlannerScreen(),
          ),
          GoRoute(
            name: RouteNames.more,
            path: RoutePaths.more,
            // NX-07/08: the standalone More landing page is removed from the
            // IA.  The old /more location is kept ONLY as a compatibility
            // redirect to Home (never renders a More landing); its former
            // child destinations (Settings, Colors, Start-of-week, Appearance,
            // Planner Event Colors, Privacy) remain reachable from the drawer
            // and their direct routes.
            redirect: (context, state) => RoutePaths.home,
          ),
          GoRoute(
            name: RouteNames.contacts,
            path: RoutePaths.contacts,
            builder: (context, state) => const ContactsScreen(),
            routes: <RouteBase>[
              GoRoute(
                name: RouteNames.contactSearch,
                path: 'search',
                builder: (context, state) => const ContactSearchScreen(),
              ),
              GoRoute(
                name: RouteNames.contactDetail,
                path: 'contact/:contactId',
                builder: (context, state) => ContactDetailScreen(
                  contactId: state.pathParameters['contactId']!,
                ),
                routes: <RouteBase>[
                  GoRoute(
                    name: RouteNames.contactEdit,
                    path: 'edit',
                    builder: (context, state) => ContactFormScreen.edit(
                      contactId: state.pathParameters['contactId']!,
                    ),
                  ),
                ],
              ),
            ],
          ),
          GoRoute(
            name: RouteNames.maps,
            path: RoutePaths.maps,
            builder: (context, state) => const MapsScreen(),
            routes: <RouteBase>[
              GoRoute(
                name: RouteNames.mapSearch,
                path: 'search',
                builder: (context, state) => const MapsSearchScreen(),
              ),
            ],
          ),
          GoRoute(
            name: RouteNames.settings,
            path: RoutePaths.settings,
            builder: (context, state) => const SettingsScreen(),
          ),
          GoRoute(
            name: RouteNames.colors,
            path: RoutePaths.colors,
            builder: (context, state) => const ColorsScreen(),
          ),
          GoRoute(
            name: RouteNames.startOfWeek,
            path: RoutePaths.startOfWeek,
            builder: (context, state) => const StartOfWeekScreen(),
          ),
          GoRoute(
            name: RouteNames.appearance,
            path: RoutePaths.appearance,
            builder: (context, state) => const AppearanceScreen(),
          ),
          GoRoute(
            name: RouteNames.mapsSettings,
            path: RoutePaths.mapsSettings,
            builder: (context, state) => const MapsSettingsScreen(),
          ),
          GoRoute(
            name: RouteNames.notificationsSettings,
            path: RoutePaths.notificationsSettings,
            builder: (context, state) => const NotificationsSettingsScreen(),
          ),
          GoRoute(
            name: RouteNames.plannerEventColors,
            path: RoutePaths.plannerEventColors,
            builder: (context, state) => const PlannerEventColorsScreen(),
          ),
          GoRoute(
            name: RouteNames.indicatorList,
            path: RoutePaths.progress,
            builder: (context, state) => const IndicatorListScreen(),
          ),
          GoRoute(
            name: RouteNames.indicatorEdit,
            path: '${RoutePaths.progress}/metric/:indicatorKey/edit',
            builder: (context, state) {
              return IndicatorEditScreen(
                indicatorKey: state.pathParameters['indicatorKey']!,
                periodStart: _periodStart(
                  state.uri.queryParameters['week'],
                  ref.read(plannerDateSourceProvider).today(),
                  ref,
                ),
              );
            },
          ),
          GoRoute(
            name: RouteNames.indicatorDetail,
            path: '${RoutePaths.progress}/metric/:indicatorKey',
            builder: (context, state) {
              final period = _periodStart(
                state.uri.queryParameters['week'],
                ref.read(plannerDateSourceProvider).today(),
                ref,
              );
              return IndicatorDetailScreen(
                indicatorKey: state.pathParameters['indicatorKey']!,
                periodStart: period,
              );
            },
          ),
          GoRoute(
            name: RouteNames.weeklyPlanning,
            path: RoutePaths.weeklyPlanning,
            builder: (context, state) {
              final raw = state.uri.queryParameters['week'];
              return WeeklyPlanningScreen(
                periodStart: raw == null
                    ? null
                    : _periodStart(
                        raw,
                        ref.read(plannerDateSourceProvider).today(),
                        ref,
                      ),
                initialManagementMode: state.extra == true,
              );
            },
          ),
          GoRoute(
            name: RouteNames.weeklyPlanningTargets,
            path: RoutePaths.weeklyPlanningTargetsPath,
            builder: (context, state) {
              return WeeklyTargetPromptScreen(
                periodStart: _periodStart(
                  state.uri.queryParameters['week'],
                  ref.read(plannerDateSourceProvider).today(),
                  ref,
                ),
                indicatorKey: state.uri.queryParameters['indicator'],
              );
            },
          ),
          GoRoute(
            name: RouteNames.weeklyPlanningHistory,
            path: RoutePaths.weeklyPlanningHistory,
            builder: (context, state) => const WeeklyPlanHistoryScreen(),
          ),
          GoRoute(
            name: RouteNames.starterGoals,
            path: RoutePaths.starterGoals,
            builder: (context, state) => const StarterGoalsScreen(),
          ),
          GoRoute(
            name: RouteNames.goalCreate,
            path: RoutePaths.goalCreate,
            builder: (context, state) => const GoalCreateScreen(),
            routes: <RouteBase>[
              GoRoute(
                name: RouteNames.goalCreateIconPicker,
                path: 'icon',
                pageBuilder: (context, state) {
                  final args = state.extra is GoalIconPickerArgs
                      ? state.extra! as GoalIconPickerArgs
                      : const GoalIconPickerArgs(
                          goalTitle: 'Goal',
                          currentIconId: null,
                        );
                  return NoTransitionPage<void>(
                    child: GoalIconPickerScreen(args: args),
                  );
                },
              ),
            ],
          ),
          GoRoute(
            name: RouteNames.goalArchive,
            path: RoutePaths.goalArchive,
            builder: (context, state) => const GoalArchiveScreen(),
          ),
          GoRoute(
            name: RouteNames.goalEdit,
            path: '${RoutePaths.goalEditPath}/:goalId/edit',
            builder: (context, state) => GoalEditScreen(
              goalId: state.pathParameters['goalId']!,
              initialGoal: state.extra is Goal ? state.extra as Goal : null,
            ),
            routes: <RouteBase>[
              GoRoute(
                name: RouteNames.goalEditIconPicker,
                path: 'icon',
                pageBuilder: (context, state) {
                  final args = state.extra is GoalIconPickerArgs
                      ? state.extra! as GoalIconPickerArgs
                      : const GoalIconPickerArgs(
                          goalTitle: 'Goal',
                          currentIconId: null,
                        );
                  return NoTransitionPage<void>(
                    child: GoalIconPickerScreen(args: args),
                  );
                },
              ),
            ],
          ),
          GoRoute(
            name: RouteNames.goalIconPicker,
            path: RoutePaths.goalIconPicker,
            pageBuilder: (context, state) {
              final args = state.extra is GoalIconPickerArgs
                  ? state.extra! as GoalIconPickerArgs
                  : const GoalIconPickerArgs(
                      goalTitle: 'Goal',
                      currentIconId: null,
                    );
              return NoTransitionPage<void>(
                child: GoalIconPickerScreen(args: args),
              );
            },
          ),
        ],
      ),
      GoRoute(
        name: RouteNames.taskCreate,
        path: RoutePaths.taskCreate,
        builder: (context, state) {
          final rawDate = state.uri.queryParameters['date'];
          final rawContacts = state.uri.queryParameters['contacts'];
          return TaskFormScreen.create(
            initialDueDate: rawDate == null ? null : PlannerDate.parse(rawDate),
            initialContactIds: rawContacts == null
                ? const <String>[]
                : rawContacts
                      .split(',')
                      .where((id) => id.isNotEmpty)
                      .toList(growable: false),
            // M7 section 8: the Contact Detail chooser forwards a typed
            // ephemeral intent.  Unknown/malformed extra fails closed to
            // ordinary creation rather than crashing.
            followUpContactId: _followUpContactIdOf(state),
          );
        },
      ),
      GoRoute(
        name: RouteNames.taskDetail,
        path: '${RoutePaths.tasks}/:taskId',
        builder: (context, state) {
          return TaskDetailScreen(taskId: state.pathParameters['taskId']!);
        },
        routes: <RouteBase>[
          GoRoute(
            name: RouteNames.taskEdit,
            path: 'edit',
            builder: (context, state) {
              return TaskFormScreen.edit(
                taskId: state.pathParameters['taskId']!,
              );
            },
          ),
          GoRoute(
            name: RouteNames.taskLinkEvent,
            path: 'link-event',
            builder: (context, state) => TaskEventLinkScreen.forTask(
              taskId: state.pathParameters['taskId']!,
            ),
          ),
          GoRoute(
            name: RouteNames.taskCreateEvent,
            path: 'create-event',
            builder: (context, state) {
              final rawDate = state.uri.queryParameters['date'];
              final rawStart = state.uri.queryParameters['startMinute'];
              return CalendarEventCreateGateScreen(
                sourceTaskId: state.pathParameters['taskId']!,
                initialDate: rawDate == null
                    ? PlannerDate.fromDateTime(DateTime.now())
                    : PlannerDate.parse(rawDate),
                initialStartMinute: int.tryParse(rawStart ?? ''),
                initialIndicatorKey: state.uri.queryParameters['indicator'],
                initialEventTypeId: state.uri.queryParameters['eventType'],
              );
            },
          ),
        ],
      ),
      GoRoute(
        name: RouteNames.calendarEventCreate,
        path: RoutePaths.calendarEventCreate,
        builder: (context, state) {
          final rawDate = state.uri.queryParameters['date'];
          final rawStart = state.uri.queryParameters['startMinute'];
          final rawContacts = state.uri.queryParameters['contacts'];
          final rawLat = state.uri.queryParameters['lat'];
          final rawLng = state.uri.queryParameters['lng'];
          final coordinate = MapCoordinate.tryParse(
            double.tryParse(rawLat ?? ''),
            double.tryParse(rawLng ?? ''),
          );
          return CalendarEventCreateGateScreen(
            initialDate: rawDate == null
                ? PlannerDate.fromDateTime(DateTime.now())
                : PlannerDate.parse(rawDate),
            initialStartMinute: int.tryParse(rawStart ?? ''),
            initialIndicatorKey: state.uri.queryParameters['indicator'],
            initialEventTypeId: state.uri.queryParameters['eventType'],
            initialContactIds: rawContacts == null
                ? const <String>[]
                : rawContacts
                      .split(',')
                      .where((id) => id.isNotEmpty)
                      .toList(growable: false),
            initialCoordinate: coordinate,
            // M7 section 8: typed follow-up provenance from the Contact Detail
            // chooser; unknown extra fails closed to ordinary creation.
            followUpContactId: _followUpContactIdOf(state),
          );
        },
      ),
      GoRoute(
        name: RouteNames.calendarEventDetail,
        path: '${RoutePaths.calendarEvents}/:eventId/:originalDate',
        builder: (context, state) {
          final routeExtra = state.extra is CalendarEventDetailRouteExtra
              ? state.extra! as CalendarEventDetailRouteExtra
              : null;
          return CalendarEventDetailScreen(
            eventId: state.pathParameters['eventId']!,
            originalDate: PlannerDate.parse(
              state.pathParameters['originalDate']!,
            ),
            timelineOriginContactId: routeExtra?.timelineOriginContactId,
          );
        },
        routes: <RouteBase>[
          GoRoute(
            name: RouteNames.calendarEventEdit,
            path: 'edit',
            builder: (context, state) {
              final rawScope = state.uri.queryParameters['scope'];
              return CalendarEventFormScreen.edit(
                eventId: state.pathParameters['eventId']!,
                originalDate: PlannerDate.parse(
                  state.pathParameters['originalDate']!,
                ),
                scope: rawScope == null
                    ? CalendarEventEditScope.occurrence
                    : CalendarEventEditScope.values.byName(rawScope),
                // Delta 4.1 edit flow: the detail screen opens the Edit form
                // first, so for a repeating Event the recurrence scope
                // chooser is deferred until the user commits a change on
                // Save.  The form only asks when this flag is set.
                deferRecurrenceScopeToSave:
                    state.uri.queryParameters['deferScope'] == '1',
                // NX-06: identity seeds for the Edit loading shell (known
                // from the detail sheet at open time). Null on deep-link /
                // direct entries keeps the previous behavior.
                initialTitle: state.uri.queryParameters['title'],
                initialEventTypeLabel:
                    state.uri.queryParameters['eventTypeLabel'],
                initialStatusIntent:
                    switch (state.uri.queryParameters['status']) {
                      final raw? => CalendarEventStatus.values.byName(raw),
                      null => null,
                    },
              );
            },
          ),
          GoRoute(
            name: RouteNames.calendarEventReschedule,
            path: 'reschedule',
            builder: (context, state) {
              final rawScope = state.uri.queryParameters['scope'];
              return CalendarEventFormScreen.reschedule(
                eventId: state.pathParameters['eventId']!,
                originalDate: PlannerDate.parse(
                  state.pathParameters['originalDate']!,
                ),
                scope: rawScope == null
                    ? CalendarEventEditScope.occurrence
                    : CalendarEventEditScope.values.byName(rawScope),
              );
            },
          ),
          GoRoute(
            name: RouteNames.calendarEventLinkTask,
            path: 'link-task',
            builder: (context, state) {
              final eventId = state.pathParameters['eventId']!;
              final originalDate = PlannerDate.parse(
                state.pathParameters['originalDate']!,
              );
              return TaskEventLinkScreen.forEvent(
                eventId: eventId,
                occurrenceId: CalendarEventOccurrenceIdentity.forDate(
                  eventId: eventId,
                  originalDate: originalDate,
                ),
                originalDate: originalDate,
              );
            },
          ),
        ],
      ),
      GoRoute(
        name: RouteNames.activityHistory,
        path: RoutePaths.activityHistory,
        builder: (context, state) => const ActivityHistoryScreen(),
      ),
      GoRoute(
        name: RouteNames.messages,
        path: RoutePaths.messages,
        builder: (context, state) => const MessagesScreen(),
        routes: <RouteBase>[
          // Bundled local message detail. The id is a stable bundled message
          // identity, never a database row, so this route resolves purely from
          // the shipped catalog.
          GoRoute(
            name: RouteNames.messageDetail,
            path: 'message/:messageId',
            builder: (context, state) => MessageDetailScreen(
              messageId: state.pathParameters['messageId']!,
            ),
          ),
        ],
      ),
      GoRoute(
        name: RouteNames.about,
        path: RoutePaths.about,
        builder: (context, state) => const AboutScreen(),
      ),
      GoRoute(
        name: RouteNames.plannerSettings,
        path: RoutePaths.plannerSettings,
        builder: (context, state) => const PlannerSettingsScreen(),
      ),
      GoRoute(
        name: RouteNames.eventTypes,
        path: RoutePaths.eventTypes,
        builder: (context, state) => const EventTypesScreen(),
      ),
      GoRoute(
        name: RouteNames.eventTypeCreate,
        path: RoutePaths.eventTypeCreate,
        builder: (context, state) => const EventTypeFormScreen.create(),
      ),
      GoRoute(
        name: RouteNames.eventTypeEdit,
        path: '${RoutePaths.eventTypes}/:eventTypeId/edit',
        builder: (context, state) => EventTypeFormScreen.edit(
          eventTypeId: state.pathParameters['eventTypeId']!,
        ),
      ),
      GoRoute(
        name: RouteNames.privacyCenter,
        path: RoutePaths.privacyCenter,
        builder: (context, state) => const PrivacyCenterScreen(),
      ),
      GoRoute(
        name: RouteNames.permissions,
        path: RoutePaths.permissions,
        builder: (context, state) => const PermissionsScreen(),
      ),
      GoRoute(
        name: RouteNames.diagnosticPreview,
        path: RoutePaths.diagnosticPreview,
        builder: (context, state) => const DiagnosticPreviewScreen(),
      ),
      GoRoute(
        name: RouteNames.backupRecovery,
        path: RoutePaths.backupRecovery,
        builder: (context, state) => const BackupRecoveryScreen(),
      ),
      GoRoute(
        name: RouteNames.mapPicker,
        path: RoutePaths.mapPicker,
        builder: (context, state) {
          final args = state.extra is MapPickerArgs
              ? state.extra! as MapPickerArgs
              : const MapPickerArgs(displayName: 'Pin');
          return MapLocationPickerScreen(args: args);
        },
      ),
      GoRoute(
        name: RouteNames.contactCreate,
        path: RoutePaths.contactCreate,
        builder: (context, state) {
          final extra = state.extra is AddContactMapExtra
              ? state.extra! as AddContactMapExtra
              : null;
          return ContactFormScreen.create(initialCoordinate: extra?.coordinate);
        },
      ),
      GoRoute(
        name: RouteNames.contactGroups,
        path: RoutePaths.contactGroups,
        builder: (context, state) => const ContactGroupsScreen(),
      ),
      GoRoute(
        name: RouteNames.contactGroupDetail,
        path: '${RoutePaths.contactGroupDetailPath}/:groupId',
        builder: (context, state) =>
            ContactGroupDetailScreen(groupId: state.pathParameters['groupId']!),
      ),
      GoRoute(
        name: RouteNames.contactLifecycle,
        path: RoutePaths.contactLifecycle,
        builder: (context, state) => const ContactLifecycleScreen(),
      ),
      GoRoute(
        name: RouteNames.savedFilters,
        path: RoutePaths.savedFilters,
        builder: (context, state) => const SavedFiltersScreen(),
      ),
      GoRoute(
        name: RouteNames.filterBuilder,
        path: RoutePaths.filterBuilder,
        builder: (context, state) {
          final extra = state.extra is FilterBuilderArgs
              ? state.extra! as FilterBuilderArgs
              : const FilterBuilderArgs();
          return FilterBuilderScreen(args: extra);
        },
      ),
      GoRoute(
        name: RouteNames.multiSelect,
        path: RoutePaths.multiSelect,
        builder: (context, state) {
          final extra = state.extra is MultiSelectArgs
              ? state.extra! as MultiSelectArgs
              : const MultiSelectArgs();
          return ContactMultiSelectScreen(args: extra);
        },
      ),
      GoRoute(
        name: RouteNames.mergeContacts,
        path: RoutePaths.mergeContacts,
        builder: (context, state) => const MergeContactsScreen(),
      ),
      GoRoute(
        name: RouteNames.deviceImport,
        path: RoutePaths.deviceImport,
        builder: (context, state) => const DeviceContactImportScreen(),
      ),
      GoRoute(
        name: RouteNames.addPeople,
        path: RoutePaths.addPeople,
        builder: (context, state) {
          final extra = state.extra is AddPeopleArgs
              ? state.extra! as AddPeopleArgs
              : const AddPeopleArgs();
          return AddPeopleScreen(args: extra);
        },
      ),
    ],
    errorBuilder: (context, state) =>
        LinkRecoveryScreen(attemptedLocation: state.uri.toString()),
  );
  ref.onDispose(() {
    router.dispose();
  });
  return router;
});

/// Keeps one router alive while redirects refresh only across access gates.
/// Onboarding draft/checkpoint updates intentionally do not notify it.
final class _StartupRouterRefresh {
  static bool requiresRefresh(StartupState? previous, StartupState next) {
    if (previous == null || previous.runtimeType != next.runtimeType) {
      return true;
    }
    if (previous is StartupReady && next is StartupReady) {
      return previous.profile.id != next.profile.id;
    }
    return false;
  }
}

/// M7 section 8 — resolve the typed follow-up provenance carried by the
/// Contact Detail chooser.
///
/// Only an explicit [ContactFollowUpCreationIntent] counts.  Anything else
/// (null, an unknown object type, or a blank Contact id) fails closed to
/// ordinary creation so an unforeseen `extra` can never invent provenance.
String? _followUpContactIdOf(GoRouterState state) {
  final extra = state.extra;
  if (extra is! ContactFollowUpCreationIntent) {
    return null;
  }
  return extra.isValid ? extra.contactId : null;
}

PlannerDate _periodStart(String? raw, PlannerDate today, Ref ref) {
  if (raw != null) {
    try {
      return PlannerDate.parse(raw);
    } on FormatException {
      // Fall through to the truthful current-week context.
    }
  }
  return resolveWeek(
    date: today,
    startDay: ref.read(startOfWeekProvider),
  ).start;
}
