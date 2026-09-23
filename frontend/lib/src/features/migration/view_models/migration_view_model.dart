import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import '../../../core/analytics_audit.dart';
import '../../../core/analytics_engine.dart';
import '../../../core/result.dart';
import '../../../data/models/migration.dart';
import '../../../data/models/migration_collapse.dart';
import '../../../data/repositories/migration_repository.dart';
import '../../../data/services/migration_uploader.dart';
import 'collapse_view_model.dart';

/// How stock on-hand is established when products are imported.
///
/// Quantities only. What each product *cost* is a separate decision
/// ([MigrationViewModel.carryCosts]) — it used to hang off this one, and "no
/// quantities" quietly meant "no costs" too.
///
/// * [snapshot] — copy the old system's stored quantities as they are.
/// * [reconstruct] — compute on-hand from the transaction history (purchases
///   minus sales); for shops whose stored balances drifted but whose invoices
///   are intact. Requires importing the purchase + sale history.
/// * [none] — every product starts at zero and the shop counts its shelves.
enum MigrationStockSource {
  snapshot,
  reconstruct,
  none;

  /// The value sent in the run's ``options.stock_source``.
  String get wireValue => name;

  /// `cost_only` was "no quantities, keep the costs" in one word; it reads as
  /// [none] now, with the costs half carried by `carry_costs`.
  static MigrationStockSource fromWire(Object? value) => switch (value) {
    'snapshot' => MigrationStockSource.snapshot,
    'reconstruct' => MigrationStockSource.reconstruct,
    _ => MigrationStockSource.none,
  };
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
  String _scopeKey = '';
  bool _onlyStockedProducts = false;
  bool _carryCosts = true;
  MigrationRun? _activeRun;
  MigrationRun? _lastRun;
  List<MigrationIssue> _issues = const [];
  CollapseViewModel? _collapse;

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

  /// The named scope in play, or the free selection when none is chosen.
  String get scopeKey => _scopeKey.isEmpty ? 'custom' : _scopeKey;
  bool get isCustomScope => scopeKey == 'custom';
  List<MigrationScope> get scopes => _catalog?.scopes ?? const [];

  /// Whether the owner asked to leave behind products the old system says are
  /// out of stock. Only meaningful when the detected system records a quantity.
  bool get onlyStockedProducts => _onlyStockedProducts && canFilterByStock;
  bool get canFilterByStock => _source?.supportsStockFilter ?? false;

  /// The chosen preset attaches to a catalogue an earlier import made (the
  /// costs-only update) rather than importing one. Nothing is closed over
  /// dependencies then — that would bring back the product pass, and on a
  /// second upload the product pass is what duplicates the catalogue.
  bool get attachesToCatalogue {
    final scope = scopes.where((item) => item.key == _scopeKey).firstOrNull;
    return scope?.options['attach_to_catalogue'] == true;
  }

  /// Presets the detected file can actually run. A scope whose entities the
  /// connector cannot produce resolves to nothing, and offering it would be
  /// offering a button that imports nothing.
  List<MigrationScope> get availableScopes => [
    for (final scope in scopes)
      if (!scope.isPreset || (scope.entities?.isNotEmpty ?? true)) scope,
  ];

  /// Entities the selection did not ask for but cannot run without. Shown
  /// before the run, so nothing arrives in the summary unannounced.
  List<String> get impliedEntities {
    final catalog = _catalog;
    if (catalog == null || attachesToCatalogue) return const [];
    final available = supportedEntities.toSet();
    final implied =
        catalog
            .dependenciesOf(_selectedEntities)
            .where((entity) => available.contains(entity))
            .toSet()
          ..removeAll(_selectedEntities);
    return [
      for (final spec in catalog.entities)
        if (implied.contains(spec.entityType)) spec.entityType,
    ];
  }

  /// True when the run will carry each party's balance as it stands *today*
  /// rather than the balance they were opened with — which is the right answer
  /// exactly when none of the documents that moved it are being imported.
  bool get carriesCurrentBalances {
    if (!_selectedEntities.contains('party_balance')) return false;
    const movers = {
      'sale',
      'sale_return',
      'payment',
      'purchase_order',
      'supplier_payment',
    };
    final running = {..._selectedEntities, ...impliedEntities};
    return running.intersection(movers).isEmpty;
  }

  /// The contradiction the server refuses: bringing the invoice history while
  /// dropping the products it references.
  List<String> get stockFilterConflicts {
    if (!onlyStockedProducts) return const [];
    const referencing = {'sale', 'sale_return', 'purchase_order'};
    final running = {..._selectedEntities, ...impliedEntities};
    return running.intersection(referencing).toList()..sort();
  }

  /// Whether each product's cost comes across. On unless the owner turns it
  /// off, and independent of the quantity choice — that pairing is exactly how
  /// a shop that only wanted to count its own shelves lost every cost.
  bool get carryCosts => _carryCosts;

  /// Costs travel on the stock record, so a source without one has none to
  /// offer, and a run without products has nothing to cost.
  bool get canCarryCosts =>
      !attachesToCatalogue &&
      supportedEntities.contains('stock') &&
      _selectedEntities.contains('product');

  /// Money accounts selected without any of the history that moves them. The
  /// file's figure is the box's balance on the first day of that history, so
  /// on its own it reads as years-old cash standing as today's. The server
  /// refuses the combination; this says so before anyone presses a button.
  bool get moneyAccountConflict {
    if (!_selectedEntities.contains('money_account')) return false;
    const movers = {'sale', 'payment', 'expense', 'supplier_payment'};
    final running = {..._selectedEntities, ...impliedEntities};
    return running.intersection(movers).isEmpty;
  }

