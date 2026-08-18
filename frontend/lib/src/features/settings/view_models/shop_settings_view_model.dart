import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/analytics_audit.dart';
import '../../../core/analytics_engine.dart';
import '../../../core/result.dart';
import '../../../data/models/analytics_event.dart';
import '../../../data/models/analytics_export.dart';
import '../../../data/models/shop_settings.dart';
import '../../../data/models/system_backup.dart';
import '../../../data/repositories/shop_settings_repository.dart';

class ShopSettingsViewModel extends ChangeNotifier {
  ShopSettingsViewModel(this._repository, {AnalyticsEngine? analyticsEngine})
    : _analyticsEngine = analyticsEngine {
    loadSettings();
    loadBackupOperations();
  }

  final ShopSettingsRepository _repository;
  final AnalyticsEngine? _analyticsEngine;

  ShopSettings? _settings;
  bool _isLoading = false;
  bool _isSaving = false;
  bool _isExportingAnalytics = false;
  AnalyticsExportProgress? _analyticsExportProgress;
  AnalyticsExportCancellation? _analyticsExportCancellation;
  DateTime? _analyticsExportProgressNotifiedAt;
  bool _isLoadingBackupOperations = false;
  bool _isSavingBackupSchedule = false;
  bool _isStartingBackup = false;
  bool _isRestoringBackup = false;
  bool _hasLoadError = false;
  bool _hasSaveError = false;
  bool _hasAnalyticsExportError = false;
  bool _hasBackupOperationsError = false;
  BackupOperationsStatus? _backupStatus;
  List<BackupDestination> _backupDestinations = const [];
  Timer? _backupPollTimer;

  ShopSettings? get settings => _settings;
  bool get isLoading => _isLoading;
  bool get isSaving => _isSaving;
  bool get isExportingAnalytics => _isExportingAnalytics;

  /// Live download progress of the running export, or `null` when idle.
  AnalyticsExportProgress? get analyticsExportProgress =>
      _analyticsExportProgress;

  bool get canCancelAnalyticsExport => _analyticsExportCancellation != null;
  bool get isLoadingBackupOperations => _isLoadingBackupOperations;
  bool get isSavingBackupSchedule => _isSavingBackupSchedule;
  bool get isStartingBackup => _isStartingBackup;
  bool get isRestoringBackup => _isRestoringBackup;
  bool get hasLoadError => _hasLoadError;
  bool get hasSaveError => _hasSaveError;
  bool get hasAnalyticsExportError => _hasAnalyticsExportError;
  bool get hasBackupOperationsError => _hasBackupOperationsError;
  BackupOperationsStatus? get backupStatus => _backupStatus;
  List<BackupDestination> get backupDestinations => _backupDestinations;

  @override
  void dispose() {
    _backupPollTimer?.cancel();
    super.dispose();
  }

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

  /// Stop a running export. Safe to call when none is running.
  void cancelAnalyticsExport() {
    _analyticsExportCancellation?.cancel();
  }

  /// Progress is reported per network chunk — far more often than a UI needs.
  /// Repainting the settings screen on every 64KB of a multi-GB download would
  /// cost more than the download does, so coalesce to a few frames a second.
  static const _analyticsExportProgressInterval = Duration(milliseconds: 250);

  void _onAnalyticsExportProgress(AnalyticsExportProgress progress) {
    _analyticsExportProgress = progress;
    final now = DateTime.now();
    final last = _analyticsExportProgressNotifiedAt;
    if (last != null &&
        now.difference(last) < _analyticsExportProgressInterval) {
      return;
    }
    _analyticsExportProgressNotifiedAt = now;
    notifyListeners();
  }

