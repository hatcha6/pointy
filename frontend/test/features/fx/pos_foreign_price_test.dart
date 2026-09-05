import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/currency.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/data/models/shop_settings.dart';
import 'package:pointy_frontend/src/data/repositories/fx_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/shared/formatters.dart';

/// The till half of multi-currency.
///
/// This build shows a foreign price beside the dinar shelf price; it never
/// reads a rate, because a sale prices off the stored base price. So the whole
/// contract is: does the shop's switch gate the fetch, does the currency list
/// parse, and does a foreign-priced variant carry both numbers.
void main() {
  setUp(() {
    configureCurrencySymbol('د.ل', code: 'LYD');
    configureForeignCurrencySymbols(const <String, String>{});
  });

  group('the master switch', () {
    test('an older backend that never heard of fx reads as off', () {
      final settings = ShopSettings.fromJson(const {'shop_name': 'متجر'});
      expect(settings.fxEnabled, isFalse);
    });

    test('the flag is read when the backend sends it', () {
      final settings = ShopSettings.fromJson(const {
        'shop_name': 'متجر',
        'fx_enabled': true,
      });
      expect(settings.fxEnabled, isTrue);
    });
  });

  group('currency list', () {
    FxRepository repositoryReturning(String body) {
      final client = MockClient((request) async {
        expect(request.url.path, contains('currencies/'));
        return http.Response(
          body,
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });
      return FxRepository(PosApiService(client: client));
    }

    test('a paginated payload yields the currencies', () async {
      final repository = repositoryReturning(
        jsonEncode({
          'results': [
            {'code': 'USD', 'symbol_ar': r'$', 'name_ar': 'دولار'},
            {'code': 'TRY', 'symbol_ar': '₺', 'name_ar': 'ليرة'},
          ],
        }),
      );

      final result = await repository.loadCurrencies();

      expect(result, isA<Ok<List<Currency>>>());
      final currencies = (result as Ok<List<Currency>>).value;
      expect(currencies.map((c) => c.code), ['USD', 'TRY']);
      expect(currencies.first.symbol, r'$');
    });

    test('a bare list is accepted too', () async {
      final repository = repositoryReturning(
        jsonEncode([
          {'code': 'EUR', 'symbol_ar': '€'},
        ]),
      );

      final result = await repository.loadCurrencies();

      expect((result as Ok<List<Currency>>).value.single.code, 'EUR');
    });

    test('a currency with no symbol falls back to its code', () {
      final currency = Currency.fromJson(const {'code': 'XAF'});
      expect(currency.symbol, 'XAF');
    });
  });

  group('what the cashier sees', () {
    test('a foreign price renders as a symbol once the list has loaded', () {
      configureForeignCurrencySymbols(const {'USD': r'$'});
      expect(formatForeignMoney(12, 'USD'), contains(r'$'));
    });

    test('without the list it degrades to the code, never to nothing', () {
      // The fetch is best-effort — a till must not wait on it — so this is the
      // state a failed or skipped load leaves behind, and it stays readable.
      expect(formatForeignMoney(12, 'USD'), contains('USD'));
    });

    test('a foreign-priced variant carries both numbers', () {
      final variant = ProductVariant.fromJson(const {
        'id': 1,
        'sku': 'X',
        'unit_price': '82.20',
        'price_amount': '12.00',
        'pricing_currency': 'USD',
      });

      expect(variant.hasForeignPrice, isTrue);
      expect(variant.priceAmount, 12);
      expect(variant.pricingCurrency, 'USD');
      // unit_price stays the shop's own currency: the invariant the whole
      // feature rests on.
      expect(variant.unitPrice, 82.20);
    });

    test('an ordinary product is not foreign-priced', () {
      final variant = ProductVariant.fromJson(const {
        'id': 2,
        'sku': 'Y',
        'unit_price': '5.00',
      });
      expect(variant.hasForeignPrice, isFalse);
      expect(variant.priceAmount, isNull);
    });
  });
}
