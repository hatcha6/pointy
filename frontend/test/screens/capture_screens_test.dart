// Renders real screens to PNG, headlessly, so a change can be looked at
// instead of described.
//
// Not a golden gate: an ordinary `flutter test` run skips every case here, so
// a deliberate design change never fails CI with a pixel diff. Capture with:
//
//   POINTY_CAPTURE_SCREENS=1 flutter test test/screens --update-goldens
//
// The PNGs land in test/screens/goldens/.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/integration_card.dart';
import 'package:pointy_frontend/src/data/models/integration_provider.dart';
import 'package:pointy_frontend/src/data/models/integration_recent_search.dart';
import 'package:pointy_frontend/src/data/repositories/integrations_repository.dart';
import 'package:pointy_frontend/src/data/services/integrations_api_client.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/pos/view_models/integration_recharge_view_model.dart';
import 'package:pointy_frontend/src/features/pos/views/integration_recharge_screen.dart';
import 'package:pointy_frontend/src/features/pos/views/pos_catalog_pane.dart';
import 'package:pointy_frontend/src/shared/catalog/pointy_catalog_pane.dart';
import 'package:pointy_frontend/src/features/settings/view_models/integrations_view_model.dart';
import 'package:pointy_frontend/src/features/settings/views/integration_action_button.dart';
import 'package:pointy_frontend/src/features/settings/views/integration_float_sheet.dart';
import 'package:pointy_frontend/src/features/settings/views/integration_prices_sheet.dart';
import 'package:pointy_frontend/src/features/settings/views/integrations_page.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/responsive/responsive.dart';
import 'package:pointy_frontend/src/shared/shell/shell.dart';

final bool _capture = Platform.environment['POINTY_CAPTURE_SCREENS'] == '1';

const Size kPhone = Size(430, 1400);
// Tall on purpose: a capture is for reading the whole screen at once, not for
// reproducing a viewport. The layout logic still keys off width.
const Size kWide = Size(1280, 1150);

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
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: patch(theme.elevatedButtonTheme.style),
    ),
  );
}

/// Where the Flutter SDK lives, so the icon font can be found.
String _flutterRoot() {
  final fromEnv = Platform.environment['FLUTTER_ROOT'];
  if (fromEnv != null && fromEnv.isNotEmpty) return fromEnv;
  // dart:io's resolvedExecutable is <root>/bin/cache/dart-sdk/bin/dart
  return Directory(
    Platform.resolvedExecutable,
  ).parent.parent.parent.parent.parent.path;
}

