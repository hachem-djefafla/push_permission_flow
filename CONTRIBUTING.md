# Contributing to push_permission_flow

Contributions are welcome.

## Setup

Clone the repository and install dependencies:

```bash
dart pub get
```

## Before submitting a pull request

Run:

```bash
dart format .
dart analyze --fatal-infos
dart test
```

All tests and analysis must pass.

## Pull requests

* Keep changes focused.
* Add tests for new behavior or bug fixes.
* Update documentation when changing the public API.
* Avoid adding runtime dependencies unless clearly necessary.
* Keep the package framework-neutral and dependency-light.

For significant API or architectural changes, please open an issue first so the approach can be discussed.

## Reporting bugs

When opening an issue, include:

* package version
* Dart/Flutter version
* platform
* expected behavior
* actual behavior
* minimal reproduction when possible
