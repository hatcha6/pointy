import 'dart:async';

// Dev-only preview harness for the POS and purchasing catalog browsers.
//
// Renders the real catalog panes inside faithful two-pane and compact
// workspaces (with the real cart / draft panes beside them) using fake
// repositories — no backend, no auth, no register-session gate. Pick a surface
// with a `?screen=` query param and resize the browser to test responsiveness.
// Run with:
//
//   flutter run -d web-server --web-port 8080 -t lib/dev/pos_preview.dart
//
// Screens: pos | purchase | pos-empty | purchase-empty | board
// Add `&theme=dark` to check either surface against the dark palette, and
// `&picker=on` for the search-mode picker a device can turn on (code / name).
//
// See AGENTS.md ("UI preview harness") for the pattern. Not part of the
// shipping app. Safe to delete.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/barcode_resolution.dart';
import 'package:pointy_frontend/src/data/models/contact.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/models/product.dart';
import 'package:pointy_frontend/src/data/models/product_category.dart';
import 'package:pointy_frontend/src/data/models/product_page.dart';
import 'package:pointy_frontend/src/data/models/product_query.dart';
import 'package:pointy_frontend/src/data/models/product_unit.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/data/models/product_variant_page.dart';
import 'package:pointy_frontend/src/data/models/purchase_submission.dart';
import 'package:pointy_frontend/src/data/models/purchase_suggestion.dart';
import 'package:pointy_frontend/src/data/models/unit_of_measure.dart';
import 'package:pointy_frontend/src/data/models/money_position.dart';
import 'package:pointy_frontend/src/data/models/sale_order.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/contact_repository.dart';
import 'package:pointy_frontend/src/data/repositories/printing_repository.dart';
import 'package:pointy_frontend/src/data/repositories/purchase_repository.dart';
import 'package:pointy_frontend/src/data/repositories/register_session_repository.dart';
import 'package:pointy_frontend/src/data/repositories/sale_repository.dart';
import 'package:pointy_frontend/src/data/repositories/shop_settings_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/pos/view_models/pos_view_model.dart';
import 'package:pointy_frontend/src/features/pos/views/pos_cart_pane.dart';
import 'package:pointy_frontend/src/features/pos/views/payment/payment_sheet.dart';
import 'package:pointy_frontend/src/features/pos/views/pos_catalog_pane.dart';
import 'package:pointy_frontend/src/features/pos/views/pos_shortcuts_sheet.dart';
import 'package:pointy_frontend/src/features/pos/views/unit_quantity_sheet.dart';
import 'package:pointy_frontend/src/shared/barcode/scan_feedback_sounds.dart';
import 'package:pointy_frontend/src/shared/unit_options.dart';
import 'package:pointy_frontend/src/features/purchasing/view_models/purchase_view_model.dart';
import 'package:pointy_frontend/src/features/purchasing/views/purchase_catalog_pane.dart';
import 'package:pointy_frontend/src/features/purchasing/views/purchase_draft_pane.dart';
import 'package:pointy_frontend/src/features/purchasing/views/purchasing_shortcuts_sheet.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/product_filter_sheet.dart';
import 'package:pointy_frontend/src/shared/product_search/product_search_mode_controller.dart';
import 'package:pointy_frontend/src/shared/formatters.dart';
import 'package:pointy_frontend/src/shared/order/order.dart';
import 'package:pointy_frontend/src/shared/responsive/responsive.dart';
import 'package:pointy_frontend/src/shared/shell/shell.dart';

void main() => runApp(const _PreviewApp());

class _PreviewApp extends StatelessWidget {
  const _PreviewApp();

  @override
  Widget build(BuildContext context) {
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
      theme: _isDark() ? PointyTheme.dark() : PointyTheme.light(),
      builder: (context, child) => ProductSearchModeScope(
        controller: _searchModes,
        child: PointyNavigationRailScope(
          isActive: false,
          controller: PointyNavigationRailController(),
          child: child ?? const SizedBox.shrink(),
        ),
      ),
      home: const _Router(),
    );
  }
}

bool _isDark() => Uri.base.queryParameters['theme'] == 'dark';

// Never loaded from storage: the query string alone decides, so a preview
// never inherits a setting from the browser it runs in.
final _searchModes = ProductSearchModeController(
  pickerEnabled: Uri.base.queryParameters['picker'] == 'on',
);

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
  return parsed?.queryParameters['screen'] ?? 'pos';
}

class _Router extends StatelessWidget {
  const _Router();

