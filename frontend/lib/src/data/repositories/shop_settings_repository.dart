import '../../core/result.dart';
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
}
