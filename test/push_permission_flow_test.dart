import 'dart:async';

import 'package:push_permission_flow/push_permission_flow.dart';
import 'package:test/test.dart';

void main() {
  group('PushPermissionState.allowsPush', () {
    test('allows authorized and provisional states only', () {
      for (final state in PushPermissionState.values) {
        expect(
          state.allowsPush,
          state == PushPermissionState.authorized ||
              state == PushPermissionState.provisional,
          reason: '$state',
        );
      }
    });
  });

  group('PushPermissionHistory', () {
    test('has safe defaults and value semantics', () {
      const first = PushPermissionHistory();
      const second = PushPermissionHistory();

      expect(first, second);
      expect(first.hashCode, second.hashCode);
      expect(first.wasDeferred, isFalse);
      expect(
        first.osPromptRequestStatus,
        PushPermissionRequestStatus.notRequested,
      );
      expect(first.hasObservedConclusiveStatus, isFalse);
    });

    test('copyWith replaces selected fields', () {
      const initial = PushPermissionHistory(wasDeferred: true);
      final changed = initial.copyWith(
        osPromptRequestStatus: PushPermissionRequestStatus.completed,
        hasObservedConclusiveStatus: true,
      );

      expect(
        changed,
        const PushPermissionHistory(
          wasDeferred: true,
          osPromptRequestStatus: PushPermissionRequestStatus.completed,
          hasObservedConclusiveStatus: true,
        ),
      );
    });
  });

  group('resolution', () {
    final cases = <_ResolutionCase>[
      const _ResolutionCase(
        'authorized ignores history',
        PushPermissionOsStatus.authorized,
        PushPermissionHistory(wasDeferred: true),
        PushPermissionState.authorized,
      ),
      const _ResolutionCase(
        'provisional allows quiet push',
        PushPermissionOsStatus.provisional,
        PushPermissionHistory(wasDeferred: true),
        PushPermissionState.provisional,
      ),
      const _ResolutionCase(
        'definitive denial overrides deferral',
        PushPermissionOsStatus.denied,
        PushPermissionHistory(wasDeferred: true),
        PushPermissionState.denied,
      ),
      const _ResolutionCase(
        'unavailable ignores history',
        PushPermissionOsStatus.unavailable,
        PushPermissionHistory(wasDeferred: true),
        PushPermissionState.unavailable,
      ),
      const _ResolutionCase(
        'not determined stays not determined',
        PushPermissionOsStatus.notDetermined,
        PushPermissionHistory(),
        PushPermissionState.notDetermined,
      ),
      const _ResolutionCase(
        'not determined respects deferral',
        PushPermissionOsStatus.notDetermined,
        PushPermissionHistory(wasDeferred: true),
        PushPermissionState.deferred,
      ),
      const _ResolutionCase(
        'first ambiguous observation is not determined',
        PushPermissionOsStatus.notDeterminedOrDenied,
        PushPermissionHistory(),
        PushPermissionState.notDetermined,
      ),
      const _ResolutionCase(
        'ambiguous observation respects deferral',
        PushPermissionOsStatus.notDeterminedOrDenied,
        PushPermissionHistory(wasDeferred: true),
        PushPermissionState.deferred,
      ),
      const _ResolutionCase(
        'completed request makes ambiguity denied',
        PushPermissionOsStatus.notDeterminedOrDenied,
        PushPermissionHistory(
          osPromptRequestStatus: PushPermissionRequestStatus.completed,
        ),
        PushPermissionState.denied,
      ),
      const _ResolutionCase(
        'conclusive history makes ambiguity denied',
        PushPermissionOsStatus.notDeterminedOrDenied,
        PushPermissionHistory(hasObservedConclusiveStatus: true),
        PushPermissionState.denied,
      ),
      const _ResolutionCase(
        'unknown request outcome makes ambiguity unavailable',
        PushPermissionOsStatus.notDeterminedOrDenied,
        PushPermissionHistory(
          wasDeferred: true,
          osPromptRequestStatus: PushPermissionRequestStatus.outcomeUnknown,
        ),
        PushPermissionState.unavailable,
      ),
    ];

    for (final testCase in cases) {
      test(testCase.name, () async {
        final flow = PushPermissionFlow(
          gateway: _Gateway(status: testCase.osStatus),
          ledger: _MemoryLedger(testCase.history),
        );
        addTearDown(flow.dispose);

        expect(await flow.refresh(), testCase.expected);
      });
    }

    test('conclusive observations clear stale deferral', () async {
      final ledger = _MemoryLedger(
        const PushPermissionHistory(wasDeferred: true),
      );
      final flow = PushPermissionFlow(
        gateway: _Gateway(status: PushPermissionOsStatus.authorized),
        ledger: ledger,
      );
      addTearDown(flow.dispose);

      await flow.refresh();

      expect(
        ledger.history,
        const PushPermissionHistory(hasObservedConclusiveStatus: true),
      );
    });

    test('pre-grant followed by ambiguous denial resolves as denied', () async {
      final gateway = _Gateway(status: PushPermissionOsStatus.authorized);
      final ledger = _MemoryLedger();
      final first = PushPermissionFlow(gateway: gateway, ledger: ledger);

      expect(await first.refresh(), PushPermissionState.authorized);
      first.dispose();
      gateway.status = PushPermissionOsStatus.notDeterminedOrDenied;
      final second = PushPermissionFlow(gateway: gateway, ledger: ledger);
      addTearDown(second.dispose);

      expect(await second.refresh(), PushPermissionState.denied);
    });
  });

  group('deferral', () {
    test('persists and survives a new flow instance', () async {
      final gateway = _Gateway(
        status: PushPermissionOsStatus.notDeterminedOrDenied,
      );
      final ledger = _MemoryLedger();
      final first = PushPermissionFlow(gateway: gateway, ledger: ledger);

      expect(await first.deferPermission(), PushPermissionState.deferred);
      first.dispose();
      final second = PushPermissionFlow(gateway: gateway, ledger: ledger);
      addTearDown(second.dispose);

      expect(await second.refresh(), PushPermissionState.deferred);
    });

    test('does not override an existing definitive denial', () async {
      final ledger = _MemoryLedger();
      final flow = PushPermissionFlow(
        gateway: _Gateway(status: PushPermissionOsStatus.denied),
        ledger: ledger,
      );
      addTearDown(flow.dispose);

      expect(await flow.deferPermission(), PushPermissionState.denied);
      expect(ledger.history.wasDeferred, isFalse);
    });

    test('write failure resolves unavailable', () async {
      final ledger = _MemoryLedger()..failWriteAt = 1;
      final flow = PushPermissionFlow(
        gateway: _Gateway(status: PushPermissionOsStatus.notDetermined),
        ledger: ledger,
      );
      addTearDown(flow.dispose);

      expect(await flow.deferPermission(), PushPermissionState.unavailable);
    });
  });

  group('requests', () {
    test(
      'writes unknown before prompting and completed after result',
      () async {
        final ledger = _MemoryLedger(
          const PushPermissionHistory(wasDeferred: true),
        );
        late PushPermissionHistory historyAtRequest;
        final gateway = _Gateway(
          status: PushPermissionOsStatus.notDeterminedOrDenied,
          requestResult: PushPermissionOsStatus.notDeterminedOrDenied,
          onRequest: () => historyAtRequest = ledger.history,
        );
        final flow = PushPermissionFlow(gateway: gateway, ledger: ledger);
        addTearDown(flow.dispose);

        expect(await flow.requestPermission(), PushPermissionState.denied);
        expect(
          historyAtRequest,
          const PushPermissionHistory(
            osPromptRequestStatus: PushPermissionRequestStatus.outcomeUnknown,
          ),
        );
        expect(
          ledger.history.osPromptRequestStatus,
          PushPermissionRequestStatus.completed,
        );
        expect(gateway.requestCalls, 1);
      },
    );

    test('supports provisional authorization', () async {
      final flow = PushPermissionFlow(
        gateway: _Gateway(
          status: PushPermissionOsStatus.notDetermined,
          requestResult: PushPermissionOsStatus.provisional,
        ),
        ledger: _MemoryLedger(),
      );
      addTearDown(flow.dispose);

      final state = await flow.requestPermission();

      expect(state, PushPermissionState.provisional);
      expect(state.allowsPush, isTrue);
    });

    test('definitive denial returned by the request is conclusive', () async {
      final ledger = _MemoryLedger();
      final flow = PushPermissionFlow(
        gateway: _Gateway(
          status: PushPermissionOsStatus.notDetermined,
          requestResult: PushPermissionOsStatus.denied,
        ),
        ledger: ledger,
      );
      addTearDown(flow.dispose);

      expect(await flow.requestPermission(), PushPermissionState.denied);
      expect(
        ledger.history,
        const PushPermissionHistory(
          osPromptRequestStatus: PushPermissionRequestStatus.completed,
          hasObservedConclusiveStatus: true,
        ),
      );
    });

    test('unavailable request result keeps its outcome uncertain', () async {
      final ledger = _MemoryLedger();
      final flow = PushPermissionFlow(
        gateway: _Gateway(
          status: PushPermissionOsStatus.notDetermined,
          requestResult: PushPermissionOsStatus.unavailable,
        ),
        ledger: ledger,
      );
      addTearDown(flow.dispose);

      expect(await flow.requestPermission(), PushPermissionState.unavailable);
      expect(
        ledger.history.osPromptRequestStatus,
        PushPermissionRequestStatus.outcomeUnknown,
      );
    });

    test('does not prompt from a final state', () async {
      for (final status in <PushPermissionOsStatus>[
        PushPermissionOsStatus.authorized,
        PushPermissionOsStatus.provisional,
        PushPermissionOsStatus.denied,
        PushPermissionOsStatus.unavailable,
      ]) {
        final gateway = _Gateway(status: status);
        final flow = PushPermissionFlow(
          gateway: gateway,
          ledger: _MemoryLedger(),
        );

        await flow.requestPermission();

        expect(gateway.requestCalls, 0, reason: '$status');
        flow.dispose();
      }
    });

    test('pre-prompt ledger failure prevents the gateway call', () async {
      final ledger = _MemoryLedger()..failWriteAt = 1;
      final gateway = _Gateway(status: PushPermissionOsStatus.notDetermined);
      final flow = PushPermissionFlow(gateway: gateway, ledger: ledger);
      addTearDown(flow.dispose);

      expect(await flow.requestPermission(), PushPermissionState.unavailable);
      expect(gateway.requestCalls, 0);
    });

    test('post-result ledger failure resolves unavailable', () async {
      final ledger = _MemoryLedger()..failWriteAt = 2;
      final flow = PushPermissionFlow(
        gateway: _Gateway(
          status: PushPermissionOsStatus.notDetermined,
          requestResult: PushPermissionOsStatus.authorized,
        ),
        ledger: ledger,
      );
      addTearDown(flow.dispose);

      expect(await flow.requestPermission(), PushPermissionState.unavailable);
      expect(
        ledger.history.osPromptRequestStatus,
        PushPermissionRequestStatus.outcomeUnknown,
      );
    });

    test('gateway failure preserves uncertainty instead of denial', () async {
      final gateway = _Gateway(
        status: PushPermissionOsStatus.notDeterminedOrDenied,
        requestError: StateError('plugin failed'),
      );
      final ledger = _MemoryLedger();
      final flow = PushPermissionFlow(gateway: gateway, ledger: ledger);
      addTearDown(flow.dispose);

      expect(await flow.requestPermission(), PushPermissionState.unavailable);
      expect(
        ledger.history.osPromptRequestStatus,
        PushPermissionRequestStatus.outcomeUnknown,
      );

      gateway.requestError = null;
      gateway.requestResult = PushPermissionOsStatus.authorized;
      expect(await flow.requestPermission(), PushPermissionState.unavailable);
      expect(gateway.requestCalls, 1);

      expect(
        await flow.requestPermission(retryIfUncertain: true),
        PushPermissionState.authorized,
      );
      expect(gateway.requestCalls, 2);
    });

    test('process-death history never becomes never-requested', () async {
      final gateway = _Gateway(
        status: PushPermissionOsStatus.notDeterminedOrDenied,
      );
      final ledger = _MemoryLedger(
        const PushPermissionHistory(
          osPromptRequestStatus: PushPermissionRequestStatus.outcomeUnknown,
        ),
      );
      final flow = PushPermissionFlow(gateway: gateway, ledger: ledger);
      addTearDown(flow.dispose);

      expect(await flow.refresh(), PushPermissionState.unavailable);
      expect(await flow.requestPermission(), PushPermissionState.unavailable);
      expect(gateway.requestCalls, 0);
    });

    test('explicit retry cannot bypass final OS observations', () async {
      for (final entry in <PushPermissionOsStatus, PushPermissionState>{
        PushPermissionOsStatus.authorized: PushPermissionState.authorized,
        PushPermissionOsStatus.provisional: PushPermissionState.provisional,
        PushPermissionOsStatus.denied: PushPermissionState.denied,
        PushPermissionOsStatus.unavailable: PushPermissionState.unavailable,
      }.entries) {
        final gateway = _Gateway(status: entry.key);
        final flow = PushPermissionFlow(
          gateway: gateway,
          ledger: _MemoryLedger(
            const PushPermissionHistory(
              osPromptRequestStatus: PushPermissionRequestStatus.outcomeUnknown,
            ),
          ),
        );

        expect(
          await flow.requestPermission(retryIfUncertain: true),
          entry.value,
        );
        expect(gateway.requestCalls, 0, reason: '${entry.key}');
        flow.dispose();
      }
    });

    test('explicit retry cannot bypass conclusive persisted history', () async {
      final gateway = _Gateway(
        status: PushPermissionOsStatus.notDeterminedOrDenied,
      );
      final flow = PushPermissionFlow(
        gateway: gateway,
        ledger: _MemoryLedger(
          const PushPermissionHistory(
            osPromptRequestStatus: PushPermissionRequestStatus.outcomeUnknown,
            hasObservedConclusiveStatus: true,
          ),
        ),
      );
      addTearDown(flow.dispose);

      expect(
        await flow.requestPermission(retryIfUncertain: true),
        PushPermissionState.denied,
      );
      expect(gateway.requestCalls, 0);
    });

    test('not-determined result permits a future normal request', () async {
      final gateway = _Gateway(
        status: PushPermissionOsStatus.notDetermined,
        requestResult: PushPermissionOsStatus.notDetermined,
      );
      final ledger = _MemoryLedger();
      final flow = PushPermissionFlow(gateway: gateway, ledger: ledger);
      addTearDown(flow.dispose);

      expect(await flow.requestPermission(), PushPermissionState.notDetermined);
      expect(
        ledger.history.osPromptRequestStatus,
        PushPermissionRequestStatus.notRequested,
      );

      gateway.requestResult = PushPermissionOsStatus.authorized;
      expect(await flow.requestPermission(), PushPermissionState.authorized);
      expect(gateway.requestCalls, 2);
    });

    test('concurrent requests share one gateway operation', () async {
      final requestCompleter = Completer<PushPermissionOsStatus>();
      final gateway = _Gateway(
        status: PushPermissionOsStatus.notDetermined,
        requestCompleter: requestCompleter,
      );
      final flow = PushPermissionFlow(
        gateway: gateway,
        ledger: _MemoryLedger(),
      );
      addTearDown(flow.dispose);

      final first = flow.requestPermission();
      final second = flow.requestPermission();
      expect(identical(first, second), isTrue);
      await _nextEventLoop();
      expect(gateway.requestCalls, 1);

      requestCompleter.complete(PushPermissionOsStatus.authorized);
      expect(await first, PushPermissionState.authorized);
      expect(await second, PushPermissionState.authorized);
    });

    test('refresh waits for an in-flight request', () async {
      final requestCompleter = Completer<PushPermissionOsStatus>();
      final gateway = _Gateway(
        status: PushPermissionOsStatus.notDetermined,
        requestCompleter: requestCompleter,
      );
      final flow = PushPermissionFlow(
        gateway: gateway,
        ledger: _MemoryLedger(),
      );
      addTearDown(flow.dispose);

      final request = flow.requestPermission();
      await _nextEventLoop();
      gateway.status = PushPermissionOsStatus.authorized;
      final refresh = flow.refresh();
      requestCompleter.complete(PushPermissionOsStatus.authorized);

      expect(await request, PushPermissionState.authorized);
      expect(await refresh, PushPermissionState.authorized);
      expect(flow.state, PushPermissionState.authorized);
    });

    test('queued deferral cannot overwrite an authorized request', () async {
      final requestCompleter = Completer<PushPermissionOsStatus>();
      final gateway = _Gateway(
        status: PushPermissionOsStatus.notDetermined,
        requestCompleter: requestCompleter,
      );
      final ledger = _MemoryLedger();
      final flow = PushPermissionFlow(gateway: gateway, ledger: ledger);
      addTearDown(flow.dispose);

      final request = flow.requestPermission();
      await _nextEventLoop();
      gateway.status = PushPermissionOsStatus.authorized;
      final defer = flow.deferPermission();
      requestCompleter.complete(PushPermissionOsStatus.authorized);

      expect(await request, PushPermissionState.authorized);
      expect(await defer, PushPermissionState.authorized);
      expect(ledger.history.wasDeferred, isFalse);
    });
  });

  group('failures and observation', () {
    test('gateway status failure resolves unavailable', () async {
      final flow = PushPermissionFlow(
        gateway: _Gateway(
          status: PushPermissionOsStatus.notDetermined,
          statusError: StateError('plugin failed'),
        ),
        ledger: _MemoryLedger(),
      );
      addTearDown(flow.dispose);

      expect(await flow.refresh(), PushPermissionState.unavailable);
    });

    test('ledger read failure resolves unavailable', () async {
      final ledger = _MemoryLedger()..failRead = true;
      final flow = PushPermissionFlow(
        gateway: _Gateway(status: PushPermissionOsStatus.notDetermined),
        ledger: ledger,
      );
      addTearDown(flow.dispose);

      expect(await flow.refresh(), PushPermissionState.unavailable);
    });

    test('stateChanges is broadcast, distinct, and non-replaying', () async {
      final gateway = _Gateway(status: PushPermissionOsStatus.authorized);
      final flow = PushPermissionFlow(
        gateway: gateway,
        ledger: _MemoryLedger(),
      );
      addTearDown(flow.dispose);
      expect(flow.stateChanges.isBroadcast, isTrue);
      await flow.refresh();

      final first = <PushPermissionState>[];
      final second = <PushPermissionState>[];
      final firstSubscription = flow.stateChanges.listen(first.add);
      final secondSubscription = flow.stateChanges.listen(second.add);
      addTearDown(firstSubscription.cancel);
      addTearDown(secondSubscription.cancel);

      await flow.refresh();
      gateway.status = PushPermissionOsStatus.denied;
      await flow.refresh();
      await flow.refresh();
      await _nextEventLoop();

      expect(first, [PushPermissionState.denied]);
      expect(second, first);
    });

    test('request emits requesting followed by its final state', () async {
      final flow = PushPermissionFlow(
        gateway: _Gateway(
          status: PushPermissionOsStatus.notDetermined,
          requestResult: PushPermissionOsStatus.authorized,
        ),
        ledger: _MemoryLedger(),
      );
      addTearDown(flow.dispose);
      final changes = <PushPermissionState>[];
      final subscription = flow.stateChanges.listen(changes.add);
      addTearDown(subscription.cancel);

      await flow.requestPermission();
      await _nextEventLoop();

      expect(changes, [
        PushPermissionState.requesting,
        PushPermissionState.authorized,
      ]);
    });

    test('dispose closes changes and rejects later operations', () async {
      final flow = PushPermissionFlow(
        gateway: _Gateway(status: PushPermissionOsStatus.notDetermined),
        ledger: _MemoryLedger(),
      );
      final done = expectLater(flow.stateChanges, emitsDone);

      flow.dispose();
      flow.dispose();

      await done;
      expect(flow.refresh, throwsStateError);
      expect(flow.deferPermission, throwsStateError);
      expect(flow.requestPermission, throwsStateError);
    });
  });
}

