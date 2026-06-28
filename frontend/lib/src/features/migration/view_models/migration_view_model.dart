import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/analytics_audit.dart';
import '../../../core/analytics_engine.dart';
import '../../../core/result.dart';
import '../../../data/models/migration.dart';
import '../../../data/repositories/migration_repository.dart';

/// Drives the Data Migration page: connection config, compatibility check,
/// dry-run / import, and live polling of the active run.
class MigrationViewModel extends ChangeNotifier {
  MigrationViewModel(this._repository, {AnalyticsEngine? analyticsEngine})
    : _analyticsEngine = analyticsEngine;

  final MigrationRepository _repository;
  final AnalyticsEngine? _analyticsEngine;

  static const _pollInterval = Duration(seconds: 2);

  MigrationCatalog? _catalog;
  List<MigrationSource> _sources = const [];
  int? _selectedSourceId;
  final Set<String> _selectedEntities = <String>{};
  bool _productsWithoutQuantities = false;
  CompatibilityReport? _compatReport;
  MigrationConnectionTest? _connectionTest;
  MigrationRun? _activeRun;
  MigrationRun? _lastRun;
  List<MigrationIssue> _issues = const [];

  bool _isLoading = false;
  bool _hasLoadError = false;
  bool _isMutating = false;
  bool _hasMutationError = false;
  bool _isTesting = false;
  bool _isChecking = false;
  bool _isDiscovering = false;
  bool _isStartingRun = false;
  bool _isLoadingIssues = false;
  String? _mutationMessage;

  Timer? _pollTimer;

  // --- getters ---------------------------------------------------------
  MigrationCatalog? get catalog => _catalog;
  List<MigrationSystem> get systems => _catalog?.systems ?? const [];
  List<MigrationSource> get sources => _sources;
  MigrationSource? get selectedSource {
    for (final source in _sources) {
      if (source.id == _selectedSourceId) return source;
    }
    return null;
  }

  Set<String> get selectedEntities => _selectedEntities;
  bool get productsWithoutQuantities => _productsWithoutQuantities;
  CompatibilityReport? get compatibilityReport =>
      _compatReport ?? _checkedReportFromSource;
  MigrationConnectionTest? get connectionTest => _connectionTest;
  MigrationRun? get activeRun => _activeRun;
  MigrationRun? get lastRun => _lastRun;
  MigrationRun? get currentRun => _activeRun ?? _lastRun;
  List<MigrationIssue> get issues => _issues;

  bool get isLoading => _isLoading;
  bool get hasLoadError => _hasLoadError;
  bool get isMutating => _isMutating;
  bool get hasMutationError => _hasMutationError;
  bool get isTesting => _isTesting;
  bool get isChecking => _isChecking;
  bool get isDiscovering => _isDiscovering;
  bool get isStartingRun => _isStartingRun;
  bool get isLoadingIssues => _isLoadingIssues;
  String? get mutationMessage => _mutationMessage;

  bool get isCompatible => compatibilityReport?.compatible ?? false;

  /// Import is gated on a clean dry run (no failed records).
  bool get canImport {
    final run = _lastRun;
    return run != null &&
        run.isDryRun &&
        run.isTerminal &&
        run.totalFailed == 0 &&
        isCompatible;
  }

  CompatibilityReport? get _checkedReportFromSource {
    final report = selectedSource?.lastCompatReport;
    return (report != null && report.checked) ? report : null;
  }

  MigrationSystem? systemFor(String systemKey) {
    for (final system in systems) {
      if (system.systemKey == systemKey) return system;
    }
    return null;
  }

  List<String> get supportedEntitiesForSelected {
    final source = selectedSource;
    if (source == null) return const [];
    return systemFor(source.systemKey)?.supportedEntities ?? const [];
  }

  String entityLabel(String entityType) {
    for (final spec in _catalog?.entities ?? const <MigrationEntitySpec>[]) {
      if (spec.entityType == entityType) return spec.label;
    }
    return entityType;
  }

