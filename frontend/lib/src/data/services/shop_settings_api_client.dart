import '../models/analytics_export.dart';
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

  Future<ShopSettings> uploadShopLogo(ShopLogoUpload upload) async {
    final response = await _session.postMultipart(
      'shop-settings/logo/',
      files: [
        ApiMultipartFile(
          fieldName: 'file',
          filename: upload.filename,
          bytes: upload.bytes,
          contentType: upload.contentType,
        ),
      ],
    );
    _session.ensureSuccess(response, 'Shop logo upload failed with status');
    return ShopSettings.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<ShopSettings> removeShopLogo() async {
    final response = await _session.delete('shop-settings/logo/');
    _session.ensureSuccess(response, 'Shop logo remove failed with status');
    return ShopSettings.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<AnalyticsExportFile> exportAnalyticsEvents(
    AnalyticsExportQuery query,
  ) async {
    final response = await _session.get(
      'analytics-events/export/',
      query: query.toQueryParameters(),
    );
    _session.throwApiException(response, 'Analytics export failed with status');
    return AnalyticsExportFile(
      bytes: response.bodyBytes,
      filename: _filenameFromHeaders(response.headers),
      contentType: response.headers['content-type'] ?? 'application/zip',
    );
  }

  String _filenameFromHeaders(Map<String, String> headers) {
    final disposition = headers['content-disposition'] ?? '';
    final filenameStar = RegExp(
      "filename\\*=UTF-8''([^;]+)",
      caseSensitive: false,
    ).firstMatch(disposition);
    if (filenameStar != null) {
      return Uri.decodeComponent(filenameStar.group(1)!);
    }

    final filename = RegExp(
      'filename="?([^";]+)"?',
      caseSensitive: false,
    ).firstMatch(disposition);
    return filename?.group(1) ?? 'pointy-analytics-events.zip';
  }
}
