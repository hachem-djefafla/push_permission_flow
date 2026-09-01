/// What is durably known about prior operating-system prompt requests.
enum PushPermissionRequestStatus {
  /// No request is known to have been initiated.
  notRequested,

  /// A request began, but whether it reached the operating system is unknown.
  ///
  /// This write-ahead state survives gateway failures and process termination.
  outcomeUnknown,

  /// The gateway request completed and returned a platform observation.
  completed,
}

/// The durable history needed to resolve permission observations.
final class PushPermissionHistory {
  /// Creates permission history with safe first-run defaults.
  const PushPermissionHistory({
    this.wasDeferred = false,
    this.osPromptRequestStatus = PushPermissionRequestStatus.notRequested,
    this.hasObservedConclusiveStatus = false,
  });

  /// Whether the user most recently deferred the application's explanation.
  final bool wasDeferred;

  /// What is known about attempts to request the operating-system permission.
  final PushPermissionRequestStatus osPromptRequestStatus;

  /// Whether an authorized, provisional, or definitive denied status was seen.
  ///
  /// This handles platforms that later report an ambiguous denied-looking
  /// value after an initially conclusive or pre-granted state.
  final bool hasObservedConclusiveStatus;

  /// Returns a copy with the supplied fields replaced.
  PushPermissionHistory copyWith({
    bool? wasDeferred,
    PushPermissionRequestStatus? osPromptRequestStatus,
    bool? hasObservedConclusiveStatus,
  }) => PushPermissionHistory(
    wasDeferred: wasDeferred ?? this.wasDeferred,
    osPromptRequestStatus: osPromptRequestStatus ?? this.osPromptRequestStatus,
    hasObservedConclusiveStatus:
        hasObservedConclusiveStatus ?? this.hasObservedConclusiveStatus,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PushPermissionHistory &&
          wasDeferred == other.wasDeferred &&
          osPromptRequestStatus == other.osPromptRequestStatus &&
          hasObservedConclusiveStatus == other.hasObservedConclusiveStatus;

  @override
  int get hashCode => Object.hash(
    wasDeferred,
    osPromptRequestStatus,
    hasObservedConclusiveStatus,
  );

  @override
  String toString() =>
      'PushPermissionHistory('
      'wasDeferred: $wasDeferred, '
      'osPromptRequestStatus: $osPromptRequestStatus, '
      'hasObservedConclusiveStatus: $hasObservedConclusiveStatus)';
}
