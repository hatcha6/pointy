// Dev-only preview harness for the till's «كروت دفتر» voucher menu.
//
// Renders the real catalog pane (with the «كروت دفتر» chip picked, so the menu
// stands in for the product grid) beside the real cart pane, on fake
// repositories — no backend, no auth, no register-session gate. The card art
// and the flags are drawn in code (lib/dev/voucher_menu_fixtures.dart). Run
// with `make frontend-voucher-menu-preview`, then pick a screen:
//
//   ?screen=board            every state below in fixed device frames
//   ?screen=menu             the menu in the till (a manager)
//   ?screen=menu-dark        the same against the dark palette
//   ?screen=sheet            a one-country brand's sheet (ليبيانا)
//   ?screen=sheet-countries  a brand sold for several countries (آيتونز)
//   ?screen=brand:<key>      any brand's sheet by its key (pubg, orange, sohoul ...)
//   ?screen=cashier          that sheet for a cashier: no cost, no profit
//   ?screen=manager          that sheet for a manager: the profit per card
//   ?screen=empty            nothing to sell (the cards are not switched on)
//   ?screen=error            the menu could not be read
//   ?screen=loading          the first read still on its way
//
// See AGENTS.md ("UI preview harness") for the pattern. Not part of the
// shipping app. Safe to delete.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/models/product.dart';
import 'package:pointy_frontend/src/data/models/product_category.dart';
import 'package:pointy_frontend/src/data/models/product_page.dart';
import 'package:pointy_frontend/src/data/models/product_query.dart';
import 'package:pointy_frontend/src/data/models/register_session.dart';
import 'package:pointy_frontend/src/data/models/sale_order.dart';
import 'package:pointy_frontend/src/data/models/voucher_menu.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/contact_repository.dart';
import 'package:pointy_frontend/src/data/repositories/integrations_repository.dart';
import 'package:pointy_frontend/src/data/repositories/printing_repository.dart';
import 'package:pointy_frontend/src/data/repositories/register_session_repository.dart';
import 'package:pointy_frontend/src/data/repositories/sale_repository.dart';
import 'package:pointy_frontend/src/data/repositories/shop_settings_repository.dart';
import 'package:pointy_frontend/src/data/services/local_scoped_json_storage.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/pos/view_models/pos_view_model.dart';
import 'package:pointy_frontend/src/features/pos/views/pos_cart_pane.dart';
import 'package:pointy_frontend/src/features/pos/views/pos_catalog_pane.dart';
import 'package:pointy_frontend/src/features/pos/views/pos_voucher_brand_sheet.dart';
import 'package:pointy_frontend/src/shared/app_navigation_drawer.dart';
import 'package:pointy_frontend/src/shared/catalog/catalog.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/formatters.dart';
import 'package:pointy_frontend/src/shared/order/order.dart';
import 'package:pointy_frontend/src/shared/responsive/responsive.dart';
import 'package:pointy_frontend/src/shared/shell/shell.dart';

import 'voucher_menu_fixtures.dart';

void main() {
  PointyProductImageFrame.debugImageOverride = voucherPreviewArtResolver;
  runApp(VoucherMenuPreviewApp(screen: _screen()));
}

String _screen() {
  final uri = Uri.base;
  final direct = uri.queryParameters['screen'];
  if (direct != null) {
    return direct;
  }
  final fragment = uri.fragment;
  final parsed = Uri.tryParse(
    fragment.startsWith('/') ? fragment.substring(1) : fragment,
  );
  return parsed?.queryParameters['screen'] ?? 'menu';
}

/// Public so the capture test pumps exactly what the harness serves. The
/// caller sets `PointyProductImageFrame.debugImageOverride` to
/// [voucherPreviewArtResolver] so the card art draws without a server.
class VoucherMenuPreviewApp extends StatelessWidget {
  const VoucherMenuPreviewApp({
    super.key,
    required this.screen,
    this.theme,
    this.instant = false,
  });

  final String screen;

  /// Wins over the screen's own light/dark choice.
  final ThemeData? theme;

  /// Answer every fake read at once (the capture test); otherwise a short
  /// delay shows the skeleton the way a real till would.
  final bool instant;

  @override
  Widget build(BuildContext context) {
    final dark = screen.endsWith('-dark');
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: theme ?? (dark ? PointyTheme.dark() : PointyTheme.light()),
      builder: (context, child) => PointyNavigationRailScope(
        isActive: false,
        controller: PointyNavigationRailController(),
        child: child ?? const SizedBox.shrink(),
      ),
      home: switch (screen) {
        'board' => _DesignBoard(instant: instant),
        _ => _surfaceFor(screen, instant: instant),
      },
    );
  }
}