  @override
  Widget build(BuildContext context) {
    switch (_screen()) {
      case 'purchase':
        return const _PurchaseSurface();
      case 'pos-empty':
        return const _PosSurface(empty: true);
      case 'purchase-empty':
        return const _PurchaseSurface(empty: true);
      case 'filter':
        return const _FilterSheetSurface();
      case 'unit-sheet':
        return const _UnitSheetSurface();
      case 'payment':
        return const _PaymentSurface();
      case 'payment-staff':
        // A cashier ringing up their own shopping on their staff account.
        return const _PaymentSurface(staffAccount: true);
      case 'board':
        return const _DesignBoard();
      case 'pos':
      default:
        return const _PosSurface();
    }
  }
}

// ---------------------------------------------------------------------------
// POS surface
// ---------------------------------------------------------------------------

class _PosSurface extends StatefulWidget {
  const _PosSurface({this.empty = false});

  final bool empty;

  @override
  State<_PosSurface> createState() => _PosSurfaceState();
}

class _PosSurfaceState extends State<_PosSurface> {
  late final PosViewModel _viewModel;
  final ContactRepository _contacts = _FakeContactRepository();

  @override
  void initState() {
    super.initState();
    _viewModel = PosViewModel(
      _FakeCatalogRepository(empty: widget.empty),
      _FakeRegisterSessionRepository(),
      _FakeSaleRepository(),
      _FakeShopSettingsRepository(),
      PrintingRepository(PosApiService()),
      // Real chimes so the preview exercises the scan sounds end to end.
      scanFeedback: ScanFeedbackSounds.instance.play,
    );
    _viewModel.loadCatalog();
    if (!widget.empty) {
      _viewModel
        ..addVariant(_variantFor(_items[0]), quantity: 2, source: 'seed')
        ..addVariant(_variantFor(_items[5]), source: 'seed')
        // A pack-unit line so the cart shows its unit chip + base conversion.
        ..addVariant(
          _variantFor(_items[4]),
          quantity: 2,
          unit: const UnitOption(
            code: 'carton',
            label: 'كرتون',
            unitPrice: 15,
            factorToBase: 24,
            allowsFractional: false,
            isBase: false,
          ),
          source: 'seed',
        );
      // One line sold at an agreed price, so the repriced badge and the
      // original price beside it can be looked at.
      final repriced = _viewModel.cart.first;
      _viewModel.setCartLinePrice(repriced.lineKey, 7.25);
      unawaited(_viewModel.toggleCostRevealed());
    }
  }

  @override
  void dispose() {
    _viewModel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _viewModel,
      builder: (context, _) {
        final l10n = AppLocalizations.of(context)!;
        return PointyScaffold(
          appBar: PointyAppBar(
            style: PointyAppBarStyle.highFocus,
            leading: const Icon(Icons.point_of_sale_outlined),
            title: Text(l10n.appTitle),
            actions: [
              IconButton(
                icon: const Icon(Icons.keyboard_outlined),
                tooltip: l10n.posShortcutsButtonTooltip,
                onPressed: () => showPosShortcutsSheet(context),
              ),
              const Padding(
                padding: EdgeInsetsDirectional.only(end: 8),
                child: Icon(Icons.sync),
              ),
            ],
          ),
          body: _PosWorkspace(
            viewModel: _viewModel,
            contactRepository: _contacts,
            capabilities: _managerCaps,
          ),
        );
      },
    );
  }
}

class _PosWorkspace extends StatelessWidget {
  const _PosWorkspace({
    required this.viewModel,
    required this.contactRepository,
    required this.capabilities,
  });

  final PosViewModel viewModel;
  final ContactRepository contactRepository;
  final AuthorizationCapabilities capabilities;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        if (AppBreakpoints.usesTwoPane(width)) {
          return TwoPaneLayout(
            minPrimaryWidth: 390,
            primaryPane: PosCatalogPane(
              viewModel: viewModel,
              capabilities: capabilities,
            ),
            secondaryPane: PosCartPane(
              viewModel: viewModel,
              contactRepository: contactRepository,
              capabilities: capabilities,
            ),
          );
        }

