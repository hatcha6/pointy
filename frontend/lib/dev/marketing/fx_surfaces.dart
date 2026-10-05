// Dev-only, safe to delete, never imported by lib/main.dart.
//
// Foreign-currency pricing on the parallel-market cash rate (USD = 6.85 د.ل):
//   product-fx      — the new-product form, «سماعات لاسلكية» priced at 12 $,
//                     its dinar price shown beside it (≈ 82.20 د.ل)
//   exchange-rates  — the exchange-rate settings: today's rates with their age
//                     and source, and the products the dollar's move from
//                     6.70 to 6.85 has drifted, ready to reprice
//
// The two agree: the headphones' 12 $ is 80.40 د.ل at last week's 6.70 and
// 82.20 د.ل at today's 6.85 on both screens.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/catalog_identity_conflict.dart';
import 'package:pointy_frontend/src/data/models/customer_asset.dart';
import 'package:pointy_frontend/src/data/models/exchange_rate.dart';
import 'package:pointy_frontend/src/data/models/modifier_group.dart';
import 'package:pointy_frontend/src/data/models/product_category.dart';
import 'package:pointy_frontend/src/data/models/product_category_query.dart';
import 'package:pointy_frontend/src/data/models/product_page.dart';
import 'package:pointy_frontend/src/data/models/product_query.dart';
import 'package:pointy_frontend/src/data/models/unit_of_measure.dart';
import 'package:pointy_frontend/src/data/models/variant_option.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/fx_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/catalog/view_models/catalog_view_model.dart';
import 'package:pointy_frontend/src/features/catalog/views/product_form.dart';
import 'package:pointy_frontend/src/features/settings/view_models/exchange_rates_view_model.dart';
import 'package:pointy_frontend/src/features/settings/views/exchange_rates_page.dart';

import 'drive.dart';

// ---------------------------------------------------------------------------
// product-fx
// ---------------------------------------------------------------------------

class ProductFxSurface extends StatefulWidget {
  const ProductFxSurface({super.key});

  @override
  State<ProductFxSurface> createState() => _ProductFxSurfaceState();
}

class _ProductFxSurfaceState extends State<ProductFxSurface> {
  late final _catalog = CatalogViewModel(
    _FakeCatalogRepository(),
    fxRepository: FakeFxRepository(),
  );

  @override
  void initState() {
    super.initState();
    unawaited(_fill());
  }

  /// What the owner types: the name, the dollar price, and «دولار أمريكي».
  Future<void> _fill() async {
    final l10n = lookupAppLocalizations(const Locale('ar'));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await typeInto(l10n.barcodeLabel, '6291041500213');
    await typeInto(l10n.productNameLabel, 'سماعات لاسلكية');
    await typeInto(l10n.unitPriceLabel, '12');
    await pickDropdown<String>(
      const ValueKey('product_pricing_currency_field'),
      'USD',
    );
    FocusManager.instance.primaryFocus?.unfocus();
  }

  @override
  void dispose() {
    _catalog.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.newProductTitle)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ProductForm(
            viewModel: _catalog,
            showOpeningStock: true,
            onCreated: (_) {},
          ),
        ),
      ),
    );
  }
}

class _FakeCatalogRepository extends CatalogRepository {
  _FakeCatalogRepository() : super(PosApiService());

  @override
  Future<Result<ProductPage>> loadProducts({
    required ProductQuery query,
    int page = 1,
    bool bypassCache = false,
  }) async => const Ok(ProductPage(products: [], hasMore: false));

  @override
  Future<Result<String>> nextVariantSku() async => const Ok('1187');

  @override
  Future<Result<List<CustomerAssetType>>> loadAssetTypes() async =>
      const Ok([]);

  @override
  Future<Result<ProductCategoryPage>> loadProductCategories({
    ProductCategoryQuery query = const ProductCategoryQuery(),
    int page = 1,
  }) async => const Ok(
    ProductCategoryPage(
      categories: [
        ProductCategory(id: 1, name: 'اكسسوارات هواتف'),
        ProductCategory(id: 2, name: 'سماعات'),
      ],
      hasMore: false,
    ),
  );

  @override
  Future<Result<CatalogIdentityCheck>> checkVariantIdentity({
    String sku = '',
    String barcode = '',
    int? excludeVariantId,
  }) async => const Ok(CatalogIdentityCheck());

  @override
  Future<Result<List<VariantOption>>> loadAllActiveVariantOptions() async =>
      const Ok([]);

  @override
  Future<Result<List<ModifierGroup>>> loadAllModifierGroups() async =>
      const Ok([]);

  @override
  Future<Result<List<UnitOfMeasure>>> loadAllUnits({
    bool activeOnly = true,
  }) async => const Ok([]);
}

// ---------------------------------------------------------------------------
// exchange-rates
// ---------------------------------------------------------------------------