  // --- loading ---------------------------------------------------------
  Future<void> load() async {
    _isLoading = true;
    _hasLoadError = false;
    notifyListeners();

    final catalogResult = await _repository.loadCatalog();
    switch (catalogResult) {
      case Ok<MigrationCatalog>():
        _catalog = catalogResult.value;
      case Error<MigrationCatalog>():
        _hasLoadError = true;
    }
    if (!_hasLoadError) {
      await _refreshSources(selectId: _selectedSourceId);
    }

    _isLoading = false;
    notifyListeners();
  }

  Future<void> _refreshSources({int? selectId}) async {
    final result = await _repository.loadSources();
    if (result is Ok<List<MigrationSource>>) {
      _sources = result.value.where((source) => !source.isArchived).toList();
      final keep = selectId ?? _selectedSourceId;
      _selectedSourceId = _sources.any((source) => source.id == keep)
          ? keep
          : (_sources.isEmpty ? null : _sources.first.id);
      _syncSelectedEntities();
    } else if (result is Error<List<MigrationSource>>) {
      _hasLoadError = true;
    }
  }

  void selectSource(int id) {
    _selectedSourceId = id;
    _compatReport = null;
    _connectionTest = null;
    _lastRun = null;
    _issues = const [];
    _syncSelectedEntities();
    notifyListeners();
  }

  void _syncSelectedEntities() {
    _selectedEntities
      ..clear()
      ..addAll(supportedEntitiesForSelected);
  }

  void toggleEntity(String entityType, bool selected) {
    if (selected) {
      _selectedEntities.add(entityType);
    } else {
      _selectedEntities.remove(entityType);
    }
    notifyListeners();
  }

  void setProductsWithoutQuantities(bool value) {
    _productsWithoutQuantities = value;
    notifyListeners();
  }

  // --- mutations -------------------------------------------------------
  Future<bool> saveSource({
    int? sourceId,
    required String name,
    required String systemKey,
    required String transportKind,
    String? host,
    int? port,
    String? databaseName,
    String? username,
    String? password,
    Map<String, Object?>? extraOptions,
  }) async {
    return await _mutate(() async {
          final draft = MigrationSourceDraft(
            name: name,
            systemKey: systemKey,
            transportKind: transportKind,
            host: host,
            port: port,
            databaseName: databaseName,
            username: username,
            password: password,
            extraOptions: extraOptions,
          );
          final result = sourceId == null
              ? await _repository.createSource(draft)
              : await _repository.updateSource(sourceId, draft);
          switch (result) {
            case Ok<MigrationSource>():
              _compatReport = null;
              _connectionTest = null;
              await _refreshSources(selectId: result.value.id);
              return true;
            case Error<MigrationSource>():
              _failMutation(result.exception);
              return false;
          }
        }) ??
        false;
  }

  Future<bool> deleteSource(int id) async {
    return await _mutate(() async {
          final result = await _repository.deleteSource(id);
          switch (result) {
            case Ok<void>():
              await _refreshSources();
              return true;
            case Error<void>():
              _failMutation(result.exception);
              return false;
          }
        }) ??
        false;
  }

  /// Broadcasts on the LAN and returns reachable SQL Server instances. This is a
  /// discovery probe only — no credentials are sent and no source is touched.
  /// The caller lets the operator pick one to prefill host/port.
  Future<List<DiscoveredServer>?> discoverServers() async {
    if (_isDiscovering) return null;
    _isDiscovering = true;
    _hasMutationError = false;
    notifyListeners();
    final result = await _repository.discoverServers();
    List<DiscoveredServer>? servers;
    switch (result) {
      case Ok<List<DiscoveredServer>>():
        servers = result.value;
      case Error<List<DiscoveredServer>>():
        _failMutation(result.exception);
    }
    _isDiscovering = false;
    notifyListeners();
    return servers;
  }

