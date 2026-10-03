// Dev-only preview harness for the create-product and create/edit-variant
// dialogs — specifically their duplicate SKU/barcode feedback.
// Safe to delete — never imported by lib/main.dart.
//
// Run: flutter run -d web-server --web-port 8080 -t lib/dev/product_form_preview.dart
// (or `make frontend-product-form-preview`). Reload the browser once after the
// server reports "is being served at" so Flutter paints.
//
// The fake catalog answers the identity probe from a small taken-codes table:
//   SKU "COF-1" and barcode "6210000000123" belong to "قهوة عربية"
//   barcode "6210000000777" is the "carton" packaging code of "أرز"
//   barcode "6210000000555" belongs to an archived product
// Type one of those into a SKU/barcode field to see the live inline error, or
// use `?fail=1` to make every save come back rejected with a server conflict.
// The automatic SKU starts at 1042 and counts up with each product created;
// `?screen=variant` opens straight on the new-variant sheet instead.
//
// Rapid entry: «إنشاء وإضافة آخر» (Ctrl/⌘+Shift+Enter) keeps the form open and
// starts the next product — try pinning the name or price (pin button, or F7
// in the field), a scan from any field (type a code fast and press Enter),
// and the Enter path barcode → name → price → stock → button. The created
// product echoes the typed name, and three categories are offered.
//
// «منتج مشابه»: `?screen=similar` opens the form as a copy of a cola can
// (category, description, a carton with its own barcode), and
// `?screen=similar-grid` as a copy of a shirt in sizes and colours.
// `?screen=details` shows the can's details card, whose «منتج مشابه» button
// opens that copy the way the catalogue does.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/bought_together_product.dart';
import 'package:pointy_frontend/src/data/models/catalog_identity_conflict.dart';
import 'package:pointy_frontend/src/data/models/modifier_group.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/models/product.dart';
import 'package:pointy_frontend/src/data/models/product_category.dart';
import 'package:pointy_frontend/src/data/models/product_category_query.dart';
import 'package:pointy_frontend/src/data/models/product_draft.dart';
import 'package:pointy_frontend/src/data/models/product_unit.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/data/models/product_variant_draft.dart';
import 'package:pointy_frontend/src/data/models/purchase_submission.dart';
import 'package:pointy_frontend/src/data/models/unit_of_measure.dart';
import 'package:pointy_frontend/src/data/models/variant_option.dart';
import 'package:pointy_frontend/src/data/models/variant_option_value.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/inventory_repository.dart';
import 'package:pointy_frontend/src/data/repositories/printing_repository.dart';
import 'package:pointy_frontend/src/data/repositories/purchase_repository.dart';
import 'package:pointy_frontend/src/data/repositories/sale_repository.dart';
import 'package:pointy_frontend/src/data/repositories/shop_settings_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/catalog/view_models/catalog_view_model.dart';
import 'package:pointy_frontend/src/features/catalog/view_models/product_details_view_model.dart';
import 'package:pointy_frontend/src/features/catalog/views/product_details_screen.dart';
import 'package:pointy_frontend/src/features/catalog/views/product_form.dart';
import 'package:pointy_frontend/src/features/catalog/views/product_variant_form_sheet.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/responsive/responsive.dart';

void main() => runApp(const _PreviewApp());

/// Codes the fake backend considers taken, and who owns each.
const _takenCodes = {
  'sku:COF-1': {
    'field': 'sku',
    'kind': 'variant',
    'product_id': 7,
    'product_name': 'قهوة عربية',
    'variant_id': 70,
    'variant_sku': 'COF-1',
    'is_archived': false,
  },
  'barcode:6210000000123': {
    'field': 'barcode',
    'kind': 'variant',
    'product_id': 7,
    'product_name': 'قهوة عربية',
    'variant_id': 70,
    'variant_sku': 'COF-1',
    'is_archived': false,
  },
  'barcode:6210000000777': {
    'field': 'barcode',
    'kind': 'unit',
    'product_id': 9,
    'product_name': 'أرز',
    'unit_code': 'carton',
    'is_archived': false,
  },
  'barcode:6210000000555': {
    'field': 'barcode',
    'kind': 'variant',
    'product_id': 11,
    'product_name': 'سكر قديم',
    'variant_id': 110,
    'variant_sku': 'SUG-OLD',
    'is_archived': true,
  },
};