void main() {
  setUpAll(() async {
    if (!_capture) return;
    // Without the real font every Arabic glyph renders as a box, and the
    // screenshot would be worse than no screenshot.
    final loader = FontLoader('IBMPlexSansArabic');
    for (final weight in const ['Regular', 'Medium', 'SemiBold', 'Bold']) {
      loader.addFont(
        rootBundle.load('assets/fonts/IBMPlexSansArabic-$weight.ttf'),
      );
    }
    await loader.load();

    // Button labels resolve to Roboto, which carries no Arabic glyphs. On a
    // real till the platform's own font covers them; in a headless test there
    // is no system fallback, so point Roboto at the app's font and the
    // capture shows what a shop actually sees instead of a row of boxes.
    final robotoStandIn = FontLoader('Roboto');
    for (final weight in const ['Regular', 'Medium', 'SemiBold', 'Bold']) {
      robotoStandIn.addFont(
        rootBundle.load('assets/fonts/IBMPlexSansArabic-$weight.ttf'),
      );
    }
    await robotoStandIn.load();

    // Material icons ship as a font in the Flutter cache rather than in the
    // app bundle, so without this every icon captures as an empty box.
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

  Future<void> shoot(
    WidgetTester tester, {
    required Size size,
    required Widget child,
    required String name,
    bool dark = false,
    // Runs after the tree has settled and before the shutter, for states
    // that only exist once something has been pressed.
    Future<void> Function(WidgetTester tester)? after,
  }) async {
    // `size` is LOGICAL pixels — the units breakpoints are decided in.
    // physicalSize is in device pixels, so it has to be scaled by the ratio;
    // setting it to the logical size with a ratio of 2 silently renders every
    // screen at HALF the intended width, which had the wide-till captures
    // coming out in the phone layout and looking correct while being wrong.
    // flutter_test draws every shadow as a hard black outline so goldens stay
    // deterministic. These PNGs are for looking at, not for diffing, and that
    // outline reads as a 2px black border somebody put there on purpose —
    // most visibly around menus and dialogs. Let the real shadow through.
    // Restored before this call returns, not in a tearDown: the framework
    // checks painting debug flags before tearDowns run.
    debugDisableShadows = false;

    const ratio = 2.0;
    tester.view.devicePixelRatio = ratio;
    tester.view.physicalSize = size * ratio;
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
        // Button styles in PointyComponentStyles set an explicit textStyle
        // with no fontFamily, which replaces the ambient one — so on a real
        // device button labels come out in the platform font. Patch the
        // family back in for the capture so these PNGs show the layout rather
        // than a font-fallback artifact. (The underlying theme issue is
        // tracked separately.)
        theme: _withButtonFont(dark ? PointyTheme.dark() : PointyTheme.light()),
        builder: (context, inner) => PointyNavigationRailScope(
          isActive: false,
          controller: PointyNavigationRailController(),
          child: inner ?? const SizedBox.shrink(),
        ),
        home: child,
      ),
    );
    await tester.pumpAndSettle();

    // Decoding a real asset is real async I/O, which a widget test's fake
    // clock never advances — the image stays frameless forever and the
    // capture shows an empty box where the logo should be. runAsync steps
    // outside the fake clock just long enough to decode it.
    await tester.runAsync(() async {
      for (final asset in const [
        'assets/integrations/hdbox.png',
        'assets/integrations/lnet.png',
        'assets/integrations/qareeb.png',
      ]) {
        // Ask the bundle first. precacheImage on a missing asset reports
        // through FlutterError, which flutter_test counts as a failure no
        // matter what this catch does — and a provider with no artwork yet
        // is the normal case, not a broken test.
        try {
          await rootBundle.load(asset);
        } catch (_) {
          continue;
        }
        await precacheImage(
          AssetImage(asset),
          tester.element(find.byType(MaterialApp)),
        );
      }
    });
    await tester.pumpAndSettle();

    if (after != null) {
      await after(tester);
      await tester.pumpAndSettle();
    }

    try {
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/$name.png'),
      );
    } finally {
      debugDisableShadows = true;
    }
  }

  testWidgets('integrations settings', (tester) async {
    await shoot(
      tester,
      size: kWide,
      name: 'settings_integrations',
      child: IntegrationsPage(
        viewModel: IntegrationsViewModel(_SettingsRepo()),
      ),
    );
  }, skip: !_capture);

  testWidgets('integration prices', (tester) async {
    final viewModel = IntegrationsViewModel(_PricesRepo());
    await viewModel.loadPrices(IntegrationProviderKey.hdbox);
    await shoot(
      tester,
      size: const Size(760, 1240),
      name: 'settings_prices',
      child: Scaffold(
        appBar: AppBar(title: const Text('أسعار البيع · HD Box')),
        body: IntegrationPricesForm(
          viewModel: viewModel,
          providerKey: IntegrationProviderKey.hdbox,
        ),
      ),
    );
  }, skip: !_capture);

  testWidgets('pos catalog header', (tester) async {
    // Where the top-up action actually lives: the catalog pane's header, in
    // the same slot purchasing puts "new product".
    await shoot(
      tester,
      size: const Size(1280, 520),
      name: 'pos_recharge_button',
      child: Scaffold(
        body: PointyCatalogPane(
          title: 'المنتجات',
          resultCount: 128,
          hasMoreResults: true,
          isLoading: false,
          headerAction: PosRechargeButton(
            providers: const ['hdbox'],
            onSelected: (_) {},
          ),
          search: const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: TextField(
              decoration: InputDecoration(
                hintText: 'ابحث أو امسح الباركود',
                prefixIcon: Icon(Icons.search),
              ),
            ),
          ),
          grid: const SizedBox(height: 220),
        ),
      ),
    );
  }, skip: !_capture);

  testWidgets('pos catalog header - narrow till', (tester) async {
    await shoot(
      tester,
      size: const Size(680, 320),
      name: 'pos_recharge_button_narrow',
      child: Scaffold(
        body: PointyCatalogPane(
          title: 'المنتجات',
          resultCount: 128,
          hasMoreResults: true,
          isLoading: false,
          headerAction: PosRechargeButton(
            providers: const ['hdbox'],
            onSelected: (_) {},
          ),
          search: const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: TextField(
              decoration: InputDecoration(
                hintText: 'ابحث أو امسح الباركود',
                prefixIcon: Icon(Icons.search),
              ),
            ),
          ),
          grid: const SizedBox(height: 100),
        ),
      ),
    );
  }, skip: !_capture);

  testWidgets('pos catalog header - two providers', (tester) async {
    await shoot(
      tester,
      size: const Size(1280, 320),
      name: 'pos_recharge_menu',
      child: Scaffold(
        body: PointyCatalogPane(
          title: 'المنتجات',
          resultCount: 128,
          hasMoreResults: true,
          isLoading: false,
          headerAction: PosRechargeButton(
            providers: const ['hdbox', 'lnet'],
            onSelected: (_) {},
          ),
          search: const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: TextField(
              decoration: InputDecoration(
                hintText: 'ابحث أو امسح الباركود',
                prefixIcon: Icon(Icons.search),
              ),
            ),
          ),
          grid: const SizedBox(height: 100),
        ),
      ),
    );
  }, skip: !_capture);

  testWidgets('provider logo in dark mode', (tester) async {
    // The mark is black on transparency; without its chip it vanishes here.
    await shoot(
      tester,
      size: const Size(1280, 320),
      name: 'pos_recharge_button_dark',
      dark: true,
      child: Scaffold(
        body: PointyCatalogPane(
          title: 'المنتجات',
          resultCount: 128,
          hasMoreResults: true,
          isLoading: false,
          headerAction: PosRechargeButton(
            providers: const ['hdbox'],
            onSelected: (_) {},
          ),
          search: const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: TextField(
              decoration: InputDecoration(
                hintText: 'ابحث أو امسح الباركود',
                prefixIcon: Icon(Icons.search),
              ),
            ),
          ),
          grid: const SizedBox(height: 100),
        ),
      ),
    );
  }, skip: !_capture);

  testWidgets('expenses app bar - one provider', (tester) async {
    // The other end of the same feature: where a member of staff records the
    // money they paid into the float. Captured beside the actions it
    // competes with, which is the whole reason it is tonal and not filled.
    await shoot(
      tester,
      size: const Size(1280, 200),
      name: 'expenses_top_up_button',
      child: _expensesBar(const ['hdbox']),
    );
  }, skip: !_capture);

  testWidgets('expenses app bar - two providers', (tester) async {
    await shoot(
      tester,
      size: const Size(1280, 200),
      name: 'expenses_top_up_menu',
      child: _expensesBar(const ['hdbox', 'lnet']),
    );
  }, skip: !_capture);

  testWidgets('expenses app bar - menu open', (tester) async {
    // Each float named and marked, so nobody tops up the wrong account.
    await shoot(
      tester,
      size: const Size(1280, 320),
      name: 'expenses_top_up_menu_open',
      child: _expensesBar(const ['hdbox', 'lnet']),
      after: (tester) => tester.tap(find.text('شحن رصيد')),
    );
  }, skip: !_capture);

  testWidgets('expenses app bar - dark', (tester) async {
    // The mark's light chip has to survive an outlined button too, not just
    // the till's filled one.
    await shoot(
      tester,
      size: const Size(1280, 200),
      name: 'expenses_top_up_button_dark',
      dark: true,
      child: _expensesBar(const ['hdbox']),
    );
  }, skip: !_capture);

  testWidgets('integration float', (tester) async {
    final viewModel = IntegrationsViewModel(_FloatRepo());
    await viewModel.loadFloat(IntegrationProviderKey.hdbox);
    await shoot(
      tester,
      size: const Size(760, 1100),
      name: 'settings_float',
      child: Scaffold(
        appBar: AppBar(title: const Text('رصيد الوكالة · HD Box')),
        body: IntegrationFloatForm(
          viewModel: viewModel,
          providerKey: IntegrationProviderKey.hdbox,
        ),
      ),
    );
  }, skip: !_capture);

  testWidgets('recharge - expired card, phone', (tester) async {
    final viewModel = _recharge();
    await shoot(
      tester,
      size: kPhone,
      name: 'recharge_phone',
      child: _Host(viewModel: viewModel),
    );
  }, skip: !_capture);

  testWidgets('recharge - expired card, wide till', (tester) async {
    await shoot(
      tester,
      size: kWide,
      name: 'recharge_wide',
      child: _Host(viewModel: _recharge()),
    );
  }, skip: !_capture);

  testWidgets('recharge - LNET, the search-mode picker', (tester) async {
    await shoot(
      tester,
      size: kPhone,
      name: 'recharge_search_mode',
      child: _Host(viewModel: _rechargeLnet()),
    );
  }, skip: !_capture);

  testWidgets('recharge - LNET, the picker open', (tester) async {
    await shoot(
      tester,
      size: kPhone,
      name: 'recharge_search_mode_open',
      child: _Host(viewModel: _rechargeLnet()),
      after: (tester) =>
          tester.tap(find.byKey(const ValueKey('recharge_search_mode_picker'))),
    );
  }, skip: !_capture);

  testWidgets('recharge - as a dialog on a till', (tester) async {
    await shoot(
      tester,
      size: kWide,
      name: 'recharge_dialog',
      child: Scaffold(
        backgroundColor: const Color(0xFF6B6B6B),
        body: AdaptiveDialogSurface(
          size: AdaptiveModalSize.expanded,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(PointyRadii.card),
            child: _Host(viewModel: _recharge(), isDialog: true),
          ),
        ),
      ),
    );
  }, skip: !_capture);

  testWidgets('recharge - option chosen', (tester) async {
    final viewModel = _recharge();
    await shoot(
      tester,
      size: kWide,
      name: 'recharge_selected',
      child: _Host(viewModel: viewModel, selectIndex: 3),
    );
  }, skip: !_capture);

  testWidgets('recharge - status history tab', (tester) async {
    await shoot(
      tester,
      size: kWide,
      name: 'recharge_statuses',
      child: _Host(viewModel: _recharge(), statusTab: true),
    );
  }, skip: !_capture);

  testWidgets('recharge - card not found', (tester) async {
    await shoot(
      tester,
      size: kWide,
      name: 'recharge_notfound',
      child: _Host(viewModel: _recharge(refusal: 'not_found')),
    );
  }, skip: !_capture);
}

