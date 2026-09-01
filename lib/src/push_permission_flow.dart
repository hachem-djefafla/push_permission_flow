import 'dart:async';

import 'push_permission_gateway.dart';
import 'push_permission_history.dart';
import 'push_permission_ledger.dart';
import 'push_permission_os_status.dart';
import 'push_permission_state.dart';

/// Coordinates notification permission state and durable resolution history.
///
/// The flow is framework-neutral. A consuming application owns its platform
/// gateway, durable ledger, explanation UI, system-settings navigation, and
/// lifecycle integration. Call [refresh] when the application starts and when
/// it returns from system settings.
final class PushPermissionFlow {
  /// Creates a permission flow backed by [gateway] and [ledger].
  PushPermissionFlow({
    required PushPermissionGateway gateway,
    required PushPermissionLedger ledger,
  }) : _gateway = gateway,
       _ledger = ledger;

  final PushPermissionGateway _gateway;
  final PushPermissionLedger _ledger;
  final StreamController<PushPermissionState> _stateController =
      StreamController<PushPermissionState>.broadcast();

  Future<void> _operationTail = Future<void>.value();
  Future<PushPermissionState>? _requestInFlight;
  PushPermissionState _state = PushPermissionState.notDetermined;
  bool _disposed = false;

  /// The latest state resolved by this instance.
  ///
  /// It is [PushPermissionState.notDetermined] until an operation resolves a
  /// different state. Read this before subscribing to [stateChanges], because
  /// the stream does not replay it.
  PushPermissionState get state => _state;

  /// Distinct state changes emitted after this flow is constructed.
  ///
  /// This is a broadcast stream and does not replay [state].
  Stream<PushPermissionState> get stateChanges => _stateController.stream;

  /// Re-reads durable history and the current platform observation.
  Future<PushPermissionState> refresh() => _enqueue(_refresh);

  /// Records that the user postponed the application's permission explanation.
  ///
  /// Deferral is recorded only while the current permission remains unresolved.
  Future<PushPermissionState> deferPermission() => _enqueue(_deferPermission);

  /// Requests operating-system notification permission when it is safe to do so.
  ///
  /// Concurrent calls share one operation. By default, an earlier request with
  /// an unknown outcome is not repeated. Set [retryIfUncertain] only in response
  /// to an explicit retry decision; the earlier request might have reached the
  /// operating system even though its result was not observed.
  Future<PushPermissionState> requestPermission({
    bool retryIfUncertain = false,
  }) {
    _ensureActive();
    final existing = _requestInFlight;
    if (existing != null) return existing;

    late final Future<PushPermissionState> tracked;
    tracked =
        _enqueue(
          () => _requestPermission(retryIfUncertain: retryIfUncertain),
        ).whenComplete(() {
          if (identical(_requestInFlight, tracked)) {
            _requestInFlight = null;
          }
        });
    _requestInFlight = tracked;
    return tracked;
  }

