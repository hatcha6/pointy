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
//
// See AGENTS.md ("UI preview harness") for the pattern. Not part of the
// shipping app. Safe to delete.
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
import 'package:pointy_frontend/src/data/models/product_unit.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/data/models/product_variant_page.dart';
import 'package:pointy_frontend/src/data/models/unit_of_measure.dart';
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
import 'package:pointy_frontend/src/features/pos/views/unit_quantity_sheet.dart';
import 'package:pointy_frontend/src/shared/unit_options.dart';
import 'package:pointy_frontend/src/features/purchasing/view_models/purchase_view_model.dart';
import 'package:pointy_frontend/src/features/purchasing/views/purchase_catalog_pane.dart';
import 'package:pointy_frontend/src/features/purchasing/views/purchase_draft_pane.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/product_filter_sheet.dart';
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
      theme: PointyTheme.light(),
      builder: (context, child) => PointyNavigationRailScope(
        isActive: false,
        controller: PointyNavigationRailController(),
        child: child ?? const SizedBox.shrink(),
      ),
      home: const _Router(),
    );
  }
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
            actions: const [
              Padding(
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
    if (!widget.empty) {
      _viewModel
        ..addVariant(_variantFor(_items[1]), quantity: 6, source: 'seed')
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
            actions: const [
              Padding(
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
            primaryPane: PurchaseCatalogPane(viewModel: viewModel),
            secondaryPane: PurchaseDraftPane(
              viewModel: viewModel,
              contactRepository: contactRepository,
            ),
          );
        }

        final l10n = AppLocalizations.of(context)!;
        return Column(
          children: [
            Expanded(child: PurchaseCatalogPane(viewModel: viewModel)),
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
  const _PaymentSurface();

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
      showPrintInvoiceToggle: true,
      printInvoiceAfterPayment: _print,
      onPrintInvoiceChanged: (value) => _print = value,
      showShareInvoiceToggle: true,
      shareInvoiceAfterPayment: _share,
      onShareInvoiceChanged: (value) => _share = value,
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
  'permissions': <String>[],
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
}

class _FakeRegisterSessionRepository extends RegisterSessionRepository {
  _FakeRegisterSessionRepository() : super(PosApiService());
}

class _FakeSaleRepository extends SaleRepository {
  _FakeSaleRepository() : super(PosApiService());

  // Demo discounts so the cart totals can be previewed with deductions (a rule
  // discount + a coupon), exercising the itemized-breakdown path.
  @override
  Future<Result<SaleDiscountPreview>> previewDiscounts(
    SaleDiscountPreviewDraft draft,
  ) async {
    if (draft.lines.isEmpty) {
      return const Ok(
        SaleDiscountPreview(subtotal: 0, discountTotal: 0, total: 0),
      );
    }
    return const Ok(
      SaleDiscountPreview(
        subtotal: 10.20,
        discountTotal: 1.50,
        total: 8.70,
        appliedDiscounts: [
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
}

class _FakePurchaseRepository extends PurchaseRepository {
  _FakePurchaseRepository() : super(PosApiService());

  @override
  Future<Result<double?>> loadLastProductCost(
    int productId, {
    int? variantId,
  }) async {
    return Ok(_costForProduct(productId));
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
    final matchesSearch =
        search.isEmpty ||
        name.toLowerCase().contains(search) ||
        sku.toLowerCase().contains(search) ||
        barcode.contains(search);
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