IntegrationRechargeViewModel _rechargeLnet() {
  return IntegrationRechargeViewModel(
    repository: _RechargeRepo(),
    provider: IntegrationProviderKey.lnet,
  );
}

IntegrationRechargeViewModel _recharge({String? refusal}) {
  return IntegrationRechargeViewModel(
    repository: _RechargeRepo(refusal: refusal),
    provider: IntegrationProviderKey.hdbox,
  );
}

/// Drives the lookup on mount so the capture shows a loaded screen.
class _Host extends StatefulWidget {
  const _Host({
    required this.viewModel,
    this.selectIndex,
    this.statusTab = false,
    this.isDialog = false,
  });

  final IntegrationRechargeViewModel viewModel;
  final int? selectIndex;
  final bool statusTab;
  final bool isDialog;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await widget.viewModel.lookup('210906803499');
      if (widget.statusTab) {
        await widget.viewModel.showHistoryKind(IntegrationHistoryKind.statuses);
      }
      final index = widget.selectIndex;
      if (index != null && index < widget.viewModel.snapshot!.offers.length) {
        widget.viewModel.selectOffer(widget.viewModel.snapshot!.offers[index]);
      }
    });
  }

  @override
  Widget build(BuildContext context) => IntegrationRechargeScreen(
    viewModel: widget.viewModel,
    isDialog: widget.isDialog,
  );
}

