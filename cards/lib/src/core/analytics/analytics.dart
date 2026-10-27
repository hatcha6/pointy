import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:posthog_flutter/posthog_flutter.dart';

import '../../config.dart';
import 'posthog_web_init.dart'
    if (dart.library.js_interop) 'posthog_web_init_web.dart';

/// What the app tells product analytics, and the feature flags it reads
/// back: the one place PostHog is spoken to, so the rest of the app never
/// imports it and a build (or a test) without a token simply sends nothing.
///
/// Customers are known by their customer id only, never their phone. Session
/// replay records the phone apps with every figure masked (codes, amounts,
/// the phone number, a PIN) and [Sensitive] parts blacked out whole.
abstract class Analytics {
  /// Starts sending, or held off when [share] is false. Safe to call once,
  /// before the first frame.
  Future<void> start({bool share = true});

  /// Names each page a customer opens (see [screenSettings]).
  NavigatorObserver? get observer;

  /// A page the navigator cannot see: the shell's tabs.
  void screen(String name);

  /// Something the customer did, as `snake_case`, with plain properties.
  void capture(String event, [Map<String, Object> properties = const {}]);

  /// The customer signed in: their events join their customer id.
  void identify(String customerId);

  /// The customer signed out: this device starts over as nobody.
  void reset();

  /// Whether feature flag [key] is on for this customer. False until the
  /// flags have loaded, and always in a build without analytics.
  Future<bool> isEnabled(String key);

  /// Notifies when feature flags (re)load, for a screen that waits on one.
  Listenable get flags;

  /// The whole app, under session replay's camera where there is one.
  Widget wrap(Widget app);

  /// The customer's «مشاركة بيانات الاستخدام»: off stops every event and
  /// recording from this device until it is turned back on.
  void share(bool on);
}

/// A part of a screen session replay never shows, whatever the masking
/// rules: a card's code, its QR, a bank card form, a PIN.
class Sensitive extends StatelessWidget {
  const Sensitive({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => PostHogMaskWidget(child: child);
}

/// The page's name for analytics, carried in its route's arguments: a named
/// route would become the web build's address.
RouteSettings screenSettings(String name) =>
    RouteSettings(arguments: ScreenName(name));

/// [screenSettings]' marker.
@immutable
class ScreenName {
  const ScreenName(this.name);

  final String name;
}

/// Sends nothing: tests, the preview harness, a build with no token.
class NoAnalytics implements Analytics {
  NoAnalytics();

  @override
  final Listenable flags = ChangeNotifier();

  @override
  Future<void> start({bool share = true}) async {}

  @override
  NavigatorObserver? get observer => null;

  @override
  void screen(String name) {}

  @override
  void capture(String event, [Map<String, Object> properties = const {}]) {}

  @override
  void identify(String customerId) {}

  @override
  void reset() {}

  @override
  Future<bool> isEnabled(String key) async => false;

  @override
  Widget wrap(Widget app) => app;

  @override
  void share(bool on) {}
}

/// PostHog, on every platform the app runs on.
class PostHogAnalytics implements Analytics {
  PostHogAnalytics({required this.config});

  /// The real thing in a release build with a token, else [NoAnalytics]:
  /// `flutter run` while developing stays out of the numbers.
  static Analytics forConfig(CardsConfig config) =>
      kReleaseMode && config.posthogToken.isNotEmpty
      ? PostHogAnalytics(config: config)
      : NoAnalytics();

  final CardsConfig config;
  final _flags = _Flags();
  bool _started = false;

  @override
  Listenable get flags => _flags;

  @override
  late final NavigatorObserver observer = PosthogObserver(
    nameExtractor: (settings) => switch (settings.arguments) {
      ScreenName(:final name) => name,
      _ => null,
    },
    // Sheets and dialogs too, where they are named.
    routeFilter: (route) => route is ModalRoute,
  );

  @override
  Future<void> start({bool share = true}) async {
    if (_started) {
      return;
    }
    _started = true;
    try {
      // The web build's library is started by the page's own posthog-js,
      // which the plugin then hooks into.
      startPosthogWeb(
        token: config.posthogToken,
        host: config.posthogHost,
        share: share,
      );
      final setup = PostHogConfig(config.posthogToken)
        ..host = config.posthogHost
        ..personProfiles = PostHogPersonProfiles.identifiedOnly
        ..captureApplicationLifecycleEvents = true
        ..optOut = !share
        // The phone apps only: the web build is a canvas, which posthog-js
        // would record as video.
        ..sessionReplay = !kIsWeb
        ..sessionReplayConfig = (PostHogSessionReplayConfig()
          // Words show, so a replay can be followed; every run of figures is
          // masked: codes, amounts, the phone number, a PIN.
          ..textMaskPolicy = PostHogTextMaskPolicies.digits()
          // Card art and brand logos are the catalog's, nobody's secret.
          ..maskAllImages = false)
        ..onFeatureFlags = _flags.changed;
      // Error tracking: Flutter's own errors, uncaught async ones, and the
      // phone's native crashes, each with its stack, frames from this app
      // marked as ours.
      setup.errorTrackingConfig
        ..captureFlutterErrors = true
        ..capturePlatformDispatcherErrors = true
        ..captureNativeExceptions = !kIsWeb
        ..inAppIncludes.add('package:pointy_cards');
      await Posthog().setup(setup);
      // Every event says which build sent it, as the relay's catalog does.
      await Posthog().register('channel', config.channel);
    } catch (error) {
      // Analytics never stands in the customer's way.
      debugPrint('PostHog did not start: $error');
    }
  }

  @override
  void screen(String name) =>
      _quietly(() => Posthog().screen(screenName: name));

  @override
  void capture(String event, [Map<String, Object> properties = const {}]) =>
      _quietly(
        () => Posthog().capture(eventName: event, properties: properties),
      );

  @override
  void identify(String customerId) =>
      _quietly(() => Posthog().identify(userId: customerId));

  @override
  void reset() => _quietly(() => Posthog().reset());

  @override
  Future<bool> isEnabled(String key) async {
    try {
      return await Posthog().isFeatureEnabled(key);
    } catch (_) {
      return false;
    }
  }

  @override
  Widget wrap(Widget app) => kIsWeb ? app : PostHogWidget(child: app);

  @override
  void share(bool on) =>
      _quietly(() => on ? Posthog().optIn() : Posthog().optOut());

  void _quietly(Future<void> Function() call) {
    if (!_started) {
      return;
    }
    call().catchError((Object error) => debugPrint('PostHog: $error'));
  }
}

class _Flags extends ChangeNotifier {
  void changed() => notifyListeners();
}
