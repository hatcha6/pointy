import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import '../../../core/analytics_audit.dart';
import '../../../core/analytics_engine.dart';
import '../../../core/result.dart';
import '../../../data/models/migration.dart';
import '../../../data/repositories/migration_repository.dart';
import '../../../data/services/migration_uploader.dart';

/// How stock on-hand is established when products are imported.
///
/// * [snapshot] — copy the old system's stored quantities as they are.
/// * [reconstruct] — compute on-hand from the transaction history (purchases
///   minus sales); for shops whose stored balances drifted but whose invoices
///   are intact. Requires importing the purchase + sale history.
/// * [none] — import products with no quantities and count physically later.
enum MigrationStockSource {
  snapshot,
  reconstruct,
  none;

  /// The value sent in the run's ``options.stock_source``.
  String get wireValue => name;
}

/// Where the owner is in the migration.
///
/// Derived from server state rather than stored, so closing the page mid-way and
/// coming back lands on the step the work is actually at — which matters when
/// the work is a twenty-minute conversion nobody should have to watch.
enum MigrationStep {
  /// No file yet.
  choose,

  /// Bytes are moving.
  uploading,

  /// The server is converting / reconstructing / identifying.
  preparing,

  /// It failed, and we can say why.
  failed,

  /// Identified, counted, and waiting on the owner's choices.
  review,

  /// A dry run or an import is running.
  running,

  /// The import landed and the file is gone.
  done,
}

/// Drives the Data Migration wizard: pick a file, upload it, watch it be
/// prepared, see what is inside, preview, import, and confirm the file was
/// deleted afterwards.
class MigrationViewModel extends ChangeNotifier {
  MigrationViewModel(this._repository, {AnalyticsEngine? analyticsEngine})
    : _analyticsEngine = analyticsEngine;

  final MigrationRepository _repository;
  final AnalyticsEngine? _analyticsEngine;

  /// Runs finish in seconds or minutes; two seconds is responsive without being
  /// a load on a till that is also serving customers.
  static const _runPollInterval = Duration(seconds: 2);

  /// Preparation is measured in minutes, and its stage detail changes slowly.
  static const _preparePollInterval = Duration(seconds: 3);

  MigrationCatalog? _catalog;
  MigrationSource? _source;
  final Set<String> _selectedEntities = <String>{};
  MigrationStockSource _stockSource = MigrationStockSource.none;
  MigrationRun? _activeRun;
  MigrationRun? _lastRun;
  List<MigrationIssue> _issues = const [];

  PlatformFile? _pickedFile;
  MigrationUploader? _uploader;
  MigrationUploadProgress? _uploadProgress;
  bool _isUploading = false;

  bool _isLoading = false;
  bool _hasLoadError = false;
  bool _isStartingRun = false;
  bool _isLoadingIssues = false;
  bool _isDiscarding = false;
  String? _errorMessage;

  Timer? _pollTimer;

  // --- getters ---------------------------------------------------------
  MigrationCatalog? get catalog => _catalog;
  List<MigrationSystem> get systems => _catalog?.systems ?? const [];
  MigrationUploadConfig get uploadConfig =>
      _catalog?.upload ?? MigrationUploadConfig.fallback;
  MigrationSource? get source => _source;
  PlatformFile? get pickedFile => _pickedFile;
  MigrationUploadProgress? get uploadProgress => _uploadProgress;
  Set<String> get selectedEntities => _selectedEntities;
  MigrationStockSource get stockSource => _stockSource;
  MigrationRun? get activeRun => _activeRun;
  MigrationRun? get lastRun => _lastRun;
  MigrationRun? get currentRun => _activeRun ?? _lastRun;
  List<MigrationIssue> get issues => _issues;

  bool get isLoading => _isLoading;
  bool get hasLoadError => _hasLoadError;
  bool get isUploading => _isUploading;
  bool get isStartingRun => _isStartingRun;
  bool get isLoadingIssues => _isLoadingIssues;
  bool get isDiscarding => _isDiscarding;
  String? get errorMessage => _errorMessage;

  MigrationAnalysis get analysis => _source?.analysis ?? MigrationAnalysis.empty;

  List<String> get supportedEntities => _source?.supportedEntities ?? const [];

  /// The stage list to render: the running job's if there is one, else the
  /// file's preparation history.
  List<MigrationStage> get stages {
    final run = currentRun;
    if (run != null && run.stages.isNotEmpty) return run.stages;
    return _source?.stages ?? const [];
  }

