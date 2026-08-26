import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/shop_settings.dart';
import 'package:pointy_frontend/src/data/repositories/shop_settings_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/settings/view_models/shop_settings_view_model.dart';
import 'package:pointy_frontend/src/data/models/system_backup.dart';

/// Changing how stock is costed is refused by the backend until the user has
/// confirmed it. These pin the client half of that handshake: the refusal has
/// to read as a question (show the dialog), not as a failure (show the red
/// banner), and the acknowledgement must never leak into an ordinary save.
void main() {
  ShopSettingsDraft draft({
    InventoryValuationMethod method = InventoryValuationMethod.fifo,
  }) {
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
      inventoryValuationMethod: method,
    );
  }

  group('wire format', () {
    test('the method is sent on every save', () {
      final json = draft().toJson();
      expect(json['inventory_valuation_method'], 'fifo');
    });

    test('an ordinary save carries no acknowledgement', () {
      expect(
        draft().toJson().containsKey('valuation_method_change_acknowledged'),
        isFalse,
      );
    });

    test('acknowledging adds the flag and keeps the rest of the draft', () {
      final acknowledged = draft().acknowledgingValuationMethodChange();
      final json = acknowledged.toJson();
      expect(json['valuation_method_change_acknowledged'], isTrue);
      expect(json['inventory_valuation_method'], 'fifo');
      expect(json['shop_name'], 'متجر');
      expect(json['low_stock_threshold'], 5);
    });

    test('settings default to moving average when the field is absent', () {
      final settings = ShopSettings.fromJson(const {'shop_name': 'متجر'});
      expect(
        settings.inventoryValuationMethod,
        InventoryValuationMethod.movingAverage,
      );
    });

    test('an unrecognised method falls back instead of throwing', () {
      final settings = ShopSettings.fromJson(const {
        'shop_name': 'متجر',
        'inventory_valuation_method': 'something_new',
      });
      expect(
        settings.inventoryValuationMethod,
        InventoryValuationMethod.movingAverage,
      );
    });

    test('a known method is read back', () {
      final settings = ShopSettings.fromJson(const {
        'shop_name': 'متجر',
        'inventory_valuation_method': 'lifo',
      });
      expect(settings.inventoryValuationMethod, InventoryValuationMethod.lifo);
    });
  });

  group('the guard', () {
    test('a guard response asks for confirmation, it does not fail', () async {
      final repo = _FakeRepo(
        result: Error(
          PosApiException(
            message: 'Shop settings update failed with status 400',
            statusCode: 400,
            responseBody: jsonEncode({
              'inventory_valuation_method': ['Confirm the change to continue.'],
              'code': ['valuation_method_change_requires_acknowledgement'],
              'current_method': ['moving_average'],
              'requested_method': ['fifo'],
            }),
          ),
        ),
      );
      final viewModel = ShopSettingsViewModel(repo);

      final saved = await viewModel.updateSettings(draft());

      expect(saved, isFalse);
      expect(viewModel.needsValuationMethodConfirmation, isTrue);
      // The red save-error banner would misread as a failure underneath the
      // confirmation dialog.
      expect(viewModel.hasSaveError, isFalse);
    });

    test('an ordinary failure is still a failure', () async {
      final repo = _FakeRepo(result: Error(Exception('network down')));
      final viewModel = ShopSettingsViewModel(repo);

      final saved = await viewModel.updateSettings(draft());

      expect(saved, isFalse);
      expect(viewModel.needsValuationMethodConfirmation, isFalse);
      expect(viewModel.hasSaveError, isTrue);
    });

    test('a 400 that is not the guard is a failure', () async {
      final repo = _FakeRepo(
        result: Error(
          PosApiException(
            message: 'Shop settings update failed with status 400',
            statusCode: 400,
            responseBody: jsonEncode({
              'payment_methods': ['At least one payment method must be enabled.'],
            }),
          ),
        ),
      );
      final viewModel = ShopSettingsViewModel(repo);

      final saved = await viewModel.updateSettings(draft());

      expect(saved, isFalse);
      expect(viewModel.needsValuationMethodConfirmation, isFalse);
      expect(viewModel.hasSaveError, isTrue);
    });

    test('a non-JSON error body does not crash the save path', () async {
      final repo = _FakeRepo(
        result: Error(
          PosApiException(
            message: 'Shop settings update failed with status 502',
            statusCode: 502,
            responseBody: '<html>gateway</html>',
          ),
        ),
      );
      final viewModel = ShopSettingsViewModel(repo);

      final saved = await viewModel.updateSettings(draft());

      expect(saved, isFalse);
      expect(viewModel.needsValuationMethodConfirmation, isFalse);
      expect(viewModel.hasSaveError, isTrue);
    });

    test('the flag clears once a save succeeds', () async {
      final repo = _FakeRepo(
        result: Error(
          PosApiException(
            message: 'Shop settings update failed with status 400',
            statusCode: 400,
            responseBody: jsonEncode({
              'code': ['valuation_method_change_requires_acknowledgement'],
            }),
          ),
        ),
      );
      final viewModel = ShopSettingsViewModel(repo);
      await viewModel.updateSettings(draft());
      expect(viewModel.needsValuationMethodConfirmation, isTrue);

      repo.result = const Ok(
        ShopSettings(
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
          trustedCardTerminalIds: [],
          cardCommissionPercent: 0,
          transferCommissionPercent: 0,
          inventoryValuationMethod: InventoryValuationMethod.fifo,
        ),
      );

      final saved = await viewModel.updateSettings(
        draft().acknowledgingValuationMethodChange(),
      );

      expect(saved, isTrue);
      expect(viewModel.needsValuationMethodConfirmation, isFalse);
      expect(
        viewModel.settings?.inventoryValuationMethod,
        InventoryValuationMethod.fifo,
      );
    });
  });
}

class _FakeRepo extends ShopSettingsRepository {
  _FakeRepo({required this.result}) : super(PosApiService());

  Result<ShopSettings> result;

  ShopSettingsDraft? lastDraft;

  @override
  Future<Result<ShopSettings>> updateSettings(ShopSettingsDraft draft) async {
    lastDraft = draft;
    return result;
  }

  // Loaded on construction; keep them inert.
  @override
  Future<Result<ShopSettings>> loadSettings() async =>
      Error(Exception('not used'));

  @override
  Future<Result<BackupOperationsStatus>> loadBackupOperationsStatus() async =>
      Error(Exception('not used'));

  @override
  Future<Result<List<BackupDestination>>> loadBackupDestinations() async =>
      Error(Exception('not used'));
}