  /// Closes [stateChanges] and rejects future operations.
  ///
  /// Disposal is idempotent. Operations already interacting with a gateway
  /// cannot be cancelled, but they will not emit after disposal.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_stateController.close());
  }

  Future<PushPermissionState> _refresh() async {
    final observation = await _observe();
    return _setState(observation?.state ?? PushPermissionState.unavailable);
  }

  Future<PushPermissionState> _deferPermission() async {
    final observation = await _observe();
    if (observation == null) {
      return _setState(PushPermissionState.unavailable);
    }
    if (observation.state != PushPermissionState.notDetermined &&
        observation.state != PushPermissionState.deferred) {
      return _setState(observation.state);
    }

    try {
      await _ledger.write(observation.history.copyWith(wasDeferred: true));
      return _setState(PushPermissionState.deferred);
    } on Object {
      return _setState(PushPermissionState.unavailable);
    }
  }

  Future<PushPermissionState> _requestPermission({
    required bool retryIfUncertain,
  }) async {
    final observation = await _observe();
    if (observation == null) {
      return _setState(PushPermissionState.unavailable);
    }

    final isOrdinarilyRequestable =
        observation.state == PushPermissionState.notDetermined ||
        observation.state == PushPermissionState.deferred;
    final isExplicitUncertainRetry =
        retryIfUncertain &&
        observation.osStatus == PushPermissionOsStatus.notDeterminedOrDenied &&
        observation.history.osPromptRequestStatus ==
            PushPermissionRequestStatus.outcomeUnknown &&
        !observation.history.hasObservedConclusiveStatus;
    if (!isOrdinarilyRequestable && !isExplicitUncertainRetry) {
      return _setState(observation.state);
    }

    final pendingHistory = observation.history.copyWith(
      wasDeferred: false,
      osPromptRequestStatus: PushPermissionRequestStatus.outcomeUnknown,
    );
    try {
      await _ledger.write(pendingHistory);
    } on Object {
      return _setState(PushPermissionState.unavailable);
    }

    _setState(PushPermissionState.requesting);
    final PushPermissionOsStatus result;
    try {
      result = await _gateway.requestPermission();
    } on Object {
      return _setState(PushPermissionState.unavailable);
    }

    final completedHistory = _historyAfterRequest(pendingHistory, result);
    try {
      await _ledger.write(completedHistory);
    } on Object {
      return _setState(PushPermissionState.unavailable);
    }
    return _setState(_resolve(result, completedHistory));
  }

  Future<_Observation?> _observe() async {
    try {
      final osStatus = await _gateway.getStatus();
      if (osStatus == PushPermissionOsStatus.unavailable) {
        return const _Observation(
          osStatus: PushPermissionOsStatus.unavailable,
          history: PushPermissionHistory(),
          state: PushPermissionState.unavailable,
        );
      }

      final history = await _ledger.read();
      final normalized = _historyAfterObservation(history, osStatus);
      if (normalized != history) {
        await _ledger.write(normalized);
      }
      return _Observation(
        osStatus: osStatus,
        history: normalized,
        state: _resolve(osStatus, normalized),
      );
    } on Object {
      return null;
    }
  }

  PushPermissionState _setState(PushPermissionState next) {
    if (_disposed || next == _state) return next;
    _state = next;
    _stateController.add(next);
    return next;
  }

  Future<T> _enqueue<T>(Future<T> Function() operation) {
    _ensureActive();
    final completer = Completer<T>();
    _operationTail = _operationTail.then((_) async {
      if (_disposed) {
        completer.completeError(_disposedError());
        return;
      }
      try {
        completer.complete(await operation());
      } on Object catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  void _ensureActive() {
    if (_disposed) throw _disposedError();
  }

  StateError _disposedError() => StateError('PushPermissionFlow is disposed.');
}

final class _Observation {
  const _Observation({
    required this.osStatus,
    required this.history,
    required this.state,
  });

  final PushPermissionOsStatus osStatus;
  final PushPermissionHistory history;
  final PushPermissionState state;
}

PushPermissionHistory _historyAfterObservation(
  PushPermissionHistory history,
  PushPermissionOsStatus status,
) {
  if (!_isConclusive(status)) return history;
  return history.copyWith(
    wasDeferred: false,
    osPromptRequestStatus:
        history.osPromptRequestStatus ==
            PushPermissionRequestStatus.outcomeUnknown
        ? PushPermissionRequestStatus.completed
        : history.osPromptRequestStatus,
    hasObservedConclusiveStatus: true,
  );
}

PushPermissionHistory _historyAfterRequest(
  PushPermissionHistory history,
  PushPermissionOsStatus status,
) => switch (status) {
  PushPermissionOsStatus.notDetermined => history.copyWith(
    osPromptRequestStatus: PushPermissionRequestStatus.notRequested,
  ),
  PushPermissionOsStatus.unavailable => history,
  PushPermissionOsStatus.authorized ||
  PushPermissionOsStatus.provisional ||
  PushPermissionOsStatus.denied => history.copyWith(
    osPromptRequestStatus: PushPermissionRequestStatus.completed,
    hasObservedConclusiveStatus: true,
  ),
  PushPermissionOsStatus.notDeterminedOrDenied => history.copyWith(
    osPromptRequestStatus: PushPermissionRequestStatus.completed,
  ),
};

bool _isConclusive(PushPermissionOsStatus status) =>
    status == PushPermissionOsStatus.authorized ||
    status == PushPermissionOsStatus.provisional ||
    status == PushPermissionOsStatus.denied;

PushPermissionState _resolve(
  PushPermissionOsStatus status,
  PushPermissionHistory history,
) => switch (status) {
  PushPermissionOsStatus.authorized => PushPermissionState.authorized,
  PushPermissionOsStatus.provisional => PushPermissionState.provisional,
  PushPermissionOsStatus.denied => PushPermissionState.denied,
  PushPermissionOsStatus.unavailable => PushPermissionState.unavailable,
  PushPermissionOsStatus.notDetermined =>
    history.wasDeferred
        ? PushPermissionState.deferred
        : PushPermissionState.notDetermined,
  PushPermissionOsStatus.notDeterminedOrDenied =>
    history.hasObservedConclusiveStatus ||
            history.osPromptRequestStatus ==
                PushPermissionRequestStatus.completed
        ? PushPermissionState.denied
        : history.osPromptRequestStatus ==
              PushPermissionRequestStatus.outcomeUnknown
        ? PushPermissionState.unavailable
        : history.wasDeferred
        ? PushPermissionState.deferred
        : PushPermissionState.notDetermined,
};
