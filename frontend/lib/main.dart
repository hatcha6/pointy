import 'package:flutter/material.dart';

import 'src/app.dart';
import 'src/core/app_version.dart';
import 'src/core/resilient_preferences.dart';
import 'src/core/storage/app_key_value_store.dart';

Future<void> main() async {
  // Start the clock before anything else runs. It is a lazy `final` that
  // starts itself on first access, so this line is what fixes the zero that
  // `app.started` measures its duration from; starting an already-running
  // stopwatch is a no-op, so nothing later can move it.
  kProcessUptime.start();
  WidgetsFlutterBinding.ensureInitialized();
  // Recover from a corrupt legacy shared_preferences.json (e.g. a power outage
  // during a write) before anything reads it. Still relevant as the guard for
  // the one-time migration read below and as the web backend. See
  // [ResilientPreferences].
  await ResilientPreferences.ensureHealthy();
  // Open the durable SQLite-backed local store — running the one-time migration
  // off shared_preferences and the integrity guard — before the first read, so
  // a damaged store can never stop the app from starting. See [AppKeyValueStore].
  await AppKeyValueStore.instance();
  runApp(const PointyApp());
}
