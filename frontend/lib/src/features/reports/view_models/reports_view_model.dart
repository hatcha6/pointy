import 'package:flutter/material.dart' show DateTimeRange;
import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/analytics_export.dart';
import '../../../data/models/report_catalog.dart';
import '../../../data/models/report_run.dart';
import '../../../data/repositories/report_repository.dart';

/// Drives the reports screen: what may be run, over which window, and what came
/// back.
///
/// Three things it exists to fix, all of them about the screen being a form
/// with no memory:
///
/// * **A report was write-only.** The screen could create a run and nothing
///   else — no results on screen, no history, no way to reopen last month's
///   report. Every look at a number cost a full server-side rebuild *and* a
///   PDF. The run is held here, so previewing, printing, sharing and exporting
///   all act on one build instead of three.
///
/// * **The period vocabulary was hard-coded in the client.** Which is how a
///   "Detailed" control shipped that the server had never read. The catalogue
///   is fetched; the screen offers exactly the windows the server resolves.
///
/// * **Failures lost their reason.** The backend has always returned precise
///   refusals; the screen replaced every one with "could not generate the
///   report". The server's message is kept and shown.
class ReportsViewModel extends ChangeNotifier {
  ReportsViewModel(this._repository);

  final ReportRepository _repository;

  ReportCatalog _catalog = ReportCatalog.empty;
  bool _isLoadingCatalog = false;
  bool _hasCatalogError = false;

  ReportRunType _selectedType = ReportRunType.salesSummary;
  String _preset = ReportPeriodPresetOption.lastMonth;
  DateTimeRange? _customRange;
  String _granularity = ReportGranularityOption.summary;
  String _comparison = ReportComparisonOption.previousPeriod;
  int? _customerId;
  String _customerName = '';
  int? _supplierId;
  String _supplierName = '';
  String _unitCode = '';

  ReportRun? _run;
  bool _isRunning = false;
  String _errorMessage = '';

  List<ReportRunSummary> _history = const [];
  bool _isLoadingHistory = false;
  ReportVerification? _verification;
  int? _verifyingRunId;

  PeriodLockState _lock = const PeriodLockState();
  bool _isSavingLock = false;

  // -- catalogue -----------------------------------------------------------

  ReportCatalog get catalog => _catalog;
  bool get isLoadingCatalog => _isLoadingCatalog;
  bool get hasCatalogError => _hasCatalogError;
  List<ReportCatalogEntry> get reports => _catalog.reports;

  ReportCatalogEntry? get selectedEntry => _catalog.entryFor(_selectedType);

  /// Reports grouped by the server's own category, in catalogue order.
  Map<String, List<ReportCatalogEntry>> get reportsByCategory {
    final grouped = <String, List<ReportCatalogEntry>>{};
    for (final entry in _catalog.reports) {
      grouped.putIfAbsent(entry.category, () => []).add(entry);
    }
    return grouped;
  }

  // -- selection -----------------------------------------------------------

  ReportRunType get selectedType => _selectedType;
  String get preset => _preset;
  String get granularity => _granularity;
  String get comparison => _comparison;
  int? get customerId => _customerId;
  String get customerName => _customerName;
  int? get supplierId => _supplierId;
  String get supplierName => _supplierName;

  /// The serial or IMEI a unit ledger is about, as typed or scanned.
  String get unitCode => _unitCode;

  /// The dates a custom window covers. A preset resolves server-side, so this
  /// is only meaningful — and only shown — when the preset is `custom`.
  DateTimeRange get customRange => _customRange ?? _defaultRange();

  bool get isCustomPeriod => _preset == ReportPeriodPresetOption.custom;

  /// Whether the selected report can be built from what has been chosen. A
  /// statement without a party is not a failed report; it is an unfinished
  /// request, and the screen says so rather than letting the server refuse it.
  bool get canRun {
    final entry = selectedEntry;
    if (entry == null) {
      return false;
    }
    if (entry.needsCustomer && _customerId == null) {
      return false;
    }
    if (entry.needsSupplier && _supplierId == null) {
      return false;
    }
    if (entry.needsUnitCode && _unitCode.isEmpty) {
      return false;
    }
    return !_isRunning;
  }

  // -- result --------------------------------------------------------------

  ReportRun? get run => _run;
  bool get isRunning => _isRunning;
  String get errorMessage => _errorMessage;
  bool get hasResult => _run != null;

