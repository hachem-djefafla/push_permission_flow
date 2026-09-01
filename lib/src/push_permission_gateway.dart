import 'push_permission_os_status.dart';

/// Performs platform-specific notification permission operations.
///
/// Implementations adapt a platform API or plugin to the generic
/// [PushPermissionOsStatus] model. They must return
/// [PushPermissionOsStatus.notDeterminedOrDenied] when the platform observation
/// is genuinely ambiguous rather than guessing from application history.
abstract interface class PushPermissionGateway {
  /// Reads the current platform permission observation without prompting.
  Future<PushPermissionOsStatus> getStatus();

  /// Requests notification permission and returns the resulting observation.
  Future<PushPermissionOsStatus> requestPermission();
}