class ExchangeRatesSurface extends StatefulWidget {
  const ExchangeRatesSurface({super.key});

  @override
  State<ExchangeRatesSurface> createState() => _ExchangeRatesSurfaceState();
}

class _ExchangeRatesSurfaceState extends State<ExchangeRatesSurface> {
  late final _viewModel = ExchangeRatesViewModel(FakeFxRepository());

  @override
  void initState() {
    super.initState();
    // Every drifted product ticked, as the owner would before «تطبيق».
    unawaited(
      Future<void>.delayed(
        const Duration(milliseconds: 500),
      ).then((_) => _viewModel.selectAll()),
    );
  }

  @override
  void dispose() {
    _viewModel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      ExchangeRatesPage(viewModel: _viewModel);
}

// ---------------------------------------------------------------------------
// The rates
// ---------------------------------------------------------------------------

/// A shop that settles its imports in cash on the parallel market.
class FakeFxRepository extends FxRepository {
  FakeFxRepository() : super(PosApiService());

  @override
  Future<Result<CurrentRates>> loadCurrentRates() async {
    final now = DateTime.now();
    ResolvedRate rate(String code, double value, double hours, RateSource src) {
      return ResolvedRate(
        fromCode: code,
        toCode: 'LYD',
        rate: value,
        effectiveAt: now.subtract(Duration(minutes: (hours * 60).round())),
        source: src,
        instrument: SettlementInstrument.cash,
        bankCode: '',
        requestedInstrument: SettlementInstrument.cash,
        requestedBankCode: '',
        ageHours: hours,
      );
    }

    return Ok(
      CurrentRates(
        baseCode: 'LYD',
        instrument: SettlementInstrument.cash,
        bankCode: '',
        stalenessHours: 24,
        fxEnabled: true,
        rates: [
          rate('USD', 6.85, 2, RateSource.relay),
          rate('EUR', 7.42, 2, RateSource.relay),
          rate('TRY', 0.1675, 2, RateSource.relay),
          // A rate the owner typed from their own supplier's quote.
          rate('CNY', 0.95, 30, RateSource.manual),
        ],
      ),
    );
  }

  @override
  Future<Result<List<Currency>>> loadCurrencies() async => const Ok([
    Currency(
      code: 'LYD',
      nameAr: 'دينار ليبي',
      nameEn: 'Libyan Dinar',
      symbolAr: 'د.ل',
      symbolEn: 'LD',
      decimals: 3,
    ),
    Currency(
      code: 'USD',
      nameAr: 'دولار أمريكي',
      nameEn: 'US Dollar',
      symbolAr: r'$',
      symbolEn: r'$',
      displayOrder: 1,
    ),
    Currency(
      code: 'EUR',
      nameAr: 'يورو',
      nameEn: 'Euro',
      symbolAr: '€',
      symbolEn: '€',
      displayOrder: 2,
    ),
    Currency(
      code: 'TRY',
      nameAr: 'ليرة تركية',
      nameEn: 'Turkish Lira',
      symbolAr: '₺',
      symbolEn: '₺',
      displayOrder: 3,
    ),
    Currency(
      code: 'CNY',
      nameAr: 'يوان صيني',
      nameEn: 'Chinese Yuan',
      symbolAr: '¥',
      symbolEn: '¥',
      displayOrder: 4,
    ),
  ]);

  @override
  Future<Result<RepricePreview>> loadRepricePreview() async {
    PriceProposal dollars(int id, String label, double price) {
      const oldRate = 6.70;
      const newRate = 6.85;
      return PriceProposal(
        kind: 'variant',
        targetId: id,
        productId: id,
        label: label,
        currencyCode: 'USD',
        priceAmount: price,
        currentBasePrice: _round(price * oldRate),
        proposedBasePrice: _round(price * newRate),
        oldRate: oldRate,
        newRate: newRate,
        deltaPercent: (newRate / oldRate - 1) * 100,
      );
    }

    return Ok(
      RepricePreview(
        resolvedAt: DateTime.now(),
        proposals: [
          dollars(41, 'آيفون 13 برو 256 جيجا', 610),
          dollars(42, 'ساعة ذكية', 45),
          dollars(43, 'سماعات لاسلكية', 12),
          dollars(44, 'شاحن سريع 25 واط', 8),
          PriceProposal(
            kind: 'variant',
            targetId: 45,
            productId: 45,
            label: 'مكنسة كهربائية',
            currencyCode: 'EUR',
            priceAmount: 30,
            currentBasePrice: 219,
            proposedBasePrice: _round(30 * 7.42),
            oldRate: 7.30,
            newRate: 7.42,
            deltaPercent: (7.42 / 7.30 - 1) * 100,
          ),
        ],
      ),
    );
  }
}

double _round(double value) => (value * 100).roundToDouble() / 100;
