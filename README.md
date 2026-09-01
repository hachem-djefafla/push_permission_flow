# push_permission_flow

A small, predictable state machine for notification permission orchestration.
It separates application-level deferral from operating-system permission,
handles ambiguous Android observations, and remains independent of Flutter,
Firebase, storage plugins, UI frameworks, and backend logic.

## Why use it?

Notification permission is not always a single platform value:

- An application can offer "Not now" without denying permission at the OS.
- On Android 13+, some APIs cannot distinguish never requested from denied.
- iOS can provisionally authorize quiet notifications.
- A process can terminate while a permission request is being initiated.
- Permissions can change while the user is in system settings.

`push_permission_flow` combines the current platform observation with a small
durable history to resolve those cases deterministically.

## Core API

Implement two ports in your application:

```dart
abstract interface class PushPermissionGateway {
  Future<PushPermissionOsStatus> getStatus();
  Future<PushPermissionOsStatus> requestPermission();
}

abstract interface class PushPermissionLedger {
  Future<PushPermissionHistory> read();
  Future<void> write(PushPermissionHistory history);
}
```

The gateway adapts your platform permission API. The ledger durably replaces
the complete `PushPermissionHistory`; when storage is empty it must return
`const PushPermissionHistory()`.

```dart
final flow = PushPermissionFlow(
  gateway: myPlatformGateway,
  ledger: myDurableLedger,
);

final subscription = flow.stateChanges.listen((state) {
  // Update your application state or UI.
});

final initial = await flow.refresh();
if (initial == PushPermissionState.notDetermined) {
  // Show your own explanation UI first.
}

final result = await flow.requestPermission();
if (result.allowsPush) {
  // Token and backend work belongs in the consuming application.
}

await subscription.cancel();
flow.dispose();
```

Call `refresh()` when the app starts and whenever it resumes after opening
system settings. Opening settings and observing the Flutter application
lifecycle intentionally remain application responsibilities.

## Deferral and Android ambiguity

When the user chooses "Not now" in your explanation UI:

```dart
await flow.deferPermission();
```

This records an application decision without claiming that the OS permission
was denied.

An Android 13+ adapter should return
`PushPermissionOsStatus.notDeterminedOrDenied` when its platform API returns a
denied-looking observation that cannot distinguish never requested from actual
denial. Do not consult the ledger inside the gateway; `PushPermissionFlow`
owns that resolution.

The ledger tracks the request as one of:

- `notRequested`: no request is known to have started;
- `outcomeUnknown`: a request began, but the result was not observed;
- `completed`: the gateway request returned a platform observation.

`outcomeUnknown` is written before calling the gateway. If the process dies or
the gateway throws, a later ambiguous Android observation resolves to
`unavailable`, not to `notDetermined` or `denied`. This prevents an automatic
repeat without falsely claiming the user denied permission.

If your product offers a deliberate retry action, it may opt in explicitly:

```dart
await flow.requestPermission(retryIfUncertain: true);
```

Use this only for explicit user intent. The previous request might have reached
the OS even though the application did not observe its result. The retry flag
cannot bypass definitive denial, authorization, an unsupported platform, or a
ledger failure.

## States and ownership

`PushPermissionState.authorized` and `PushPermissionState.provisional` are the
only states for which `allowsPush` is true. `requesting` is transient, while
`unavailable` is the safe result for unsupported platforms, failed operations,
or an ambiguous observation following an uncertain request.

The package owns:

- deterministic state resolution and transitions;
- operation serialization and concurrent request coalescing;
- durable-history coordination;
- a distinct, broadcast, non-replaying `stateChanges` stream.

Your application owns:

- Firebase or another messaging provider;
- the platform gateway and persistent ledger adapters;
- explanation and settings UI;
- Flutter lifecycle and state-management integration;
- push tokens, backend registration, navigation, and analytics.

## Error behavior

Gateway and required ledger failures resolve safely to `unavailable`. A ledger
write failure before a request prevents the gateway call. A ledger write
failure after a returned request also resolves to `unavailable`, because the
result cannot be relied on across restarts.

`dispose()` closes `stateChanges`, is idempotent, and causes later operations
to throw `StateError`.

## License

MIT
