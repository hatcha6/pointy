import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/analytics_audit.dart';
import '../../../core/analytics_engine.dart';
import '../../../core/result.dart';
import '../../../data/models/migration_collapse.dart';
import '../../../data/repositories/migration_repository.dart';

/// Which rows the review list is showing.
enum CollapseFilter {
  /// Least confident first — where a person's time is actually worth spending.
  needsReview,

  /// Everything that becomes an identified article.
  collapsing,

  /// Everything the collapse deliberately left alone.
  kept,
}

/// Drives the §12 review screen: propose, look, disagree, approve.
///
/// Kept apart from [MigrationViewModel] because it is a different kind of work.
/// The migration wizard is a job to watch; this is a document to argue with —
/// its state is a list somebody is editing, not a percentage that is climbing.
class CollapseViewModel extends ChangeNotifier {
  CollapseViewModel(
    this._repository, {
    required this.sourceId,
    AnalyticsEngine? analyticsEngine,
  }) : _analyticsEngine = analyticsEngine;

  final MigrationRepository _repository;
  final AnalyticsEngine? _analyticsEngine;
  final int sourceId;

  /// Reading a catalogue, its purchases and its sales is measured in minutes on
  /// a real export; its stage detail changes slowly.
  static const _pollInterval = Duration(seconds: 3);

  CollapsePlan? _plan;
  List<CollapseCluster> _clusters = const [];
  List<CollapseCandidate> _candidates = const [];
  CollapseFilter _filter = CollapseFilter.needsReview;
  String _search = '';
  String _stemKeyFilter = '';

  bool _isLoading = false;
  bool _isProposing = false;
  bool _isApproving = false;
  bool _isLoadingCandidates = false;
  int? _savingCandidateId;
  String? _errorMessage;
  Timer? _pollTimer;

  // --- getters ---------------------------------------------------------
  CollapsePlan? get plan => _plan;
  CollapseStats get stats => _plan?.stats ?? CollapseStats.empty;
  List<CollapseCluster> get clusters => _clusters;
  List<CollapseCandidate> get candidates => _candidates;
  CollapseFilter get filter => _filter;
  String get search => _search;
  String get stemKeyFilter => _stemKeyFilter;

  bool get isLoading => _isLoading;
  bool get isProposing => _isProposing;
  bool get isApproving => _isApproving;
  bool get isLoadingCandidates => _isLoadingCandidates;
  int? get savingCandidateId => _savingCandidateId;
  String? get errorMessage => _errorMessage;

  bool get hasPlan => _plan != null;
  bool get isBuilding => _plan?.isBuilding ?? false;
  bool get isEditable => _plan?.isEditable ?? false;

  /// Approval is offered once there is something to approve and nothing left
  /// that only a person can settle.
  bool get canApprove =>
      (_plan?.isReady ?? false) && stats.units > 0 && !_isApproving;

