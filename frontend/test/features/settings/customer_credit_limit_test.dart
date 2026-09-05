import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/contact.dart';
import 'package:pointy_frontend/src/data/models/customer_activity.dart';
import 'package:pointy_frontend/src/data/models/sale_order.dart';
import 'package:pointy_frontend/src/data/models/shop_settings.dart';
import 'package:pointy_frontend/src/data/repositories/sale_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';

/// The credit (آجل) ceiling, from the client's side of the wire.
///
/// The riskiest part of this feature on the frontend is not the arithmetic —
/// the server owns that — but the *silences*: a settings key that stops being
/// sent, a refusal payload whose keys drift, or an upgrade that reads a missing
/// field as "enabled". Each of those fails without an error, so each gets a
/// test here.
void main() {
  group('shop settings wire format', () {
    ShopSettingsDraft draft({bool enforce = true, double? limit}) {
      return ShopSettingsDraft(
        shopName: 'متجر',
        receiptHeader: '',
        receiptFooter: '',
        enableOnlineInvoices: false,
        requireOpeningCash: true,
        autoPrintReceipts: false,
        allowOverselling: false,
        preventSellingAtLoss: true,
        lowStockThreshold: 5,
        cashierReturnWindowHours: 42,
        enableCashPayments: true,
        enableCardPayments: true,
        enableTransferPayments: true,
        requireCardPaymentReceipt: false,
        trustedCardTerminalIds: const [],
        cardCommissionPercent: 0,
        transferCommissionPercent: 0,
        enforceCustomerCreditLimits: enforce,
        defaultCustomerCreditLimit: limit,
      );
    }

    test('the switch and the amount are both sent on save', () {
      final json = draft(limit: 500).toJson();
      expect(json['enforce_customer_credit_limits'], isTrue);
      expect(json['default_customer_credit_limit'], '500.00');
    });

    test('no amount is sent as null, which the server reads as "no limit"', () {
      expect(draft().toJson()['default_customer_credit_limit'], isNull);
    });

    test('zero survives the round trip — it means "no credit by default"', () {
      expect(draft(limit: 0).toJson()['default_customer_credit_limit'], '0.00');
    });

    test('a backend that has never heard of the feature reads as off', () {
      // The upgrade path: an older server omits both keys entirely, and the
      // client must not invent enforcement out of their absence.
      final settings = ShopSettings.fromJson(const {'shop_name': 'متجر'});
      expect(settings.enforceCustomerCreditLimits, isFalse);
      expect(settings.defaultCustomerCreditLimit, isNull);
      expect(settings.hasDefaultCustomerCreditLimit, isFalse);
    });

    test('a shop default of zero is a limit, not the absence of one', () {
      final settings = ShopSettings.fromJson(const {
        'shop_name': 'متجر',
        'default_customer_credit_limit': '0.00',
      });
      expect(settings.defaultCustomerCreditLimit, 0);
      expect(settings.hasDefaultCustomerCreditLimit, isTrue);
    });
  });

  group('customer record', () {
    test('the policy and both amounts are read from the payload', () {
      final customer = Customer.fromJson(const {
        'id': 7,
        'full_name': 'عميل',
        'credit_limit_policy': 'custom',
        'credit_limit': '750.00',
        'effective_credit_limit': '750.00',
      });
      expect(customer.creditLimitPolicy, CreditLimitPolicy.custom);
      expect(customer.creditLimit, 750);
      expect(customer.effectiveCreditLimit, 750);
    });

    test('an unknown policy falls back to following the shop', () {
      final customer = Customer.fromJson(const {
        'id': 7,
        'full_name': 'عميل',
        'credit_limit_policy': 'something_new',
      });
      expect(customer.creditLimitPolicy, CreditLimitPolicy.shopDefault);
    });

    test('an unlimited customer reports no effective ceiling', () {
      final customer = Customer.fromJson(const {
        'id': 7,
        'full_name': 'عميل',
        'credit_limit_policy': 'unlimited',
        'effective_credit_limit': null,
      });
      expect(customer.creditLimitPolicy, CreditLimitPolicy.unlimited);
      expect(customer.effectiveCreditLimit, isNull);
    });
  });

  group('sales summary', () {
    test('the ceiling and the head-room come through', () {
      final summary = CustomerSalesSummary.fromJson(const {
        'customer': 3,
        'outstanding_balance': '40.00',
        'credit_limit': '100.00',
        'available_credit': '60.00',
      });
      expect(summary.outstandingBalance, 40);
      expect(summary.creditLimit, 100);
      expect(summary.availableCredit, 60);
    });

    test('no limit is null, not zero — zero would read as "nothing left"', () {
      final summary = CustomerSalesSummary.fromJson(const {
        'customer': 3,
        'outstanding_balance': '40.00',
        'credit_limit': null,
        'available_credit': null,
      });
      expect(summary.creditLimit, isNull);
      expect(summary.availableCredit, isNull);
    });
  });

  group('checkout refusal', () {
    SaleRepository repositoryReturning(String body) {
      final client = MockClient((request) async {
        return http.Response(
          body,
          400,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });
      return SaleRepository(PosApiService(client: client));
    }

    const draft = SaleCheckoutDraft(
      lines: [SaleCheckoutLineDraft(variantId: 1, quantity: 1)],
      payments: [],
      saleType: SaleType.credit,
      customerId: 4,
    );

    test('the server refusal becomes a typed exception carrying its numbers',
        () async {
      final repository = repositoryReturning(
        jsonEncode({
          'code': 'credit_limit_exceeded',
          'detail': 'over the limit',
          'credit': {
            'limit': '10.00',
            'outstanding': '7.00',
            'available': '3.00',
            'new_debt': '7.00',
            'projected': '14.00',
          },
        }),
      );

      final result = await repository.checkout(draft);

      expect(result, isA<Error<SaleOrder>>());
      final exception = (result as Error<SaleOrder>).exception;
      expect(exception, isA<SaleCheckoutCreditLimitException>());
      final credit = exception as SaleCheckoutCreditLimitException;
      expect(credit.limit, 10);
      expect(credit.outstanding, 7);
      expect(credit.available, 3);
      expect(credit.newDebt, 7);
      expect(credit.projected, 14);
    });

    test('an ordinary 400 is not mistaken for a credit refusal', () async {
      final repository = repositoryReturning(
        jsonEncode({'detail': 'something else entirely'}),
      );

      final result = await repository.checkout(draft);

      expect(result, isA<Error<SaleOrder>>());
      expect(
        (result as Error<SaleOrder>).exception,
        isNot(isA<SaleCheckoutCreditLimitException>()),
      );
    });
  });
}