Widget _surfaceFor(String screen, {required bool instant}) {
  return switch (screen) {
    'sheet' => _TillSurface(
      instant: instant,
      openBrand: voucherPreviewPicks.single,
    ),
    'sheet-countries' || 'manager' => _TillSurface(
      instant: instant,
      openBrand: voucherPreviewPicks.countries,
    ),
    'cashier' => _TillSurface(
      instant: instant,
      openBrand: voucherPreviewPicks.countries,
      cashier: true,
    ),
    final named when named.startsWith('brand:') => _TillSurface(
      instant: instant,
      openBrand: named.substring('brand:'.length),
    ),
    'empty' => _TillSurface(instant: instant, menu: _MenuState.empty),
    'error' => _TillSurface(instant: instant, menu: _MenuState.error),
    'loading' => _TillSurface(instant: instant, menu: _MenuState.loading),
    _ => _TillSurface(instant: instant),
  };
}

enum _MenuState { ready, empty, error, loading }

/// The till as a cashier sees it with the «كروت دفتر» chip picked: the real
/// catalog pane and cart pane, two-pane from a tablet up, the cart behind a
/// launcher on a phone. One card is already in the invoice, so the line's
/// name can be read.
class _TillSurface extends StatefulWidget {
  const _TillSurface({
    required this.instant,
    this.menu = _MenuState.ready,
    this.openBrand,
    this.cashier = false,
  });

  final bool instant;
  final _MenuState menu;

  /// Opens this brand's sheet once the menu is on screen.
  final String? openBrand;

  /// A cashier: no cost in the menu, so no profit line.
  final bool cashier;

  @override
  State<_TillSurface> createState() => _TillSurfaceState();
}

class _TillSurfaceState extends State<_TillSurface> {
  late final PosViewModel _viewModel;
  late final VoucherMenu _menu = voucherPreviewMenu(withCost: !widget.cashier);

  @override
  void initState() {
    super.initState();
    _viewModel = PosViewModel(
      _PreviewCatalogRepository(),
      _PreviewRegisterSessionRepository(),
      _PreviewSaleRepository(_menu),
      ShopSettingsRepository(PosApiService()),
      PrintingRepository(PosApiService()),
      integrationsRepository: _PreviewIntegrationsRepository(
        state: widget.menu,
        menu: _menu,
        delay: widget.instant
            ? Duration.zero
            : const Duration(milliseconds: 450),
      ),
      sessionStorage: MemoryScopedJsonStorage(),
    );
    unawaited(_open());
  }

  Future<void> _open() async {
    await _viewModel.loadCurrentRegisterSession();
    await _viewModel.resumeRegisterSession();
    await _viewModel.applyQuery(
      _viewModel.query.copyWith(categories: const [_vouchersCategory]),
    );
    // One card already sold into the invoice: the line names the brand, the
    // country and the denomination.
    final seeded = _menu.brands.firstWhere(
      (brand) => brand.key == voucherPreviewPicks.seeded,
    );
    final card = seeded.variantFor(seeded.items[1]);
    if (card != null) {
      _viewModel.addVariant(card, source: 'seed');
    }
    final brandKey = widget.openBrand;
    if (brandKey == null || widget.menu != _MenuState.ready) {
      return;
    }
    await _viewModel.voucherMenu.ensureLoaded();
    if (!mounted) {
      return;
    }
    final menu = _viewModel.voucherMenu.menu ?? _menu;
    final brand = menu.brands.firstWhere((brand) => brand.key == brandKey);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        // The preview shows the owner's view as if F9 had revealed cost.
        unawaited(
          showPosVoucherBrandSheet(
            context,
            brand: brand,
            menu: menu,
            showsProfit: true,
          ),
        );
      }
    });
  }

  @override
  void dispose() {
    _viewModel.dispose();
    super.dispose();
  }

  AuthorizationCapabilities get _caps =>
      widget.cashier ? _cashierCaps : _managerCaps;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _viewModel,
      builder: (context, _) {
        final l10n = AppLocalizations.of(context)!;
        return PointyScaffold(
          // The real drawer, so a desktop-width frame spends the same 88px on
          // the navigation rail the till does.
          drawer: AppNavigationDrawer(
            selectedDestination: AppNavigationDestination.pos,
            navigation: _PreviewNavigation(cashier: widget.cashier),
          ),
          appBar: PointyAppBar(
            style: PointyAppBarStyle.highFocus,
            leading: const PointyNavigationMenuButton(),
            title: Text(l10n.appTitle),
          ),
          body: _Workspace(viewModel: _viewModel, capabilities: _caps),
        );
      },
    );
  }
}

