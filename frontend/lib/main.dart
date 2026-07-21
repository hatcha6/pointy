import 'package:flutter/material.dart';

import 'src/app.dart';
import 'src/core/resilient_preferences.dart';
import 'src/core/storage/app_key_value_store.dart';

Future<void> main() async {
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
