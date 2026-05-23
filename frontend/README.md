# Pointy Frontend

Arabic-first Flutter POS client for cashier checkout, register sessions,
catalog management, purchasing, reports, printing, and shop settings.

## Common Commands

```sh
flutter pub get
flutter gen-l10n
dart format lib test
flutter analyze
flutter test
flutter test test/e2e
```

From the repository root, prefer:

```sh
make frontend-format
make frontend-analyze
make frontend-test
make frontend-e2e
```

## Test Shape

- `test/` contains unit and widget coverage for models, view models, shared UI,
  and main workflows.
- `test/e2e/` contains opt-in full-app flow tests. These use deterministic fake
  services so they can run without a live backend while still driving the real
  Arabic UI.
- Backend HTTP load, stress, and endurance runners live behind root Make targets
  such as `make backend-load-test`.
