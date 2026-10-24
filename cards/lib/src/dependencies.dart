import 'package:shared_preferences/shared_preferences.dart';

import 'config.dart';
import 'data/api/relay_api.dart';
import 'data/repositories/auth_repository.dart';
import 'data/repositories/catalog_repository.dart';
import 'data/repositories/orders_repository.dart';
import 'data/session/session_store.dart';
import 'data/vault/code_vault.dart';

/// Everything the screens use, built once at launch. Screens get it from
/// [CardsScope]; tests and the preview harness build it with fakes.
class CardsDependencies {
  CardsDependencies({
    required this.config,
    required this.auth,
    required this.catalog,
    required this.orders,
    required this.vault,
    required this.lock,
    this.preferences,
  });

  /// The real thing: the relay over HTTPS, the session in the keychain.
  factory CardsDependencies.live(CardsConfig config) {
    final preferences = SharedPreferencesAsync();
    final sessions = SecureSessionStore();
    final api = RelayApi(baseUrl: config.relayBaseUrl, sessions: sessions);
    return CardsDependencies(
      config: config,
      auth: AuthRepository(
        api: api,
        sessions: sessions,
        preferences: preferences,
      ),
      catalog: CatalogRepository(
        api: api,
        channel: config.channel,
        preferences: preferences,
      ),
      orders: OrdersRepository(api: api, channel: config.channel),
      vault: SecureCodeVault(),
      lock: CodeLock(),
      preferences: preferences,
    );
  }

  final CardsConfig config;
  final AuthRepository auth;
  final CatalogRepository catalog;
  final OrdersRepository orders;

  /// Delivered codes on the device, and the biometric lock in front of them.
  final CodeVault vault;
  final CodeLock lock;

  /// Small per-device choices (the last payment method). Null in tests.
  final SharedPreferencesAsync? preferences;
}