class _PreviewApp extends StatelessWidget {
  const _PreviewApp();

  @override
  Widget build(BuildContext context) {
    final rejectSaves = Uri.base.queryParameters['fail'] == '1';
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
      darkTheme: PointyTheme.dark(),
      home: _Home(rejectSaves: rejectSaves),
    );
  }
}

class _Home extends StatefulWidget {
  const _Home({required this.rejectSaves});

  final bool rejectSaves;

  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> {
  late final _FakeCatalogRepository _catalog = _FakeCatalogRepository(
    rejectSaves: widget.rejectSaves,
  );
  late final CatalogViewModel _catalogViewModel = CatalogViewModel(_catalog);
  var _showVariantSheet = Uri.base.queryParameters['screen'] == 'variant';
  final _similarTo = switch (Uri.base.queryParameters['screen']) {
    'similar' => _similarCola,
    'similar-grid' => _similarShirt,
    _ => null,
  };
  final _showDetails = Uri.base.queryParameters['screen'] == 'details';
  late final _colaDetails = ProductDetailsViewModel(
    _catalog,
    _FakePurchaseRepository(),
    _FakeSaleRepository(),
    _similarCola,
    shouldLoadSaleHistory: false,
    shouldLoadPurchaseHistory: false,
  );

  @override
  void dispose() {
    _catalogViewModel.dispose();
    if (_showDetails) {
      _colaDetails.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_showDetails) {
      return Scaffold(
        body: ProductDetailsView(
          viewModel: _colaDetails,
          inventoryRepository: InventoryRepository(PosApiService()),
          printingRepository: PrintingRepository(PosApiService()),
          purchaseRepository: _FakePurchaseRepository(),
          shopSettingsRepository: ShopSettingsRepository(PosApiService()),
          capabilities: AuthorizationCapabilities.forUser(
            PosUser.fromJson(const {
              'id': 1,
              'username': 'manager',
              'role': 'manager',
            }),
          ),
          onCreateSimilar: _openSimilar,
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(_showVariantSheet ? 'متغيّر جديد' : 'منتج جديد'),
        actions: [
          TextButton(
            onPressed: () =>
                setState(() => _showVariantSheet = !_showVariantSheet),
            child: Text(_showVariantSheet ? 'نموذج المنتج' : 'نموذج المتغيّر'),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: _showVariantSheet
              ? ProductVariantFormSheet(viewModel: _buildDetailsViewModel())
              : ProductForm(
                  viewModel: _catalogViewModel,
                  similarTo: _similarTo,
                  // The harness stands in for a manager, who is who the
                  // opening-stock pair is for.
                  showOpeningStock: true,
                  // As the catalogue opens it: a shop entering its shelves.
                  offerAddAnother: true,
                  onCreated: (product) =>
                      _say('أُغلقت النافذة: ${product.name}'),
                  onOpenCreated: (product) => _say('فتح «${product.name}»'),
                ),
        ),
      ),
    );
  }

  void _say(String message) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// What the catalogue does with «منتج مشابه»: the new-product panel, opened
  /// on the product's values.
  void _openSimilar(Product source) {
    showAdaptiveFormSurface<void>(
      context: context,
      size: AdaptiveModalSize.standard,
      desktopPresentation: AdaptiveFormPresentation.sidePanel,
      maxHeightFactor: 0.9,
      builder: (sheetContext) => ProductForm(
        viewModel: _catalogViewModel,
        similarTo: source,
        showOpeningStock: true,
        offerAddAnother: true,
        onCreated: (product) {
          Navigator.of(sheetContext).pop();
          _say('أُنشئ: ${product.name}');
        },
      ),
    );
  }

  ProductDetailsViewModel _buildDetailsViewModel() {
    return ProductDetailsViewModel(
      _catalog,
      _FakePurchaseRepository(),
      _FakeSaleRepository(),
      _previewProduct,
      shouldLoadSaleHistory: false,
      shouldLoadPurchaseHistory: false,
    );
  }
}

const _previewProduct = Product(
  id: 1,
  name: 'شاي أخضر',
  quantityOnHand: 0,
  variants: [ProductVariant(id: 11, productId: 1, sku: 'TEA-1', unitPrice: 5)],
);

/// `?screen=similar`: a can sold by the piece and by the carton.
const _similarCola = Product(
  id: 2,
  name: 'كولا علبة 330 مل',
  quantityOnHand: 48,
  description: 'مشروب غازي، علبة معدنية',
  tracksExpiry: true,
  categories: [ProductCategory(id: 2, name: 'مشروبات')],
  units: [
    ProductUnit(
      unit: UnitOfMeasure(id: 5, code: 'carton', name: 'كرتون'),
      factorToBase: 24,
      price: 28,
      barcodes: ['6281000000999'],
    ),
  ],
  defaultVariant: ProductVariant(
    id: 21,
    productId: 2,
    sku: '1001',
    barcode: '6281000000013',
    unitPrice: 1.25,
    isDefault: true,
  ),
);

/// `?screen=similar-grid`: a shirt in three sizes of red, and a small blue
/// it no longer sells. Value ids follow [_option]: colour 1xx, size 2xx.
final _smallRedShirt = _shirt(31, [201, 100], 45, isDefault: true);
final _similarShirt = Product(
  id: 3,
  name: 'قميص قطن',
  quantityOnHand: 0,
  variantOptions: [_previewVariantOptions[0], _previewVariantOptions[1]],
  defaultVariant: _smallRedShirt,
  variants: [
    _smallRedShirt,
    _shirt(32, [202, 100], 45),
    _shirt(33, [203, 100], 50),
    _shirt(34, [201, 101], 45, isActive: false),
  ],
);

ProductVariant _shirt(
  int id,
  List<int> valueIds,
  double price, {
  bool isDefault = false,
  bool isActive = true,
}) {
  return ProductVariant(
    id: id,
    productId: 3,
    sku: 'SHIRT-$id',
    barcode: '628000000$id',
    unitPrice: price,
    isDefault: isDefault,
    isActive: isActive,
    optionValueIds: valueIds,
  );
}

class _FakeCatalogRepository extends CatalogRepository {
  _FakeCatalogRepository({required this.rejectSaves}) : super(PosApiService());

  /// Simulates the server finding a clash the live probe missed.
  final bool rejectSaves;

  var _nextSku = 1042;
  var _created = 0;

  @override
  Future<Result<String>> nextVariantSku() async => Ok('$_nextSku');

  @override
  Future<Result<ProductCategoryPage>> loadProductCategories({
    ProductCategoryQuery query = const ProductCategoryQuery(),
    int page = 1,
  }) async {
    return const Ok(
      ProductCategoryPage(
        categories: [
          ProductCategory(id: 1, name: 'اكسسوارات هواتف'),
          ProductCategory(id: 2, name: 'مشروبات'),
          ProductCategory(id: 3, name: 'منظفات'),
        ],
        hasMore: false,
      ),
    );
  }

  @override
  Future<Result<CatalogIdentityCheck>> checkVariantIdentity({
    String sku = '',
    String barcode = '',
    int? excludeVariantId,
  }) async {
    // A visible round-trip, so the spinner in the field is not a single frame.
    await Future<void>.delayed(const Duration(milliseconds: 350));
    return Ok(
      CatalogIdentityCheck(
        sku: _lookup('sku', sku),
        barcode: _lookup('barcode', barcode),
      ),
    );
  }

  CatalogIdentityConflict? _lookup(String field, String value) {
    final code = value.trim();
    if (code.isEmpty) {
      return null;
    }
    final key = '$field:${field == 'sku' ? code.toUpperCase() : code}';
    final owner = _takenCodes[key];
    if (owner == null) {
      return null;
    }
    return CatalogIdentityConflict.fromJson({
      ...owner,
      'value': field == 'sku' ? code.toUpperCase() : code,
      'target': '',
    });
  }

  @override
  Future<Result<Product>> createProduct(ProductDraft draft) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (rejectSaves) {
      return Error(_conflictException('default_variant'));
    }
    _created += 1;
    final sku = draft.variantSku.isEmpty ? '$_nextSku' : draft.variantSku;
    if (draft.variantSku.isEmpty || draft.variantSku == '$_nextSku') {
      _nextSku += 1;
    }
    return Ok(
      Product(
        id: 100 + _created,
        name: draft.name,
        quantityOnHand: 0,
        variants: [
          ProductVariant(
            id: 1000 + _created,
            productId: 100 + _created,
            sku: sku,
            unitPrice: draft.variantUnitPrice,
          ),
        ],
      ),
    );
  }

  @override
  Future<Result<ProductVariant>> createVariantForProduct(
    int productId,
    ProductVariantDraft draft,
  ) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (rejectSaves) {
      return Error(_conflictException('variant'));
    }
    return Ok(
      ProductVariant(
        id: 99,
        productId: productId,
        sku: draft.sku,
        unitPrice: draft.unitPrice,
      ),
    );
  }

  /// The exact 400 body the catalog endpoints answer a clash with.
  PosApiException _conflictException(String target) {
    return PosApiException(
      message: 'create failed with status 400',
      statusCode: 400,
      responseBody:
          '{"conflicts":[{"field":"barcode","value":"6210000000123",'
          '"kind":"variant","target":"$target","index":"","product_id":"7",'
          '"product_name":"قهوة عربية","variant_id":"70",'
          '"variant_sku":"COF-1","variant_name":"","unit_code":"",'
          '"is_archived":"false","message":"taken"}]}',
    );
  }

  @override
  Future<Result<Product>> loadProduct(int id) async =>
      Ok(id == _similarCola.id ? _similarCola : _previewProduct);

  @override
  Future<Result<List<BoughtTogetherProduct>>> loadBoughtTogether(
    int productId, {
    int limit = 8,
  }) async => const Ok([]);

  @override
  Future<Result<List<VariantOption>>> loadAllActiveVariantOptions() async {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    return Ok(_previewVariantOptions);
  }

  @override
  Future<Result<List<ModifierGroup>>> loadAllModifierGroups() async =>
      const Ok([]);

  @override
  Future<Result<List<UnitOfMeasure>>> loadAllUnits({
    bool activeOnly = true,
  }) async => const Ok([]);
}

/// A shop that has been running long enough to accumulate options — the case
/// the old wall of "reuse" chips fell apart on.
final _previewVariantOptions = [
  _option(1, 'color', 'اللون', [
    'أحمر',
    'أزرق',
    'أخضر',
    'أسود',
    'أبيض',
    'أصفر',
    'برتقالي',
    'بنفسجي',
    'وردي',
    'رمادي',
    'بني',
    'ذهبي',
    'فضي',
    'كحلي',
    'بيج',
    'تركواز',
  ]),
  _option(2, 'size', 'المقاس', [
    'XS',
    'S',
    'M',
    'L',
    'XL',
    'XXL',
    '3XL',
    '38',
    '40',
    '42',
    '44',
    '46',
  ]),
  _option(3, 'material', 'الخامة', [
    'قطن',
    'كتان',
    'صوف',
    'جلد',
    'بوليستر',
    'حرير',
    'دنيم',
  ]),
  _option(4, 'flavor', 'النكهة', [
    'فراولة',
    'شوكولاتة',
    'فانيليا',
    'مانجو',
    'ليمون',
    'نعناع',
  ]),
  _option(5, 'weight', 'الوزن', ['250 غ', '500 غ', '1 كغ', '2 كغ', '5 كغ']),
  _option(6, 'pack', 'التعبئة', ['فردي', 'علبة', 'كرتونة']),
  _option(7, 'origin', 'بلد المنشأ', [
    'ليبيا',
    'تركيا',
    'مصر',
    'الصين',
    'إيطاليا',
  ]),
  _option(8, 'grade', 'الدرجة', ['ممتاز', 'أولى', 'ثانية']),
];

VariantOption _option(int id, String code, String name, List<String> values) {
  return VariantOption(
    id: id,
    code: code,
    name: name,
    displayOrder: id,
    values: [
      for (final (index, value) in values.indexed)
        VariantOptionValue(
          id: id * 100 + index,
          optionId: id,
          code: '$code-$index',
          name: value,
          displayOrder: index,
        ),
    ],
  );
}

class _FakePurchaseRepository extends PurchaseRepository {
  _FakePurchaseRepository() : super(PosApiService());

  @override
  Future<Result<List<VariantCostSummary>>> loadProductCostSummary(
    int productId,
  ) async => const Ok([]);
}

class _FakeSaleRepository extends SaleRepository {
  _FakeSaleRepository() : super(PosApiService());
}