class _SettingsRepo extends IntegrationsRepository {
  _SettingsRepo() : super(PosApiService());

  @override
  Future<Result<List<IntegrationProvider>>> loadProviders() async {
    return Ok([
      IntegrationProvider(
        key: IntegrationProviderKey.hdbox,
        availability: IntegrationAvailability.available,
        capabilities: const [
          IntegrationCapability.balance,
          IntegrationCapability.lookup,
        ],
        fields: const [
          IntegrationField.baseUrl,
          IntegrationField.username,
          IntegrationField.password,
        ],
        secretFields: const [IntegrationField.password],
        defaultBaseUrl: 'http://cas.hdboxly.com:18688',
        isConfigurable: true,
        account: IntegrationAccount(
          provider: IntegrationProviderKey.hdbox,
          baseUrl: 'http://cas.hdboxly.com:18688',
          username: 'Alnassim',
          hasPassword: true,
          isConfigured: true,
          balance: 25,
          accountLabel: 'Alnassim',
          lastCheckedAt: DateTime(2026, 9, 19, 9, 14),
          lastConnectedAt: DateTime(2026, 9, 19, 9, 14),
        ),
      ),
      const IntegrationProvider(
        key: IntegrationProviderKey.lnet,
        availability: IntegrationAvailability.planned,
        blockedReason: IntegrationBlockedReason.portalUnreachable,
        capabilities: [
          IntegrationCapability.balance,
          IntegrationCapability.lookup,
          IntegrationCapability.recharge,
        ],
      ),
      const IntegrationProvider(
        key: IntegrationProviderKey.qareeb,
        availability: IntegrationAvailability.planned,
        blockedReason: IntegrationBlockedReason.awaitingAccess,
        capabilities: [
          IntegrationCapability.balance,
          IntegrationCapability.recharge,
        ],
      ),
    ]);
  }
}

