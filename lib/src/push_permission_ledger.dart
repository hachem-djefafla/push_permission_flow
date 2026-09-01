import 'push_permission_history.dart';

/// Persists the history used to resolve ambiguous permission observations.
///
/// Implementations should replace the complete history atomically when
/// possible. When no history exists, [read] must return
/// `const PushPermissionHistory()`.
abstract interface class PushPermissionLedger {
  /// Reads the last durably stored permission history.
  Future<PushPermissionHistory> read();

  /// Replaces the durably stored permission history.
  Future<void> write(PushPermissionHistory history);
}
