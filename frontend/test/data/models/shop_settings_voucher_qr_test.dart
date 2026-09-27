import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/shop_settings.dart';

/// The voucher QR switch: one shop-wide setting, on until an owner turns it
/// off, and offered only to a shop that sells a provider's cards.
void main() {
  ShopSettings settings(Map<String, Object?> json) =>
      ShopSettings.fromJson({'shop_name': 'متجر', ...json});

  test('a shop prints voucher QR codes unless it says otherwise', () {
    // Including a backend that predates the setting.
    expect(settings(const {}).printVoucherQrCodes, isTrue);
    expect(
      settings(const {'print_voucher_qr_codes': true}).printVoucherQrCodes,
      isTrue,
    );
    expect(
      settings(const {'print_voucher_qr_codes': false}).printVoucherQrCodes,
      isFalse,
    );
  });

  test('a save sends the switch as the form left it', () {
    final draft = ShopSettingsDraft.fromSettings(
      settings(const {'print_voucher_qr_codes': false}),
    );
    expect(draft.toJson()['print_voucher_qr_codes'], isFalse);
    expect(
      draft
          .copyWith(printVoucherQrCodes: true)
          .toJson()['print_voucher_qr_codes'],
      isTrue,
    );
  });

  group('who is offered the switch', () {
    test('a shop selling Qareeb cards', () {
      final shop = settings(const {
        'connected_integrations': ['hdbox', 'qareeb'],
        'lookup_integrations': ['hdbox', 'lnet'],
      });
      expect(shop.sellsProviderCards, isTrue);
    });

    test('not a shop that only tops up subscriptions', () {
      final shop = settings(const {
        'connected_integrations': ['hdbox', 'lnet'],
        'lookup_integrations': ['hdbox', 'lnet'],
      });
      expect(shop.sellsProviderCards, isFalse);
    });

    test('not a shop with no provider at all', () {
      expect(settings(const {}).sellsProviderCards, isFalse);
    });

    test('not against a backend too old to say which providers look up', () {
      // Such a backend lists only lookup providers, and has no card shelf.
      final shop = settings(const {
        'connected_integrations': ['hdbox'],
      });
      expect(shop.sellsProviderCards, isFalse);
    });
  });
}
