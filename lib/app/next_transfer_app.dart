import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rmplanner/app/m5_app_splash.dart';
import 'package:rmplanner/app/notification_open_presentation.dart';
import 'package:rmplanner/app/router/app_router.dart';
import 'package:rmplanner/app/router/route_names.dart';
import 'package:rmplanner/app/theme/app_theme.dart';
import 'package:rmplanner/core/notifications/notification_payload.dart';
import 'package:rmplanner/core/platform/app_environment.dart';
import 'package:rmplanner/features/goals/application/goal_providers.dart';
import 'package:rmplanner/features/indicators/application/indicator_providers.dart';
import 'package:rmplanner/features/notifications/application/launcher_badge_providers.dart';
import 'package:rmplanner/features/notifications/application/notification_privacy_refresh_provider.dart';
import 'package:rmplanner/features/notifications/application/notification_providers.dart';
import 'package:rmplanner/features/planner/application/calendar_event_providers.dart';
import 'package:rmplanner/features/planner/application/calendar_event_repository.dart';
import 'package:rmplanner/features/planner/application/planner_providers.dart';
import 'package:rmplanner/features/planner/domain/calendar_event.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:rmplanner/features/privacy/application/privacy_providers.dart';
import 'package:rmplanner/features/privacy/application/privacy_services.dart';
import 'package:rmplanner/features/settings/application/appearance_providers.dart';
import 'package:rmplanner/features/settings/application/appearance_repository.dart';
import 'package:rmplanner/features/settings/application/start_of_week_providers.dart';
import 'package:rmplanner/features/startup/application/startup_providers.dart';
import 'package:rmplanner/features/startup/domain/startup_state.dart';
import 'package:rmplanner/features/weekly_planning/application/weekly_planning_providers.dart';
import 'package:rmplanner/features/weekly_planning/domain/weekly_plan.dart';

final appEnvironmentProvider = Provider<AppEnvironment>((ref) {
  throw StateError('AppEnvironment must be overridden at the app root');
});

final class NextTransferApp extends ConsumerStatefulWidget {
  const NextTransferApp({super.key});

  @override
  ConsumerState<NextTransferApp> createState() => _NextTransferAppState();
}

