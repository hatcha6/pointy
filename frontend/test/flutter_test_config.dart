import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'support/key_value_store_testing.dart';

/// Wraps every test in the suite. Installs a fresh in-memory [KeyValueStore]
/// before each test so nothing accidentally opens the real native SQLite store
/// (unregistered under `flutter test`). Tests that need seeded data call
/// `installMemoryKeyValueStore({...})` again in their own setUp / body, which
/// runs after this global one and wins.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  setUp(() {
    installMemoryKeyValueStore();
  });
  await testMain();
}