  /// True when the held result was built from the selection now on screen. A
  /// stale result stays visible (losing it on every knob-turn is worse) but the
  /// screen marks it, so nobody prints last week's window by mistake.
  bool get resultMatchesSelection {
    final run = _run;
    if (run == null) {
      return false;
    }
    return run.reportType == _selectedType &&
        _sameParams(run.params, currentParams());
  }

  // -- history and lock ----------------------------------------------------

  List<ReportRunSummary> get history => _history;
  bool get isLoadingHistory => _isLoadingHistory;
  ReportVerification? get verification => _verification;
  int? get verifyingRunId => _verifyingRunId;
  PeriodLockState get lock => _lock;
  bool get isSavingLock => _isSavingLock;

  /// The day of the month the closed month is snapshotted on; 0 means off.
  int get snapshotDay => _lock.monthEndSnapshotDay;

  // -- loading -------------------------------------------------------------

  Future<void> load() async {
    if (_isLoadingCatalog) {
      return;
    }
    _isLoadingCatalog = true;
    _hasCatalogError = false;
    notifyListeners();

    final result = await _repository.loadCatalog();
    _isLoadingCatalog = false;
    switch (result) {
      case Ok(:final value):
        _catalog = value;
        _lock = PeriodLockState(
          lockedThrough: value.booksLockedThrough,
          fiscalYearStartMonth: value.fiscalYearStartMonth,
          monthEndSnapshotDay: value.monthEndSnapshotDay,
          canManage: value.canManagePeriodLock,
        );
        if (_catalog.entryFor(_selectedType) == null &&
            _catalog.reports.isNotEmpty) {
          _selectedType = _catalog.reports.first.type;
        }
      case Error():
        _hasCatalogError = true;
    }
    notifyListeners();
  }

  // -- selection changes ---------------------------------------------------

  void selectType(ReportRunType type) {
    if (_selectedType == type) {
      return;
    }
    _selectedType = type;
    _errorMessage = '';
    notifyListeners();
  }

  void selectPreset(String preset) {
    _preset = preset;
    notifyListeners();
  }

  void selectCustomRange(DateTimeRange range) {
    _customRange = range;
    _preset = ReportPeriodPresetOption.custom;
    notifyListeners();
  }

  void selectGranularity(String granularity) {
    _granularity = granularity;
    notifyListeners();
  }

  void selectComparison(String comparison) {
    _comparison = comparison;
    notifyListeners();
  }

  void selectCustomer(int? id, String name) {
    _customerId = id;
    _customerName = name;
    notifyListeners();
  }

  void selectSupplier(int? id, String name) {
    _supplierId = id;
    _supplierName = name;
    notifyListeners();
  }

  void selectUnitCode(String code) {
    final trimmed = code.trim();
    if (trimmed == _unitCode) {
      return;
    }
    _unitCode = trimmed;
    notifyListeners();
  }

  /// The request parameters for the current selection.
  ///
  /// A preset is sent as a preset and resolved on the server, so the run
  /// records the days it actually covered rather than the client's idea of
  /// them — a device with a wrong clock can no longer label an August window
  /// as September.
  Map<String, Object?> currentParams() {
    return {
      if (isCustomPeriod) ...{
        'start_date': _apiDate(customRange.start),
        'end_date': _apiDate(customRange.end),
      } else
        'preset': _preset,
      'granularity': _granularity,
      'comparison': _comparison,
      if (_customerId != null) 'customer_id': _customerId,
      if (_supplierId != null) 'supplier_id': _supplierId,
      // Only for the report that asks for it: a code is free text naming one
      // article, and riding along on every other run it would be stored
      // against reports it means nothing to.
      if (_unitCode.isNotEmpty && (selectedEntry?.needsUnitCode ?? false))
        'code': _unitCode,
    };
  }

  ReportRunDraft currentDraft({
    ReportOutputFormat format = ReportOutputFormat.pdf,
  }) {
    return ReportRunDraft(
      reportType: _selectedType,
      outputFormat: format,
      params: currentParams(),
    );
  }

  // -- running -------------------------------------------------------------

  /// Builds the report and holds it. Returns the run, or null on failure with
  /// [errorMessage] set to the server's own reason.
  Future<ReportRun?> runReport() async {
    if (_isRunning) {
      return null;
    }
    _isRunning = true;
    _errorMessage = '';
    notifyListeners();

    final result = await _repository.createReportRun(currentDraft());
    _isRunning = false;
    switch (result) {
      case Ok(:final value):
        if (value.status == ReportRunStatus.failed) {
          _errorMessage = value.errorMessage;
          notifyListeners();
          return null;
        }
        _run = value;
        _verification = null;
        notifyListeners();
        return value;
      case Error(:final exception):
        _errorMessage = _messageFor(exception);
        notifyListeners();
        return null;
    }
  }

