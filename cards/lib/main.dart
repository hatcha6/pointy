import 'package:flutter/material.dart';
import 'package:flutter_web_plugins/url_strategy.dart';

import 'src/app.dart';
import 'src/config.dart';
import 'src/dependencies.dart';
import 'src/features/splash/splash_overlay.dart';

Future<void> main() async {
  // cards.dftr.ly/brand/pubg, not /#/brand/pubg: the web build answers to
  // the same addresses that open the app on a phone.
  usePathUrlStrategy();
  WidgetsFlutterBinding.ensureInitialized();
  final dependencies = CardsDependencies.live(CardsConfig.fromEnvironment());
  // The system's splash covers all three; none waits on another.
  // The customer's language and theme are known before the first frame.
  final (_, _, run, art) = await (
    dependencies.settings.load(),
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
