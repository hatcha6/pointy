import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/analytics_device_profile.dart';

import 'support/key_value_store_testing.dart';

/// Wraps every test in the suite.
///
/// Installs a fresh in-memory [KeyValueStore] before each test so nothing
/// accidentally opens the real native SQLite store (unregistered under
/// `flutter test`). Tests that need seeded data call
/// `installMemoryKeyValueStore({...})` again in their own setUp / body, which
/// runs after this global one and wins.
///
/// Answers the analytics device profile for the same reason: resolving it for
/// real reads the app bundle, and real I/O never completes under the fake clock
/// a widget test runs on — so any test that builds the app would wait out the
/// engine's deadline and then fail on the timer it left armed. A test that
/// cares about the profile injects its own resolver into the engine.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  setUp(() {
    installMemoryKeyValueStore();
    debugOverrideAnalyticsDeviceProfile(
      const AnalyticsDeviceProfile(
        appVersion: '0.0.0-test',
        versionSource: 'test',
      ),
    );
  });
  tearDown(debugResetAnalyticsDeviceProfile);
  await testMain();
}
