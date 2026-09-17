import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rmplanner/features/privacy/application/privacy_providers.dart';
import 'package:rmplanner/features/privacy/domain/permission_summary.dart';

/// Session-scoped half of the ONE first-entry Location education law.
///
/// The DURABLE half already exists in the shipped privacy architecture:
/// `PermissionAudits.requestedByApp` records that the app really asked Android.
/// This notifier only supplies the missing in-session fact, so a user who
/// answers "Not now" is never nagged again on a later Maps tab switch.
///
/// It is deliberately NOT persisted: adding a column would be a schema change,
/// and the durable decision is already covered once the user answers either
/// way (an ask is recorded, a grant is visible to the operating system).
final mapsLocationEducationProvider =
    NotifierProvider<MapsLocationEducationController, bool>(
      MapsLocationEducationController.new,
    );

final class MapsLocationEducationController extends Notifier<bool> {
  @override
  bool build() => false;

  void markPresented() {
    if (!state) {
      state = true;
    }
  }
}

/// True only when Maps must present the one first-entry Location education.
///
/// Due when Android's Location permission for this app is still `denied` AND
/// the durable audit proves the app has never asked
/// ([PermissionState.notRequested]) AND this session has not presented it.
///
/// A granted permission, a permanently denied one, or a permission the app has
/// already asked about is NEVER due — each of those already has its own
/// truthful flow (the blue dot, or the Android Settings route).
///
/// Every dependency read is fail-safe: when the app-root privacy or permission
/// gateway override is unavailable, the answer is NOT due, so Maps can never
/// stall, throw, or block the base map on an education prompt.
final mapsLocationEducationDueProvider = FutureProvider<bool>((ref) async {
  if (ref.watch(mapsLocationEducationProvider)) {
    return false;
  }
  final OperatingSystemPermissionState osState;
  try {
    osState = await ref
        .read(permissionGatewayProvider)
        .status(OptionalPermission.foregroundLocation);
  } on Object {
    return false;
  }
  if (osState != OperatingSystemPermissionState.denied) {
    return false;
  }
  try {
    final audit = await ref
        .read(privacyRepositoryProvider)
        .readPermissionAudit(OptionalPermission.foregroundLocation);
    if (audit.requestedByApp || audit.everGranted) {
      return false;
    }
  } on Object {
    return false;
  }
  return true;
});