  Future<AnalyticsExportFile?> exportAnalyticsEvents(
    AnalyticsExportQuery query,
  ) async {
    _isExportingAnalytics = true;
    _hasAnalyticsExportError = false;
    _analyticsExportProgress = null;
    _analyticsExportProgressNotifiedAt = null;
    final cancellation = AnalyticsExportCancellation();
    _analyticsExportCancellation = cancellation;
    notifyListeners();

    final stopwatch = Stopwatch()..start();
    final attributes = query.toAnalyticsAttributes();
    unawaited(
      _analyticsEngine?.trackUsage(
        AnalyticsEventName.analyticsExportStarted,
        attributes: attributes,
      ),
    );

    final result = await _repository.exportAnalyticsEvents(
      query,
      onProgress: _onAnalyticsExportProgress,
      cancellation: cancellation,
    );
    stopwatch.stop();
    _isExportingAnalytics = false;
    _analyticsExportCancellation = null;
    _analyticsExportProgress = null;

    // A cancel is the user getting what they asked for, not a failure: report
    // it as its own outcome so the UI does not cry "export failed" at them.
    if (result is Error<AnalyticsExportFile> &&
        result.exception is AnalyticsExportCanceledException) {
      unawaited(
        _analyticsEngine?.trackUsage(
          AnalyticsEventName.analyticsExportCanceled,
          attributes: attributes,
          metrics: {'elapsed_ms': stopwatch.elapsedMilliseconds},
        ),
      );
      notifyListeners();
      return null;
    }

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
            metrics: {'byte_count': result.value.sizeBytes},
          ),
        );
        unawaited(
          _analyticsEngine?.trackUsage(
            AnalyticsEventName.analyticsExportCompleted,
            attributes: {
              ...attributes,
              'filename_extension': result.value.filename.split('.').last,
            },
            metrics: {'byte_count': result.value.sizeBytes},
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

  Future<void> loadBackupOperations({bool silent = false}) async {
    if (!silent) {
      _isLoadingBackupOperations = true;
      _hasBackupOperationsError = false;
      notifyListeners();
    }

    final statusResult = await _repository.loadBackupOperationsStatus();
    final destinationsResult = await _repository.loadBackupDestinations();
    switch (statusResult) {
      case Ok<BackupOperationsStatus>():
        _backupStatus = statusResult.value;
      case Error<BackupOperationsStatus>():
        _hasBackupOperationsError = true;
    }
    switch (destinationsResult) {
      case Ok<List<BackupDestination>>():
        _backupDestinations = destinationsResult.value;
      case Error<List<BackupDestination>>():
        _hasBackupOperationsError = true;
    }

    _isLoadingBackupOperations = false;
    _syncBackupPolling();
    notifyListeners();
  }

  Future<bool> updateBackupSchedule(BackupScheduleDraft draft) async {
    _isSavingBackupSchedule = true;
    _hasBackupOperationsError = false;
    notifyListeners();

    final result = await _repository.updateBackupSchedule(draft);
    _isSavingBackupSchedule = false;
    switch (result) {
      case Ok<BackupOperationsStatus>():
        _backupStatus = result.value;
        _trackBackupOperation(
          name: 'settings.backup.schedule_saved',
          attributes: {
            'enabled': draft.enabled,
            'destination_selected': draft.destinationPath.trim().isNotEmpty,
            'source': 'shop_settings',
          },
        );
        _syncBackupPolling();
        notifyListeners();
        return true;
      case Error<BackupOperationsStatus>():
        _hasBackupOperationsError = true;
        notifyListeners();
        return false;
    }
  }

  Future<bool> startBackup() async {
    _isStartingBackup = true;
    _hasBackupOperationsError = false;
    notifyListeners();

    final result = await _repository.startBackup();
    _isStartingBackup = false;
    switch (result) {
      case Ok<SystemMaintenanceJob>():
        _trackBackupOperation(
          name: 'settings.backup.manual_started',
          attributes: {'source': 'shop_settings'},
        );
        await loadBackupOperations(silent: true);
        return true;
      case Error<SystemMaintenanceJob>():
        _hasBackupOperationsError = true;
        notifyListeners();
        return false;
    }
  }

  Future<bool> restoreBackup(RestoreBackupUpload upload) async {
    _isRestoringBackup = true;
    _hasBackupOperationsError = false;
    notifyListeners();

    final result = await _repository.restoreBackup(upload);
    _isRestoringBackup = false;
    switch (result) {
      case Ok<SystemMaintenanceJob>():
        _trackBackupOperation(
          name: 'settings.backup.restore_started',
          attributes: {
            'source': 'shop_settings',
            'filename_extension': upload.filename.split('.').last,
          },
          metrics: {'byte_count': upload.bytes.length},
        );
        await loadBackupOperations(silent: true);
        return true;
      case Error<SystemMaintenanceJob>():
        _hasBackupOperationsError = true;
        notifyListeners();
        return false;
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
        metrics: {'byte_count': file.sizeBytes},
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
        'warn_low_stock_before_sale': settings.warnLowStockBeforeSale,
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

  void _syncBackupPolling() {
    final hasActiveJob = _backupStatus?.activeJob?.isActive ?? false;
    if (!hasActiveJob) {
      _backupPollTimer?.cancel();
      _backupPollTimer = null;
      return;
    }
    _backupPollTimer ??= Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(loadBackupOperations(silent: true)),
    );
  }

  void _trackBackupOperation({
    required String name,
    Map<String, Object?> attributes = const {},
    Map<String, num> metrics = const {},
  }) {
    trackAuditEvent(
      _analyticsEngine,
      name: name,
      entityType: 'system_backup',
      attributes: attributes,
      metrics: metrics,
    );
  }
}
