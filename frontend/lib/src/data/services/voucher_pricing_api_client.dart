import 'package:http/http.dart' as http;

import '../models/voucher_pricing.dart';
import 'api_session.dart';

/// REST access to how the shop prices «كروت دفتر» under
/// `/api/integrations/pointy/pricing/` (owner and manager only).
class VoucherPricingApiClient {
  const VoucherPricingApiClient(this._session);

  final PosApiSession _session;

  static const _base = 'integrations/pointy/pricing/';

  Future<VoucherPricing> fetch() async {
    final response = await _session.get(_base);
    _session.throwApiException(response, 'Loading the prices failed');
    return _pricing(response);
  }

  Future<VoucherPricing> save(VoucherPricing pricing) async {
    final response = await _session.put(_base, body: pricing.toJson());
    _session.throwApiException(response, 'Saving the prices failed');
    return _pricing(response);
  }

  Future<CardPricePage> fetchCards({
    String search = '',
    String brand = '',
    int page = 1,
    bool belowCost = false,
  }) async {
    final response = await _session.get(
      '${_base}cards/',
      query: {
        if (belowCost) 'below_cost': '1',
        if (search.trim().isNotEmpty) 'search': search.trim(),
        if (brand.isNotEmpty) 'brand': brand,
        'page': '$page',
      },
    );
    _session.throwApiException(response, 'Loading the card prices failed');
    final decoded = _session.decodedBody(response);
    return decoded is Map<String, Object?>
        ? CardPricePage.fromJson(decoded)
        : const CardPricePage();
  }

  Future<CardPriceRow> saveCard(
    int variantId, {
    required PricingMode mode,
    double? price,
  }) async {
    final response = await _session.put(
      '${_base}cards/$variantId/',
      body: {'mode': mode.name, 'price': price},
    );
    _session.throwApiException(response, 'Saving the card price failed');
    return CardPriceRow.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  /// Applies one mode to many cards; returns how many were updated.
  Future<int> bulk({
    List<int>? variantIds,
    String? brand,
    required PricingMode mode,
    double? markupPercent,
    bool belowCost = false,
  }) async {
    final response = await _session.post(
      '${_base}cards/bulk/',
      body: {
        if (belowCost) 'below_cost': true,
        'variant_ids': ?variantIds,
        'brand': ?brand,
        'mode': mode.name,
        'markup_percent': ?markupPercent,
      },
    );
    _session.throwApiException(response, 'Saving the card prices failed');
    final decoded = _session.decodedBody(response);
    return decoded is Map<String, Object?>
        ? (decoded['updated'] as num?)?.toInt() ?? 0
        : 0;
  }

  VoucherPricing _pricing(http.Response response) {
    final decoded = _session.decodedBody(response);
    return decoded is Map<String, Object?>
        ? VoucherPricing.fromJson(decoded)
        : const VoucherPricing();
  }
}
