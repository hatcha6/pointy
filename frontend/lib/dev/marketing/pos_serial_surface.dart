// Dev-only, safe to delete, never imported by lib/main.dart.
//
// The till of a phone shop. `pos-serial` opens the real sell screen with a
// sale under way — a Samsung handset already rung up by its IMEI, plus two
// accessories — and the unit picker open for «آيفون 13 برو»: the cashier picks
// (or scans) the exact handset, oldest stock first, with battery and grade
// beside each IMEI. `pos-phones` is the same till without the picker.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/barcode_resolution.dart';
import 'package:pointy_frontend/src/data/models/product.dart';
import 'package:pointy_frontend/src/data/models/product_category.dart';
import 'package:pointy_frontend/src/data/models/product_page.dart';
import 'package:pointy_frontend/src/data/models/product_query.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/data/models/product_variant_page.dart';
import 'package:pointy_frontend/src/data/models/sale_order.dart';
import 'package:pointy_frontend/src/data/models/stock_unit.dart';
import 'package:pointy_frontend/src/data/models/tracking_mode.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/contact_repository.dart';
import 'package:pointy_frontend/src/data/repositories/printing_repository.dart';
import 'package:pointy_frontend/src/data/repositories/register_session_repository.dart';
import 'package:pointy_frontend/src/data/repositories/sale_repository.dart';
import 'package:pointy_frontend/src/data/repositories/shop_settings_repository.dart';
import 'package:pointy_frontend/src/data/repositories/tracked_stock_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/pos/view_models/pos_view_model.dart';
import 'package:pointy_frontend/src/features/pos/views/pos_cart_pane.dart';
import 'package:pointy_frontend/src/features/pos/views/pos_catalog_pane.dart';
import 'package:pointy_frontend/src/features/pos/views/pos_unit_pick.dart';
import 'package:pointy_frontend/src/shared/app_navigation_drawer.dart';
import 'package:pointy_frontend/src/shared/formatters.dart';
import 'package:pointy_frontend/src/shared/order/order.dart';
import 'package:pointy_frontend/src/shared/responsive/responsive.dart';
import 'package:pointy_frontend/src/shared/shell/shell.dart';

import 'preview_navigation.dart';
import 'staff_surfaces.dart' show previewManager;

class PosSerialSurface extends StatefulWidget {
  const PosSerialSurface({super.key, required this.openPicker});

  final bool openPicker;

  @override
  State<PosSerialSurface> createState() => _PosSerialSurfaceState();
}

class _PosSerialSurfaceState extends State<PosSerialSurface> {
  late final PosViewModel _viewModel;
  final _capabilities = AuthorizationCapabilities.forUser(previewManager);

