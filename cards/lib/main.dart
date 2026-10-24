import 'package:flutter/material.dart';

import 'src/app.dart';
import 'src/config.dart';
import 'src/dependencies.dart';
import 'src/features/splash/splash_overlay.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final dependencies = CardsDependencies.live(CardsConfig.fromEnvironment());
  // The system's splash covers all three; none waits on another.
  final (_, run, art) = await (
    dependencies.auth.restore(),
    SplashMemory.next(),
    SplashArt.load(),
  ).wait;
  runApp(
    CardsApp(
      dependencies: dependencies,
      splash: SplashOpening(run, art: art),
    ),
  );
}
