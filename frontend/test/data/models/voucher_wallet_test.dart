import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/integration_provider.dart';
import 'package:pointy_frontend/src/data/models/wallet.dart';

/// «رصيد الكروت»: the wallet's own balance for the company's cards, filled by
/// moving money out of the main wallet, shown only once the owner switched
/// «كروت دفتر» on.
void main() {
  group('the voucher balance', () {
    test('reads the wallet block', () {
      final overview = WalletOverview.fromJson({
        'available': true,
        'balance': '200.00',
        'vouchers': {
          'balance': '122.50',
          'configured': true,
          'test_mode': true,
          'enabled': true,
        },
      });

      final vouchers = overview.vouchers!;
      expect(vouchers.balance, 122.5);
      expect(vouchers.configured, isTrue);
      expect(vouchers.testMode, isTrue);
      expect(vouchers.enabled, isTrue);
      expect(vouchers.acceptsTransfers, isTrue);
    });

    test('switched off by the owner, or not ready, takes no transfer', () {
      final off = VoucherWallet.fromJson(const {
        'balance': '0',
        'configured': true,
        'enabled': false,
      });
      final notReady = VoucherWallet.fromJson(const {
        'balance': '10',
        'configured': false,
        'enabled': true,
      });

      expect(off.acceptsTransfers, isFalse);
      expect(notReady.acceptsTransfers, isFalse);
    });

    test('a relay that sells no cards of its own sends no block', () {
      final overview = WalletOverview.fromJson(const {'available': true});

      expect(overview.vouchers, isNull);
    });

    test('a transfer\'s answer carries both balances', () {
      final allocation = WalletVoucherAllocation.fromJson({
        'balance': '85.00',
        'vouchers': {'balance': '215.00', 'configured': true, 'enabled': true},
        'transfer': {'out': 'e-1', 'in': 'e-2'},
        'replayed': true,
      });

      expect(allocation.balance, 85);
      expect(allocation.vouchers?.balance, 215);
      expect(allocation.replayed, isTrue);
    });

    test('its statement entries are told apart from the main wallet\'s', () {
      expect(WalletAccount.parse('vouchers'), WalletAccount.vouchers);
      expect(WalletAccount.vouchers.key, 'vouchers');
      expect(WalletAccount.parse('sms'), WalletAccount.sms);
      expect(WalletAccount.parse('anything'), WalletAccount.main);
      final entry = WalletEntry.fromJson(const {
        'id': 'v1',
        'account': 'vouchers',
        'kind': 'charge',
        'service': 'vouchers',
        'amount': '-128.00',
        'balance_after': '122.00',
      });
      expect(entry.account, WalletAccount.vouchers);
      expect(entry.amount, -128);
    });

    test('a spend patches it without touching the rest', () {
      final overview = WalletOverview.fromJson({
        'available': true,
        'balance': '100',
        'sms': {'balance': '4.5', 'price': '0.15', 'messages_left': 30},
        'vouchers': {'balance': '0', 'enabled': true},
      });
      final patched = overview.copyWith(
        balance: 50,
        vouchers: const VoucherWallet(balance: 50, enabled: true),
      );

      expect(patched.balance, 50);
      expect(patched.vouchers?.balance, 50);
      expect(patched.sms?.balance, 4.5);
    });
  });

  group('the «كروت دفتر» provider', () {
    test('is read by its backend key and written back the same', () {
      expect(
        integrationProviderKeyFromJson('pointy'),
        IntegrationProviderKey.pointy,
      );
      expect(
        integrationProviderKeyToJson(IntegrationProviderKey.pointy),
        'pointy',
      );
      // An unknown key is still unknown — nothing borrows the new one.
      expect(
        integrationProviderKeyFromJson('pointy2'),
        IntegrationProviderKey.unknown,
      );
    });

    test('asks for no credential, and is on only when switched on', () {
      final off = IntegrationProvider.fromJson(const {
        'key': 'pointy',
        'availability': 'available',
        'capabilities': ['balance', 'vouchers'],
        'fields': <String>[],
        'is_configurable': true,
      });
      final on = IntegrationProvider.fromJson(const {
        'key': 'pointy',
        'availability': 'available',
        'fields': <String>[],
        'is_configurable': true,
        'account': {
          'provider': 'pointy',
          'is_configured': true,
          'is_active': true,
          'balance': '345.50',
        },
      });
      final paused = IntegrationProvider.fromJson(const {
        'key': 'pointy',
        'availability': 'available',
        'fields': <String>[],
        'is_configurable': true,
        'account': {
          'provider': 'pointy',
          'is_configured': true,
          'is_active': false,
        },
      });

      expect(off.needsNoCredentials, isTrue);
      expect(off.sellsVouchers, isTrue);
      expect(off.isEnabled, isFalse);
      expect(on.isEnabled, isTrue);
      expect(on.account?.balance, 345.5);
      expect(paused.isEnabled, isFalse);
    });

    test('a provider with a login still asks for it', () {
      final hdbox = IntegrationProvider.fromJson(const {
        'key': 'hdbox',
        'availability': 'available',
        'fields': ['base_url', 'username', 'password'],
      });

      expect(hdbox.needsNoCredentials, isFalse);
    });

    test('switching it on or off sends only the switch', () {
      expect(const IntegrationCredentialsDraft(isActive: true).toJson(), {
        'is_active': true,
      });
      expect(const IntegrationCredentialsDraft(isActive: false).toJson(), {
        'is_active': false,
      });
    });
  });
}