  @override
  void initState() {
    super.initState();
    _viewModel = PosViewModel(
      _FakeCatalogRepository(),
      RegisterSessionRepository(PosApiService()),
      _FakeSaleRepository(() => _viewModel.subtotal),
      ShopSettingsRepository(PosApiService()),
      PrintingRepository(PosApiService()),
      trackedStockRepository: _FakeTrackedStockRepository(),
    );
    _viewModel
      ..loadCatalog()
      ..addVariant(
        _variantFor(_items[1]),
        stockUnit: _units[_items[1].id]!.first,
        source: 'seed',
      )
      ..addVariant(_variantFor(_items[2]), source: 'seed')
      ..addVariant(_variantFor(_items[4]), source: 'seed');
    if (widget.openPicker) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(
          Future<void>.delayed(const Duration(milliseconds: 300)).then((_) {
            if (!mounted) {
              return Future<void>.value();
            }
            return pickAndAddStockUnit(
              context,
              viewModel: _viewModel,
              variant: _variantFor(_items[0]),
              source: 'catalog_grid',
            );
          }),
        );
      });
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
          drawer: AppNavigationDrawer(
            selectedDestination: AppNavigationDestination.pos,
            navigation: PreviewNavigation(previewManager, _capabilities),
          ),
          appBar: PointyAppBar(
            style: PointyAppBarStyle.highFocus,
            leading: const PointyNavigationMenuButton(),
            title: Text(l10n.appTitle),
            actions: const [
              Padding(
                padding: EdgeInsetsDirectional.only(end: 8),
                child: Icon(Icons.sync),
              ),
            ],
          ),
          body: _workspace(context, l10n),
        );
      },
    );
  }

  /// Catalogue and cart side by side on a till; on a phone the cart folds
  /// into the launcher bar, as the sell screen does.
  Widget _workspace(BuildContext context, AppLocalizations l10n) {
    final width = MediaQuery.sizeOf(context).width;
    final catalog = PosCatalogPane(
      viewModel: _viewModel,
      capabilities: _capabilities,
    );
    if (!AppBreakpoints.usesTwoPane(width)) {
      return Column(
        children: [
          Expanded(child: catalog),
          PointyCompactOrderLauncher(
            title: l10n.currentSaleTitle,
            lineCountLabel: l10n.lineItemCount(_viewModel.cart.length),
            totalLabel: formatMoney(_viewModel.total),
            actionLabel: l10n.openCartSheetButton,
            icon: Icons.shopping_cart_checkout_outlined,
            onPressed: () {},
          ),
        ],
      );
    }
    return TwoPaneLayout(
      minPrimaryWidth: 390,
      secondaryPaneMaxWidth: AppPaneWidths.orderPaneMaxWidthFor(width),
      primaryPane: catalog,
      secondaryPane: PosCartPane(
        viewModel: _viewModel,
        contactRepository: ContactRepository(PosApiService()),
        capabilities: _capabilities,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// The shop's shelves
// ---------------------------------------------------------------------------

class _Item {
  const _Item(
    this.id,
    this.name,
    this.sku,
    this.price,
    this.stock,
    this.categoryId, {
    this.serial = false,
  });

  final int id;
  final String name;
  final String sku;
  final double price;
  final double stock;
  final int categoryId;
  final bool serial;
}

const _categories = [
  ProductCategory(id: 1, name: 'هواتف', isQuickAccess: true),
  ProductCategory(id: 2, name: 'سماعات', isQuickAccess: true),
  ProductCategory(id: 3, name: 'شواحن', isQuickAccess: true),
  ProductCategory(id: 4, name: 'اكسسوارات', isQuickAccess: true),
];

/// Dinar prices; the imported ones are the dollar price at 6.85.
const _items = [
  _Item(1, 'آيفون 13 برو 256 جيجا', 'IP13P-256', 4178.50, 4, 1, serial: true),
  _Item(2, 'سامسونج جالاكسي A54', 'A54-128', 1650, 6, 1, serial: true),
  _Item(3, 'سماعات لاسلكية', 'EAR-012', 82.20, 18, 2),
  _Item(4, 'شاحن سريع 25 واط', 'CHG-025', 54.80, 31, 3),
  _Item(5, 'كفر حماية سيليكون', 'CASE-SIL', 25, 64, 4),
  _Item(6, 'واقي شاشة زجاجي', 'GLS-9H', 15, 120, 4),
  _Item(7, 'ساعة ذكية', 'WATCH-S', 308.25, 7, 4),
  _Item(8, 'باور بانك 20000', 'PWR-20K', 95, 12, 3),
  _Item(9, 'كابل تايب سي 1 متر', 'CBL-C1', 12, 85, 3),
  _Item(10, 'شاومي ريدمي نوت 13', 'RN13-256', 1150, 9, 1, serial: true),
  _Item(11, 'سماعة رأس للألعاب', 'HDS-GM', 145, 5, 2),
  _Item(12, 'حامل هاتف للسيارة', 'CAR-MNT', 35, 22, 4),
];

ProductCategory _categoryOf(_Item item) =>
    _categories.firstWhere((category) => category.id == item.categoryId);

TrackingMode _modeOf(_Item item) =>
    item.serial ? TrackingMode.serial : TrackingMode.quantity;

ProductVariant _variantFor(_Item item) => ProductVariant(
  id: item.id * 10,
  productId: item.id,
  productName: item.name,
  displayName: item.name,
  fullName: item.name,
  sku: item.sku,
  unitPrice: item.price,
  barcode: '62100${item.id.toString().padLeft(8, '0')}',
  quantityOnHand: item.stock,
  isDefault: true,
  trackingMode: _modeOf(item),
);

Product _productFor(_Item item) => Product(
  id: item.id,
  name: item.name,
  quantityOnHand: item.stock,
  unit: 'piece',
  trackingMode: _modeOf(item),
  categories: [_categoryOf(item)],
  defaultVariant: _variantFor(item),
);

bool _matches(_Item item, ProductQuery query) {
  final search = query.search.trim();
  final ids = query.categories.map((category) => category.id).toSet();
  return (search.isEmpty || item.name.contains(search)) &&
      (ids.isEmpty || ids.contains(item.categoryId));
}

/// The handsets on the shelf, by product id: two IMEIs each, oldest first.
final _units = <int, List<StockUnit>>{
  1: [
    _unit(101, 1, '356789104421837', '356789104421845', 4050, 97, 'ممتاز', 86),
    _unit(
      102,
      1,
      '356789104502291',
      '356789104502309',
      4178.50,
      41,
      'جديد',
      100,
    ),
    _unit(
      103,
      1,
      '356789104677115',
      '356789104677123',
      3900,
      23,
      'جيد جدًا',
      81,
    ),
    _unit(
      104,
      1,
      '356789104713860',
      '356789104713878',
      4178.50,
      6,
      'جديد',
      100,
    ),
  ],
  2: [
    _unit(201, 2, '351234567012348', '351234567012355', 1650, 18, 'جديد', 100),
  ],
};

StockUnit _unit(
  int id,
  int productId,
  String imei,
  String imei2,
  double price,
  int days,
  String grade,
  int battery,
) {
  return StockUnit.fromJson({
    'id': id,
    'variant': productId * 10,
    'code': imei,
    'identifier_kind': 'imei',
    'secondary_code': imei2,
    'status': 'in_stock',
    'warehouse_name': 'المحل',
    'product_name': _items.firstWhere((item) => item.id == productId).name,
    'list_price': price,
    'in_stock_since': DateTime.now()
        .subtract(Duration(days: days))
        .toIso8601String(),
    'attribute_display': [
      {'key': 'grade', 'label': 'الحالة', 'display': grade},
      {'key': 'battery', 'label': 'البطارية', 'display': '$battery%'},
    ],
  });
}

class _FakeCatalogRepository extends CatalogRepository {
  _FakeCatalogRepository() : super(PosApiService());

  @override
  Future<Result<ProductPage>> loadProducts({
    required ProductQuery query,
    int page = 1,
    bool bypassCache = false,
  }) async {
    if (page > 1) {
      return const Ok(ProductPage(products: [], hasMore: false));
    }
    return Ok(
      ProductPage(
        products: [
          for (final item in _items)
            if (_matches(item, query)) _productFor(item),
        ],
        hasMore: false,
      ),
    );
  }

  @override
  Future<Result<ProductVariantPage>> loadProductVariants({
    required ProductQuery query,
    int page = 1,
  }) async {
    if (page > 1) {
      return const Ok(ProductVariantPage(variants: [], hasMore: false));
    }
    return Ok(
      ProductVariantPage(
        variants: [
          for (final item in _items)
            if (_matches(item, query)) _variantFor(item),
        ],
        hasMore: false,
      ),
    );
  }

  @override
  Future<Result<ProductVariantPage>> loadVariantsForProduct(
    int productId, {
    int page = 1,
  }) async => Ok(
    ProductVariantPage(
      variants: [
        for (final item in _items)
          if (item.id == productId) _variantFor(item),
      ],
      hasMore: false,
    ),
  );

  @override
  Future<Result<List<ProductCategory>>> loadQuickAccessCategories() async =>
      const Ok(_categories);

  @override
  Future<Result<BarcodeResolution?>> resolveBarcode(
    String barcode, {
    bool activeOnly = true,
  }) async => const Ok(null);
}

class _FakeSaleRepository extends SaleRepository {
  _FakeSaleRepository(this._subtotal) : super(PosApiService());

  final double Function() _subtotal;

  /// No promotion running: the total is the lines' sum.
  @override
  Future<Result<SaleDiscountPreview>> previewDiscounts(
    SaleDiscountPreviewDraft draft,
  ) async {
    final subtotal = _subtotal();
    return Ok(
      SaleDiscountPreview(
        subtotal: subtotal,
        discountTotal: 0,
        total: subtotal,
      ),
    );
  }
}

class _FakeTrackedStockRepository extends TrackedStockRepository {
  _FakeTrackedStockRepository() : super(PosApiService());

  @override
  Future<Result<StockUnitPage>> loadSellableUnits({
    required int variantId,
  }) async {
    final units = _units[variantId ~/ 10] ?? const <StockUnit>[];
    return Ok(StockUnitPage(units: units, count: units.length));
  }
}
