import '../models/analytics_export.dart';
import '../models/shop_settings.dart';
import '../models/system_backup.dart';
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

  Future<ShopSettings> setupShop({
    required String shopType,
    String? shopName,
    bool? allowOverselling,
    bool? requireOpeningCash,
    bool? autoPrintReceipts,
    bool? autoPrintKitchenTickets,
  }) async {
    final body = <String, Object?>{'shop_type': shopType};
    if (shopName != null) body['shop_name'] = shopName;
    if (allowOverselling != null) body['allow_overselling'] = allowOverselling;
    if (requireOpeningCash != null) {
      body['require_opening_cash'] = requireOpeningCash;
    }
    if (autoPrintReceipts != null) {
      body['auto_print_receipts'] = autoPrintReceipts;
    }
    if (autoPrintKitchenTickets != null) {
      body['auto_print_kitchen_tickets'] = autoPrintKitchenTickets;
    }
    final response = await _session.post('shop-settings/setup/', body: body);
    _session.ensureSuccess(response, 'Shop setup failed with status');
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

  Future<List<BackupDestination>> fetchBackupDestinations() async {
    final response = await _session.get('backup/destinations/');
    _session.ensureSuccess(
      response,
      'Backup destinations request failed with status',
    );
    final decoded = _session.decodedBody(response) as Map<String, Object?>;
    final destinations = decoded['destinations'] as List<Object?>? ?? const [];
    return destinations
        .whereType<Map<String, Object?>>()
        .map(BackupDestination.fromJson)
        .toList(growable: false);
  }

  Future<BackupOperationsStatus> fetchBackupOperationsStatus() async {
    final response = await _session.get('backup/');
    _session.ensureSuccess(
      response,
      'Backup status request failed with status',
    );
    return BackupOperationsStatus.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<BackupOperationsStatus> updateBackupSchedule(
    BackupScheduleDraft draft,
  ) async {
    final response = await _session.patch('backup/', body: draft.toJson());
    _session.ensureSuccess(
      response,
      'Backup schedule update failed with status',
    );
    return BackupOperationsStatus.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<SystemMaintenanceJob> startBackup() async {
    final response = await _session.post('backup/');
    _session.ensureSuccess(response, 'Backup start failed with status');
    return SystemMaintenanceJob.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<SystemMaintenanceJob> restoreBackup(RestoreBackupUpload upload) async {
    final response = await _session.postMultipart(
      'backup/restore/',
      files: [
        ApiMultipartFile(
          fieldName: 'file',
          filename: upload.filename,
          bytes: upload.bytes,
          contentType: upload.contentType,
        ),
      ],
    );
    _session.ensureSuccess(response, 'Backup restore failed with status');
    return SystemMaintenanceJob.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
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
