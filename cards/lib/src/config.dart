import 'package:flutter/foundation.dart';

/// Where the app finds the relay, and which build it is.
///
/// The channel is what the relay narrows the catalog by: the App Store build
/// may sell services only (guideline 3.1.1), so it says "ios"; the Android
/// build installed from our site says "apk", the Play one "play", the web app
/// "web". Both come from `--dart-define` so one source builds every channel.
class CardsConfig {
  const CardsConfig({
    required this.relayBaseUrl,
    required this.channel,
    this.posthogToken = '',
    this.posthogHost = defaultPosthogHost,
  });

  /// Read from `--dart-define=CARDS_RELAY_URL=…` and `CARDS_CHANNEL=…`.
  factory CardsConfig.fromEnvironment() {
    const url = String.fromEnvironment(
      'CARDS_RELAY_URL',
      defaultValue: 'https://my.dftr.ly',
    );
    const channel = String.fromEnvironment('CARDS_CHANNEL');
    const posthogHost = String.fromEnvironment(
      'CARDS_POSTHOG_HOST',
      defaultValue: defaultPosthogHost,
    );
    return CardsConfig(
      relayBaseUrl: Uri.parse(url),
      channel: channel.isNotEmpty ? channel : defaultChannel(),
      posthogToken: const String.fromEnvironment(
        'CARDS_POSTHOG_TOKEN',
        defaultValue: defaultPosthogToken,
      ),
      posthogHost: posthogHost,
    );
  }

  final Uri relayBaseUrl;
  final String channel;

  /// PostHog's project token: a public key (it only sends), so it ships in
  /// every build. `--dart-define=CARDS_POSTHOG_TOKEN=` (empty) builds one
  /// that sends nothing.
  final String posthogToken;

  /// PostHog's ingestion host: the project lives on its EU cloud.
  final String posthogHost;

  static const String defaultPosthogToken =
      'phc_Bquv28MdZLocFXyF2mC5xgWQQbBYFzdVix9fWthMD5jo';
  static const String defaultPosthogHost = 'https://eu.i.posthog.com';

  static const List<String> channels = ['ios', 'play', 'apk', 'web'];

  /// The channel of a build that did not say: the platform's own.
  static String defaultChannel() {
    if (kIsWeb) {
      return 'web';
    }
    return switch (defaultTargetPlatform) {
      TargetPlatform.iOS => 'ios',
      _ => 'apk',
    };
  }
}
