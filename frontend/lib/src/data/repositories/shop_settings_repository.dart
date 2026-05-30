import '../../core/result.dart';
import '../models/analytics_export.dart';
import '../models/shop_settings.dart';
import '../services/pos_api_service.dart';

class ShopSettingsRepository {
  ShopSettingsRepository(this._service);

  final PosApiService _service;

  Future<Result<ShopSettings>> loadSettings() async {
    return Result.guard(_service.fetchShopSettings);
  }

  Future<Result<ShopSettings>> updateSettings(ShopSettingsDraft draft) async {
    return Result.guard(() => _service.updateShopSettings(draft));
  }

  Future<Result<ShopSettings>> uploadLogo(ShopLogoUpload upload) async {
    return Result.guard(() => _service.uploadShopLogo(upload));
  }

  Future<Result<ShopSettings>> removeLogo() async {
    return Result.guard(_service.removeShopLogo);
  }

  Future<Result<AnalyticsExportFile>> exportAnalyticsEvents(
    AnalyticsExportQuery query,
  ) async {
    return Result.guard(() => _service.exportAnalyticsEvents(query));
  }
}