  /// The held run when it still matches the selection, otherwise a fresh build.
  ///
  /// This is what stops preview, print and share from being three separate
  /// server-side rebuilds of the same report.
  Future<ReportRun?> ensureRun() async {
    if (resultMatchesSelection) {
      return _run;
    }
    return runReport();
  }

  Future<AnalyticsExportFile?> exportCsv() async {
    _errorMessage = '';
    final result = await _repository.downloadCsv(
      currentDraft(format: ReportOutputFormat.csv),
    );
    switch (result) {
      case Ok(:final value):
        return value;
      case Error(:final exception):
        _errorMessage = _messageFor(exception);
        notifyListeners();
        return null;
    }
  }

  // -- history -------------------------------------------------------------

  Future<void> loadHistory() async {
    if (_isLoadingHistory) {
      return;
    }
    _isLoadingHistory = true;
    notifyListeners();

    final result = await _repository.loadHistory(type: _selectedType);
    _isLoadingHistory = false;
    switch (result) {
      case Ok(:final value):
        _history = value;
      case Error():
        _history = const [];
    }
    notifyListeners();
  }

  /// Reopens a stored run, exactly as it was recorded.
  Future<bool> openHistoricRun(int id) async {
    final result = await _repository.loadRun(id);
    switch (result) {
      case Ok(:final value):
        _run = value;
        _verification = null;
        notifyListeners();
        return true;
      case Error(:final exception):
        _errorMessage = _messageFor(exception);
        notifyListeners();
        return false;
    }
  }

  /// Re-runs a stored report and reports whether its figures still hold.
  Future<ReportVerification?> verifyRun(int id) async {
    _verifyingRunId = id;
    notifyListeners();

    final result = await _repository.verifyRun(id);
    _verifyingRunId = null;
    switch (result) {
      case Ok(:final value):
        _verification = value;
        notifyListeners();
        return value;
      case Error(:final exception):
        _errorMessage = _messageFor(exception);
        notifyListeners();
        return null;
    }
  }

  // -- period lock ---------------------------------------------------------

  Future<bool> setPeriodLock({
    DateTime? lockedThrough,
    bool includeLockedThrough = true,
    int? fiscalYearStartMonth,
    String note = '',
    bool acknowledged = false,
  }) async {
    _isSavingLock = true;
    _errorMessage = '';
    notifyListeners();

    final result = await _repository.setPeriodLock(
      lockedThrough: lockedThrough,
      includeLockedThrough: includeLockedThrough,
      fiscalYearStartMonth: fiscalYearStartMonth,
      note: note,
      acknowledged: acknowledged,
    );
    _isSavingLock = false;
    switch (result) {
      case Ok(:final value):
        _lock = value;
        notifyListeners();
        return true;
      case Error(:final exception):
        _errorMessage = _messageFor(exception);
        notifyListeners();
        return false;
    }
  }

  /// True when the server refused because re-opening needs acknowledging.
  bool get lastErrorWasReopenGuard =>
      _errorMessage.contains('period_reopen_requires_acknowledgement');

  void clearError() {
    if (_errorMessage.isEmpty) {
      return;
    }
    _errorMessage = '';
    notifyListeners();
  }

  // -- helpers -------------------------------------------------------------

  /// The server's own words when it gave any, the failure's otherwise.
  ///
  /// "Start date must be before end date" and "period cannot be longer than 366
  /// days" were both reaching the client and both being replaced with a generic
  /// failure, leaving the user told that something went wrong and not what.
  String _messageFor(Object failure) {
    final body = _detailOf(failure);
    return body.isEmpty ? failure.toString() : body;
  }

  String _detailOf(Object failure) {
    final text = failure.toString();
    final match = RegExp(r'"detail"\s*:\s*"([^"]+)"').firstMatch(text);
    if (match != null) {
      return match.group(1)!;
    }
    return '';
  }

  DateTimeRange _defaultRange() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return DateTimeRange(
      start: DateTime(today.year, today.month - 1, 1),
      end: DateTime(today.year, today.month, 0),
    );
  }

  bool _sameParams(Map<String, Object?> a, Map<String, Object?> b) {
    if (a.length != b.length) {
      return false;
    }
    for (final entry in a.entries) {
      if ('${b[entry.key]}' != '${entry.value}') {
        return false;
      }
    }
    return true;
  }

  String _apiDate(DateTime date) {
    return '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
  }
}