class _Workspace extends StatelessWidget {
  const _Workspace({required this.viewModel, required this.capabilities});

  final PosViewModel viewModel;
  final AuthorizationCapabilities capabilities;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final catalog = PosCatalogPane(
          viewModel: viewModel,
          capabilities: capabilities,
        );
        if (AppBreakpoints.usesTwoPane(width)) {
          return TwoPaneLayout(
            minPrimaryWidth: 390,
            secondaryPaneMaxWidth: AppPaneWidths.orderPaneMaxWidthFor(width),
            primaryPane: catalog,
            secondaryPane: PosCartPane(
              viewModel: viewModel,
              contactRepository: ContactRepository(PosApiService()),
              capabilities: capabilities,
            ),
          );
        }
        final l10n = AppLocalizations.of(context)!;
        return Column(
          children: [
            Expanded(child: catalog),
            PointyCompactOrderLauncher(
              title: l10n.currentSaleTitle,
              lineCountLabel: l10n.lineItemCount(viewModel.cart.length),
              totalLabel: formatMoney(viewModel.total),
              actionLabel: l10n.openCartSheetButton,
              icon: Icons.shopping_cart_checkout_outlined,
              onPressed: () {},
            ),
          ],
        );
      },
    );
  }
}

/// Every state at once, in fixed device frames, for one review screenshot.
/// Size the browser large (e.g. 2900x2900) so Flutter paints all of it.
class _DesignBoard extends StatelessWidget {
  const _DesignBoard({required this.instant});

  final bool instant;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFFE7E5E0),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Wrap(
          spacing: 24,
          runSpacing: 24,
          children: [
            _Frame(
              label: 'Menu · phone',
              size: const Size(390, 844),
              child: _TillSurface(instant: instant),
            ),
            _Frame(
              label: 'Menu · compact till 1024×768',
              size: const Size(1024, 768),
              child: _TillSurface(instant: instant),
            ),
            _Frame(
              label: 'Menu · wide 1366×900',
              size: const Size(1366, 900),
              child: _TillSurface(instant: instant),
            ),
            _Frame(
              label: 'Sheet · countries · phone',
              size: const Size(390, 844),
              child: _TillSurface(
                instant: instant,
                openBrand: voucherPreviewPicks.countries,
              ),
            ),
            _Frame(
              label: 'Sheet · one country · till',
              size: const Size(1024, 768),
              child: _TillSurface(
                instant: instant,
                openBrand: voucherPreviewPicks.single,
              ),
            ),
            _Frame(
              label: 'Empty · phone',
              size: const Size(390, 844),
              child: _TillSurface(instant: instant, menu: _MenuState.empty),
            ),
            _Frame(
              label: 'Error · phone',
              size: const Size(390, 844),
              child: _TillSurface(instant: instant, menu: _MenuState.error),
            ),
          ],
        ),
      ),
    );
  }
}

class _Frame extends StatelessWidget {
  const _Frame({required this.label, required this.size, required this.child});