  // --- loading ---------------------------------------------------------
  Future<void> load() async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();
    final result = await _repository.loadCollapsePlans(sourceId: sourceId);
    if (result is Ok<List<CollapsePlan>>) {
      // Newest first; a superseded proposal is history, not the answer.
      _plan = result.value
          .where((plan) => !plan.isSuperseded)
          .cast<CollapsePlan?>()
          .firstWhere((plan) => true, orElse: () => null);
    }
    _isLoading = false;
    notifyListeners();
    await _afterPlanChanged();
  }

  /// Asks the server what this catalogue would collapse into. Writes nothing.
  Future<void> propose() async {
    if (_isProposing) return;
    _isProposing = true;
    _errorMessage = null;
    notifyListeners();
    final result = await _repository.proposeCollapse(sourceId);
    switch (result) {
      case Ok<CollapsePlan>():
        _plan = result.value;
        trackAuditEvent(
          _analyticsEngine,
          name: 'migration.collapse.proposed',
          entityType: 'migration_source',
          entityId: sourceId,
        );
        _startPolling();
      case Error<CollapsePlan>():
        _errorMessage = result.exception.toString();
    }
    _isProposing = false;
    notifyListeners();
  }

  Future<void> _afterPlanChanged() async {
    final plan = _plan;
    if (plan == null) return;
    if (plan.isBuilding) {
      _startPolling();
      return;
    }
    _stopPolling();
    if (plan.isFailed) return;
    await Future.wait([_loadClusters(), loadCandidates()]);
  }

  Future<void> _loadClusters() async {
    final plan = _plan;
    if (plan == null) return;
    final result = await _repository.loadCollapseClusters(plan.id);
    if (result is Ok<List<CollapseCluster>>) {
      _clusters = result.value;
      notifyListeners();
    }
  }

  Future<void> loadCandidates() async {
    final plan = _plan;
    if (plan == null) return;
    _isLoadingCandidates = true;
    notifyListeners();
    final result = await _repository.loadCollapseCandidates(
      plan.id,
      decision: switch (_filter) {
        CollapseFilter.needsReview => 'collapse',
        CollapseFilter.collapsing => 'collapse',
        CollapseFilter.kept => 'keep',
      },
      needsReview: _filter == CollapseFilter.needsReview,
      stemKey: _stemKeyFilter.isEmpty ? null : _stemKeyFilter,
      search: _search,
    );
    if (result is Ok<CollapseCandidatePage>) {
      _candidates = result.value.candidates;
    }
    _isLoadingCandidates = false;
    notifyListeners();
  }

  // --- filtering -------------------------------------------------------
  Future<void> setFilter(CollapseFilter value) async {
    if (_filter == value) return;
    _filter = value;
    _stemKeyFilter = '';
    notifyListeners();
    await loadCandidates();
  }

  Future<void> showCluster(String stemKey) async {
    _filter = CollapseFilter.collapsing;
    _stemKeyFilter = stemKey;
    notifyListeners();
    await loadCandidates();
  }

  Future<void> setSearch(String value) async {
    if (_search == value) return;
    _search = value;
    notifyListeners();
    await loadCandidates();
  }

  // --- editing ---------------------------------------------------------
  /// Replaces the parser's answer with a person's, and recounts the headline.
  Future<bool> editCandidate(
    CollapseCandidate candidate,
    Map<String, Object?> changes,
  ) async {
    final plan = _plan;
    if (plan == null || !plan.isEditable || changes.isEmpty) return false;
    _savingCandidateId = candidate.id;
    _errorMessage = null;
    notifyListeners();
    final result = await _repository.updateCollapseCandidate(
      candidate.id,
      changes,
    );
    var ok = false;
    switch (result) {
      case Ok<({CollapseCandidate candidate, CollapseStats stats})>():
        _replace(result.value.candidate);
        _plan = _withStats(plan, result.value.stats);
        ok = true;
      case Error<({CollapseCandidate candidate, CollapseStats stats})>():
        _errorMessage = result.exception.toString();
    }
    _savingCandidateId = null;
    notifyListeners();
    if (ok) await _loadClusters();
    return ok;
  }

  /// Renames a proposed product — and thereby merges it into another.
  Future<bool> renameCluster(String stemKey, String stem) async {
    final plan = _plan;
    if (plan == null || !plan.isEditable) return false;
    _errorMessage = null;
    final result = await _repository.renameCollapseCluster(
      plan.id,
      stemKey: stemKey,
      stem: stem,
    );
    switch (result) {
      case Ok<CollapsePlan>():
        _plan = result.value;
        if (_stemKeyFilter == stemKey) _stemKeyFilter = '';
        notifyListeners();
        await Future.wait([_loadClusters(), loadCandidates()]);
        return true;
      case Error<CollapsePlan>():
        _errorMessage = result.exception.toString();
        notifyListeners();
        return false;
    }
  }

  // --- approval --------------------------------------------------------
  Future<bool> approve() async {
    final plan = _plan;
    if (plan == null || !canApprove) return false;
    _isApproving = true;
    _errorMessage = null;
    notifyListeners();
    final result = await _repository.approveCollapsePlan(plan.id);
    var ok = false;
    switch (result) {
      case Ok<CollapsePlan>():
        _plan = result.value;
        ok = true;
        trackAuditEvent(
          _analyticsEngine,
          name: 'migration.collapse.approved',
          entityType: 'migration_source',
          entityId: sourceId,
          attributes: {'units': '${result.value.stats.units}'},
        );
      case Error<CollapsePlan>():
        _errorMessage = result.exception.toString();
    }
    _isApproving = false;
    notifyListeners();
    return ok;
  }

  void acknowledgeError() {
    _errorMessage = null;
    notifyListeners();
  }

  // --- polling ---------------------------------------------------------
  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(_pollInterval, (_) => _poll());
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  Future<void> _poll() async {
    final plan = _plan;
    if (plan == null || !plan.isBuilding) {
      _stopPolling();
      return;
    }
    final result = await _repository.loadCollapsePlan(plan.id);
    if (result is! Ok<CollapsePlan>) return; // transient; keep polling
    _plan = result.value;
    notifyListeners();
    if (!result.value.isBuilding) {
      _stopPolling();
      await _afterPlanChanged();
    }
  }

  void _replace(CollapseCandidate updated) {
    final next = <CollapseCandidate>[];
    for (final candidate in _candidates) {
      if (candidate.id != updated.id) {
        next.add(candidate);
        continue;
      }
      // A row that no longer matches the list it is in leaves it, rather than
      // sitting in "needs a look" after somebody has just looked at it.
      final belongs = switch (_filter) {
        CollapseFilter.needsReview => updated.needsReview,
        CollapseFilter.collapsing => updated.isCollapsing,
        CollapseFilter.kept => !updated.isCollapsing,
      };
      if (belongs) next.add(updated);
    }
    _candidates = next;
  }

  CollapsePlan _withStats(CollapsePlan plan, CollapseStats stats) {
    return CollapsePlan(
      id: plan.id,
      source: plan.source,
      status: plan.status,
      isEditable: plan.isEditable,
      stages: plan.stages,
      errorMessage: plan.errorMessage,
      assetTypeId: plan.assetTypeId,
      assetTypeName: plan.assetTypeName,
      warrantyDays: plan.warrantyDays,
      stats: stats,
      lowConfidence: plan.lowConfidence,
      builtAt: plan.builtAt,
      approvedAt: plan.approvedAt,
      approvedByUsername: plan.approvedByUsername,
    );
  }

  @override
  void dispose() {
    _stopPolling();
    super.dispose();
  }
}
