import '../models/analytics_export.dart';
import '../models/shop_settings.dart';
import '../models/system_backup.dart';
import 'analytics_export_receiver.dart';
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
    // throwApiException (not ensureSuccess) so the response body survives: the
    // valuation-method guard answers 400 with a code the screen has to read to
    // know it should raise the confirmation dialog.
    _session.throwApiException(
      response,
      'Shop settings update failed with status',
    );
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
    bool? kitchenAutoComplete,
    InventoryValuationMethod? inventoryValuationMethod,
    bool? fxEnabled,
    String? fxInstrument,
  }) async {
    final body = <String, Object?>{'shop_type': shopType};
    if (inventoryValuationMethod != null) {
      body['inventory_valuation_method'] = inventoryValuationMethod.wireValue;
    }
    if (shopName != null) body['shop_name'] = shopName;
    // Multi-currency, answered once at setup. Sent only when the wizard asked,
    // so an older client's payload leaves the shop single-currency.
    if (fxEnabled != null) body['fx_enabled'] = fxEnabled;
    if (fxInstrument != null) body['fx_instrument'] = fxInstrument;
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
    if (kitchenAutoComplete != null) {
      body['kitchen_auto_complete'] = kitchenAutoComplete;
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

  /// Clear the shop's stored event history. Returns how many rows went.
  ///
  /// Manager-only on the server, and irreversible: there is no soft-delete
  /// behind this and no undo in front of it.
  Future<int> purgeAnalyticsEvents() async {
    // Well past the 60-second default. The sweep is batched server-side, but a
    // shop clearing a year of telemetry is deleting millions of rows and a
    // client timeout here would report a failure for a purge that is actually
    // still running — the worst possible thing to tell someone about a button
    // they cannot press twice with confidence.
    final response = await _session.post(
      'analytics-events/purge/',
      timeout: const Duration(minutes: 5),
    );
    _session.ensureSuccess(response, 'Analytics purge failed with status');
    final body = _session.decodedBody(response);
    if (body is Map<String, Object?>) {
      final deleted = body['deleted'];
      if (deleted is int) {
        return deleted;
      }
      if (deleted is num) {
        return deleted.toInt();
      }
    }
    return 0;
  }

  Future<AnalyticsExportFile> exportAnalyticsEvents(
    AnalyticsExportQuery query, {
    void Function(AnalyticsExportProgress progress)? onProgress,
    AnalyticsExportCancellation? cancellation,
  }) async {
    // Streamed, not buffered: the backend streams the zip as it is built, and
    // on native platforms the receiver spools it straight to disk — an export
    // is never limited by what fits in app memory.
    final stopwatch = Stopwatch()..start();
    final response = await _session.getStreamed(
      'analytics-events/export/',
      query: query.toQueryParameters(),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final errorBody = await response.stream.bytesToString();
      throw PosApiException(
        message: 'Analytics export failed with status ${response.statusCode}',
        statusCode: response.statusCode,
        responseBody: errorBody,
      );
    }
    // Approximate, and sent before the first row: an exact count would mean
    // scanning the whole filtered range before any byte could be streamed.
    final expectedEventCount = int.tryParse(
      response.headers['x-pointy-analytics-event-count-estimate'] ??
          response.headers['x-pointy-analytics-event-count'] ??
          '',
    );
    return receiveAnalyticsExport(
      response,
      filename: _filenameFromHeaders(response.headers),
      contentType: response.headers['content-type'] ?? 'application/zip',
      cancellation: cancellation,
      onProgress: onProgress == null
          ? null
          : (receivedBytes) => onProgress(
              AnalyticsExportProgress(
                receivedBytes: receivedBytes,
                elapsed: stopwatch.elapsed,
                expectedEventCount: expectedEventCount,
              ),
            ),
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
      // Uploading a whole database dump over a shop LAN.
      timeout: PosApiSession.longRunningRequestTimeout,
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
