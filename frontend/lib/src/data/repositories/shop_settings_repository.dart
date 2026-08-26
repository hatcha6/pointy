import 'dart:typed_data';

import '../../core/result.dart';
import '../models/analytics_export.dart';
import '../models/shop_settings.dart';
import '../models/system_backup.dart';
import '../services/pos_api_service.dart';

class ShopSettingsRepository {
  ShopSettingsRepository(this._service);

  final PosApiService _service;

  Future<Result<ShopSettings>> loadSettings() async {
    return Result.guard(_service.fetchShopSettings);
  }

  Future<Result<Uint8List?>> loadLogoBytes(ShopSettings? settings) {
    return Result.guard(() => _service.fetchShopLogoBytes(settings));
  }

  /// The trusted card-terminal IDs alone (empty on any failure). Used by the
  /// card-receipt scan dialogs to mark which Moamalat terminals are trusted, so
  /// every customer card-payment flow resolves them the same way.
  Future<List<String>> loadTrustedCardTerminalIds() async {
    final result = await loadSettings();
    return switch (result) {
      Ok<ShopSettings>(value: final settings) =>
        settings.trustedCardTerminalIds,
      Error<ShopSettings>() => const <String>[],
    };
  }

  Future<Result<ShopSettings>> updateSettings(ShopSettingsDraft draft) async {
    return Result.guard(() => _service.updateShopSettings(draft));
  }

  Future<Result<ShopSettings>> setupShop({
    required String shopType,
    String? shopName,
    bool? allowOverselling,
    bool? requireOpeningCash,
    bool? autoPrintReceipts,
    bool? autoPrintKitchenTickets,
    InventoryValuationMethod? inventoryValuationMethod,
  }) async {
    return Result.guard(
      () => _service.setupShop(
        shopType: shopType,
        shopName: shopName,
        allowOverselling: allowOverselling,
        requireOpeningCash: requireOpeningCash,
        autoPrintReceipts: autoPrintReceipts,
        autoPrintKitchenTickets: autoPrintKitchenTickets,
        inventoryValuationMethod: inventoryValuationMethod,
      ),
    );
  }

  Future<Result<ShopSettings>> uploadLogo(ShopLogoUpload upload) async {
    return Result.guard(() => _service.uploadShopLogo(upload));
  }

  Future<Result<ShopSettings>> removeLogo() async {
    return Result.guard(_service.removeShopLogo);
  }

  Future<Result<AnalyticsExportFile>> exportAnalyticsEvents(
    AnalyticsExportQuery query, {
    void Function(AnalyticsExportProgress progress)? onProgress,
    AnalyticsExportCancellation? cancellation,
  }) async {
    return Result.guard(
      () => _service.exportAnalyticsEvents(
        query,
        onProgress: onProgress,
        cancellation: cancellation,
      ),
    );
  }

  Future<Result<List<BackupDestination>>> loadBackupDestinations() async {
    return Result.guard(_service.fetchBackupDestinations);
  }

  Future<Result<BackupOperationsStatus>> loadBackupOperationsStatus() async {
    return Result.guard(_service.fetchBackupOperationsStatus);
  }

  Future<Result<BackupOperationsStatus>> updateBackupSchedule(
    BackupScheduleDraft draft,
  ) async {
    return Result.guard(() => _service.updateBackupSchedule(draft));
  }

  Future<Result<SystemMaintenanceJob>> startBackup() async {
    return Result.guard(_service.startBackup);
  }

  Future<Result<SystemMaintenanceJob>> restoreBackup(
    RestoreBackupUpload upload,
  ) async {
    return Result.guard(() => _service.restoreBackup(upload));
  }
}
