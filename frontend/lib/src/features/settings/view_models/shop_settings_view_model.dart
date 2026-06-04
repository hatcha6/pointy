import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/analytics_audit.dart';
import '../../../core/analytics_engine.dart';
import '../../../core/result.dart';
import '../../../data/models/analytics_event.dart';
import '../../../data/models/analytics_export.dart';
import '../../../data/models/shop_settings.dart';
import '../../../data/repositories/shop_settings_repository.dart';

class ShopSettingsViewModel extends ChangeNotifier {
  ShopSettingsViewModel(this._repository, {AnalyticsEngine? analyticsEngine})
    : _analyticsEngine = analyticsEngine {
    loadSettings();
  }

  final ShopSettingsRepository _repository;
  final AnalyticsEngine? _analyticsEngine;

  ShopSettings? _settings;
  bool _isLoading = false;
  bool _isSaving = false;
  bool _isExportingAnalytics = false;
  bool _hasLoadError = false;
  bool _hasSaveError = false;
  bool _hasAnalyticsExportError = false;

  ShopSettings? get settings => _settings;
  bool get isLoading => _isLoading;
  bool get isSaving => _isSaving;
  bool get isExportingAnalytics => _isExportingAnalytics;
  bool get hasLoadError => _hasLoadError;
  bool get hasSaveError => _hasSaveError;
  bool get hasAnalyticsExportError => _hasAnalyticsExportError;

  Future<void> loadSettings() async {
    _isLoading = true;
    _hasLoadError = false;
    notifyListeners();

    final result = await _repository.loadSettings();
    switch (result) {
      case Ok<ShopSettings>():
        _settings = result.value;
      case Error<ShopSettings>():
        _hasLoadError = true;
    }

    _isLoading = false;
    notifyListeners();
  }

  Future<bool> updateSettings(ShopSettingsDraft draft) async {
    _isSaving = true;
    _hasSaveError = false;
    notifyListeners();

    final result = await _repository.updateSettings(draft);
    _isSaving = false;
    switch (result) {
      case Ok<ShopSettings>():
        _settings = result.value;
        _trackShopSettingsUpdated(result.value, draft);
        notifyListeners();
        return true;
      case Error<ShopSettings>():
        _hasSaveError = true;
        notifyListeners();
        return false;
    }
  }

  Future<bool> uploadLogo(ShopLogoUpload upload) async {
    _isSaving = true;
    _hasSaveError = false;
    notifyListeners();

    final result = await _repository.uploadLogo(upload);
    _isSaving = false;
    switch (result) {
      case Ok<ShopSettings>():
        _settings = result.value;
        _trackShopLogoChanged(
          name: 'settings.shop.logo_upload.completed',
          settings: result.value,
        );
        notifyListeners();
        return true;
      case Error<ShopSettings>():
        _hasSaveError = true;
        notifyListeners();
        return false;
    }
  }

  Future<bool> removeLogo() async {
    _isSaving = true;
    _hasSaveError = false;
    notifyListeners();

    final result = await _repository.removeLogo();
    _isSaving = false;
    switch (result) {
      case Ok<ShopSettings>():
        _settings = result.value;
        _trackShopLogoChanged(
          name: 'settings.shop.logo_remove.completed',
          settings: result.value,
        );
        notifyListeners();
        return true;
      case Error<ShopSettings>():
        _hasSaveError = true;
        notifyListeners();
        return false;
    }
  }