  final String label;
  final Size size;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            label,
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              color: Color(0xFF101828),
            ),
          ),
        ),
        ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: SizedBox.fromSize(
            size: size,
            child: MediaQuery(
              data: MediaQuery.of(context).copyWith(
                size: size,
                padding: EdgeInsets.zero,
                viewInsets: EdgeInsets.zero,
                viewPadding: EdgeInsets.zero,
              ),
              child: child,
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

const _vouchersCategory = ProductCategory(
  id: 99,
  name: 'كروت دفتر',
  isQuickAccess: true,
  isSystem: true,
  systemKey: ProductCategorySystemKey.pointyVouchers,
);

final PosUser _managerUser = PosUser.fromJson(const {
  'id': 1,
  'username': 'manager',
  'role': 'manager',
  'permissions': <String>[],
});

final PosUser _cashierUser = PosUser.fromJson(const {
  'id': 2,
  'username': 'cashier',
  'role': 'cashier',
  'permissions': <String>[],
});

final AuthorizationCapabilities _managerCaps =
    AuthorizationCapabilities.forUser(_managerUser);
final AuthorizationCapabilities _cashierCaps =
    AuthorizationCapabilities.forUser(_cashierUser);

class _PreviewNavigation implements AppNavigation {
  const _PreviewNavigation({required this.cashier});

  final bool cashier;

  @override
  PosUser get currentUser => cashier ? _cashierUser : _managerUser;

  @override
  AuthorizationCapabilities get capabilities =>
      cashier ? _cashierCaps : _managerCaps;

  @override
  void navigateTo(
    BuildContext context,
    AppNavigationDestination destination, {
    AppNavigationDestination? from,
  }) {}

  @override
  void openAiChat(
    BuildContext context, {
    String? seedPrompt,
    bool autoSend = false,
    AppNavigationDestination? from,
  }) {}

  @override
  void logout(BuildContext context) {}
}

class _PreviewIntegrationsRepository extends IntegrationsRepository {
  _PreviewIntegrationsRepository({
    required this.state,
    required this.menu,
    required this.delay,
  }) : super(PosApiService());

  final _MenuState state;
  final VoucherMenu menu;
  final Duration delay;

  @override
  Future<Result<VoucherMenu>> loadVoucherMenu() async {
    if (state == _MenuState.loading) {
      return Completer<Result<VoucherMenu>>().future;
    }
    if (delay > Duration.zero) {
      await Future<void>.delayed(delay);
    }
    return switch (state) {
      _MenuState.error => Error(Exception('offline (preview)')),
      _MenuState.empty => Ok(voucherPreviewEmptyMenu()),
      _ => Ok(menu),
    };
  }
}

/// A few ordinary products, so a search typed over the menu has a grid to
/// fall back to.
class _PreviewCatalogRepository extends CatalogRepository {
  _PreviewCatalogRepository() : super(PosApiService());

  static final _products = [
    for (final (id, name, price) in const [
      (501, 'مياه معدنية 1.5 لتر', 1.25),
      (502, 'عصير برتقال', 2.75),
      (503, 'شوكولاتة بالحليب', 3.5),
    ])
      Product.fromJson({
        'id': id,
        'name': name,
        'quantity_on_hand': 40,
        'default_variant': {
          'id': id * 10,
          'product': id,
          'sku': 'SKU-$id',
          'unit_price': price.toStringAsFixed(2),
          'quantity_on_hand': 40,
          'is_default': true,
        },
      }),
  ];

  @override
  Future<Result<ProductPage>> loadProducts({
    required ProductQuery query,
    int page = 1,
    bool bypassCache = false,
  }) async {
    final term = query.search.trim();
    return Ok(
      ProductPage(
        products: page > 1
            ? const []
            : [
                for (final product in _products)
                  if (term.isEmpty || product.name.contains(term)) product,
              ],
        hasMore: false,
      ),
    );
  }

  @override
  Future<Result<List<ProductCategory>>> loadQuickAccessCategories() async {
    return const Ok([
      ProductCategory(id: 1, name: 'مشروبات', isQuickAccess: true),
      _vouchersCategory,
      ProductCategory(id: 2, name: 'وجبات خفيفة', isQuickAccess: true),
      ProductCategory(id: 3, name: 'منظفات', isQuickAccess: true),
    ]);
  }
}

class _PreviewRegisterSessionRepository extends RegisterSessionRepository {
  _PreviewRegisterSessionRepository() : super(PosApiService());

  @override
  Future<Result<RegisterSession?>> loadCurrentSession() async {
    return Ok(
      RegisterSession(
        id: 12,
        sessionNumber: 'RS-12',
        status: 'open',
        ownerName: 'سالم',
        openingCash: 100,
        openedAt: DateTime(2026, 10, 7, 8),
      ),
    );
  }
}

/// Totals the cart from the menu's own prices, so the panel reconciles.
class _PreviewSaleRepository extends SaleRepository {
  _PreviewSaleRepository(VoucherMenu menu)
    : _prices = {
        for (final brand in menu.brands)
          for (final item in brand.items) item.variantId: item.price,
      },
      super(PosApiService());

  final Map<int, double> _prices;

  @override
  Future<Result<SaleDiscountPreview>> previewDiscounts(
    SaleDiscountPreviewDraft draft,
  ) async {
    var subtotal = 0.0;
    for (final line in draft.lines) {
      subtotal += (_prices[line.variantId] ?? 0) * line.quantity;
    }
    return Ok(
      SaleDiscountPreview(
        subtotal: subtotal,
        discountTotal: 0,
        total: subtotal,
      ),
    );
  }

  @override
  Future<Result<Map<int, double>>> loadLineCosts(List<int> variantIds) async =>
      const Ok({});
}
