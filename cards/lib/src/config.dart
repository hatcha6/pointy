import 'package:flutter/foundation.dart';

/// Where the app finds the relay, and which build it is.
///
/// The channel is what the relay narrows the catalog by: the App Store build
/// may sell services only (guideline 3.1.1), so it says "ios"; the Android
/// build installed from our site says "apk", the Play one "play", the web app
/// "web". Both come from `--dart-define` so one source builds every channel.
class CardsConfig {
  const CardsConfig({required this.relayBaseUrl, required this.channel});

  /// Read from `--dart-define=CARDS_RELAY_URL=…` and `CARDS_CHANNEL=…`.
  factory CardsConfig.fromEnvironment() {
    const url = String.fromEnvironment(
      'CARDS_RELAY_URL',
      defaultValue: 'https://my.dftr.ly',
    );
    const channel = String.fromEnvironment('CARDS_CHANNEL');
    return CardsConfig(
      relayBaseUrl: Uri.parse(url),
      channel: channel.isNotEmpty ? channel : defaultChannel(),
    );
  }

  final Uri relayBaseUrl;
  final String channel;

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
