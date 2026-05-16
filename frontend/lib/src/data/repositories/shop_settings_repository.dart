import '../../core/result.dart';
import '../models/shop_settings.dart';
import '../services/pos_api_service.dart';

class ShopSettingsRepository {
  ShopSettingsRepository(this._service);

  final PosApiService _service;

  Future<Result<ShopSettings>> loadSettings() async {
    try {
      return Ok(await _service.fetchShopSettings());
    } on Exception catch (exception) {
      return Error(exception);
    }
  }

  Future<Result<ShopSettings>> updateSettings(ShopSettingsDraft draft) async {
    try {
      return Ok(await _service.updateShopSettings(draft));
    } on Exception catch (exception) {
      return Error(exception);
    }
  }
}
