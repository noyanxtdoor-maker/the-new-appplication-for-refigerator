/// Projects one profile's UNREPORTED backlog size to the platform.
///
/// The production Android implementation shows the count both as the launcher
/// badge and as a silent, ongoing app-status notification.  Because that
/// notification is tappable, the count is always profile-scoped: the tap
/// carries the canonical response intent (open the Unreported hub) for THIS
/// profile, never a bare number with no destination.
abstract interface class LauncherBadgeGateway {
  Future<void> setCount({required String profileId, required int count});
}
