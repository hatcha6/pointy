// Dev-only (safe to delete): the app as the store screenshots and the app
// preview film it, on a phone or simulator. A separate entrypoint, never
// imported by lib/main.dart, so it does not ship.
//
//   flutter build ios --simulator --debug -t lib/dev/store_shots.dart \
//     --dart-define=CARDS_PREVIEW_RELAY=https://my.dftr.ly --dart-define=CARDS_CHANNEL=ios
//
// The screen comes from `store_shot.json` in the app's tmp folder, so one
// build films them all: `{"STORE_SCREEN": "reveal"}` (any name
// cards_preview.dart takes; `home` by default) and `"STORE_THEME": "dark"`. `brand`, `checkout` and `reveal`
// open on a brand of the real shelf: `STORE_BRAND=almadar`, `STORE_ITEM=2`
// (the value's place on the brand's page).
//
// The shelf, its art and prices come from the real relay; the customer is
// signed in, and orders, payment and codes are the fixture relay's, so every
// purchase ends with a card and nothing is paid.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../src/app.dart';
import '../src/core/result.dart';
import '../src/data/models/catalog.dart';
import '../src/data/models/order.dart';
import '../src/features/brand/brand_page.dart';
import '../src/features/checkout/checkout_model.dart';
import '../src/features/checkout/checkout_sheet.dart';
import '../src/features/reveal/reveal_page.dart';
import '../src/features/shell/cards_shell.dart';
import '../src/features/splash/splash_overlay.dart';
import '../src/shared/cards_scope.dart';
import 'cards_fixtures.dart';
import 'cards_preview.dart';
import 'preview_scenarios.dart';
import 'store_film.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final env = _shot();
  final screen = env['STORE_SCREEN'] ?? 'home';
  final dark = env['STORE_THEME'] == 'dark';
  const relay = String.fromEnvironment('CARDS_PREVIEW_RELAY');
  const channel = String.fromEnvironment('CARDS_CHANNEL', defaultValue: 'ios');
  final dependencies = fixtureDependencies(
    signedIn: screen != 'signed-out' && !screen.startsWith('sign-in'),
    shelfRelay: relay.isEmpty ? null : Uri.parse(relay),
    // Every purchase delivers its card: the film's story.
    scenarios: _AlwaysDelivered(),
    channel: channel,
  );
  dependencies.settings.setLanguage('ar');
  // `STORE_SPLASH=1`: the full opening first, as a first launch has it.
  final film = screen == 'film';
  final opening = film || env['STORE_SPLASH'] == '1'
      ? SplashOpening(SplashRun.full, art: await SplashArt.load())
      : null;
  runApp(
    CardsApp(
      dependencies: dependencies,
      themeMode: dark ? ThemeMode.dark : ThemeMode.light,
      splash: opening,
      home: switch (screen) {
        'brand' || 'checkout' || 'reveal' => _BrandSurface(
          screen: screen,
          brand: env['STORE_BRAND'] ?? 'libyana',
          item: int.tryParse(env['STORE_ITEM'] ?? '') ?? 1,
        ),
        'film' => const PreviewSurface(screen: 'home'),
        _ => PreviewSurface(screen: screen),
      },
    ),
  );
  if (film) {
    await playFilm();
  }
}

/// Every purchase delivers its card: the film's story.
class _AlwaysDelivered extends PreviewScenarios {
  @override
  PreviewOutcome take() => PreviewOutcome.delivered;
}

/// A brand's page, its checkout or its card, on the real shelf's brand.
class _BrandSurface extends StatefulWidget {
  const _BrandSurface({
    required this.screen,
    required this.brand,
    required this.item,
  });

  final String screen;
  final String brand;
  final int item;

  @override
  State<_BrandSurface> createState() => _BrandSurfaceState();
}

class _BrandSurfaceState extends State<_BrandSurface> {
  CardBrand? _brand;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_brand != null) {
      return;
    }
    CardsScope.of(context).catalog.refresh().then((result) {
      if (result case Ok(:final value) when mounted) {
        final brand = value.brands.firstWhere((b) => b.key == widget.brand);
        setState(() => _brand = brand);
        if (widget.screen == 'checkout') {
          WidgetsBinding.instance.addPostFrameCallback((_) => _checkout());
        }
      }
    });
  }

  CardItem get _item =>
      _brand!.items[widget.item.clamp(0, _brand!.items.length - 1)];

  void _checkout() {
    final model = CheckoutModel(
      orders: CardsScope.of(context).orders,
      brand: _brand!,
      item: _item,
    )..setUseCredit(false);
    model.load();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => CheckoutSheet(model: model),
    );
  }

  @override
  Widget build(BuildContext context) {
    final brand = _brand;
    if (brand == null) {
      return const Scaffold();
    }
    return switch (widget.screen) {
      'reveal' => RevealPage(
        brand: brand,
        order: CardOrder.fromJson(
          fixtureOrder(
            item: _item.key,
            brand: brand.key,
            name: '${brand.name} · ${_item.label}',
            total: _item.price.toWire(),
          ),
        ),
      ),
      'checkout' => const CardsShell(),
      _ => BrandPage(brand: brand),
    };
  }
}

/// What to film: `store_shot.json` in the app's temporary folder (an iOS app
/// sees no environment of its own), a flat map of the `STORE_*` names above.
Map<String, String> _shot() {
  final file = File('${Directory.systemTemp.path}/store_shot.json');
  // ignore: avoid_print
  print('store_shots: ${file.path} ${file.existsSync()}');
  if (!file.existsSync()) {
    return const {};
  }
  return (jsonDecode(file.readAsStringSync()) as Map<String, dynamic>).map(
    (key, value) => MapEntry(key, '$value'),
  );
}
