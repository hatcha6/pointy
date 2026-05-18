import '../models/shop_settings.dart';
import 'api_session.dart';

class ShopSettingsApiClient {
  const ShopSettingsApiClient(this._session);

  final PosApiSession _session;

  Future<ShopSettings> fetchShopSettings() async {
    final response = await _session.get('shop-settings/');
    _session.ensureSuccess(
      response,
      'Shop settings request failed with status',
    );
    return ShopSettings.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<ShopSettings> updateShopSettings(ShopSettingsDraft draft) async {
    final response = await _session.patch(
      'shop-settings/',
      body: draft.toJson(),
    );
    _session.ensureSuccess(response, 'Shop settings update failed with status');
    return ShopSettings.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }
}