final class _NextTransferAppState extends ConsumerState<NextTransferApp>
    with WidgetsBindingObserver {
  late final PrivacyBackgroundSession _backgroundSession;
  late PlannerDate _lastResolvedDate;
  StreamSubscription<NotificationResponseIntent>? _notificationResponses;
  ProviderSubscription<StartupState>? _badgeStartupSubscription;
  String? _badgedProfileId;
  NotificationResponseIntent? _pendingNotification;
  Timer? _reminderDateTimer;

  @override
  void initState() {
    super.initState();
    _backgroundSession = PrivacyBackgroundSession(
      clock: ref.read(monotonicClockProvider),
    );
    _lastResolvedDate = ref.read(plannerDateSourceProvider).today();
    final responses = ref.read(notificationResponseControllerProvider);
    _notificationResponses = responses.responses.listen(_routeNotification);
    _badgeStartupSubscription = ref.listenManual<StartupState>(
      startupControllerProvider,
      (_, next) {
        if (next is StartupReady) {
          unawaited(_recoverReminders());
          final pending = _pendingNotification;
          _pendingNotification = null;
          if (pending != null) unawaited(_routeNotification(pending));
        }
        if (next is StartupReady && _badgedProfileId != next.profile.id) {
          _badgedProfileId = next.profile.id;
          unawaited(
            ref.read(launcherBadgeRefreshProvider)().catchError((Object _) {}),
          );
        }
      },
      fireImmediately: true,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final initial = responses.takeInitial();
      if (initial != null) unawaited(_routeNotification(initial));
    });
    WidgetsBinding.instance.addObserver(this);
    _scheduleReminderDateBoundary();
  }

  @override
  void dispose() {
    _backgroundSession.dispose();
    _reminderDateTimer?.cancel();
    unawaited(_notificationResponses?.cancel() ?? Future<void>.value());
    _badgeStartupSubscription?.close();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _recoverReminders() async {
    if (!mounted || ref.read(startupControllerProvider) is! StartupReady) {
      return;
    }
    // Section 28: a DURABLE dirty marker turns into one bounded KEEP recovery
    // job, so a repair that commits with a mutation survives the app being
    // killed mid-pass.  KEEP never cancels a recovery that is already running.
    // No marker means nothing to repair and no OS work is scheduled.
    try {
      final startup = ref.read(startupControllerProvider);
      final profileId =
          ref.read(reminderRuntimeProfileIdProvider) ??
          (startup is StartupReady ? startup.profile.id : null);
      if (profileId != null) {
        await ref
            .read(reminderRecoveryCoordinatorProvider)
            .enqueueIfDirty(profileId: profileId);
      }
    } on Object {
      // Recovery enqueue is opportunistic; the in-process pass below and the
      // native boot/time receiver both remain available.
    }
    try {
      await ref.read(reconcileRemindersProvider)();
    } on Object {
      // A later lifecycle/source/preference trigger retries canonical recovery.
    }
  }

  void _scheduleReminderDateBoundary() {
    _reminderDateTimer?.cancel();
    final now = DateTime.now();
    final midnight = DateTime(now.year, now.month, now.day + 1);
    _reminderDateTimer = Timer(midnight.difference(now), () {
      unawaited(_recoverReminders());
      _scheduleReminderDateBoundary();
    });
  }

  bool _notificationProfileReady(String profileId) {
    if (!mounted) return false;
    final startup = ref.read(startupControllerProvider);
    return startup is StartupReady && startup.profile.id == profileId;
  }

  Future<void> _routeNotification(NotificationResponseIntent intent) async {
    try {
      await _resolveNotificationRoute(intent);
    } on Object {
      // Missing/deleted/invalid source and repository failures are safe no-ops.
    }
  }

  Future<void> _resolveNotificationRoute(
    NotificationResponseIntent intent,
  ) async {
    if (intent.action == NotificationResponseAction.snooze) {
      // Snooze is DEFERRED (contract section 48).  Response routing is one of
      // the required kill-switch entry points: a legacy or forged-but-valid
      // Snooze intent terminates here without scheduling or mutating anything.
      return;
    }
    final startup = ref.read(startupControllerProvider);
    if (startup is! StartupReady) {
      _pendingNotification = intent;
      return;
    }
    if (startup.profile.id != intent.profileId) {
      return;
    }
    final router = ref.read(appRouterProvider);
    switch (intent.sourceKind) {
      case NotificationSourceKind.calendarEvent:
        final occurrenceId = intent.occurrenceId;
        if (occurrenceId == null) return;
        final repository = ref.read(calendarEventRepositoryProvider);
        if (repository is! CalendarEventOccurrenceIdLookup) return;
        final lookup = repository as CalendarEventOccurrenceIdLookup;
        final occurrence = await lookup.readOccurrenceById(
          profileId: intent.profileId,
          eventId: intent.sourceId,
          occurrenceId: occurrenceId,
        );
        if (occurrence != null &&
            occurrence.status == CalendarEventStatus.scheduled &&
            _notificationProfileReady(intent.profileId)) {
          // Owner-approved planner-first UX: become the Planner destination
          // (inside the MainShell, exactly like a normal Planner visit), then
          // present the SAME canonical Event preview used by normal Planner
          // taps. Canonical occurrence identity is re-read from the
          // repository — never guessed from the payload.
          router.go(RoutePaths.planner);
          // One frame later the shell exists; capture the navigator via a
          // microtask-safe read so the overlay context outlives the async gap.
          await Future<void>.delayed(Duration.zero);
          final navigator = _navigatorAfterAwait(intent.profileId);
          if (navigator == null || !navigator.mounted) return;
          await showNotificationEventPreview(
            navigator.context,
            eventId: occurrence.eventId,
            originalDate: occurrence.originalDate,
            initialHeading: occurrence.displayTitle,
          );
        }
      case NotificationSourceKind.task:
        final task = await ref
            .read(plannerRepositoryProvider)
            .readTask(profileId: intent.profileId, taskId: intent.sourceId);
        if (task != null && _notificationProfileReady(intent.profileId)) {
          // Planner-first UX for Tasks as well: Planner destination first,
          // then the shared Task preview presenter.
          router.go(RoutePaths.planner);
          await Future<void>.delayed(Duration.zero);
          final navigator = _navigatorAfterAwait(intent.profileId);
          if (navigator == null || !navigator.mounted) return;
          await showNotificationTaskPreview(navigator.context, taskId: task.id);
        }
      case NotificationSourceKind.weeklyReview:
        final plan = await ref
            .read(weeklyPlanningRepositoryProvider)
            .readPlan(profileId: intent.profileId, planId: intent.sourceId);
        if (plan == null || !_notificationProfileReady(intent.profileId)) {
          return;
        }
        final today = await ref
            .read(weeklyPlanningRepositoryProvider)
            .todayForProfile(intent.profileId);
        if (plan.effectiveState(today) != WeeklyPlanState.reviewDue) {
          return;
        }
        router.go(RoutePaths.weeklyPlanningFor(plan.period.start));
      case NotificationSourceKind.awaitingReport:
        final occurrenceId = intent.occurrenceId;
        if (occurrenceId == null) return;
        final repository = ref.read(calendarEventRepositoryProvider);
        if (repository is! CalendarEventOccurrenceIdLookup) return;
        final occurrence = await (repository as CalendarEventOccurrenceIdLookup)
            .readOccurrenceById(
              profileId: intent.profileId,
              eventId: intent.sourceId,
              occurrenceId: occurrenceId,
            );
        if (occurrence == null ||
            !_notificationProfileReady(intent.profileId)) {
          return;
        }
        final today = await ref
            .read(weeklyPlanningRepositoryProvider)
            .todayForProfile(intent.profileId);
        if (!occurrence.isAwaitingReport(
          nowUtc: DateTime.now().toUtc(),
          displayToday: today,
        )) {
          return;
        }
        router.go(RoutePaths.planner);
        await Future<void>.delayed(Duration.zero);
        final navigator = _navigatorAfterAwait(intent.profileId);
        if (navigator == null || !navigator.mounted) return;
        await showNotificationEventPreview(
          navigator.context,
          eventId: occurrence.eventId,
          originalDate: occurrence.originalDate,
          initialHeading: occurrence.displayTitle,
        );
      default:
        return;
    }
  }

  /// Post-await readiness recheck (contract section 19, forensic F06).
  ///
  /// `router.go` plus a zero-duration delay yields a frame, and Privacy Lock can
  /// re-lock the app in that gap.  The pending notification must therefore be
  /// re-validated against the CURRENT mounted state and the CURRENT ready
  /// profile before any preview is presented; a stale resolution is a safe
  /// no-op rather than a presentation over a locked app.
  NavigatorState? _navigatorAfterAwait(String profileId) {
    if (!_notificationProfileReady(profileId)) return null;
    final navigator = appRootNavigatorKey.currentState;
    if (navigator == null || !navigator.mounted) return null;
    return navigator;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = ref.read(privacyControllerProvider.notifier);
    switch (state) {
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        // M1 (S01): unknown privacy provenance still requires protection, so
        // a fallback "disabled" value cannot skip the accepted session timer.
        if (ref.read(privacyControllerProvider).requiresProtection) {
          _backgroundSession.enterBackground(() {
            _relockForBackground(controller);
          });
        }
      case AppLifecycleState.resumed:
        _scheduleReminderDateBoundary();
        if (_backgroundSession.resume()) {
          _relockForBackground(controller);
        }
        if (ref.read(startupControllerProvider) is StartupReady) {
          unawaited(_recoverReminders());
          final resolvedDate = ref.read(plannerDateSourceProvider).today();
          if (resolvedDate != _lastResolvedDate) {
            _lastResolvedDate = resolvedDate;
            // A real local-date boundary can change Home's active period.
            // Preserve confirmed provider values while re-resolving instead
            // of rebuilding every provider on every same-day resume.
            ref.invalidate(plannerDateSourceProvider);
            unawaited(ref.read(startOfWeekProvider.notifier).refresh());
            ref.invalidate(goalPlanningProvider);
            ref.invalidate(weeklyPlanEstablishedProvider);
            unawaited(
              ref.read(homeIndicatorControllerProvider.notifier).refresh(),
            );
          }
        }
    }
  }

  void _relockForBackground(PrivacyController controller) {
    final relocked = controller.lockForBackground();
    if (relocked) {
      unawaited(ref.read(startupControllerProvider.notifier).initialize());
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(privacyControllerProvider);
    // Pack B2: the device Appearance drives ThemeMode.  The notifier is
    // seeded synchronously from the pre-runApp read (main.dart), so the first
    // build already has the persisted mode.  Changing it rebuilds the
    // presentation layer only — no Goal/Planner domain provider is touched.
    final appearance = ref.watch(appearanceProvider);
    final themeColor = ref.watch(themeColorProvider);
    final router = ref.watch(appRouterProvider);
    final environment = ref.watch(appEnvironmentProvider);

    return MaterialApp.router(
      title: 'Next Transfer',
      debugShowCheckedModeBanner: environment.showDebugBanner,
      // B2-CORRECTION: Appearance Mode chooses brightness; Theme Color
      // chooses the semantic palette.  Both are seeded synchronously before
      // runApp, so the first build already has the persisted pair.  Changing
      // either rebuilds the presentation layer only — no Goal/Planner domain
      // provider is touched.
      theme: AppTheme.light(themeColor),
      darkTheme: AppTheme.dark(themeColor),
      themeMode: switch (appearance) {
        AppearanceMode.system => ThemeMode.system,
        AppearanceMode.light => ThemeMode.light,
        AppearanceMode.dark => ThemeMode.dark,
      },
      // B2-CORRECTION: explicit SystemUiOverlayStyle from the ACTIVE
      // ThemeData.  The Flutter presets hard-code a black navigation bar with
      // light icons in BOTH themes, which Android 15+ contrast enforcement
      // turns into a black region in Light.  Here Light gets the semantic
      // app/nav surface with dark icons and disabled contrast enforcement;
      // Dark keeps the dark appearance.  Status bar stays transparent with
      // brightness-correct icons.  The native splash stays system-following.
      builder: (context, child) => AnnotatedRegion<SystemUiOverlayStyle>(
        value: Theme.of(context).brightness == Brightness.dark
            ? SystemUiOverlayStyle(
                statusBarColor: Colors.transparent,
                statusBarIconBrightness: Brightness.light,
                statusBarBrightness: Brightness.dark,
                systemNavigationBarColor: const Color(0xFF101113),
                systemNavigationBarIconBrightness: Brightness.light,
                systemNavigationBarContrastEnforced: false,
              )
            : SystemUiOverlayStyle(
                statusBarColor: Colors.transparent,
                statusBarIconBrightness: Brightness.dark,
                statusBarBrightness: Brightness.light,
                systemNavigationBarColor: Theme.of(
                  context,
                ).colorScheme.surfaceContainer,
                systemNavigationBarIconBrightness: Brightness.dark,
                systemNavigationBarContrastEnforced: false,
              ),
        child: M5AppSplashGate(child: child!),
      ),
      routerConfig: router,
    );
  }
}
