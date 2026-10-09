import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/dev/services_fixtures.dart';
import 'package:pointy_frontend/src/data/models/integration_card.dart';
import 'package:pointy_frontend/src/data/models/provider_receipt_fields.dart';
import 'package:pointy_frontend/src/data/models/service_country_detail.dart';
import 'package:pointy_frontend/src/data/models/service_kinds.dart';
import 'package:pointy_frontend/src/data/models/service_quote.dart';
import 'package:pointy_frontend/src/data/models/services_directory.dart';
import 'package:pointy_frontend/src/data/models/voucher_menu.dart';

/// «كروت دفتر»' direct services as the shop's backend serves them. A bad entry
/// costs the till that entry, never the screen; and nothing Latin is ever the
/// name a cashier reads.
void main() {
  group('the directory', () {
    test('keeps countries, calling codes, counts and the popular order', () {
      final directory = servicesPreviewDirectory();

      expect(directory.available, isTrue);
      expect(directory.balance, 345.5);
      expect(directory.version, isNotEmpty);
      expect(directory.popular.take(3), ['NE', 'ML', 'NG']);

      final mali = directory.country('ML')!;
      expect(mali.name, 'مالي');
      expect(mali.nameEn, 'Mali');
      expect(mali.dial, ['223']);
      expect(mali.currency, 'XOF');
      expect(mali.currencyName, 'فرنك أفريقي');
      expect(mali.currencyLabel, 'فرنك أفريقي');
      expect(mali.popularRank, 2);
      expect(mali.airtimeCount, 3);
      expect(mali.billCount, 2);
      expect(directory.country('ml'), same(mali), reason: 'any case');
      expect(directory.country('ZZ'), isNull);
    });

    test('lists the bill types and the countries that have each', () {
      final directory = servicesPreviewDirectory();

      expect(directory.billTypes.map((type) => type.type), [
        BillType.electricity,
        BillType.water,
        BillType.tv,
        BillType.internet,
      ]);
      expect(directory.billCountries(BillType.water).map((c) => c.code), [
        'SN',
      ], reason: 'water is sold in Senegal only');
      expect(
        directory
            .billCountries(BillType.electricity)
            .map((c) => c.code)
            .toSet(),
        {'NG', 'SN', 'ML', 'ZA', 'MZ', 'MW'},
      );
      expect(directory.billType(BillType.electricity)?.billers, 16);
    });

    test('names the countries the services do not reach', () {
      final directory = servicesPreviewDirectory();

      expect(directory.unsupported.map((c) => c.code), contains('SD'));
      expect(
        directory.unsupported.firstWhere((c) => c.code == 'SD').label,
        'السودان',
      );
    });

    test('a server that sends no bill_types falls back to billers counts', () {
      final directory = ServicesDirectory.fromJson({
        'available': true,
        'countries': [
          {
            'code': 'NG',
            'name': 'نيجيريا',
            'dial': ['234'],
            'airtime': 4,
            'bills': 12,
          },
          {
            'code': 'ML',
            'name': 'مالي',
            'dial': ['223'],
            'airtime': 3,
          },
        ],
      });

      expect(directory.billCountries(BillType.electricity).map((c) => c.code), [
        'NG',
      ]);
      expect(directory.airtimeCountries.map((c) => c.code), ['NG', 'ML']);
    });

    test('is tolerant: a bad country is skipped, a missing field is empty', () {
      final directory = ServicesDirectory.fromJson({
        'available': true,
        'popular': ['ml', 'zz'],
        'countries': [
          'not a map',
          {'name': 'no code'},
          {
            'code': 'ml',
            'name': 'مالي',
            'dial': 223,
            'airtime': {
              'operators': [{}, {}],
            },
          },
          {
            'code': 'NE',
            'dial': ['+227'],
            'bills': 'x',
          },
        ],
        'unsupported': [
          {'code': 'sd'},
          5,
        ],
        'bill_types': [
          {'type': 'tv', 'countries': []},
        ],
      });

      expect(directory.countries.map((c) => c.code), ['ML', 'NE']);
      expect(directory.country('ML')!.dial, ['223'], reason: 'a number is ok');
      expect(directory.country('ML')!.airtimeCount, 2, reason: 'counted list');
      expect(directory.country('NE')!.dial, ['227'], reason: 'plus stripped');
      expect(directory.country('NE')!.billCount, 0);
      expect(directory.popular, ['ML', 'ZZ']);
      expect(directory.unsupported.single.code, 'SD');
      expect(directory.billTypes, isEmpty, reason: 'no countries, no card');
    });

    test('with nothing to say, is not available', () {
      expect(ServicesDirectory.fromJson(const {}).available, isFalse);
      expect(ServicesDirectory.empty.hasCountries, isFalse);
      expect(
        ServicesDirectory.fromJson(const {
          'available': false,
          'error_code': 'switched_off',
        }).errorCode,
        'switched_off',
      );
    });

    test(
      'shows an Arabic name, and a Latin one only as a left-to-right fallback',
      () {
        expect(const ServiceCountry(code: 'ML', name: 'مالي').label, 'مالي');
        expect(
          const ServiceCountry(code: 'ZZ', name: 'Zedland').label,
          '\u{2066}Zedland\u{2069}',
        );
        expect(const ServiceCountry(code: 'ZZ').label, 'ZZ');
        expect(serviceDisplayName('', fallback: '#5'), '#5');
      },
    );
  });

  group('one country', () {
    test(
      'has networks that take a range or a list, and say when they round',
      () {
        final detail = servicesPreviewCountry('ML');

        expect(detail.country.code, 'ML');
        expect(detail.operators.map((o) => o.id), [289, 290, 291]);
        final orange = detail.operator(289)!;
        expect(orange.name, 'أورنج مالي');
        expect(orange.nameEn, 'Orange Mali');
        expect(orange.label, 'أورنج مالي');
        expect(orange.isRange, isTrue);
        expect(orange.min, 1967);
        expect(orange.max, 32800);
        expect(orange.amountCurrency, 'XOF');
        expect(orange.receiveCurrency, 'XOF');
        expect(orange.approximate, isFalse);
        expect(orange.popularAmount, '5000');
        expect(orange.amounts.map((a) => a.amount), [
          '2000',
          '5000',
          '10000',
          '15000',
          '25000',
        ]);
        expect(orange.amountFor('5000')!.price, 96.5);
        expect(orange.takesCustomAmount, isTrue);
        expect(orange.accepts(1967), isTrue);
        expect(orange.accepts(1966), isFalse);
        expect(orange.accepts(32801), isFalse);

        final malitel = detail.operator(290)!;
        expect(malitel.isFixed, isTrue);
        expect(malitel.takesCustomAmount, isFalse);
        expect(malitel.accepts(5000), isTrue);
        expect(malitel.accepts(5001), isFalse);

        final ghana = servicesPreviewCountry('GH').operator(342)!;
        expect(ghana.approximate, isTrue);
        expect(ghana.amountCurrency, 'USD');
        expect(ghana.receiveCurrency, 'GHS');
        expect(ghana.amounts.first.receive, '12');
        expect(ghana.amounts.first.receiveCurrency, 'GHS');
      },
    );

    test('has providers by type, with plans and the invoice they may need', () {
      final nigeria = servicesPreviewCountry('NG');
      expect(nigeria.billersOf(BillType.electricity), hasLength(10));
      final ikeja = nigeria.biller(5)!;
      expect(ikeja.name, 'كهرباء إيكيجا (مسبقة الدفع)');
      expect(ikeja.type, BillType.electricity);
      expect(ikeja.isPrepaid, isTrue);
      expect(ikeja.requiresInvoice, isFalse);
      expect(ikeja.isRange, isTrue);
      expect(ikeja.min, 1000);
      expect(ikeja.accepts(999), isFalse);
      expect(ikeja.suggested.first.amount, '2000');
      expect(nigeria.biller(6)!.isPostpaid, isTrue);

      final mali = servicesPreviewCountry('ML');
      final canal = mali.billersOf(BillType.tv).single;
      expect(canal.isFixed, isTrue);
      expect(canal.plans, hasLength(6));
      expect(canal.plan(241)!.description, 'كانال بلس أكسيس إنجليش بيسك – شهر');
      expect(
        canal.plan(241)!.descriptionEn,
        'Canalplus Acces English Basic (10000/1MOIS)',
      );
      expect(canal.plan(241)!.label, 'كانال بلس أكسيس إنجليش بيسك – شهر');

      final senegal = servicesPreviewCountry('SN');
      final water = senegal.billersOf(BillType.water).single;
      expect(water.requiresInvoice, isTrue);
      expect(water.isPostpaid, isTrue);
      expect(
        senegal.billersOf(BillType.electricity).where((b) => b.requiresInvoice),
        hasLength(1),
      );
    });

    test('reads prices from either field name, and never needs a cost', () {
      final operator = AirtimeOperator.fromJson({
        'id': 1,
        'name': 'x',
        'amounts': [
          {'amount': 100, 'price': '2.50'},
          {'amount': '200', 'retail_price': '5.00', 'unit_price': '4.80'},
          {'amount': '300'},
        ],
      });

      expect(operator.amounts.map((a) => a.price), [2.5, 5.0, null]);
      expect(operator.amounts.map((a) => a.cost), [null, null, null]);
      expect(operator.amounts.first.amount, '100');
      expect(operator.receiveCurrency, '');
    });

    test('is tolerant: bad networks and providers are skipped', () {
      final detail = ServiceCountryDetail.fromJson({
        'country': {'code': 'ml'},
        'airtime': {
          'operators': [
            'x',
            {'name': 'no id'},
            {
              'id': 7,
              'name': 'ok',
              'mode': 'weird',
              'amounts': [{}, 3],
            },
          ],
        },
        'bills': {
          'billers': [
            {'id': 0},
            {
              'id': 3,
              'type': 'television',
              'service': 'prepaid',
              'plans': [
                {'id': 1},
              ],
            },
            {'id': 4, 'type': 'toll'},
          ],
        },
      });

      expect(detail.country.code, 'ML');
      expect(detail.operators.single.id, 7);
      expect(detail.operators.single.isRange, isTrue, reason: 'default mode');
      expect(detail.operators.single.amounts, isEmpty);
      expect(detail.billers.map((b) => b.id), [3, 4]);
      expect(detail.billers.first.type, BillType.tv);
      expect(
        detail.billers.first.plans,
        isEmpty,
        reason: 'a plan has an amount',
      );
      expect(ServiceCountryDetail.fromJson(const {}).operators, isEmpty);
    });

    test(
      'shows a Latin network name left to right, an Arabic one as it is',
      () {
        expect(
          const AirtimeOperator(id: 1, name: 'أورنج مالي').label,
          'أورنج مالي',
        );
        expect(
          const AirtimeOperator(id: 1, name: 'Orange Mali').label,
          '\u{2066}Orange Mali\u{2069}',
        );
        expect(const AirtimeOperator(id: 5).label, '#5');
      },
    );
  });

  group('quotes and detection', () {
    test('a request says what it asks, and only that', () {
      const airtime = ServiceQuoteRequest.airtime(
        country: 'ML',
        operatorId: 289,
        phone: '70123456',
        amount: '5000',
        amountCurrency: 'XOF',
      );
      expect(airtime.toJson(), {
        'kind': 'airtime',
        'country': 'ML',
        'operator_id': 289,
        'phone': '70123456',
        'amount': '5000',
        'amount_currency': 'XOF',
      });

      const bill = ServiceQuoteRequest.bill(
        country: 'SN',
        billerId: 52,
        account: '12345678',
        amount: '15000',
        amountCurrency: 'XOF',
        invoiceId: '2024-118833',
      );
      expect(bill.toJson(), {
        'kind': 'bill',
        'country': 'SN',
        'biller_id': 52,
        'account': '12345678',
        'amount': '15000',
        'amount_currency': 'XOF',
        'invoice_id': '2024-118833',
      });

      const plan = ServiceQuoteRequest.bill(
        country: 'ML',
        billerId: 24,
        account: '001122',
        amount: '10000',
        amountCurrency: 'XOF',
        amountId: 241,
      );
      expect(plan.toJson()['amount_id'], 241);
      expect(plan.toJson().containsKey('invoice_id'), isFalse);
      expect(plan.signature, isNot(bill.signature));
    });

    test(
      'an answer carries the sealed price and the server\'s own option code',
      () {
        final outcome = ServiceQuoteOutcome.fromJson({
          'ok': true,
          'kind': 'airtime',
          'option_code': 'air:289:5000:XOF',
          'option_label': 'أورنج مالي · 5,000 فرنك أفريقي',
          'subscriber_ref': '+22370123456',
          'price': '96.50',
          'receive': {'amount': '5000', 'currency': 'xof'},
          'approximate': false,
          'quote': 'sealed.abc',
          'service_variant_id': 9301,
          'exceeds_float': true,
          'cost': '91.30',
        });

        final quote = outcome.quote!;
        expect(outcome.isQuoted, isTrue);
        expect(quote.kind, ServiceKind.airtime);
        expect(quote.optionCode, 'air:289:5000:XOF');
        expect(quote.subscriberRef, '+22370123456');
        expect(quote.price, 96.5);
        expect(quote.receiveAmount, '5000');
        expect(quote.receiveCurrency, 'XOF');
        expect(quote.receiveValue, 5000);
        expect(quote.quote, 'sealed.abc');
        expect(quote.serviceVariantId, 9301);
        expect(quote.exceedsFloat, isTrue);
        expect(quote.cost, 91.3);
        expect(quote.isUsable, isTrue);
      },
    );

    test('a refusal names its code and the limits', () {
      final outcome = ServiceQuoteOutcome.fromJson({
        'ok': false,
        'error_code': 'amount_out_of_range',
        'min': '1967',
        'max': 32800,
      });

      expect(outcome.isQuoted, isFalse);
      expect(outcome.refusal!.errorCode, ServiceRefusalCode.amountOutOfRange);
      expect(outcome.refusal!.min, 1967);
      expect(outcome.refusal!.max, 32800);

      final unavailable = ServiceQuoteOutcome.fromJson({
        'ok': false,
        'code': 'service_unavailable',
        'reason': 'rate_unset',
      });
      expect(unavailable.refusal!.errorCode, 'service_unavailable');
      expect(unavailable.refusal!.reason, 'rate_unset');
    });

    test('an answer that is neither a price nor a reason is not a price', () {
      final outcome = ServiceQuoteOutcome.fromJson({'ok': true, 'price': '5'});

      expect(outcome.isQuoted, isFalse);
      expect(outcome.refusal!.errorCode, ServiceRefusalCode.unreachable);
    });

    test('a quote with no price, or none worth charging, is not a quote', () {
      Map<String, Object?> answer(Object? price) => {
        'ok': true,
        'kind': 'airtime',
        'option_code': 'air:289:5000:XOF',
        'option_label': 'أورنج مالي',
        'subscriber_ref': '+22370123456',
        'price': ?price,
        'receive': {'amount': '5000', 'currency': 'XOF'},
        'quote': 'sealed',
        'service_variant_id': 1,
      };

      // A line priced at nothing would be sold for nothing.
      for (final price in [null, '', '0', '0.00', 0, -3, 'abc', 'NaN']) {
        final outcome = ServiceQuoteOutcome.fromJson(answer(price));

        expect(outcome.isQuoted, isFalse, reason: '$price');
        expect(outcome.refusal, isNotNull, reason: '$price');
        expect(outcome.refusal!.isTransient, isTrue, reason: 'ask again');
      }
      expect(ServiceQuoteOutcome.fromJson(answer('0.50')).isQuoted, isTrue);
    });

    test('a detection carries the network and the number as normalised', () {
      final found = OperatorDetection.fromJson({
        'detected': true,
        'operator': servicesPreviewCountryJson('ML')['airtime'] is Map
            ? ((servicesPreviewCountryJson('ML')['airtime']!
                          as Map)['operators']!
                      as List)
                  .first
            : null,
        'phone': {
          'e164': '+22370123456',
          'national': '70123456',
          'country': 'ml',
        },
      });

      expect(found.detected, isTrue);
      expect(found.operator!.id, 289);
      expect(found.phone!.e164, '+22370123456');
      expect(found.phone!.country, 'ML');

      final missed = OperatorDetection.fromJson({
        'detected': false,
        'reason': 'not_detected',
      });
      expect(missed.detected, isFalse);
      expect(missed.reason, ServiceRefusalCode.notDetected);
      expect(missed.operator, isNull);

      // "Detected" with no network to name is not detected.
      expect(OperatorDetection.fromJson({'detected': true}).detected, isFalse);
    });

    test(
      'recent recipients keep the number, the network and the last amount',
      () {
        final recipient = RecentRecipient.fromJson(
          servicesPreviewRecentsJson().first,
        );

        expect(recipient.phone, '+22370123456');
        expect(recipient.country, 'ML');
        expect(recipient.operatorId, 289);
        expect(recipient.operatorName, 'أورنج مالي');
        expect(recipient.amount, '5000');
        expect(recipient.currency, 'XOF');
        expect(recipient.at, isNotNull);
      },
    );
  });

  group('the voucher menu\'s services', () {
    VoucherMenu menuWith(List<Object?> services) => VoucherMenu.fromJson({
      'available': true,
      'categories': <Object?>[],
      'countries': <Object?>[],
      'brands': <Object?>[],
      'services': services,
    });

    test('lists airtime and one card per type of bill', () {
      final menu = menuWith(servicesPreviewMenuServicesJson());

      expect(menu.hasServices, isTrue);
      expect(menu.airtimeService!.key, 'airtime');
      expect(menu.airtimeService!.variantId, 9301);
      expect(menu.airtimeService!.countries, 32);
      expect(menu.billServices.map((s) => s.billType), [
        BillType.electricity,
        BillType.water,
        BillType.tv,
        BillType.internet,
      ]);
      expect(menu.billServices.first.key, 'bill:electricity');
      expect(menu.billServices.first.kind, ServiceKind.bill);
      expect(menu.billServices.first.variantId, 9302);
      expect(menu.hasBills, isTrue);
    });

    test('a service that is off, or has no product, is not sold', () {
      final menu = menuWith([
        {
          'key': 'airtime',
          'kind': 'airtime',
          'available': false,
          'variant_id': 1,
        },
        {
          'key': 'bill:water',
          'kind': 'bill',
          'bill_type': 'water',
          'available': true,
          'variant_id': 0,
        },
        {'key': 'bill:tv', 'available': true, 'variant_id': 9},
      ]);

      expect(menu.airtimeService, isNull);
      expect(menu.billServices.map((s) => s.key), ['bill:tv']);
      expect(
        menu.billServices.single.billType,
        BillType.tv,
        reason: 'from key',
      );
      expect(menu.sellableServices, hasLength(1));
    });

    test('puts the cards in the till\'s order whatever order they came in', () {
      final menu = menuWith([
        {'key': 'bill:internet', 'available': true, 'variant_id': 9},
        {'key': 'bill:tv', 'available': true, 'variant_id': 9},
        {'key': 'bill:electricity', 'available': true, 'variant_id': 9},
        {'key': 'bill:water', 'available': true, 'variant_id': 9},
      ]);

      expect(menu.billServices.map((s) => s.billType), [
        BillType.electricity,
        BillType.water,
        BillType.tv,
        BillType.internet,
      ]);
    });

    test('does not offer tolls or types it has no card for', () {
      final menu = menuWith([
        {'key': 'bill:toll', 'available': true, 'variant_id': 9},
        {'key': 'bill:other', 'available': true, 'variant_id': 9},
        {'key': 'bill:garbage', 'available': true, 'variant_id': 9},
      ]);

      expect(menu.hasBills, isFalse);
    });

    test('a menu from before services, or a bad entry, has none', () {
      expect(VoucherMenu.fromJson(const {'available': true}).services, isEmpty);
      expect(
        VoucherMenu.fromJson(const {'available': true}).hasServices,
        isFalse,
      );
      expect(
        menuWith([
          'x',
          3,
          {},
          {'key': ''},
        ]).services,
        isEmpty,
      );
      expect(
        menuWith([
          {'key': 'airtime', 'available': true, 'variant_id': 1},
        ]).hasServices,
        isTrue,
      );
      // Services of a menu that is not available are not for sale either.
      expect(
        VoucherMenu.fromJson({
          'available': false,
          'services': [
            {'key': 'airtime', 'available': true, 'variant_id': 1},
          ],
        }).hasServices,
        isFalse,
      );
    });
  });

  group('test mode (the relay on its sandbox supplier)', () {
    // Parsed the way every other flag of these answers is: only an explicit
    // true counts. Absent, null or anything else is the live supplier.
    const notTrue = <Object?>[null, false, 'true', 'yes', 1, 0, <Object?>[]];

    test('is only ever an explicit true', () {
      for (final value in notTrue) {
        final reason = 'test_mode: $value';
        expect(
          VoucherMenu.fromJson({
            'available': true,
            'test_mode': value,
          }).testMode,
          isFalse,
          reason: reason,
        );
        expect(
          VoucherMenuService.fromJson({
            'key': 'airtime',
            'test_mode': value,
          }).testMode,
          isFalse,
          reason: reason,
        );
        expect(
          ServicesDirectory.fromJson({
            'available': true,
            'test_mode': value,
          }).testMode,
          isFalse,
          reason: reason,
        );
        expect(
          ServiceCountryDetail.fromJson({'test_mode': value}).testMode,
          isFalse,
          reason: reason,
        );
      }
      expect(VoucherMenu.fromJson(const {}).testMode, isFalse);
      expect(ServicesDirectory.fromJson(const {}).testMode, isFalse);
      expect(ServiceCountryDetail.fromJson(const {}).testMode, isFalse);
    });

    test('is read where the backend puts it', () {
      expect(
        VoucherMenu.fromJson({'available': true, 'test_mode': true}).testMode,
        isTrue,
      );
      expect(
        VoucherMenuService.fromJson({
          'key': 'airtime',
          'test_mode': true,
        }).testMode,
        isTrue,
      );
      expect(
        ServicesDirectory.fromJson({
          'available': true,
          'test_mode': true,
        }).testMode,
        isTrue,
      );
      expect(
        ServiceCountryDetail.fromJson({'test_mode': true}).testMode,
        isTrue,
      );
    });

    test('a charge result says so on itself or on its slip', () {
      IntegrationChargeResult result(Map<String, Object?> extra) =>
          IntegrationChargeResult.fromJson({
            'kind': 'bill',
            'outcome': 'charged',
            ...extra,
          });

      expect(result(const {}).testMode, isFalse);
      expect(result({'test_mode': true}).testMode, isTrue);
      expect(
        result({
          'receipt': {'test_mode': true},
        }).testMode,
        isTrue,
      );
      expect(
        result({
          'receipt': {'test_mode': 'maybe'},
        }).testMode,
        isFalse,
      );
    });

    test('the preview fixtures can say it, and say nothing by default', () {
      expect(servicesPreviewDirectory().testMode, isFalse);
      expect(servicesPreviewDirectory(testMode: true).testMode, isTrue);
      expect(servicesPreviewCountry('ML').testMode, isFalse);
      expect(servicesPreviewCountry('ML', testMode: true).testMode, isTrue);
      expect(
        servicesPreviewMenuServicesJson().every(
          (service) => !service.containsKey('test_mode'),
        ),
        isTrue,
      );
      expect(
        servicesPreviewMenuServicesJson(
          testMode: true,
        ).every((service) => service['test_mode'] == true),
        isTrue,
      );
    });
  });

  group('the provider\'s printed slip', () {
    test('keeps text fields as text and the rows as JSON text', () {
      final printed = providerReceiptFromJson({
        'title': 'شحن مباشر',
        'rows': [
          ['الشبكة', 'أورنج مالي'],
          ['الرقم', '+22370123456'],
        ],
        'pin': '',
        'count': 3,
        'nothing': null,
      });

      expect(printed['title'], 'شحن مباشر');
      expect(printed['count'], '3');
      expect(printed['nothing'], '');
      expect(providerReceiptRows(printed), [
        ['الشبكة', 'أورنج مالي'],
        ['الرقم', '+22370123456'],
      ]);
    });

    test('reads rows back tolerantly', () {
      expect(providerReceiptRows(const {}), isEmpty);
      expect(providerReceiptRows(const {'rows': 'not json'}), isEmpty);
      expect(providerReceiptRows(const {'rows': '{"a":1}'}), isEmpty);
      expect(
        providerReceiptRows({
          'rows': '[["a","b"],["c",""],["lonely"],[],"text",null,[1,2]]',
        }),
        [
          ['a', 'b'],
          ['c'],
          ['lonely'],
          ['text'],
          ['1', '2'],
        ],
      );
    });

    test('anything that is not a map is no slip', () {
      expect(providerReceiptFromJson(null), isEmpty);
      expect(providerReceiptFromJson('x'), isEmpty);
    });
  });
}
