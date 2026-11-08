import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'config.dart';
import 'core/analytics/analytics.dart';
import 'core/esim/esim_device.dart';
import 'core/push/push.dart';
import 'data/accounts/saved_accounts.dart';
import 'data/api/relay_api.dart';
import 'data/repositories/attribution_repository.dart';
import 'data/repositories/auth_repository.dart';
import 'data/repositories/catalog_repository.dart';
import 'data/repositories/esim_repository.dart';
import 'data/repositories/orders_repository.dart';
import 'data/session/session_store.dart';
import 'data/settings/app_settings.dart';
import 'data/vault/card_vault.dart';
import 'data/vault/code_vault.dart';
import 'features/card_payment/moamalat_client.dart';
import 'features/links/link_inbox.dart';
import 'shared/art_preloader.dart';

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
    AppSettings? settings,
    MoamalatClient? moamalat,
    CardVault? cards,
    LinkInbox? links,
    AttributionRepository? attribution,
    Analytics? analytics,
    Push? push,
    SavedAccounts? accounts,
    EsimRepository? esim,
    EsimCompatibility? esimCompatibility,
    this.preferences,
    this.art,
  }) : settings = settings ?? AppSettings(),
       accounts = accounts ?? SavedAccounts(preferences: preferences),
       esim = esim ?? EsimRepository(api: auth.api),
       analytics = analytics ?? NoAnalytics(),
       push = push ?? NoPush(),
       moamalat = moamalat ?? MoamalatClient(),
       cards = cards ?? MemoryCardVault(),
       links = links ?? LinkInbox(),
       attribution =
           attribution ??
           AttributionRepository(
             api: auth.api,
             isSignedIn: () => auth.isSignedIn,
           ) {
    _esimCompatibility = esimCompatibility;
    // A link's campaign code is taken as the link arrives; a followed
    // campaign's own page opens after it.
    this.links.onOpen ??= this.attribution.openedLink;
    this.attribution.onLanding ??= (landing) =>
        this.links.open(Uri.parse(landing));
  }

  final EsimRepository esim;
  EsimCompatibility? _esimCompatibility;

  /// A phone other than this one: tests and the preview harness.
  void overrideEsimCompatibility(EsimCompatibility compatibility) =>
      _esimCompatibility = compatibility;

  /// What this phone says about eSIMs, read once.
  EsimCompatibility get esimCompatibility =>
      _esimCompatibility ??= EsimCompatibility(repository: esim);

  /// The real thing: the relay over HTTPS, the session in the keychain.
  factory CardsDependencies.live(CardsConfig config) {
    final preferences = SharedPreferencesAsync();
    final sessions = SecureSessionStore();
    final api = RelayApi(baseUrl: config.relayBaseUrl, sessions: sessions);
    final settings = AppSettings(preferences: preferences);
    final analytics = PostHogAnalytics.forConfig(config);
    late final AuthRepository auth;
    final attribution = AttributionRepository(
      api: api,
      isSignedIn: () => auth.isSignedIn,
      preferences: preferences,
      analytics: analytics,
    );
    auth = AuthRepository(
      api: api,
      sessions: sessions,
      preferences: preferences,
      attribution: attribution,
      analytics: analytics,
    );
    final catalog = CatalogRepository(
      api: api,
      channel: config.channel,
      preferences: preferences,
    );
    return CardsDependencies(
      config: config,
      auth: auth,
      attribution: attribution,
      catalog: catalog,
      // A browser keeps art in its own store, out of the app's reach.
      art: kIsWeb ? null : ArtPreloader(catalog: catalog),
      orders: OrdersRepository(
        api: api,
        channel: config.channel,
        analytics: analytics,
      ),
      vault: SecureCodeVault(),
      cards: SecureCardVault(),
      lock: CodeLock(settings: settings),
      settings: settings,
      analytics: analytics,
      push: FirebasePush.forPlatform(
        channel: config.channel,
        analytics: analytics,
        preferences: preferences,
      ),
      preferences: preferences,
    );
  }

  final CardsConfig config;
  final AuthRepository auth;
  final CatalogRepository catalog;

  /// Readies stored art ahead of the shelf; none in tests.
  final ArtPreloader? art;
  final OrdersRepository orders;

  /// Delivered codes on the device, and the biometric lock in front of them.
  final CodeVault vault;
  final CodeLock lock;

  /// Language, light or dark, and the code lock: the customer's choices.
  final AppSettings settings;

  /// Bank cards: the phone pays Moamalat itself, in the app's own form.
  final MoamalatClient moamalat;

  /// Bank cards the customer chose to keep on this phone.
  final CardVault cards;

  /// Links to places in the app (`https://cards.dftr.ly/…`) waiting to open.
  final LinkInbox links;

  /// Where the customer came from: a campaign's code and their answer to
  /// «من أين سمعت عنا؟», held until the relay has them.
  final AttributionRepository attribution;

  /// Product analytics and feature flags (PostHog), or nothing.
  final Analytics analytics;

  /// Notifications (Firebase Cloud Messaging), or nothing.
  final Push push;

  /// The accounts top-ups went to from this phone, offered again.
  final SavedAccounts accounts;

  /// Small per-device choices (the last payment method). Null in tests.
  final SharedPreferencesAsync? preferences;
}