Future<void> _nextEventLoop() => Future<void>.delayed(Duration.zero);

final class _ResolutionCase {
  const _ResolutionCase(this.name, this.osStatus, this.history, this.expected);

  final String name;
  final PushPermissionOsStatus osStatus;
  final PushPermissionHistory history;
  final PushPermissionState expected;
}

final class _Gateway implements PushPermissionGateway {
  _Gateway({
    required this.status,
    this.requestResult = PushPermissionOsStatus.denied,
    this.statusError,
    this.requestError,
    this.requestCompleter,
    this.onRequest,
  });

  PushPermissionOsStatus status;
  PushPermissionOsStatus requestResult;
  Object? statusError;
  Object? requestError;
  Completer<PushPermissionOsStatus>? requestCompleter;
  void Function()? onRequest;
  int requestCalls = 0;

  @override
  Future<PushPermissionOsStatus> getStatus() async {
    final error = statusError;
    if (error != null) throw error;
    return status;
  }

  @override
  Future<PushPermissionOsStatus> requestPermission() async {
    requestCalls++;
    onRequest?.call();
    final error = requestError;
    if (error != null) throw error;
    final completer = requestCompleter;
    return completer == null ? requestResult : completer.future;
  }
}

final class _MemoryLedger implements PushPermissionLedger {
  _MemoryLedger([this.history = const PushPermissionHistory()]);

  PushPermissionHistory history;
  bool failRead = false;
  int? failWriteAt;
  int writeCalls = 0;

  @override
  Future<PushPermissionHistory> read() async {
    if (failRead) throw StateError('read failed');
    return history;
  }

  @override
  Future<void> write(PushPermissionHistory history) async {
    writeCalls++;
    if (writeCalls == failWriteAt) throw StateError('write failed');
    this.history = history;
  }
}
