import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/shop_settings.dart';
import 'package:pointy_frontend/src/features/settings/views/operations_settings_page.dart';

/// A shop settings draft goes out as the **whole payload** — `toJson()` emits
/// every key and the backend applies every key it receives. So a page that
/// assembles a draft from its own handful of controls silently resets every
/// setting it forgot, and a `copyWith` that drops a field does the same. Both
/// happened: toggling kitchen operations reset the credit limits, and saving
/// the main settings form turned off automatic kitchen-ticket printing.
///
/// The fix is that every screen now starts from
/// [ShopSettingsDraft.fromSettings]. These tests hold that line, and the first
/// one is a ratchet: adding a field to the wire without teaching `fromSettings`
/// about it fails here rather than in a shop.
void main() {
  // Two settings objects that differ in *every* field that goes on the wire.
  // Everything below is driven off the pair, so a field added to one and not
  // carried through the copy shows up as a key with the same value on both.
  const quietJson = <String, Object?>{
    'shop_name': 'متجر الهدوء',
    'receipt_header': '',
    'receipt_footer': '',
    'enable_online_invoices': false,
    'require_opening_cash': false,
    'auto_print_receipts': false,
    'auto_print_kitchen_tickets': false,
    'allow_overselling': false,
    'prevent_selling_at_loss': false,
    'low_stock_threshold': 3,
    'cashier_return_window_hours': 12,
    'enable_cash_payments': true,
    'enable_card_payments': false,
    'enable_transfer_payments': false,
    'require_card_payment_receipt': false,
    'trusted_card_terminal_ids': <String>[],
    'card_commission_percent': '0.00',
    'transfer_commission_percent': '0.00',
    'require_customer_for_credit': false,
    'allow_cashier_customer_access': false,
    'warn_low_stock_before_sale': false,
    'enable_repair_operations': false,
    'enable_production_operations': false,
    'enable_kitchen_operations': false,
    'enable_job_tracking': false,
    'pos_cash_purchase_limit': null,
    'enforce_customer_credit_limits': false,
    'default_customer_credit_limit': null,
    'default_payment_terms_days': 0,
    'default_payment_terms_basis': 'net_days',
    'enable_purchase_suggestions': false,
    'enable_surveillance': false,
    'surveillance_pre_roll_seconds': 20,
    'surveillance_post_roll_seconds': 40,
    'inventory_valuation_method': 'moving_average',
  };

  const busyJson = <String, Object?>{
    'shop_name': 'متجر الزحام',
    'receipt_header': 'أهلاً',
    'receipt_footer': 'شكراً',
    'enable_online_invoices': true,
    'require_opening_cash': true,
    'auto_print_receipts': true,
    'auto_print_kitchen_tickets': true,
    'allow_overselling': true,
    'prevent_selling_at_loss': true,
    'low_stock_threshold': 9,
    'cashier_return_window_hours': 48,
    'enable_cash_payments': false,
    'enable_card_payments': true,
    'enable_transfer_payments': true,
    'require_card_payment_receipt': true,
    'trusted_card_terminal_ids': <String>['TERM-1'],
    'card_commission_percent': '2.50',
    'transfer_commission_percent': '1.25',
    'require_customer_for_credit': true,
    'allow_cashier_customer_access': true,
    'warn_low_stock_before_sale': true,
    'enable_repair_operations': true,
    'enable_production_operations': true,
    'enable_kitchen_operations': true,
    'enable_job_tracking': true,
    'pos_cash_purchase_limit': '250.00',
    'enforce_customer_credit_limits': true,
    'default_customer_credit_limit': '800.00',
    'default_payment_terms_days': 30,
    'default_payment_terms_basis': 'end_of_month',
    'enable_purchase_suggestions': true,
    'enable_surveillance': true,
    'surveillance_pre_roll_seconds': 35,
    'surveillance_post_roll_seconds': 75,
    'inventory_valuation_method': 'fifo',
  };

  final quiet = ShopSettings.fromJson(quietJson);
  final busy = ShopSettings.fromJson(busyJson);

  // `fromSettings` never sets it and `toJson` only emits it when true, so it is
  // legitimately absent from both payloads.
  const notCarried = {'valuation_method_change_acknowledged'};

  /// Every wire key on which two payloads agree — i.e. every field that failed
  /// to travel.
  Set<String> keysThatDidNotTravel(
    Map<String, Object?> a,
    Map<String, Object?> b,
  ) {
    return {
      for (final key in {...a.keys, ...b.keys})
        if (!notCarried.contains(key) && '${a[key]}' == '${b[key]}') key,
    };
  }

  group('ShopSettingsDraft.fromSettings', () {
    test('carries every field that goes on the wire', () {
      // The ratchet: a new setting that reaches `toJson` without reaching
      // `fromSettings` reads as its constructor default on both sides, so it
      // lands in this set and names itself.
      expect(
        keysThatDidNotTravel(
          ShopSettingsDraft.fromSettings(quiet).toJson(),
          ShopSettingsDraft.fromSettings(busy).toJson(),
        ),
        isEmpty,
        reason:
            'These settings did not survive fromSettings, so any screen that '
            'saves through it would reset them.',
      );
    });

    test('a payload built from settings matches those settings', () {
      final json = ShopSettingsDraft.fromSettings(busy).toJson();
      expect(json['auto_print_kitchen_tickets'], isTrue);
      expect(json['enforce_customer_credit_limits'], isTrue);
      expect(json['default_customer_credit_limit'], '800.00');
      expect(json['pos_cash_purchase_limit'], '250.00');
      expect(json['enable_surveillance'], isTrue);
      expect(json['surveillance_pre_roll_seconds'], 35);
      expect(json['inventory_valuation_method'], 'fifo');
    });
  });

  group('ShopSettingsDraft.copyWith', () {
    test('changes nothing when nothing is named', () {
      final draft = ShopSettingsDraft.fromSettings(busy);
      expect(draft.copyWith().toJson(), equals(draft.toJson()));
    });

    test('carries every unnamed field while replacing the named one', () {
      final before = ShopSettingsDraft.fromSettings(busy);
      final after = before.copyWith(enableKitchenOperations: false);
      expect(after.enableKitchenOperations, isFalse);

      final beforeJson = before.toJson()..remove('enable_kitchen_operations');
      final afterJson = after.toJson()..remove('enable_kitchen_operations');
      expect(afterJson, equals(beforeJson));
    });

    test('keeps a money field that is not named', () {
      // `null` means "no limit" for these two, so it cannot also mean "leave it
      // alone" — omitting them has to be distinguishable from clearing them.
      final draft = ShopSettingsDraft.fromSettings(busy).copyWith();
      expect(draft.posCashPurchaseLimit, 250);
      expect(draft.defaultCustomerCreditLimit, 800);
    });

    test('clears a money field when it is explicitly named null', () {
      final draft = ShopSettingsDraft.fromSettings(
        busy,
      ).copyWith(posCashPurchaseLimit: null, defaultCustomerCreditLimit: null);
      expect(draft.posCashPurchaseLimit, isNull);
      expect(draft.defaultCustomerCreditLimit, isNull);
      expect(draft.toJson()['pos_cash_purchase_limit'], isNull);
    });

    test(
      'the valuation acknowledgement rides along without disturbing a field',
      () {
        final before = ShopSettingsDraft.fromSettings(busy);
        final after = before.acknowledgingValuationMethodChange();
        expect(after.toJson()['valuation_method_change_acknowledged'], isTrue);

        final afterJson = after.toJson()
          ..remove('valuation_method_change_acknowledged');
        expect(afterJson, equals(before.toJson()));
      },
    );
  });

  group('the operations sub-page', () {
    test('turning kitchen mode on leaves every other setting alone', () {
      // The reported bug: this page shows five switches, so the draft it built
      // sent the constructor default for the other twenty-eight fields. A shop
      // that enabled kitchen mode lost its credit limits, its purchase
      // suggestions, its valuation method and its cameras.
      final before = ShopSettingsDraft.fromSettings(busy).toJson();
      final after = operationsSettingsDraft(
        busy,
        enableKitchenOperations: false,
      ).toJson();

      expect(after['enable_kitchen_operations'], isFalse);
      before.remove('enable_kitchen_operations');
      after.remove('enable_kitchen_operations');
      expect(after, equals(before));
    });

    test('the kitchen-ticket switch moves on its own too', () {
      final after = operationsSettingsDraft(
        quiet,
        autoPrintKitchenTickets: true,
      ).toJson();
      expect(after['auto_print_kitchen_tickets'], isTrue);
      expect(after['enable_kitchen_operations'], isFalse);
      expect(after['enable_purchase_suggestions'], isFalse);
    });

    test('a switch left untouched keeps the shop\'s stored value', () {
      final after = operationsSettingsDraft(busy).toJson();
      expect(after, equals(ShopSettingsDraft.fromSettings(busy).toJson()));
    });
  });

  test('no screen builds a settings draft from scratch', () {
    // The rule, enforced rather than remembered: outside the model itself there
    // is no safe way to hand-write all thirty-odd fields, and the two screens
    // that tried both got it wrong. `fromSettings(...).copyWith(...)` is the
    // only construction a screen may use, so a new field is carried by default
    // instead of being reset by whoever forgets it.
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) {
        continue;
      }
      // The model is where the field list legitimately lives.
      if (entity.path.endsWith('models/shop_settings.dart')) {
        continue;
      }
      if (entity.readAsStringSync().contains('ShopSettingsDraft(')) {
        offenders.add(entity.path);
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'Use ShopSettingsDraft.fromSettings(stored).copyWith(...). A draft '
          'is sent as the whole payload, so every field left out of a '
          'hand-built one silently resets on the shop.',
    );
  });
}