class _RechargeRepo extends IntegrationsRepository {
  _RechargeRepo({this.refusal}) : super(PosApiService());

  final String? refusal;

  /// These captures are of a looked-up card; the screen asks for its recent
  /// searches as it opens, and must not reach for a real backend to get them.
  @override
  Future<Result<IntegrationRecentSearchPage>> loadRecentSearches({
    required String providerKey,
    String search = '',
    String? cursor,
  }) async =>
      Ok(const IntegrationRecentSearchPage(searches: [], hasMore: false));

  @override
  Future<Result<IntegrationCardSnapshot>> lookupCard({
    required String providerKey,
    required String cardNo,
    String searchBy = '',
  }) async {
    if (refusal != null) {
      return Error(IntegrationProviderRefusal(refusal!));
    }
    return Ok(
      IntegrationCardSnapshot(
        card: IntegrationCardInfo(
          cardNo: cardNo,
          status: 'On hold',
          statusId: 6,
          startAt: DateTime(2022, 11, 27),
          expireAt: DateTime(2026, 8, 1),
          packageName: 'HDBOX Full package',
        ),
        offers: const [
          // HD Box's real ladder: cost 25/65/125/220, sold at its recommended
          // 30/80/140/240. Durations only — package switches are not offered.
          IntegrationOffer(
            code: 'renew:1',
            kind: 'renew',
            label: '1 month 25.00\$',
            cost: 25,
            price: 30,
            months: 1,
          ),
          IntegrationOffer(
            code: 'renew:3',
            kind: 'renew',
            label: '3 month 65.00\$',
            cost: 65,
            price: 80,
            months: 3,
          ),
          IntegrationOffer(
            code: 'renew:6',
            kind: 'renew',
            label: '6 month 125.00\$',
            cost: 125,
            price: 140,
            months: 6,
          ),
          IntegrationOffer(
            code: 'renew:12',
            kind: 'renew',
            label: '12 month 220.00\$',
            cost: 220,
            price: 245,
            months: 12,
          ),
        ],
        serviceVariant: const IntegrationServiceVariant(
          id: 9001,
          productId: 4001,
          sku: 'INTEG-HDBOX',
          name: 'شحن اشتراك HD Box',
        ),
        balance: 25,
      ),
    );
  }

  @override
  Future<Result<IntegrationHistoryPage>> loadHistory({
    required String providerKey,
    required String cardNo,
    required IntegrationHistoryKind kind,
    int limit = 10,
    int offset = 0,
  }) async {
    if (kind == IntegrationHistoryKind.statuses) {
      return Ok(
        IntegrationHistoryPage(
          ok: true,
          kind: kind,
          total: 31,
          limit: limit,
          offset: offset,
          statuses: [
            IntegrationStatusEntry(
              fromStatus: 'Soon to expire',
              toStatus: 'On hold',
              operatorName: 'System',
              at: DateTime(2026, 8, 1),
            ),
            IntegrationStatusEntry(
              fromStatus: 'Active',
              toStatus: 'Soon to expire',
              operatorName: 'System',
              at: DateTime(2026, 7, 27),
            ),
            IntegrationStatusEntry(
              fromStatus: 'On hold',
              toStatus: 'Active',
              operatorName: 'Alnassim',
              action: 'Renew card',
              at: DateTime(2026, 6, 30),
            ),
          ],
        ),
      );
    }
    return Ok(
      IntegrationHistoryPage(
        ok: true,
        kind: kind,
        total: 6,
        limit: limit,
        offset: offset,
        purchases: [
          IntegrationPurchaseEntry(
            reference: '523415',
            cost: 25,
            months: 1,
            at: DateTime(2026, 6, 30),
            operatorName: 'Alnassim',
            isOurs: true,
          ),
          IntegrationPurchaseEntry(
            reference: '484140',
            cost: 65,
            months: 3,
            at: DateTime(2026, 3, 31),
            operatorName: 'zhra',
          ),
          IntegrationPurchaseEntry(
            reference: '376198',
            cost: 220,
            months: 12,
            at: DateTime(2025, 3, 29),
            operatorName: 'zhra',
          ),
          IntegrationPurchaseEntry(
            reference: '266230',
            cost: 210,
            months: 12,
            at: DateTime(2024, 3, 21),
            operatorName: 'hmeda',
          ),
        ],
      ),
    );
  }
}

