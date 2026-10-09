import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/voucher_pricing.dart';
import 'package:pointy_frontend/src/data/repositories/integrations_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';

/// «أسعار كروت دفتر» on a fake backend: three services, a handful of cards,
/// and a refusal when a price is below what the shop pays.
class FakePricingRepository extends IntegrationsRepository {
  FakePricingRepository() : super(PosApiService());

  VoucherPricing pricing = const VoucherPricing(
    defaultMode: PricingMode.company,
    companyRule: CompanyPricingRule(fixedLyd: 0.5, shopSharePercent: 50),
    services: [
      PricingService(
        key: 'airtime',
        label: 'الشحن المباشر',
        example: PricingExample(
          costHint: 20,
          shopPays: 21.5,
          companyPrice: 22.75,
          yourPrice: 22.75,
        ),
      ),
      PricingService(
        key: 'bill:electricity',
        label: 'فواتير الكهرباء',
        mode: PricingMode.custom,
        markupPercent: 10,
        example: PricingExample(
          costHint: 100,
          shopPays: 104,
          companyPrice: 108,
          yourPrice: 114.5,
        ),
      ),
      PricingService(
        key: 'bill:tv',
        label: 'فواتير التلفزيون',
        example: PricingExample(
          costHint: 50,
          shopPays: 52,
          companyPrice: 54.25,
        ),
      ),
    ],
  );

  final List<CardPriceRow> cards = [
    const CardPriceRow(
      variantId: 1,
      name: 'آيتونز 10 دولار',
      brand: 'itunes',
      shopPays: 52.4,
      companyPrice: 55,
    ),
    const CardPriceRow(
      variantId: 2,
      name: 'بلايستيشن 20 دولار',
      brand: 'playstation',
      shopPays: 101,
      companyPrice: 105.5,
      mode: PricingMode.custom,
      customPrice: 112,
    ),
    // The company's cost has overtaken the shop's own price: blocked.
    const CardPriceRow(
      variantId: 4,
      name: 'نتفلكس 15 دولار',
      brand: 'netflix',
      shopPays: 78.6,
      companyPrice: 82,
      mode: PricingMode.custom,
      customPrice: 75,
      belowCost: true,
    ),
    const CardPriceRow(
      variantId: 3,
      name: 'ستيم 5 دولار',
      brand: 'steam',
      shopPays: 26.2,
      companyPrice: 28,
    ),
  ];

  VoucherPricing? lastSaved;
  final List<Map<String, Object?>> bulkCalls = [];

  @override
  Future<Result<VoucherPricing>> loadVoucherPricing() async => Ok(pricing);

  @override
  Future<Result<VoucherPricing>> saveVoucherPricing(VoucherPricing next) async {
    lastSaved = next;
    pricing = next;
    return Ok(next);
  }

  @override
  Future<Result<CardPricePage>> loadVoucherCardPrices({
    String search = '',
    String brand = '',
    int page = 1,
    bool belowCost = false,
  }) async {
    final rows = [
      for (final c in cards)
        if ((brand.isEmpty || c.brand == brand) &&
            (search.isEmpty || c.name.contains(search)) &&
            (!belowCost || c.belowCost))
          c,
    ];
    return Ok(
      CardPricePage(
        rows: rows,
        count: rows.length,
        page: page,
        belowCostCount: cards.where((c) => c.belowCost).length,
      ),
    );
  }

  @override
  Future<Result<CardPriceRow>> saveVoucherCardPrice(
    int variantId, {
    required PricingMode mode,
    double? price,
  }) async {
    final i = cards.indexWhere((c) => c.variantId == variantId);
    final old = cards[i];
    if (price != null && price < (old.shopPays ?? 0)) {
      return const Error(
        PosApiException(
          message: 'x',
          statusCode: 400,
          responseBody: '{"price": "السعر أقل مما تدفعه للشركة"}',
        ),
      );
    }
    final next = CardPriceRow(
      variantId: old.variantId,
      name: old.name,
      brand: old.brand,
      shopPays: old.shopPays,
      companyPrice: old.companyPrice,
      mode: mode,
      customPrice: price,
    );
    cards[i] = next;
    return Ok(next);
  }

  @override
  Future<Result<int>> bulkVoucherCardPrices({
    List<int>? variantIds,
    String? brand,
    required PricingMode mode,
    double? markupPercent,
    bool belowCost = false,
  }) async {
    bulkCalls.add({
      'ids': variantIds,
      'brand': brand,
      'mode': mode,
      'below_cost': belowCost,
    });
    for (var i = 0; i < cards.length; i++) {
      final c = cards[i];
      if ((variantIds?.contains(c.variantId) ?? false) ||
          c.brand == brand ||
          (belowCost && c.belowCost)) {
        cards[i] = CardPriceRow(
          variantId: c.variantId,
          name: c.name,
          brand: c.brand,
          shopPays: c.shopPays,
          companyPrice: c.companyPrice,
        );
      }
    }
    return Ok(variantIds?.length ?? 1);
  }
}
