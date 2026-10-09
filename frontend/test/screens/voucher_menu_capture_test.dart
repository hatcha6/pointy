// Renders the till's «كروت دفتر» voucher menu and a brand's sheet to PNG,
// headlessly, from the same surfaces as lib/dev/voucher_menu_preview.dart —
// on a phone, a compact 1024×768 till and a wide 1366 one, light and dark —
// so the screens can be looked at instead of described.
//
// Not a golden gate: an ordinary `flutter test` run skips every case here.
// Capture with:
//
//   POINTY_CAPTURE_SCREENS=1 flutter test test/screens/voucher_menu_capture_test.dart --update-goldens
//
// The PNGs land in test/screens/goldens/. With POINTY_VOUCHER_SNAPSHOT=<dir>
// (the menu a real shop's backend served, its card art and flags, exported
// from ops/catalog's catalog) the same screens are drawn from that menu
// instead of the drawn one, and land as voucher_real_*.png.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/dev/voucher_menu_fixtures.dart';
import 'package:pointy_frontend/dev/voucher_menu_preview.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/integration_provider.dart';
import 'package:pointy_frontend/src/data/repositories/integrations_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/settings/view_models/integrations_view_model.dart';
import 'package:pointy_frontend/src/features/settings/views/integrations_page.dart';
import 'package:pointy_frontend/src/shared/catalog/catalog.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

final bool _capture = Platform.environment['POINTY_CAPTURE_SCREENS'] == '1';
final String? _snapshot = Platform.environment['POINTY_VOUCHER_SNAPSHOT'];

/// Show a real shop's menu: its two JSON documents (a manager's, a cashier's)
/// and each brand's card art, which the menu names by URL and the snapshot
/// keeps as `images/<brand key>.png`.
void _useSnapshot(String dir) {
  Map<String, Object?> read(String name) =>
      jsonDecode(File('$dir/$name').readAsStringSync()) as Map<String, Object?>;
  final manager = read('menu_manager.json');
  final cashier = read('menu_cashier.json');
  voucherPreviewMenuSource = ({required bool withCost}) =>
      withCost ? manager : cashier;
  for (final brand in (manager['brands']! as List).cast<Map>()) {
    final image = (brand['product'] as Map)['primary_image'];
    final url = image is Map ? image['content_url'] as String? : null;
    final file = File('$dir/images/${brand['key']}.png');
    if (url != null && file.existsSync()) {
      voucherPreviewArtByPath[Uri.parse(url).path] = file.readAsBytesSync();
    }
  }
  voucherPreviewPicks = const VoucherPreviewPicks(
    countries: 'playstation',
    single: 'libyana',
    seeded: 'apple',
  );
}

ThemeData _withButtonFont(ThemeData theme) {
  ButtonStyle patch(ButtonStyle? style) {
    return (style ?? const ButtonStyle()).copyWith(
      textStyle: WidgetStateProperty.resolveWith((states) {
        final resolved = style?.textStyle?.resolve(states);
        return (resolved ?? const TextStyle()).copyWith(
          fontFamily: PointyTypography.fontFamily,
        );
      }),
    );
  }

  return theme.copyWith(
    filledButtonTheme: FilledButtonThemeData(
      style: patch(theme.filledButtonTheme.style),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: patch(theme.outlinedButtonTheme.style),
    ),
    textButtonTheme: TextButtonThemeData(
      style: patch(theme.textButtonTheme.style),
    ),
  );
}

String _flutterRoot() {
  final fromEnv = Platform.environment['FLUTTER_ROOT'];
  if (fromEnv != null && fromEnv.isNotEmpty) return fromEnv;
  return Directory(
    Platform.resolvedExecutable,
  ).parent.parent.parent.parent.parent.path;
}