  /// Whether "start from today's position" is on offer — the one-tap way out
  /// of both conflicts above, which are how a hand-edited list goes wrong.
  bool get offersOpeningPosition =>
      scopes.any((scope) => scope.key == 'opening_position');

  bool get canStartRun => stockFilterConflicts.isEmpty && !moneyAccountConflict;
  MigrationRun? get activeRun => _activeRun;
  MigrationRun? get lastRun => _lastRun;
  MigrationRun? get currentRun => _activeRun ?? _lastRun;
  List<MigrationIssue> get issues => _issues;

  /// The §12 review for the file currently in play, once there is one to
  /// review. Owned here so the wizard can ask whether a collapse was approved
  /// before it starts a run — the collapse is part of the import, not a
  /// separate errand run beside it.
  CollapseViewModel? get collapse => _collapse;

  CollapsePlan? get collapsePlan => _collapse?.plan;

  /// Is a collapse going to happen when this import runs?
  bool get willCollapse => collapsePlan?.isUsable ?? false;

  bool get isLoading => _isLoading;
  bool get hasLoadError => _hasLoadError;
  bool get isUploading => _isUploading;
  bool get isStartingRun => _isStartingRun;
  bool get isLoadingIssues => _isLoadingIssues;
  bool get isDiscarding => _isDiscarding;
  String? get errorMessage => _errorMessage;

  MigrationAnalysis get analysis =>
      _source?.analysis ?? MigrationAnalysis.empty;

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
    _attachCollapse(_source!);
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

  /// Gives the file its own collapse review, and asks the server whether one
  /// was already built for it — a proposal outlives the screen, like everything
  /// else in this wizard.
  void _attachCollapse(MigrationSource source) {
    if (_collapse?.sourceId == source.id) return;
    _collapse?.dispose();
    if (source.isPurged) {
      _collapse = null;
      return;
    }
    final collapse = CollapseViewModel(
      _repository,
      sourceId: source.id,
      analyticsEngine: _analyticsEngine,
    );
    _collapse = collapse;
    collapse.addListener(notifyListeners);
    unawaited(collapse.load());
  }

  void _syncSelectedEntities() {
    // A freshly identified file opens on a named scope rather than on every
    // box ticked: "everything" is a choice too, and saying so out loud is what
    // makes the alternatives visible at all.
    applyScope(_scopeKey.isEmpty ? 'everything' : _scopeKey);
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
        // A cancel the owner asked for is not a failure to report back to them.
        // It used to land in the error banner as the uploader's own English
        // "Upload cancelled", under the screen they had just chosen to leave.
        if (result.exception is! MigrationUploadCancelled) {
          // The upload is resumable, not lost: the server kept every byte it
          // acknowledged, so retrying continues from there.
          _errorMessage = result.exception.toString();
        }
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
  ///
  /// Stops the transfer before anything else. Without that the uploader kept
  /// sending chunks at a source the next line deletes — every one refused, and
  /// `_isUploading` still true, which pins [step] on `uploading` forever. The
  /// screen offering to cancel was the screen you could not leave.
  Future<void> startOver() async {
    final source = _source;
    _uploader?.cancel();
    _uploader = null;
    _isUploading = false;
    _pickedFile = null;
    _uploadProgress = null;
    _activeRun = null;
    _lastRun = null;
    _issues = const [];
    _errorMessage = null;
    _stopPolling();
    _collapse?.removeListener(notifyListeners);
    _collapse?.dispose();
    _collapse = null;
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
  /// Adopt a named scope: its entity set *and* the options that go with it.
  ///
  /// The options travel with the entities deliberately. Leaving the invoice
  /// history behind changes which balance figure each party starts on, and
  /// "products without quantities" has to still carry the costs — neither is
  /// something to leave to whatever the previous scope happened to set.
  void applyScope(String key) {
    _scopeKey = key;
    final scope = scopes.where((item) => item.key == key).firstOrNull;
    final available = supportedEntities.toSet();
    if (scope == null || !scope.isPreset || scope.entities == null) {
      if (_selectedEntities.isEmpty) _selectedEntities.addAll(available);
      notifyListeners();
      return;
    }
    _selectedEntities
      ..clear()
      ..addAll(scope.entities!.where(available.contains));
    final stock = scope.options['stock_source'];
    if (stock != null) _stockSource = MigrationStockSource.fromWire(stock);
    // Everything but an explicit "no" carries costs; `cost_only` said yes.
    _carryCosts = scope.options['carry_costs'] != false;
    notifyListeners();
  }

  void toggleEntity(String entityType, bool selected) {
    if (selected) {
      _selectedEntities.add(entityType);
    } else {
      _selectedEntities.remove(entityType);
    }
    // Hand-editing the list is what "custom" means; pretending the preset is
    // still in force would misdescribe the run about to happen.
    _scopeKey = 'custom';
    notifyListeners();
  }

  void setStockSource(MigrationStockSource value) {
    _stockSource = value;
    _scopeKey = 'custom';
    notifyListeners();
  }

  void setOnlyStockedProducts(bool value) {
    _onlyStockedProducts = value;
    notifyListeners();
  }

  void setCarryCosts(bool value) {
    _carryCosts = value;
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
      scope: isCustomScope ? null : _scopeKey,
      options: {
        'stock_source': _stockSource.wireValue,
        'carry_costs': _carryCosts,
        if (onlyStockedProducts) 'only_stocked_products': true,
        // Only an approved plan travels. The server refuses anything else, and
        // sending an unapproved one would turn a dry run into a 400.
        if (willCollapse) 'collapse_plan': collapsePlan!.id,
      },
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
      _attachCollapse(_source!);
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
    _collapse?.removeListener(notifyListeners);
    _collapse?.dispose();
    super.dispose();
  }
}
