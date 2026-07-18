import 'package:flutter/material.dart';

import 'src/app.dart';
import 'src/core/resilient_preferences.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Recover from a corrupt shared_preferences.json (e.g. a power outage during
  // a write) before any feature reads it, so a damaged store can never stop the
  // app from starting. See [ResilientPreferences].
  await ResilientPreferences.ensureHealthy();
  runApp(const PointyApp());
}