  Future<MigrationConnectionTest?> testConnection() async {
    final source = selectedSource;
    if (source == null || _isTesting) return null;
    _isTesting = true;
    _hasMutationError = false;
    _connectionTest = null;
    notifyListeners();
    final result = await _repository.testConnection(source.id);
    MigrationConnectionTest? test;
    switch (result) {
      case Ok<MigrationConnectionTest>():
        test = result.value;
        _connectionTest = test;
      case Error<MigrationConnectionTest>():
        _failMutation(result.exception);
    }
    _isTesting = false;
    notifyListeners();
    return test;
  }

  Future<CompatibilityReport?> checkCompatibility() async {
    final source = selectedSource;
    if (source == null || _isChecking) return null;
    _isChecking = true;
    _hasMutationError = false;
    notifyListeners();
    final result = await _repository.checkCompatibility(source.id);
    CompatibilityReport? report;
    switch (result) {
      case Ok<CompatibilityReport>():
        report = result.value;
        _compatReport = report;
        // Refresh the source so its persisted status badge updates too.
        await _refreshSources(selectId: source.id);
      case Error<CompatibilityReport>():
        _failMutation(result.exception);
    }
    _isChecking = false;
    notifyListeners();
    return report;
  }

  Future<MigrationRun?> startRun({required bool dryRun}) async {
    final source = selectedSource;
    if (source == null || _isStartingRun || (_activeRun?.isActive ?? false)) {
      return null;
    }
    _isStartingRun = true;
    _hasMutationError = false;
    notifyListeners();
    final result = await _repository.startRun(
      sourceId: source.id,
      mode: dryRun ? 'dry_run' : 'import',
      entities: _selectedEntities.toList(),
      options: {'products_without_quantities': _productsWithoutQuantities},
    );
    MigrationRun? run;
    switch (result) {
      case Ok<MigrationRun>():
        run = result.value;
        _activeRun = run;
        _lastRun = null;
        _issues = const [];
        trackAuditEvent(
          _analyticsEngine,
          name: 'migration.run.started',
          entityType: 'migration_source',
          entityId: source.id,
          attributes: {'mode': run.mode},
        );
        _startPolling();
      case Error<MigrationRun>():
        _failMutation(result.exception);
    }
    _isStartingRun = false;
    notifyListeners();
    return run;
  }

  Future<void> loadIssues({String? severity}) async {
    final run = currentRun;
    if (run == null) return;
    _isLoadingIssues = true;
    notifyListeners();
    final result = await _repository.loadIssues(run.id, severity: severity);
    if (result is Ok<MigrationIssuePage>) {
      _issues = result.value.issues;
    }
    _isLoadingIssues = false;
    notifyListeners();
  }

  // --- polling ---------------------------------------------------------
  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(_pollInterval, (_) => _pollActiveRun());
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  Future<void> _pollActiveRun() async {
    final active = _activeRun;
    if (active == null) {
      _stopPolling();
      return;
    }
    final result = await _repository.loadRun(active.id);
    if (result is! Ok<MigrationRun>) {
      return; // transient; keep polling
    }
    final run = result.value;
    if (run.isTerminal) {
      _activeRun = null;
      _lastRun = run;
      _stopPolling();
      await _refreshSources(selectId: _selectedSourceId);
    } else {
      _activeRun = run;
    }
    notifyListeners();
  }

  void acknowledgeMutationError() {
    _hasMutationError = false;
    _mutationMessage = null;
  }

  // --- helpers ---------------------------------------------------------
  Future<T?> _mutate<T>(Future<T?> Function() operation) async {
    if (_isMutating) return null;
    _isMutating = true;
    _hasMutationError = false;
    notifyListeners();
    try {
      return await operation();
    } finally {
      _isMutating = false;
      notifyListeners();
    }
  }

  void _failMutation(Object exception) {
    _hasMutationError = true;
    _mutationMessage = exception.toString();
  }

  @override
  void dispose() {
    _stopPolling();
    super.dispose();
  }
}