  /// Where the wizard is. Read from state, never stored, so a reopened page
  /// resumes rather than restarts.
  MigrationStep get step {
    if (_isUploading) return MigrationStep.uploading;
    final source = _source;
    if (source == null) return MigrationStep.choose;
    if (source.isPurged) {
      return _lastRun != null && !_lastRun!.isDryRun
          ? MigrationStep.done
          : MigrationStep.choose;
    }
    if (source.isFailed) return MigrationStep.failed;
    if (source.isUploading) return MigrationStep.uploading;
    if (source.isBusy) return MigrationStep.preparing;
    if (_activeRun != null) return MigrationStep.running;
    final last = _lastRun;
    if (last != null && !last.isDryRun && last.succeeded) {
      return MigrationStep.done;
    }
    return MigrationStep.review;
  }

  /// A dry run must have passed cleanly before anything is written for real.
  bool get canImport {
    final run = _lastRun;
    return run != null &&
        run.isDryRun &&
        run.isTerminal &&
        run.totalFailed == 0 &&
        (_source?.isReady ?? false);
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
      await _adoptLatestSource();
    }

    _isLoading = false;
    notifyListeners();
  }

  /// Re-attach to whatever is already in flight on the server.
  ///
  /// Preparing a big file outlives the screen: the owner can close the page,
  /// serve a customer, and come back to a finished conversion. This is what
  /// makes that work.
  Future<void> _adoptLatestSource() async {
    final result = await _repository.loadSources();
    if (result is! Ok<List<MigrationSource>>) {
      _hasLoadError = true;
      return;
    }
    final sources = result.value;
    if (sources.isEmpty) {
      _source = null;
      return;
    }
    // Sources come back newest first; prefer one still in play over a purged
    // one, so a finished migration does not hide a new upload.
    final live = sources.where((source) => !source.isPurged).toList();
    _source = live.isNotEmpty ? live.first : sources.first;
    _syncSelectedEntities();
    if (_source!.isBusy) {
      _startPolling(_preparePollInterval);
    } else {
      // Not only when the source is ready: a *purged* source is a finished
      // migration, and its run is the whole reason the screen has anything to
      // show. Skipping it there dropped the owner back to "pick a file" the
      // moment their import succeeded.
      await _adoptLatestRun();
    }
  }

  Future<void> _adoptLatestRun() async {
    final source = _source;
    if (source == null) return;
    final result = await _repository.loadRuns(sourceId: source.id);
    if (result is! Ok<List<MigrationRun>>) return;
    final runs = result.value;
    if (runs.isEmpty) return;
    final latest = runs.first;
    if (latest.isActive) {
      _activeRun = latest;
      _startPolling(_runPollInterval);
    } else {
      _lastRun = latest;
    }
  }

  void _syncSelectedEntities() {
    _selectedEntities
      ..clear()
      ..addAll(supportedEntities);
  }

  // --- choosing + uploading -------------------------------------------
  /// Opens the file picker, restricted to what the server says it can read.
  Future<PlatformFile?> pickFile() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: uploadConfig.pickerExtensions,
      allowMultiple: false,
      // Never `withData` on desktop: these files are gigabytes and the uploader
      // seeks through them on disk. The web build has no choice, and the picker
      // supplies bytes there regardless.
      withData: kIsWeb,
    );
    final file = result?.files.singleOrNull;
    if (file == null) return null;
    if (file.size > uploadConfig.maxBytes) {
      _errorMessage = 'tooLarge';
      notifyListeners();
      return null;
    }
    _pickedFile = file;
    _errorMessage = null;
    notifyListeners();
    return file;
  }

  /// Uploads the picked file, then asks the server to prepare it.
  Future<bool> startUpload() async {
    final file = _pickedFile;
    if (file == null || _isUploading) return false;

    _isUploading = true;
    _errorMessage = null;
    _uploadProgress = MigrationUploadProgress(
      sentBytes: 0,
      totalBytes: file.size,
      bytesPerSecond: 0,
    );
    final uploader = _repository.newUploader();
    _uploader = uploader;
    notifyListeners();

    final result = await _repository.uploadFile(
      file,
      uploader: uploader,
      resuming: _source?.isUploading ?? false ? _source : null,
      onProgress: (progress) {
        _uploadProgress = progress;
        notifyListeners();
      },
    );

    _isUploading = false;
    _uploader = null;
    switch (result) {
      case Ok<MigrationSource>():
        _source = result.value;
        notifyListeners();
        return await _completeUpload();
      case Error<MigrationSource>():
        // The upload is resumable, not lost: the server kept every byte it
        // acknowledged, so retrying continues from there.
        _errorMessage = result.exception.toString();
        notifyListeners();
        return false;
    }
  }

  Future<bool> _completeUpload() async {
    final source = _source;
    if (source == null) return false;
    final result = await _repository.completeUpload(source.id);
    switch (result) {
      case Ok<MigrationSource>():
        _source = result.value;
        _pickedFile = null;
        _uploadProgress = null;
        trackAuditEvent(
          _analyticsEngine,
          name: 'migration.upload.completed',
          entityType: 'migration_source',
          entityId: source.id,
          attributes: {'size_bytes': '${source.declaredSizeBytes}'},
        );
        _startPolling(_preparePollInterval);
      case Error<MigrationSource>():
        _errorMessage = result.exception.toString();
    }
    notifyListeners();
    return _source?.isBusy ?? false;
  }

  void cancelUpload() {
    _uploader?.cancel();
    _uploader = null;
    _isUploading = false;
    _uploadProgress = null;
    notifyListeners();
  }

  /// Forgets the picked file and any half-finished upload, back to step one.
  Future<void> startOver() async {
    final source = _source;
    _pickedFile = null;
    _uploadProgress = null;
    _activeRun = null;
    _lastRun = null;
    _issues = const [];
    _errorMessage = null;
    _stopPolling();
    if (source != null && !source.isPurged) {
      await discard();
    }
    _source = null;
    notifyListeners();
  }

  /// Deletes the uploaded file from the server now.
  Future<bool> discard() async {
    final source = _source;
    if (source == null || _isDiscarding) return false;
    _isDiscarding = true;
    notifyListeners();
    final result = await _repository.discardSource(source.id);
    var ok = false;
    switch (result) {
      case Ok<MigrationSource>():
        _source = result.value;
        ok = true;
      case Error<MigrationSource>():
        _errorMessage = result.exception.toString();
    }
    _isDiscarding = false;
    notifyListeners();
    return ok;
  }

  // --- choices ---------------------------------------------------------
  void toggleEntity(String entityType, bool selected) {
    if (selected) {
      _selectedEntities.add(entityType);
    } else {
      _selectedEntities.remove(entityType);
    }
    notifyListeners();
  }

  void setStockSource(MigrationStockSource value) {
    _stockSource = value;
    notifyListeners();
  }

  // --- runs ------------------------------------------------------------
  Future<MigrationRun?> startRun({required bool dryRun}) async {
    final source = _source;
    if (source == null || _isStartingRun || (_activeRun?.isActive ?? false)) {
      return null;
    }
    _isStartingRun = true;
    _errorMessage = null;
    notifyListeners();
    final result = await _repository.startRun(
      sourceId: source.id,
      mode: dryRun ? 'dry_run' : 'import',
      entities: _selectedEntities.toList(),
      options: {'stock_source': _stockSource.wireValue},
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
        _startPolling(_runPollInterval);
      case Error<MigrationRun>():
        _errorMessage = result.exception.toString();
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
  void _startPolling(Duration interval) {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(interval, (_) => _poll());
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  Future<void> _poll() async {
    final run = _activeRun;
    if (run != null) {
      await _pollRun(run);
      return;
    }
    final source = _source;
    if (source != null && source.isBusy) {
      await _pollSource(source);
      return;
    }
    _stopPolling();
  }

  Future<void> _pollSource(MigrationSource source) async {
    final result = await _repository.loadSource(source.id);
    if (result is! Ok<MigrationSource>) {
      return; // transient; keep polling
    }
    _source = result.value;
    if (!_source!.isBusy) {
      _stopPolling();
      _syncSelectedEntities();
    }
    notifyListeners();
  }

  Future<void> _pollRun(MigrationRun run) async {
    final result = await _repository.loadRun(run.id);
    if (result is! Ok<MigrationRun>) {
      return; // transient; keep polling
    }
    final updated = result.value;
    if (updated.isTerminal) {
      _activeRun = null;
      _lastRun = updated;
      _stopPolling();
      // A clean import deletes the file — refresh so the screen can say so.
      final source = _source;
      if (source != null) {
        final refreshed = await _repository.loadSource(source.id);
        if (refreshed is Ok<MigrationSource>) _source = refreshed.value;
      }
    } else {
      _activeRun = updated;
    }
    notifyListeners();
  }

  void acknowledgeError() {
    _errorMessage = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _stopPolling();
    _uploader?.cancel();
    super.dispose();
  }
}
