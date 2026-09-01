/// A platform observation reported by a permission gateway.
///
/// Unlike the application-facing state, these values do not contain decisions
/// such as deferring an explanation.
enum PushPermissionOsStatus {
  /// The operating system reports that no permission decision has been made.
  notDetermined,

  /// The platform cannot distinguish an unrequested permission from denial.
  ///
  /// This primarily models Android 13+ APIs that return a denied-looking value
  /// both before notification permission is requested and after denial.
  notDeterminedOrDenied,

  /// The operating system fully authorized notifications.
  authorized,

  /// The operating system provisionally authorized notifications.
  provisional,

  /// The operating system definitively denied notifications.
  denied,

  /// Notification permission is unsupported or could not be observed safely.
  unavailable,
}
