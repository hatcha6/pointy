import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/integration_card.dart';
import 'package:pointy_frontend/src/data/models/provider_receipt_fields.dart';
import 'package:pointy_frontend/src/data/models/sale_order.dart';
import 'package:pointy_frontend/src/data/models/service_country_detail.dart';
import 'package:pointy_frontend/src/data/models/service_kinds.dart';
import 'package:pointy_frontend/src/data/models/service_quote.dart';
import 'package:pointy_frontend/src/data/models/services_directory.dart';
import 'package:pointy_frontend/src/data/models/voucher_menu.dart';
import 'package:pointy_frontend/src/data/services/receipt_provider_slips.dart';

/// The shop backend's REAL answers for «كروت دفتر»' direct services — saved
/// from an end-to-end run (a real relay on the sandbox supplier, a real shop
/// backend, real till requests; phone numbers masked) — parsed with the till's
/// own models.
///
/// This is the contract between the two halves: when the backend changes a
/// shape, or the models change what they read, this is the test that says so.
/// The fixtures live in `test/fixtures/services/`; replace one with a fresh
/// capture to renew it.
void main() {
  final latin = RegExp('[A-Za-z]');

  Map<String, Object?> sample(String name) {
    final text = File('test/fixtures/services/$name.json').readAsStringSync();
    return (jsonDecode(text) as Map).cast<String, Object?>();
  }

  List<IntegrationChargeResult> charged(String name) => [
    for (final row in sample(name)['results']! as List)
      IntegrationChargeResult.fromJson((row as Map).cast<String, Object?>()),
  ];

  group('the menu', () {
    test('lists the services as cards, with the product each one sells', () {
      final menu = VoucherMenu.fromJson(sample('menu_cashier'));

      expect(menu.hasServices, isTrue);
      expect(menu.airtimeService!.isSellable, isTrue);
      expect(menu.airtimeService!.variantId, 1);
      expect(menu.airtimeService!.countries, 124);
      expect(menu.billServices.map((service) => service.billType), [
        BillType.electricity,
        BillType.water,
        BillType.tv,
      ]);
      expect(
        menu.billServices.every((service) => service.variantId == 2),
        isTrue,
      );
    });

    test('sells the services beside the cards when it has both', () {
      final menu = VoucherMenu.fromJson(
        sample('menu_cards_and_services_cashier'),
      );

      expect(menu.hasBrands, isTrue);
      expect(menu.hasServices, isTrue);
      expect(menu.balance, 219.84);
    });

    test('a manager reads the same menu', () {
      final menu = VoucherMenu.fromJson(sample('menu_manager'));

      expect(menu.hasServices, isTrue);
    });
  });

  group('the directory', () {
    test(
      'has every country, in Arabic, with a calling code and a currency',
      () {
        final directory = ServicesDirectory.fromJson(
          sample('services_directory'),
        );

        expect(directory.available, isTrue);
        expect(directory.version, isNotEmpty);
        expect(directory.countries, hasLength(124));
        expect(directory.airtimeCountries, hasLength(124));
        for (final country in directory.countries) {
          expect(country.name, isNotEmpty, reason: country.code);
          expect(latin.hasMatch(country.name), isFalse, reason: country.code);
          expect(country.dial, isNotEmpty, reason: country.code);
          expect(country.currencyName, isNotEmpty, reason: country.code);
          expect(
            latin.hasMatch(country.currencyName),
            isFalse,
            reason: country.code,
          );
        }
        final mali = directory.country('ML')!;
        expect(mali.dial, ['223']);
        expect(mali.airtimeCount, 3);
        expect(mali.billCount, 3);
        expect(directory.popular.take(3), ['NE', 'ML', 'NG']);
        expect(directory.unsupported, isNotEmpty);
      },
    );

    test(
      'says which countries have each type of bill, and how many providers',
      () {
        final directory = ServicesDirectory.fromJson(
          sample('services_directory'),
        );

        expect(
          directory
              .billCountries(BillType.electricity)
              .map((c) => c.code)
              .toSet(),
          containsAll(['ML', 'NG', 'SN']),
        );
        expect(directory.billCountries(BillType.water).map((c) => c.code), [
          'SN',
        ]);
        expect(
          directory.billType(BillType.electricity)!.billers,
          greaterThan(10),
        );
      },
    );

    test('carries the voucher balance when it is asked for', () {
      final directory = ServicesDirectory.fromJson(
        sample('services_directory_with_balance'),
      );

      expect(directory.available, isTrue);
      expect(directory.balance, 72.66);
    });
  });

  group('a country', () {
    ServiceCountryDetail country(String name) =>
        ServiceCountryDetail.fromJson(sample(name));

    test('Mali has its networks priced for the customer, and Canal+ plans', () {
      final mali = country('services_country_ML_cashier');

      expect(mali.available, isTrue);
      expect(mali.country.code, 'ML');
      expect(mali.operators, isNotEmpty);
      for (final operator in mali.operators) {
        expect(latin.hasMatch(operator.name), isFalse, reason: operator.name);
        for (final amount in operator.amounts) {
          expect(amount.price, isNotNull, reason: operator.name);
          expect(amount.price, greaterThan(0));
          expect(
            amount.cost,
            isNull,
            reason: 'a cashier is never sent the cost',
          );
        }
      }
      final orange = mali.operator(289)!;
      expect(orange.mode, ServiceAmountMode.range);
      expect(orange.min, 1967);
      expect(orange.max, 32800);
      expect(orange.amountCurrency, 'XOF');
      final canal = mali.biller(27)!;
      expect(canal.isFixed, isTrue);
      expect(canal.plans, isNotEmpty);
      expect(latin.hasMatch(canal.plans.first.label), isFalse);
      expect(canal.plans.first.price, greaterThan(0));
    });

    test('a name the relay has no Arabic for yet is shown, isolated', () {
      // The relay falls back to the supplier's Latin spelling for a biller
      // missing from its Arabic table: it must still read as one name, left
      // to right, inside the Arabic line.
      final mali = country('services_country_ML_cashier');

      final startimes = mali.biller(28)!;
      expect(latin.hasMatch(startimes.name), isTrue);
      expect(startimes.label, startsWith('\u{2066}'));
      expect(startimes.label, endsWith('\u{2069}'));
    });

    test('a manager is sent the cost as well', () {
      final mali = country('services_country_ML_manager');

      final amounts = [
        for (final operator in mali.operators) ...operator.amounts,
      ];
      expect(amounts.every((amount) => amount.cost != null), isTrue);
    });

    test('Senegal has its water company, which asks for an invoice', () {
      final senegal = country('services_country_SN_cashier');

      final water = senegal.billersOf(BillType.water).single;
      expect(water.requiresInvoice, isTrue);
      expect(water.isRange, isTrue);
      expect(latin.hasMatch(water.name), isFalse);
    });

    test('Nigeria has ten electricity companies, prepaid and postpaid', () {
      final nigeria = country('services_country_NG_cashier');

      final electricity = nigeria.billersOf(BillType.electricity);
      expect(electricity.where((biller) => biller.isPrepaid), isNotEmpty);
      expect(electricity.where((biller) => biller.isPostpaid), isNotEmpty);
    });

    test('Egypt sells fixed denominations', () {
      final egypt = country('services_country_EG_cashier');

      expect(egypt.operators.any((operator) => operator.isFixed), isTrue);
    });
  });

  group('detecting a network', () {
    test('finds it, with the number as the relay normalised it', () {
      final detection = OperatorDetection.fromJson(sample('detect_ok_ML'));

      expect(detection.detected, isTrue);
      expect(detection.operator!.id, 289);
      expect(detection.operator!.name, 'أورنج مالي');
      expect(detection.phone!.country, 'ML');
      expect(detection.phone!.e164, startsWith('+223'));
      expect(detection.operator!.amounts, isNotEmpty);
    });

    test('says a number is not a number', () {
      final detection = OperatorDetection.fromJson(
        sample('detect_invalid_phone_ML'),
      );

      expect(detection.detected, isFalse);
      expect(detection.reason, ServiceRefusalCode.invalidPhone);
    });

    test('works in Nigeria too', () {
      final detection = OperatorDetection.fromJson(sample('detect_NG'));

      expect(detection.detected, isTrue);
      expect(detection.phone!.country, 'NG');
    });
  });

  group('pricing', () {
    ServiceQuote quoted(String name) {
      final outcome = ServiceQuoteOutcome.fromJson(sample(name));
      expect(outcome.isQuoted, isTrue, reason: name);
      return outcome.quote!;
    }

    test('an airtime quote is sealed, priced, and names the number', () {
      final quote = quoted('quote_airtime_5000_cashier');

      expect(quote.kind, ServiceKind.airtime);
      expect(quote.optionCode, 'air:289:5000:XOF');
      expect(quote.price, 97);
      expect(quote.receiveAmount, '5000');
      expect(quote.receiveCurrency, 'XOF');
      expect(quote.subscriberRef, startsWith('+223'));
      expect(quote.serviceVariantId, 1);
      expect(quote.isUsable, isTrue);
      expect(quote.cost, isNull);
      expect(quote.exceedsFloat, isFalse);
    });

    test('a manager is sent the cost, a cashier is not', () {
      expect(quoted('quote_airtime_5000_manager').cost, isNotNull);
      expect(quoted('quote_airtime_5000_cashier').cost, isNull);
    });

    test('the voucher balance not covering it is said on the quote', () {
      expect(quoted('quote_airtime_exceeds_float').exceedsFloat, isTrue);
    });

    test('every kind of quote parses: approximate, fixed, range, bills', () {
      expect(quoted('airtime_morocco_approx_quote').approximate, isTrue);
      expect(quoted('airtime_egypt_fixed_quote').price, greaterThan(0));
      expect(quoted('airtime_tunisia_range_quote').price, greaterThan(0));
      expect(quoted('airtime_local_mode_quote').price, greaterThan(0));
      for (final name in [
        'bill_woyofal_quote',
        'bill_canalplus_quote',
        'bill_water_invoice_quote',
        'bill_nigeria_refunded_quote',
      ]) {
        final quote = quoted(name);
        expect(quote.kind, ServiceKind.bill, reason: name);
        expect(quote.optionCode, startsWith('bill:'), reason: name);
        expect(quote.price, greaterThan(0), reason: name);
      }
    });

    test('a refusal is an answer, with its limits', () {
      final high = ServiceQuoteOutcome.fromJson(
        sample('quote_refusal_out_of_range_high'),
      ).refusal!;
      final low = ServiceQuoteOutcome.fromJson(
        sample('quote_refusal_out_of_range_low'),
      ).refusal!;

      expect(high.errorCode, ServiceRefusalCode.amountOutOfRange);
      expect(high.min, isNotNull);
      expect(high.max, isNotNull);
      expect(low.errorCode, ServiceRefusalCode.amountOutOfRange);
    });

    test('a shop whose prices are not set yet refuses with its own code', () {
      final refusal = ServiceQuoteOutcome.fromJson(
        sample('quote_rate_unset'),
      ).refusal!;

      expect(refusal.errorCode, ServiceRefusalCode.rateUnset);
    });
  });

  group('recent recipients', () {
    test('come newest first with everything one tap needs', () {
      final rows = [
        for (final row in sample('services_recent_airtime')['recent']! as List)
          RecentRecipient.fromJson((row as Map).cast<String, Object?>()),
      ];

      expect(rows, isNotEmpty);
      for (final row in rows) {
        expect(row.phone, startsWith('+'));
        expect(row.country, isNotEmpty);
        expect(row.operatorId, greaterThan(0));
        expect(row.operatorName, isNotEmpty);
        expect(row.amount, isNotEmpty);
        expect(row.currency, isNotEmpty);
        expect(row.at, isNotNull);
      }
    });
  });

  group('flags', () {
    test('arrive keyed by country code', () {
      // The saved sample keeps the shape; its picture was cut out.
      final flags = sample('services_flags_US')['flags']! as Map;

      expect(flags.keys, ['US']);
      expect(flags['US'], isA<String>());
    });
  });

  group('performing a sale\'s services', () {
    test('an airtime top-up is charged, with the slip the server wrote', () {
      final result = charged('charge_response_airtime').single;

      expect(result.isCharged, isTrue);
      expect(result.isAirtime, isTrue);
      expect(result.isDirectService, isTrue);
      expect(result.status, 'confirmed');
      expect(result.providerReference, isNotEmpty);
      expect(
        result.balanceAfter,
        506.37,
        reason: 'money here is a JSON number',
      );
      final rows = providerReceiptRows(result.receipt);
      expect(rows.map((row) => row.first), [
        'الشبكة',
        'الرقم',
        'المبلغ المرسل',
        'رقم العملية',
      ]);
      expect(result.receipt['pin'], isEmpty);
      expect(result.receipt['title'], 'شحن مباشر');
    });

    test('a bill is charged with its token as the slip\'s pin', () {
      for (final name in [
        'bill_woyofal_charge',
        'bill_canalplus_charge',
        'bill_water_invoice_charge',
      ]) {
        final result = charged(name).single;

        expect(result.isBill, isTrue, reason: name);
        expect(result.isCharged, isTrue, reason: name);
        expect(providerReceiptRows(result.receipt), isNotEmpty, reason: name);
        expect(result.receipt['pin_label'], isNotEmpty, reason: name);
      }
    });

    test('every refusal says why, in a code the till words in Arabic', () {
      expect(
        charged('airtime_insufficient_charge').single.errorCode,
        'insufficient_float',
      );
      expect(charged('charge_relay_down').single.errorCode, 'unreachable');
      expect(charged('charge_switched_off').single.isRefused, isTrue);
      final changed = charged('charge_price_changed').single;
      expect(changed.isRefused, isTrue);
      expect(changed.errorCode, anyOf('price_changed', 'provider_error'));
      expect(changed.errorDetail, contains('price_changed'));
      for (final name in [
        'charge_relay_starting',
        'charge_relay_unavailable_air',
        'charge_relay_unavailable_bill',
        'bill_held_charge',
        'bill_nigeria_refunded_charge',
        'bill_token_testmode_charge',
        'airtime_morocco_approx_charge',
      ]) {
        final results = charged(name);
        expect(results, isNotEmpty, reason: name);
        expect(results.single.outcome, isNotEmpty, reason: name);
      }
    });

    test('a card sold in the same sale is still a card', () {
      final result = charged('charge_response_card').single;

      expect(result.isVoucher, isTrue);
      expect(result.isDirectService, isFalse);
    });

    test('money in a charge answer is a number, and is read as one', () {
      final raw = sample('charge_response_airtime');

      expect(raw['balance'], isA<num>());
      expect((raw['results']! as List).first['balance_after'], isA<num>());
      expect(charged('charge_response_airtime').single.balanceAfter, isNotNull);
      expect(charged('charge_price_changed').single.balanceAfter, isNull);
    });
  });

  // The relay runs its sandbox supplier — fake money — and the backend then
  // says `test_mode: true` at the top of the menu and on each of its services,
  // in the directory and in every country answer. These three samples are the
  // real ones above with that key added where the contract puts it (the end to
  // end run was on the live supplier); the real samples themselves say nothing,
  // and nothing is not test mode.
  group('test mode', () {
    test('the menu says so, at the top and on each service', () {
      final menu = VoucherMenu.fromJson(sample('menu_testmode'));

      expect(menu.testMode, isTrue);
      expect(menu.isTestMode, isTrue);
      expect(menu.services, isNotEmpty);
      expect(menu.services.every((service) => service.testMode), isTrue);
      expect(menu.hasServices, isTrue, reason: 'still sold, only marked');
      expect(menu.airtimeService!.testMode, isTrue);
    });

    test('a service alone saying so is enough to mark the menu', () {
      final json = sample('menu_cards_and_services_cashier');
      (json['services']! as List<Object?>).whereType<Map>().first['test_mode'] =
          true;

      final menu = VoucherMenu.fromJson(json);

      expect(menu.testMode, isFalse);
      expect(menu.isTestMode, isTrue);
    });

    test('the directory says so', () {
      final directory = ServicesDirectory.fromJson(
        sample('services_directory_testmode'),
      );

      expect(directory.testMode, isTrue);
      expect(directory.countries, hasLength(124), reason: 'nothing else moved');
    });

    test('a country says so', () {
      final detail = ServiceCountryDetail.fromJson(
        sample('services_country_ML_testmode'),
      );

      expect(detail.testMode, isTrue);
      expect(detail.operators, hasLength(3));
    });

    test('the real answers say nothing, which is not test mode', () {
      expect(
        VoucherMenu.fromJson(
          sample('menu_cards_and_services_cashier'),
        ).isTestMode,
        isFalse,
      );
      expect(VoucherMenu.fromJson(sample('menu_cashier')).isTestMode, isFalse);
      expect(
        ServicesDirectory.fromJson(sample('services_directory')).testMode,
        isFalse,
      );
      expect(
        ServiceCountryDetail.fromJson(
          sample('services_country_ML_cashier'),
        ).testMode,
        isFalse,
      );
    });

    test('the test supplier\'s token is told apart on its slip, in words', () {
      final row = charged('bill_token_testmode_charge').single;

      expect(row.isCharged, isTrue);
      expect(row.receipt['pin'], startsWith('TEST-'));
      expect(row.receipt['notice'], startsWith('عملية تجريبية'));
    });
  });

  group('the sale and its receipts', () {
    test('the checkout answer carries the line, not yet performed', () {
      final order = SaleOrder.fromJson(sample('checkout_response_airtime'));

      final line = order.lines.single;
      expect(line.integration!.isDirectService, isTrue);
      expect(line.integration!.kind, 'airtime');
      expect(line.integration!.status, 'pending');
      expect(line.integration!.subscriberRef, startsWith('+223'));
      expect(line.unitPrice, 97);
    });

    test(
      'the thermal receipt prints the server\'s slip for an airtime line',
      () {
        final payload = sample('receipt_thermal_airtime_full');
        final order = (payload['order']! as Map).cast<String, Object?>();

        final slips = receiptProviderSlipsFromPayload(
          order['lines'],
          printQrCodes: true,
        );

        expect(slips, hasLength(1));
        expect(slips.single.title, 'شحن مباشر');
        expect(slips.single.rows.join('\n'), contains('الشبكة'));
        expect(slips.single.notice, contains('لا يمكن استرداده'));
      },
    );

    test('and for a bill line, with the meter number', () {
      final payload = sample('receipt_thermal_bill_woyofal_full');
      final order = (payload['order']! as Map).cast<String, Object?>();

      final slips = receiptProviderSlipsFromPayload(
        order['lines'],
        printQrCodes: true,
      );

      expect(slips, hasLength(1));
      expect(slips.single.rows.join('\n'), contains('رقم العدّاد'));
    });

    test('the document routes read the same rows', () {
      for (final name in [
        'receipt_document_airtime_line',
        'receipt_document_bill_woyofal_line',
        'receipt_document_bill_water_invoice_line',
      ]) {
        final integration = SaleLineIntegration.fromJson(sample(name));

        expect(integration.isDirectService, isTrue, reason: name);
        expect(integration.isConfirmed, isTrue, reason: name);
        expect(
          providerReceiptRows(integration.receipt),
          isNotEmpty,
          reason: name,
        );
      }
    });

    test('a test-mode token still reads as a slip', () {
      final printed = providerReceiptFromJson(
        sample('receipt_token_testmode_thermal'),
      );

      expect(printed['pin'], isNotEmpty);
      expect(providerReceiptRows(printed), isNotEmpty);
    });

    test('the thermal lines of the other bills read too', () {
      for (final name in [
        'receipt_thermal_airtime_line',
        'receipt_thermal_bill_canalplus_line',
        'receipt_thermal_bill_water_invoice_line',
      ]) {
        final raw = sample(name);

        final printed = providerReceiptFromJson(raw['printed']);
        expect(providerReceiptRows(printed), isNotEmpty, reason: name);
        expect(printed['title'], isNotEmpty, reason: name);
      }
    });
  });
}