  Future<AnalyticsExportFile?> exportAnalyticsEvents(
    AnalyticsExportQuery query,
  ) async {
    _isExportingAnalytics = true;
    _hasAnalyticsExportError = false;
    notifyListeners();

    final stopwatch = Stopwatch()..start();
    final attributes = query.toAnalyticsAttributes();
    unawaited(
      _analyticsEngine?.trackUsage(
        AnalyticsEventName.analyticsExportStarted,
        attributes: attributes,
      ),
    );

    final result = await _repository.exportAnalyticsEvents(query);
    stopwatch.stop();
    _isExportingAnalytics = false;
    switch (result) {
      case Ok<AnalyticsExportFile>():
        unawaited(
          _analyticsEngine?.trackPerformance(
            name: analyticsEventNameToJson(
              AnalyticsEventName.frontendOperation,
            ),
            duration: stopwatch.elapsed,
            attributes: {
              'operation': 'analytics.export',
              ...attributes,
              'content_type': result.value.contentType,
            },
            metrics: {'byte_count': result.value.bytes.length},
          ),
        );
        unawaited(
          _analyticsEngine?.trackUsage(
            AnalyticsEventName.analyticsExportCompleted,
            attributes: {
              ...attributes,
              'filename_extension': result.value.filename.split('.').last,
            },
            metrics: {'byte_count': result.value.bytes.length},
          ),
        );
        notifyListeners();
        return result.value;
      case Error<AnalyticsExportFile>():
        _hasAnalyticsExportError = true;
        unawaited(
          _analyticsEngine?.trackPerformance(
            name: analyticsEventNameToJson(
              AnalyticsEventName.frontendOperation,
            ),
            duration: stopwatch.elapsed,
            severity: AnalyticsEventSeverity.error,
            attributes: {'operation': 'analytics.export', ...attributes},
            flushImmediately: true,
          ),
        );
        unawaited(
          _analyticsEngine?.trackUsage(
            AnalyticsEventName.analyticsExportFailed,
            severity: AnalyticsEventSeverity.error,
            attributes: attributes,
            flushImmediately: true,
          ),
        );
        notifyListeners();
        return null;
    }
  }

  void trackAnalyticsExportDownloadResult(
    AnalyticsExportFile file, {
    required bool downloaded,
  }) {
    unawaited(
      _analyticsEngine?.trackUsage(
        downloaded
            ? AnalyticsEventName.analyticsExportDownloaded
            : AnalyticsEventName.analyticsExportDownloadFailed,
        severity: downloaded
            ? AnalyticsEventSeverity.info
            : AnalyticsEventSeverity.warning,
        attributes: {
          'filename_extension': file.filename.split('.').last,
          'content_type': file.contentType,
          'source': 'analytics_export_sheet',
        },
        metrics: {'byte_count': file.bytes.length},
        flushImmediately: !downloaded,
      ),
    );
  }

  void _trackShopSettingsUpdated(
    ShopSettings settings,
    ShopSettingsDraft draft,
  ) {
    trackAuditEvent(
      _analyticsEngine,
      name: 'settings.shop.form_saved',
      entityType: 'shop_settings',
      attributes: {
        'shop_name_present': settings.shopName.trim().isNotEmpty,
        'require_opening_cash': settings.requireOpeningCash,
        'auto_print_receipts': settings.autoPrintReceipts,
        'allow_overselling': settings.allowOverselling,
        'prevent_selling_at_loss': settings.preventSellingAtLoss,
        'enable_cash_payments': settings.enableCashPayments,
        'enable_card_payments': settings.enableCardPayments,
        'enable_transfer_payments': settings.enableTransferPayments,
        'require_card_payment_receipt': settings.requireCardPaymentReceipt,
        'source': 'shop_settings',
      },
      metrics: {
        'low_stock_threshold': draft.lowStockThreshold,
        'cashier_return_window_hours': draft.cashierReturnWindowHours,
        'enabled_payment_method_count': [
          draft.enableCashPayments,
          draft.enableCardPayments,
          draft.enableTransferPayments,
        ].where((isEnabled) => isEnabled).length,
        'trusted_card_terminal_count': draft.trustedCardTerminalIds.length,
        'card_commission_percent': draft.cardCommissionPercent,
        'transfer_commission_percent': draft.transferCommissionPercent,
      },
    );
  }

  void _trackShopLogoChanged({
    required String name,
    required ShopSettings settings,
  }) {
    trackAuditEvent(
      _analyticsEngine,
      name: name,
      entityType: 'shop_settings',
      attributes: {
        'shop_name_present': settings.shopName.trim().isNotEmpty,
        'logo_present': settings.logoAttachment != null,
        'source': 'shop_settings',
      },
    );
  }
}
