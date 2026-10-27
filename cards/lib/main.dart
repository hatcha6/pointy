import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_web_plugins/url_strategy.dart';

import 'src/app.dart';
import 'src/config.dart';
import 'src/core/analytics/follow_customer.dart';
import 'src/dependencies.dart';
import 'src/features/splash/splash_overlay.dart';

Future<void> main() async {
  // cards.dftr.ly/brand/pubg, not /#/brand/pubg: the web build answers to
  // the same addresses that open the app on a phone.
  usePathUrlStrategy();
  WidgetsFlutterBinding.ensureInitialized();
  final dependencies = CardsDependencies.live(CardsConfig.fromEnvironment());
  // The system's splash covers all of it; none waits on another.
  // The customer's language and theme are known before the first frame.
  final (_, _, opening) = await (
    dependencies.settings.load(),
    dependencies.auth.restore(),
    _opening(),
  ).wait;
  // After the settings: a customer who turned sharing off sends nothing,
  // not even the app opening.
  await dependencies.analytics.start(share: dependencies.settings.shareUsage);
  followCustomer(dependencies);
  runApp(CardsApp(dependencies: dependencies, splash: opening));
}

/// The opening to play, with its pictures decoded. None on the web: the
/// page's own splash has stood through the whole download already, so the
/// app shows itself the moment it can, and the opening's pictures are
/// never fetched.
Future<SplashOpening?> _opening() async {
  if (kIsWeb) {
    return null;
  }
  final (run, art) = await (SplashMemory.next(), SplashArt.load()).wait;
  return SplashOpening(run, art: art);
}