        final l10n = AppLocalizations.of(context)!;
        return Column(
          children: [
            Expanded(
              child: PosCatalogPane(
                viewModel: viewModel,
                capabilities: capabilities,
              ),
            ),
            PointyCompactOrderLauncher(
              title: l10n.currentSaleTitle,
              lineCountLabel: l10n.lineItemCount(viewModel.cart.length),
              totalLabel: formatMoney(viewModel.total),
              actionLabel: l10n.openCartSheetButton,
              icon: Icons.shopping_cart_checkout_outlined,
              onPressed: () => _showSheet(
                context,
                backgroundColor: context.pointyColors.page,
                child: PosCartPane(
                  viewModel: viewModel,
                  contactRepository: contactRepository,
                  capabilities: capabilities,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Purchasing surface
// ---------------------------------------------------------------------------

class _PurchaseSurface extends StatefulWidget {
  const _PurchaseSurface({this.empty = false});

  final bool empty;

  @override
  State<_PurchaseSurface> createState() => _PurchaseSurfaceState();
}

class _PurchaseSurfaceState extends State<_PurchaseSurface> {
  late final PurchaseViewModel _viewModel;
  final ContactRepository _contacts = _FakeContactRepository();

  @override
  void initState() {
    super.initState();
    _viewModel = PurchaseViewModel(
      _FakeCatalogRepository(empty: widget.empty),
      _FakePurchaseRepository(),
    );
    // A supplier is what makes the suggestion strip meaningful — habits are per
    // supplier — so the preview picks one, exactly as the draft pane would.
    _viewModel.selectSupplier(_previewSupplier);
    if (!widget.empty) {
      _viewModel
        ..addVariant(_variantFor(_items[1]), quantity: 6, source: 'seed')
        // A pack line for the multi-unit product, so the draft shows the
        // per-carton cost, its per-piece equivalent, and the carton's own
        // selling price beside the piece price.
        ..addVariant(
          _variantFor(_items[4]),
          quantity: 4,
          unitCost: 20,
          unit: _waterUnits[1],
          source: 'seed',
        )
        ..addVariant(_variantFor(_items[10]), quantity: 3, source: 'seed');
    }
  }

  @override
  void dispose() {
    _viewModel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _viewModel,
      builder: (context, _) {
        final l10n = AppLocalizations.of(context)!;
        return PointyScaffold(
          appBar: PointyAppBar(
            leading: const Icon(Icons.inventory_2_outlined),
            title: Text(l10n.newPurchaseOrderTitle),
            actions: [
              IconButton(
                tooltip: l10n.purchasingShortcutsTooltip,
                onPressed: () => showPurchasingShortcutsSheet(context),
                icon: const Icon(Icons.keyboard_outlined),
              ),
              const Padding(
                padding: EdgeInsetsDirectional.only(end: 8),
                child: Icon(Icons.sync),
              ),
            ],
          ),
          body: _PurchaseWorkspace(
            viewModel: _viewModel,
            contactRepository: _contacts,
          ),
        );
      },
    );
  }
}

class _PurchaseWorkspace extends StatelessWidget {
  const _PurchaseWorkspace({
    required this.viewModel,
    required this.contactRepository,
  });

  final PurchaseViewModel viewModel;
  final ContactRepository contactRepository;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        if (AppBreakpoints.usesTwoPane(width)) {
          return TwoPaneLayout(
            minPrimaryWidth: 390,
            primaryPane: PurchaseCatalogPane(
              viewModel: viewModel,
              capabilities: _managerCaps,
            ),
            secondaryPane: PurchaseDraftPane(
              viewModel: viewModel,
              contactRepository: contactRepository,
            ),
          );
        }

        final l10n = AppLocalizations.of(context)!;
        return Column(
          children: [
            Expanded(
              child: PurchaseCatalogPane(
                viewModel: viewModel,
                capabilities: _managerCaps,
              ),
            ),
            PointyCompactOrderLauncher(
              title: l10n.purchaseDraftTitle,
              lineCountLabel: l10n.lineItemCount(viewModel.draft.length),
              totalLabel: formatMoney(viewModel.total),
              actionLabel: l10n.openPurchaseDraftSheetButton,
              icon: Icons.assignment_outlined,
              onPressed: () => _showSheet(
                context,
                backgroundColor: context.pointyColors.surface,
                child: PurchaseDraftPane(
                  viewModel: viewModel,
                  contactRepository: contactRepository,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

Future<void> _showSheet(
  BuildContext context, {
  required Color backgroundColor,
  required Widget child,
}) {
  return showAdaptiveModalBottomSheet<void>(
    context: context,
    size: AdaptiveModalSize.expanded,
    backgroundColor: backgroundColor,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(PointyRadii.sheet),
      ),
    ),
    clipBehavior: Clip.antiAlias,
    builder: (_) => child,
  );
}

// ---------------------------------------------------------------------------
// Filter / sort sheet
// ---------------------------------------------------------------------------

class _FilterSheetSurface extends StatefulWidget {
  const _FilterSheetSurface();

  @override
  State<_FilterSheetSurface> createState() => _FilterSheetSurfaceState();
}

class _FilterSheetSurfaceState extends State<_FilterSheetSurface> {
  final CatalogRepository _repo = _FakeCatalogRepository();
  ProductQuery _query = const ProductQuery(
    ordering: ProductOrdering.priceAsc,
    categories: [ProductCategory(id: 2, name: 'مأكولات')],
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _openSheet());
  }

  Future<void> _openSheet() async {
    final updated = await showAdaptiveModalBottomSheet<ProductQuery>(
      context: context,
      builder: (_) => ProductFilterSheet(
        query: _query,
        catalogRepository: _repo,
        allowAvailabilityFilter: true,
      ),
    );
    if (!mounted) {
      return;
    }
    if (updated != null) {
      setState(() => _query = updated);
    }
    // Keep the sheet on screen for the preview.
    WidgetsBinding.instance.addPostFrameCallback((_) => _openSheet());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return PointyScaffold(
      appBar: PointyAppBar(
        leading: const Icon(Icons.tune),
        title: Text(l10n.filtersButtonLabel),
      ),
      body: Center(
        child: Text(
          l10n.filtersSheetTitle,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            color: context.pointyColors.mutedInk,
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Unit + quantity sheet
// ---------------------------------------------------------------------------

class _UnitSheetSurface extends StatefulWidget {
  const _UnitSheetSurface();

  @override
  State<_UnitSheetSurface> createState() => _UnitSheetSurfaceState();
}

class _UnitSheetSurfaceState extends State<_UnitSheetSurface> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _openSheet());
  }

  Future<void> _openSheet() async {
    final item = _items[4]; // bottled water — sells by piece / pack / carton
    await showUnitQuantitySheet(
      context,
      product: _productFor(item),
      variant: _variantFor(item),
    );
    if (!mounted) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _openSheet());
  }

  @override
  Widget build(BuildContext context) {
    return PointyScaffold(
      appBar: const PointyAppBar(
        leading: Icon(Icons.straighten_outlined),
        title: Text('اختيار الوحدة'),
      ),
      body: Center(
        child: Text(
          'وحدات المنتج',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            color: context.pointyColors.mutedInk,
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Payment sheet
// ---------------------------------------------------------------------------

class _PaymentSurface extends StatefulWidget {
  const _PaymentSurface({this.staffAccount = false});

  final bool staffAccount;

  @override
  State<_PaymentSurface> createState() => _PaymentSurfaceState();
}

class _PaymentSurfaceState extends State<_PaymentSurface> {
  bool _print = true;
  bool _share = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _open());
  }

  Future<void> _open() async {
    await showPosPaymentSheet(
      context: context,
      total: 47.50,
      enableCashPayments: true,
      enableCardPayments: true,
      enableTransferPayments: true,
      requireCardReceipt: false,
      trustedCardTerminalIds: const [],
      // A shop with two identified banks, so the account control is on screen.
      // A shop with the one generic account every install is seeded with
      // passes nothing here and the sheet is exactly what it was.
      bankAccounts: const [
        MoneyAccount(
          id: 1,
          name: 'حساب المحل',
          kind: MoneyAccountKind.bank,
          bankName: 'مصرف الجمهورية',
          bankSlug: 'jbank',
          iban: 'LY83002104000000201050050',
          isDefault: true,
        ),
        MoneyAccount(
          id: 2,
          name: 'حساب الأمان',
          kind: MoneyAccountKind.bank,
          bankName: 'مصرف الأمان',
          bankSlug: 'aman',
          iban: 'LY19002200000000993011447',
        ),
      ],
      showPrintInvoiceToggle: true,
      printInvoiceAfterPayment: _print,
      onPrintInvoiceChanged: (value) => _print = value,
      showShareInvoiceToggle: true,
      shareInvoiceAfterPayment: _share,
      onShareInvoiceChanged: (value) => _share = value,
      hasCustomer: widget.staffAccount,
      requireCustomerForCredit: true,
      isStaffAccount: widget.staffAccount,
    );
    if (!mounted) {
      return;
    }
    // Keep the sheet on screen for the preview.
    WidgetsBinding.instance.addPostFrameCallback((_) => _open());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return PointyScaffold(
      appBar: PointyAppBar(
        style: PointyAppBarStyle.highFocus,
        leading: const Icon(Icons.point_of_sale_outlined),
        title: Text(l10n.appTitle),
      ),
      body: Center(
        child: Text(
          l10n.paymentDialogTitle,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            color: context.pointyColors.mutedInk,
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Design board: every layout at once for a single overview screenshot.
// ---------------------------------------------------------------------------

class _DesignBoard extends StatelessWidget {
  const _DesignBoard();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFFE7E5E0),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Wrap(
          spacing: 24,
          runSpacing: 24,
          children: const [
            _Frame(
              label: 'POS · phone',
              width: 390,
              height: 820,
              child: _PosSurface(),
            ),
            _Frame(
              label: 'POS · wide',
              width: 1280,
              height: 820,
              child: _PosSurface(),
            ),
            _Frame(
              label: 'Purchase · phone',
              width: 390,
              height: 820,
              child: _PurchaseSurface(),
            ),
            _Frame(
              label: 'Purchase · wide',
              width: 1280,
              height: 820,
              child: _PurchaseSurface(),
            ),
          ],
        ),
      ),
    );
  }
}

class _Frame extends StatelessWidget {
  const _Frame({
    required this.label,
    required this.width,
    required this.height,
    required this.child,
  });

  final String label;
  final double width;
  final double height;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8, right: 4),
          child: Text(
            label,
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              color: Color(0xFF101828),
            ),
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF101828).withValues(alpha: 0.18),
                blurRadius: 28,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: SizedBox(
              width: width,
              height: height,
              child: MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  size: Size(width, height),
                  padding: EdgeInsets.zero,
                  viewInsets: EdgeInsets.zero,
                  viewPadding: EdgeInsets.zero,
                ),
                child: child,
              ),
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

final PosUser _managerUser = PosUser.fromJson(const {
  'id': 1,
  'username': 'manager',
  'role': 'manager',
  // Named explicitly so the preview exercises the affordances they unlock:
  // the F9 cost row on a cart line and the reprice sheet. Neither is a role
  // default for a cashier, which is the whole point of them.
  'permissions': <String>['sales.view_till_cost', 'sales.override_line_price'],
});

final AuthorizationCapabilities _managerCaps =
    AuthorizationCapabilities.forUser(_managerUser);

class _FakeCatalogRepository extends CatalogRepository {
  _FakeCatalogRepository({this.empty = false}) : super(PosApiService());

  final bool empty;

  @override
  Future<Result<ProductPage>> loadProducts({
    required ProductQuery query,
    int page = 1,
    // The real repository grew a cache-bypass; a fake that serves from a list
    // has no cache to bypass, so it accepts the flag and ignores it rather than
    // failing to override.
    bool bypassCache = false,
  }) async {
    if (empty || page > 1) {
      return const Ok(ProductPage(products: [], hasMore: false));
    }
    final products = _items
        .where((item) => item.matches(query))
        .map(_productFor)
        .toList(growable: false);
    return Ok(ProductPage(products: products, hasMore: false));
  }

  @override
  Future<Result<ProductVariantPage>> loadProductVariants({
    required ProductQuery query,
    int page = 1,
  }) async {
    if (empty || page > 1) {
      return const Ok(ProductVariantPage(variants: [], hasMore: false));
    }
    final variants = _items
        .where((item) => item.matches(query))
        .map(_variantFor)
        .toList(growable: false);
    return Ok(ProductVariantPage(variants: variants, hasMore: false));
  }

  @override
  Future<Result<ProductVariantPage>> loadVariantsForProduct(
    int productId, {
    int page = 1,
  }) async {
    final variants = [
      for (final item in _items)
        if (item.id == productId) _variantFor(item),
    ];
    return Ok(ProductVariantPage(variants: variants, hasMore: false));
  }

  @override
  Future<Result<Product>> setVariantPrices({
    required int productId,
    required Map<int, double> pricesByVariant,
    Map<String, double?> pricesByUnitCode = const {},
  }) async {
    for (final item in _items) {
      if (item.id == productId) {
        return Ok(_productFor(item));
      }
    }
    return Error(Exception('product $productId not found'));
  }

  @override
  Future<Result<List<ProductCategory>>> loadQuickAccessCategories() async {
    if (empty) {
      return const Ok([]);
    }
    return Ok([
      for (final category in _categories)
        ProductCategory(
          id: category.id,
          name: category.name,
          isQuickAccess: true,
        ),
    ]);
  }

  @override
  Future<Result<ProductVariant?>> findProductVariantByBarcode(
    String barcode, {
    bool activeOnly = true,
  }) async {
    for (final item in _items) {
      if (item.barcode == barcode.trim()) {
        return Ok(_variantFor(item));
      }
    }
    return const Ok(null);
  }

  // The scan path (and its chimes): known code adds + success, unknown code
  // is a not-found, and the magic '500' demos a failed lookup (error chime).
  @override
  Future<Result<BarcodeResolution?>> resolveBarcode(
    String barcode, {
    bool activeOnly = true,
  }) async {
    final code = barcode.trim();
    if (code == '500') {
      return Error(Exception('barcode lookup failed (preview)'));
    }
    for (final item in _items) {
      if (item.barcode == code) {
        return Ok(BarcodeResolution(variant: _variantFor(item)));
      }
    }
    return const Ok(null);
  }
}

class _FakeRegisterSessionRepository extends RegisterSessionRepository {
  _FakeRegisterSessionRepository() : super(PosApiService());
}

class _FakeSaleRepository extends SaleRepository {
  _FakeSaleRepository() : super(PosApiService());

  // Demo discounts so the cart totals can be previewed with deductions (a rule
  // discount + a coupon), exercising the itemized-breakdown path.
  @override
  /// Plausible costs so the F9 row can be looked at. Roughly two thirds of
  /// the shelf price, which is what makes the margin figure readable — and one
  /// line deliberately has no cost at all, because a product the shop has
  /// never bought is a real and common state.
  @override
  Future<Result<Map<int, double>>> loadLineCosts(List<int> variantIds) async {
    return Ok({
      for (final id in variantIds)
        if (id % 4 != 0) id: (id * 3 % 7 + 2) * 0.85,
    });
  }

  @override
  Future<Result<SaleDiscountPreview>> previewDiscounts(
    SaleDiscountPreviewDraft draft,
  ) async {
    if (draft.lines.isEmpty) {
      return const Ok(
        SaleDiscountPreview(subtotal: 0, discountTotal: 0, total: 0),
      );
    }
    // The rules take 1.50; whatever the cashier typed comes off on top, so the
    // preview exercises both discount rows at once.
    const ruleDiscount = 1.50;
    const subtotal = 10.20;
    final extra = draft.extraDiscountAmount.clamp(0.0, subtotal - ruleDiscount);
    return Ok(
      SaleDiscountPreview(
        subtotal: subtotal,
        discountTotal: ruleDiscount + extra,
        total: subtotal - ruleDiscount - extra,
        extraDiscountAmount: extra,
        maxExtraDiscountAmount: subtotal - ruleDiscount,
        appliedDiscounts: const [
          AppliedDiscountInfo(
            ruleName: 'خصم ترحيبي',
            source: '',
            scope: '',
            valueType: '',
            discountAmount: 1.00,
          ),
          AppliedDiscountInfo(
            ruleName: '',
            couponCode: 'SAVE5',
            source: '',
            scope: '',
            valueType: '',
            discountAmount: 0.50,
          ),
        ],
      ),
    );
  }
}

class _FakeShopSettingsRepository extends ShopSettingsRepository {
  _FakeShopSettingsRepository() : super(PosApiService());
}

class _FakeContactRepository extends ContactRepository {
  _FakeContactRepository() : super(PosApiService());

  // The "on my account" button in the sale settings dialog.
  @override
  Future<Result<Customer>> loadStaffAccount() async {
    return const Ok(
      Customer(
        id: 90,
        customerNumber: 'C20260923000090',
        fullName: 'سلمى الكاشير',
        phone: '',
        email: '',
        gender: CustomerGender.unspecified,
        marketingConsent: false,
        notes: '',
        isActive: true,
        staffEmployeeId: 4,
      ),
    );
  }
}

/// The supplier the purchasing preview is buying from.
const SupplierContact _previewSupplier = SupplierContact(
  id: 1,
  name: 'شركة الوفاء للتوزيع',
  contactName: 'أحمد',
  phone: '0910000000',
  email: '',
  address: '',
  notes: '',
  isActive: true,
);

class _FakePurchaseRepository extends PurchaseRepository {
  _FakePurchaseRepository() : super(PosApiService());

  /// Stands in for the precomputed habit/affinity tables: a few products this
  /// shop repeatedly buys from this supplier, some with a habitual quantity and
  /// some without — which is what the real endpoint returns whenever the
  /// quantities have not repeated enough to state one.
  @override
  Future<Result<PurchaseSuggestionSet>> loadPurchaseSuggestions({
    required int supplierId,
    List<int> variantIds = const [],
    int limit = 8,
  }) async {
    PurchaseSuggestion suggest(
      int itemIndex, {
      double? quantity,
      String unit = '',
      double factor = 1,
      required PurchaseSuggestionReason reason,
      int? anchor,
      int? daysSinceLast,
      double score = 0.7,
      int orders = 6,
    }) {
      final item = _items[itemIndex];
      final cost = _costForProduct(item.id);
      return PurchaseSuggestion(
        variantId: item.id * 10,
        productId: item.id,
        productName: item.name,
        variantName: '',
        sku: item.sku,
        reason: reason,
        suggestedQuantity: quantity,
        unitCode: unit,
        unitFactor: factor,
        unitCost: cost * factor,
        baseUnitCost: cost,
        anchorVariantId: anchor,
        score: score,
        orderCount: orders,
        daysSinceLast: daysSinceLast,
      );
    }

    final onDraft = variantIds.toSet();
    final anchor = onDraft.isEmpty ? null : variantIds.last;
    return Ok(
      PurchaseSuggestionSet(
        items: [
          suggest(
            4,
            quantity: 8,
            unit: 'carton',
            factor: 24,
            reason: PurchaseSuggestionReason.oftenWith,
            anchor: anchor,
            score: 0.86,
            orders: 9,
          ),
          suggest(
            0,
            quantity: 12,
            reason: PurchaseSuggestionReason.oftenWith,
            anchor: anchor,
            score: 0.74,
          ),
          suggest(
            2,
            reason: PurchaseSuggestionReason.dueAgain,
            daysSinceLast: 21,
            score: 0.63,
            orders: 5,
          ),
          suggest(
            6,
            quantity: 5,
            reason: PurchaseSuggestionReason.usualForSupplier,
            score: 0.42,
            orders: 4,
          ),
          suggest(
            8,
            reason: PurchaseSuggestionReason.usualForSupplier,
            score: 0.36,
            orders: 4,
          ),
        ].where((item) => !onDraft.contains(item.variantId)).toList(),
        usualBasket: PurchaseUsualBasket(
          available: true,
          items: [
            suggest(
              1,
              quantity: 6,
              reason: PurchaseSuggestionReason.usualForSupplier,
            ),
            suggest(
              4,
              quantity: 8,
              unit: 'carton',
              factor: 24,
              reason: PurchaseSuggestionReason.usualForSupplier,
            ),
            suggest(
              0,
              quantity: 12,
              reason: PurchaseSuggestionReason.usualForSupplier,
            ),
            suggest(
              6,
              quantity: 5,
              reason: PurchaseSuggestionReason.usualForSupplier,
            ),
            suggest(
              10,
              quantity: 3,
              reason: PurchaseSuggestionReason.usualForSupplier,
            ),
          ],
        ),
      ),
    );
  }

  @override
  Future<Result<double?>> loadLastProductCost(
    int productId, {
    int? variantId,
  }) async {
    return Ok(_costForProduct(productId));
  }

  @override
  Future<Result<({double? suggestedPrice, double? markupPercent})>>
  loadPricingSuggestion(double unitCost, {int? productId}) async {
    return Ok((suggestedPrice: unitCost * 1.35, markupPercent: 35));
  }

  @override
  Future<Result<List<VariantCostSummary>>> loadProductCostSummary(
    int productId,
  ) async {
    final cost = _costForProduct(productId);
    return Ok([
      VariantCostSummary(
        productId: productId,
        variantId: productId * 10,
        variantName: '',
        unitPrice: 0,
        purchasesCount: 7,
        lowestCost: cost * 0.85,
        highestCost: cost * 1.2,
        averageCost: cost,
        lastCost: cost,
      ),
    ]);
  }
}

// ---------------------------------------------------------------------------
// Sample data
// ---------------------------------------------------------------------------

class _Category {
  const _Category(this.id, this.name);
  final int id;
  final String name;
}

const List<_Category> _categories = [
  _Category(1, 'مشروبات'),
  _Category(2, 'مأكولات'),
  _Category(3, 'حلويات'),
  _Category(4, 'لوازم'),
];

class _Item {
  const _Item({
    required this.id,
    required this.name,
    required this.sku,
    required this.price,
    required this.stock,
    required this.barcode,
    required this.categoryId,
  });

  final int id;
  final String name;
  final String sku;
  final double price;
  final double stock;
  final String barcode;
  final int categoryId;

  bool matches(ProductQuery query) {
    final search = query.search.trim().toLowerCase();
    final readsNames = query.searchMode != ProductSearchMode.code;
    final readsCodes = query.searchMode != ProductSearchMode.name;
    final matchesSearch =
        search.isEmpty ||
        (readsNames && name.toLowerCase().contains(search)) ||
        (readsCodes &&
            (sku.toLowerCase().contains(search) || barcode.contains(search)));
    final categoryIds = query.categories.map((c) => c.id).toSet();
    final matchesCategory =
        categoryIds.isEmpty || categoryIds.contains(categoryId);
    return matchesSearch && matchesCategory;
  }
}

const List<_Item> _items = [
  _Item(
    id: 1,
    name: 'قهوة عربية مختصة',
    sku: 'COF-001',
    price: 3.50,
    stock: 24,
    barcode: '1000001',
    categoryId: 1,
  ),
  _Item(
    id: 2,
    name: 'شاي بالنعناع الطازج',
    sku: 'TEA-002',
    price: 2.75,
    stock: 8,
    barcode: '1000002',
    categoryId: 1,
  ),
  _Item(
    id: 3,
    name: 'عصير برتقال طبيعي',
    sku: 'JCE-003',
    price: 4.25,
    stock: 0,
    barcode: '1000003',
    categoryId: 1,
  ),
  _Item(
    id: 4,
    name: 'لاتيه بالكراميل',
    sku: 'COF-004',
    price: 5.00,
    stock: 17,
    barcode: '1000004',
    categoryId: 1,
  ),
  _Item(
    id: 5,
    name: 'ماء معدني 500 مل',
    sku: 'WTR-005',
    price: 0.75,
    stock: 140,
    barcode: '1000005',
    categoryId: 1,
  ),
  _Item(
    id: 6,
    name: 'كرواسون بالجبنة والزعتر الأخضر',
    sku: 'BKR-006',
    price: 3.20,
    stock: 6,
    barcode: '1000006',
    categoryId: 2,
  ),
  _Item(
    id: 7,
    name: 'ساندويتش دجاج مشوي',
    sku: 'SND-007',
    price: 6.80,
    stock: 12,
    barcode: '1000007',
    categoryId: 2,
  ),
  _Item(
    id: 8,
    name: 'سلطة سيزر',
    sku: 'SLD-008',
    price: 5.50,
    stock: 3,
    barcode: '1000008',
    categoryId: 2,
  ),
  _Item(
    id: 9,
    name: 'بيتزا مارغريتا',
    sku: 'PIZ-009',
    price: 8.90,
    stock: 9,
    barcode: '1000009',
    categoryId: 2,
  ),
  _Item(
    id: 10,
    name: 'كيك الشوكولاتة',
    sku: 'CAK-010',
    price: 4.00,
    stock: 5,
    barcode: '1000010',
    categoryId: 3,
  ),
  _Item(
    id: 11,
    name: 'تشيز كيك التوت',
    sku: 'CAK-011',
    price: 4.75,
    stock: 0,
    barcode: '1000011',
    categoryId: 3,
  ),
  _Item(
    id: 12,
    name: 'دونات بالسكر',
    sku: 'DNT-012',
    price: 1.95,
    stock: 22,
    barcode: '1000012',
    categoryId: 3,
  ),
  _Item(
    id: 13,
    name: 'كوب ورقي كبير',
    sku: 'SUP-013',
    price: 0.20,
    stock: 320,
    barcode: '1000013',
    categoryId: 4,
  ),
  _Item(
    id: 14,
    name: 'مناديل ورقية',
    sku: 'SUP-014',
    price: 0.15,
    stock: 64,
    barcode: '1000014',
    categoryId: 4,
  ),
  _Item(
    id: 15,
    name: 'شفاطات بلاستيكية',
    sku: 'SUP-015',
    price: 0.10,
    stock: 0,
    barcode: '1000015',
    categoryId: 4,
  ),
  _Item(
    id: 16,
    name: 'علبة تغليف كرتون',
    sku: 'SUP-016',
    price: 0.35,
    stock: 48,
    barcode: '1000016',
    categoryId: 4,
  ),
];

double _costForProduct(int productId) {
  for (final item in _items) {
    if (item.id == productId) {
      return double.parse((item.price * 0.6).toStringAsFixed(2));
    }
  }
  return 0;
}

// The bottled-water item also sells by the pack and the carton, to exercise the
// fast unit picker and the cart unit chip.
const List<ProductUnit> _waterUnits = [
  ProductUnit(
    unit: UnitOfMeasure(
      id: 1,
      code: 'pack',
      name: 'عبوة (6)',
      abbreviation: 'عبوة',
    ),
    factorToBase: 6,
  ),
  ProductUnit(
    unit: UnitOfMeasure(
      id: 2,
      code: 'carton',
      name: 'كرتون (24)',
      abbreviation: 'كرتون',
    ),
    factorToBase: 24,
    price: 15,
  ),
];

Product _productFor(_Item item) {
  return Product(
    id: item.id,
    name: item.name,
    quantityOnHand: item.stock,
    unit: 'piece',
    defaultSaleUnit: item.id == 5 ? 'pack' : '',
    units: item.id == 5 ? _waterUnits : const [],
    categories: [
      ProductCategory(
        id: item.categoryId,
        name: _categoryName(item.categoryId),
      ),
    ],
    defaultVariant: _variantFor(item),
  );
}

ProductVariant _variantFor(_Item item) {
  return ProductVariant(
    id: item.id * 10,
    productId: item.id,
    productName: item.name,
    displayName: item.name,
    fullName: item.name,
    sku: item.sku,
    unitPrice: item.price,
    barcode: item.barcode,
    quantityOnHand: item.stock,
    isDefault: true,
    // Multi-unit items carry their product detail so the cart's unit chip can
    // resolve the switchable units (mirrors the real product_detail payload).
    productDetail: item.id == 5
        ? Product(
            id: item.id,
            name: item.name,
            quantityOnHand: item.stock,
            defaultSaleUnit: 'pack',
            units: _waterUnits,
          )
        : null,
  );
}

String _categoryName(int id) {
  for (final category in _categories) {
    if (category.id == id) {
      return category.name;
    }
  }
  return '';
}