/// The real field ladder: HD Box costs 25/65/125/220, the shop sells at
/// 30/80/140/240, and twelve months has slipped below cost after a rise.
class _PricesRepo extends IntegrationsRepository {
  _PricesRepo() : super(PosApiService());

  @override
  Future<Result<IntegrationPriceList>> loadPrices(String providerKey) async {
    return const Ok(
      IntegrationPriceList(
        options: [
          // Following HD Box's published card, untouched.
          IntegrationOptionPrice(
            optionCode: 'renew:1',
            kind: 'renew',
            months: 1,
            lastCost: 25,
            suggestedPrice: 30,
            isSuggested: true,
            effectivePrice: 30,
            margin: 5,
          ),
          IntegrationOptionPrice(
            optionCode: 'renew:3',
            kind: 'renew',
            months: 3,
            lastCost: 65,
            suggestedPrice: 80,
            isSuggested: true,
            effectivePrice: 80,
            margin: 15,
          ),
          // This shop decided to undercut the card.
          IntegrationOptionPrice(
            optionCode: 'renew:6',
            kind: 'renew',
            months: 6,
            lastCost: 125,
            price: 135,
            suggestedPrice: 140,
            effectivePrice: 135,
            margin: 10,
          ),
          // The provider raised cost past its own recommendation.
          IntegrationOptionPrice(
            optionCode: 'renew:12',
            kind: 'renew',
            months: 12,
            lastCost: 250,
            suggestedPrice: 240,
            isSuggested: true,
            effectivePrice: 240,
            margin: -10,
            isBelowCost: true,
          ),
        ],
      ),
    );
  }
}

/// A float that has been topped up, partly drawn, and disagrees with what the
/// provider says it holds.
class _FloatRepo extends IntegrationsRepository {
  _FloatRepo() : super(PosApiService());

  @override
  Future<Result<IntegrationFloat>> loadFloat(String providerKey) async {
    return const Ok(
      IntegrationFloat(
        expectedBalance: 780,
        toppedUp: 1000,
        drawn: 220,
        committed: 65,
        reportedBalance: 505,
        drift: -275,
        moneyAccountName: 'رصيد HDBOX — Alnassim',
      ),
    );
  }
}

/// The expenses app bar as the screen builds it, so the top-up action can be
/// judged against the actions standing next to it rather than on its own.
Widget _expensesBar(List<String> providers) {
  return Scaffold(
    appBar: AppBar(
      leading: const Icon(Icons.menu),
      title: const Text('المصروفات'),
      actions: [
        IconButton(onPressed: () {}, icon: const Icon(Icons.add)),
        Builder(
          builder: (context) {
            final l10n = AppLocalizations.of(context)!;
            return Center(
              child: Padding(
                padding: const EdgeInsetsDirectional.only(start: 4),
                child: IntegrationActionButton(
                  providers: providers,
                  onSelected: (_) {},
                  icon: Icons.account_balance_wallet_outlined,
                  menuLabel: l10n.integrationTopUpAction,
                  labelFor: l10n.integrationTopUpActionFor,
                  emphasis: IntegrationActionEmphasis.outlined,
                ),
              ),
            );
          },
        ),
        IconButton(onPressed: () {}, icon: const Icon(Icons.sell_outlined)),
        IconButton(onPressed: () {}, icon: const Icon(Icons.sync)),
      ],
    ),
    body: const SizedBox.shrink(),
  );
}