void main() {
  setUpAll(() async {
    if (!_capture) return;
    PointyProductImageFrame.debugImageOverride = voucherPreviewArtResolver;
    final snapshot = _snapshot;
    if (snapshot != null) _useSnapshot(snapshot);
    // Arabic needs the app's font, and button labels resolve to Roboto, which
    // has no Arabic: point both at IBM Plex Sans Arabic.
    for (final family in const ['IBMPlexSansArabic', 'Roboto']) {
      final loader = FontLoader(family);
      for (final weight in const ['Regular', 'Medium', 'SemiBold', 'Bold']) {
        loader.addFont(
          rootBundle.load('assets/fonts/IBMPlexSansArabic-$weight.ttf'),
        );
      }
      await loader.load();
    }
    final iconFont = File(
      '${_flutterRoot()}/bin/cache/artifacts/material_fonts/'
      'MaterialIcons-Regular.otf',
    );
    if (iconFont.existsSync()) {
      final bytes = await iconFont.readAsBytes();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(Future.value(ByteData.view(bytes.buffer)))).load();
    }
  });

  tearDownAll(() {
    PointyProductImageFrame.debugImageOverride = null;
    voucherPreviewMenuSource = null;
    voucherPreviewArtByPath.clear();
    voucherPreviewPicks = const VoucherPreviewPicks();
  });

  /// Decoding the card art and the flags is real async work, which a widget
  /// test's fake clock never advances: step outside it to decode every image
  /// on screen, then let the frames land.
  Future<void> decodeImages(WidgetTester tester) async {
    await tester.runAsync(() async {
      for (final element in find.byType(Image).evaluate().toList()) {
        final image = element.widget as Image;
        await precacheImage(image.image, element);
      }
    });
  }

  Future<void> shoot(
    WidgetTester tester, {
    required String screen,
    required Size size,
    required String name,
    bool dark = false,
    bool settles = true,
    double ratio = 2.0,
    Future<void> Function(WidgetTester tester)? act,
  }) async {
    debugDisableShadows = false;
    tester.view.devicePixelRatio = ratio;
    tester.view.physicalSize = size * ratio;
    addTearDown(tester.view.reset);

    Future<void> settle() => settles
        ? tester.pumpAndSettle()
        : tester.pump(const Duration(milliseconds: 600));

    await tester.pumpWidget(
      VoucherMenuPreviewApp(
        screen: screen,
        theme: _withButtonFont(dark ? PointyTheme.dark() : PointyTheme.light()),
        instant: true,
      ),
    );
    await settle();
    await decodeImages(tester);
    await settle();
    // A sheet opens a frame after the menu lands; its own art needs decoding.
    await decodeImages(tester);
    await settle();
    if (act != null) {
      await act(tester);
      await settle();
      // Whatever the action brought on screen needs its art decoded too.
      await decodeImages(tester);
      await settle();
    }
    try {
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile(
          'goldens/${_snapshot == null ? 'voucher_menu' : 'voucher_real'}_$name.png',
        ),
      );
    } finally {
      debugDisableShadows = true;
    }
  }

  const phone = Size(390, 844);
  const till = Size(1024, 768);
  const wide = Size(1366, 900);

  for (final (label, size) in const [
    ('phone', phone),
    ('till', till),
    ('wide', wide),
  ]) {
    testWidgets('the menu, $label', (tester) async {
      await shoot(tester, screen: 'menu', size: size, name: 'menu_$label');
    }, skip: !_capture);

    testWidgets('the menu, $label, dark', (tester) async {
      await shoot(
        tester,
        screen: 'menu',
        size: size,
        name: 'menu_${label}_dark',
        dark: true,
      );
    }, skip: !_capture);

    testWidgets('a brand sold for several countries, $label', (tester) async {
      await shoot(
        tester,
        screen: 'sheet-countries',
        size: size,
        name: 'sheet_countries_$label',
      );
    }, skip: !_capture);

    testWidgets('a brand sold for several countries, $label, dark', (
      tester,
    ) async {
      await shoot(
        tester,
        screen: 'sheet-countries',
        size: size,
        name: 'sheet_countries_${label}_dark',
        dark: true,
      );
    }, skip: !_capture);
  }

  testWidgets('the whole shelf in one view, tall', (tester) async {
    await shoot(
      tester,
      screen: 'menu',
      size: const Size(1366, 5600),
      ratio: 1.0,
      name: 'menu_tall',
    );
  }, skip: !_capture);

  // One tab of the shelf at a time on a till: the tab names are the catalog's.
  for (final (tab, name) in const [
    ('اتصالات', 'telecom'),
    ('شحن دولي', 'intl_topup'),
    ('الإنترنت', 'internet'),
    ('التلفزيون والترفيه', 'tv'),
    ('الألعاب', 'gaming'),
    ('بطاقات الهدايا', 'gift_cards'),
    ('التعليم والخدمات', 'services'),
  ]) {
    testWidgets('one category of the shelf: $name, till', (tester) async {
      await shoot(
        tester,
        screen: 'menu',
        size: till,
        name: 'menu_tab_${name}_till',
        act: (tester) async {
          final label = find.text(tab);
          if (label.evaluate().isEmpty) {
            // Past the end of the row on a till: scroll to it, as a cashier would.
            await tester.scrollUntilVisible(
              label,
              120,
              scrollable: find
                  .ancestor(
                    of: find.byKey(const ValueKey('voucher_category_all')),
                    matching: find.byWidgetPredicate(
                      (widget) =>
                          widget is Scrollable &&
                          widget.axis == Axis.horizontal,
                    ),
                  )
                  .first,
            );
          }
          await tester.ensureVisible(label.last);
          await tester.pumpAndSettle();
          await tester.tap(label.last);
        },
      );
    }, skip: !_capture || _snapshot == null);
  }

  testWidgets('a card under the keyboard and one under the mouse, till', (
    tester,
  ) async {
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    addTearDown(
      () => FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.automatic,
    );
    await shoot(
      tester,
      screen: 'menu',
      size: till,
      name: 'focus_hover_till',
      act: (tester) async {
        final focused = find.byKey(
          ValueKey('voucher_brand_${voucherPreviewPicks.seeded}'),
        );
        Focus.of(
          tester.element(
            find.descendant(of: focused, matching: find.byType(Column)).first,
          ),
        ).requestFocus();
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        addTearDown(mouse.removePointer);
        await mouse.addPointer(location: Offset.zero);
        await mouse.moveTo(
          tester.getCenter(
            find.byKey(ValueKey('voucher_brand_${voucherPreviewPicks.single}')),
          ),
        );
      },
    );
  }, skip: !_capture);

  // A few brands whose denominations are not plain money: game credit, diamonds,
  // Riot points, USDT, subscriptions by length, two countries on one brand.
  for (final key in const [
    'pubg',
    'free_fire',
    'mobile_legends',
    'league_of_legends',
    'binance',
    'mastercard',
    'orange',
    'airtel',
    'sohoul',
    'raad',
    'giga',
    'vodafone',
  ]) {
    testWidgets('the sheet of $key, till', (tester) async {
      await shoot(
        tester,
        screen: 'brand:$key',
        size: till,
        name: 'brand_${key}_till',
      );
    }, skip: !_capture || _snapshot == null);
  }

  testWidgets('a one-country brand, till', (tester) async {
    await shoot(tester, screen: 'sheet', size: till, name: 'sheet_till');
  }, skip: !_capture);

  testWidgets('a cashier sees no cost, phone', (tester) async {
    await shoot(tester, screen: 'cashier', size: phone, name: 'cashier_phone');
  }, skip: !_capture);

  testWidgets('nothing to sell, till', (tester) async {
    await shoot(tester, screen: 'empty', size: till, name: 'empty_till');
  }, skip: !_capture);

  testWidgets('the menu could not be read, till', (tester) async {
    await shoot(tester, screen: 'error', size: till, name: 'error_till');
  }, skip: !_capture);

  testWidgets('the first read on its way, phone', (tester) async {
    await shoot(
      tester,
      screen: 'loading',
      size: phone,
      name: 'loading_phone',
      settles: false,
    );
  }, skip: !_capture);

  /// «كروت دفتر» in Shop Settings → Integrations: a switch, not a login.
  Future<void> shootProvider(
    WidgetTester tester, {
    required bool enabled,
    required String name,
    bool dark = false,
  }) async {
    debugDisableShadows = false;
    const ratio = 2.0;
    tester.view.devicePixelRatio = ratio;
    tester.view.physicalSize = phone * ratio;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        locale: const Locale('ar'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        theme: _withButtonFont(dark ? PointyTheme.dark() : PointyTheme.light()),
        home: IntegrationsPage(
          viewModel: IntegrationsViewModel(_PointyRepo(enabled: enabled)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await precacheImage(
        const AssetImage('assets/integrations/pointy.png'),
        tester.element(find.byType(IntegrationsPage)),
      );
    });
    await tester.pumpAndSettle();
    try {
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/pointy_provider_$name.png'),
      );
    } finally {
      debugDisableShadows = true;
    }
  }

  testWidgets('the provider, off', (tester) async {
    await shootProvider(tester, enabled: false, name: 'off_phone');
  }, skip: !_capture);

  testWidgets('the provider, on', (tester) async {
    await shootProvider(tester, enabled: true, name: 'on_phone');
  }, skip: !_capture);

  testWidgets('the provider, on, dark', (tester) async {
    await shootProvider(
      tester,
      enabled: true,
      name: 'on_phone_dark',
      dark: true,
    );
  }, skip: !_capture);
}

class _PointyRepo extends IntegrationsRepository {
  _PointyRepo({required this.enabled}) : super(PosApiService());

  final bool enabled;

  @override
  Future<Result<List<IntegrationProvider>>> loadProviders() async => Ok([
    IntegrationProvider(
      key: IntegrationProviderKey.pointy,
      availability: IntegrationAvailability.available,
      capabilities: const [
        IntegrationCapability.balance,
        IntegrationCapability.vouchers,
      ],
      settings: const [
        IntegrationSetting(
          key: IntegrationSettingKey.lowBalanceThreshold,
          kind: 'amount',
          value: '50',
          defaultValue: '50',
          minimum: 0,
          maximum: 1000000,
        ),
      ],
      isConfigurable: true,
      account: IntegrationAccount(
        provider: IntegrationProviderKey.pointy,
        isConfigured: true,
        isActive: enabled,
        balance: 345.5,
        lastCheckedAt: DateTime(2026, 10, 7, 9, 30),
      ),
    ),
  ]);
}
