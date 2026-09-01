/// The application-facing state of a push notification permission flow.
enum PushPermissionState {
  /// No application or operating-system decision has been made.
  notDetermined,

  /// The user postponed the application's permission explanation.
  deferred,

  /// An operating-system permission request is in progress.
  requesting,

  /// The operating system fully authorized notifications.
  authorized,

  /// The operating system provisionally authorized notifications.
  provisional,

  /// The operating system denied notifications.
  denied,

  /// The permission state cannot currently be determined or used safely.
  unavailable,
}

/// Convenience capabilities for a [PushPermissionState].
extension PushPermissionStateX on PushPermissionState {
  /// Whether this state permits push notifications to be delivered.
  bool get allowsPush =>
      this == PushPermissionState.authorized ||
      this == PushPermissionState.provisional;
}
