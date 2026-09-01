import 'dart:io';

import 'package:push_permission_flow/push_permission_flow.dart';

Future<void> main() async {
  final flow = PushPermissionFlow(
    gateway: _ExampleGateway(),
    ledger: _ExampleLedger(),
  );
  final subscription = flow.stateChanges.listen(
    (state) => stdout.writeln('Permission changed: $state'),
  );

  final initial = await flow.refresh();
  stdout.writeln('Initial permission: $initial');

  if (initial == PushPermissionState.notDetermined) {
    final result = await flow.requestPermission();
    stdout.writeln('Permission result: $result');
  }

  await subscription.cancel();
  flow.dispose();
}

final class _ExampleGateway implements PushPermissionGateway {
  PushPermissionOsStatus _status = PushPermissionOsStatus.notDetermined;

  @override
  Future<PushPermissionOsStatus> getStatus() async => _status;

  @override
  Future<PushPermissionOsStatus> requestPermission() async {
    // A real adapter calls the platform notification-permission API here.
    return _status = PushPermissionOsStatus.authorized;
  }
}

final class _ExampleLedger implements PushPermissionLedger {
  PushPermissionHistory _history = const PushPermissionHistory();

  @override
  Future<PushPermissionHistory> read() async => _history;

  @override
  Future<void> write(PushPermissionHistory history) async {
    // A real adapter must persist the complete value durably.
    _history = history;
  }
}
