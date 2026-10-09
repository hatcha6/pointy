import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/voucher_pricing.dart';
import 'package:pointy_frontend/src/features/settings/view_models/voucher_pricing_view_model.dart';

import '../../support/pricing_testing.dart';

void main() {
  late FakePricingRepository repository;
  late VoucherPricingViewModel vm;

  setUp(() {
    repository = FakePricingRepository();
    vm = VoucherPricingViewModel(repository);
  });
  tearDown(() => vm.dispose());

  test('reads tolerant JSON: strings, numbers, missing fields', () {
    final pricing = VoucherPricing.fromJson({
      'default_mode': 'custom',
      'default_markup_percent': '5.00',
      'services': [
        {
          'key': 'airtime',
          'mode': 'custom',
          'markup_percent': 10,
          'country': 'ML',
          'example': {'shop_pays': '21.50'},
        },
        {'label': 'no key'},
      ],
    });
    expect(pricing.defaultMode, PricingMode.custom);
    expect(pricing.defaultMarkupPercent, 5);
    expect(pricing.services, hasLength(1));
    expect(pricing.services.single.country, 'ML');
    expect(pricing.services.single.example.shopPays, 21.5);
    expect(pricing.companyRule.fixedLyd, isNull);
  });

  test('editing a service marks it dirty; saving sends every row', () async {
    await vm.loadPricing();
    expect(vm.isDirty, isFalse);

    final airtime = vm.pricing!.services.first;
    vm.setServiceMode(airtime, PricingMode.custom);
    vm.setServiceMarkup(vm.pricing!.services.first, 12);
    expect(vm.isDirty, isTrue);

    expect(await vm.savePricing(), isTrue);
    expect(vm.isDirty, isFalse);
    final sent = repository.lastSaved!.toJson();
    final rows = sent['services']! as List;
    expect(rows, hasLength(3));
    expect((rows.first as Map)['markup_percent'], 12);
    expect((rows.last as Map)['markup_percent'], isNull);
  });

  test('the live example rounds the markup up to a quarter dinar', () {
    expect(markupExample(21.5, 10), 23.75);
    expect(markupExample(null, 10), isNull);
  });

  test('cards: filter by brand, own price, follow company', () async {
    await vm.loadCards();
    expect(vm.rows, hasLength(4));
    expect(vm.brands, containsAll(['itunes', 'steam']));

    await vm.loadCards(brand: 'steam');
    expect(vm.rows.single.name, 'ستيم 5 دولار');

    await vm.loadCards(brand: '');
    final itunes = vm.rows.first;
    expect(await vm.saveCardPrice(itunes, 60), isTrue);
    expect(vm.rows.first.sellingPrice, 60);

    expect(await vm.followCompany(), isTrue);
    expect(repository.bulkCalls.single['mode'], PricingMode.company);
    expect(vm.rows.every((r) => r.mode == PricingMode.company), isTrue);
  });

  test(
    'a price below cost shows the server message and keeps the row',
    () async {
      await vm.loadCards();
      final ok = await vm.saveCardPrice(vm.rows.first, 10);
      expect(ok, isFalse);
      expect(vm.cardError, 'السعر أقل مما تدفعه للشركة');
      expect(vm.rows.first.mode, PricingMode.company);
    },
  );

  test(
    'cards under cost are counted, filtered and handed back in one call',
    () async {
      await vm.loadCards();
      expect(vm.belowCostCount, 1);
      expect(vm.rows.where((r) => r.belowCost).single.variantId, 4);

      await vm.loadCards(belowCostOnly: true);
      expect(vm.rows.map((r) => r.variantId), [4]);

      expect(await vm.followCompanyForBelowCost(), isTrue);
      expect(repository.bulkCalls.last['below_cost'], isTrue);
      expect(vm.belowCostOnly, isFalse);
      expect(vm.belowCostCount, 0);
      expect(vm.rows, hasLength(4));
    },
  );
}
