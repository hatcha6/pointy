import 'dart:async';

import 'package:flutter/foundation.dart';

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
}
