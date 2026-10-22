import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/bulk_price_preview.dart';
import '../../../data/models/bulk_price_rule.dart';
import '../../../data/repositories/catalog_repository.dart';

/// The bulk price editor: a draft [BulkPriceSpec] the owner builds, and a
/// server preview that follows it.
///
/// The preview re-runs on its own a moment after every edit, so the numbers
/// on screen always describe the rules on screen. Applying sends the
/// preview's fingerprint back: the server refuses unless the same rules still
/// produce exactly the prices that were shown — see `bulk_pricing.py`.
class BulkPriceEditorViewModel extends ChangeNotifier {
  BulkPriceEditorViewModel({
    required CatalogRepository catalogRepository,
    List<BulkPriceRef> selectedProducts = const [],
    this.previewDebounce = const Duration(milliseconds: 450),
  }) : _catalogRepository = catalogRepository {
    final selection = selectedProducts.isEmpty
        ? null
        : BulkPriceCondition(
            key: _nextKey(),
            field: BulkPriceField.product,
            operator: BulkPriceOperator.inList,
            refs: selectedProducts,
          );
    _scopeAll = selection == null;
    _spec = BulkPriceSpec(
      filter: BulkPriceGroup(key: _nextKey(), children: [?selection]),
      steps: [
        BulkPriceStep(key: _nextKey(), action: BulkPriceAction.increasePercent),
      ],
    );
  }

  final CatalogRepository _catalogRepository;
  final Duration previewDebounce;

  int _keySeed = 0;
  String _nextKey() => 'n${_keySeed++}';

  late BulkPriceSpec _spec;
  bool _scopeAll = true;
  bool _costVisible = false;
  bool _optionsLoaded = false;
  int _maxSteps = 20;

  BulkPricePreview? _preview;
  String? _previewKey;
  bool _isPreviewing = false;
  bool _previewFailed = false;
  bool _isLoadingMore = false;
  BulkPricePreviewView _view = BulkPricePreviewView.changed;
  int _previewGeneration = 0;
  Timer? _debounce;

  bool _isApplying = false;
  BulkPriceChangeRecord? _lastApplied;

  bool _disposed = false;
  bool _dirty = false;

  BulkPriceSpec get spec => _spec;
  bool get scopeAll => _scopeAll;
  bool get costVisible => _costVisible;
  bool get optionsLoaded => _optionsLoaded;
  bool get canAddStep => _spec.steps.length < _maxSteps;
  BulkPricePreview? get preview => _preview;
  bool get isPreviewing => _isPreviewing;
  bool get previewFailed => _previewFailed;
  bool get isLoadingMore => _isLoadingMore;
  BulkPricePreviewView get view => _view;
  bool get isApplying => _isApplying;
  BulkPriceChangeRecord? get lastApplied => _lastApplied;

  /// Rules edited and not applied: leaving would lose them.
  bool get isDirty => _dirty;

  /// What is actually sent: with "all products" chosen, the conditions the
  /// owner built stay in the draft (switching back restores them) but are not
  /// part of the request.
  BulkPriceSpec get effectiveSpec => _scopeAll
      ? _spec.copyWith(filter: _spec.filter.copyWith(children: const []))
      : _spec;

  int get invalidCount =>
      effectiveSpec.invalidCount + (_spec.steps.isEmpty ? 1 : 0);

  bool get isComplete => effectiveSpec.isComplete;

  String get _specKey => jsonEncode(effectiveSpec.toJson());

  /// The preview on screen describes the rules on screen.
  bool get isPreviewFresh =>
      _preview != null && _previewKey == _specKey && !_isPreviewing;

  bool get canApply =>
      isPreviewFresh && !_isApplying && _preview!.summary.changed > 0;

  /// How many products the preview says each step touched, by step index.
  int? stepHits(int index) {
    final counts = _preview?.summary.stepCounts;
    if (counts == null || index >= counts.length || !isPreviewFresh) {
      return null;
    }
    return counts[index];
  }

  Future<void> load() async {
    final result = await _catalogRepository.loadBulkPriceOptions();
    if (_disposed) return;
    if (result case Ok(value: final options)) {
      _costVisible = options.costVisible;
      _maxSteps = options.maxSteps;
    }
    _optionsLoaded = true;
    notifyListeners();
    await refreshPreview();
  }

  // -- scope ------------------------------------------------------------------

  void setScopeAll(bool value) {
    if (_scopeAll == value) return;
    _scopeAll = value;
    if (!value && _spec.filter.isEmpty) {
      _setFilter(_spec.filter.copyWith(children: [_defaultCondition()]));
      return;
    }
    _changed();
  }

  BulkPriceCondition _defaultCondition() => BulkPriceCondition(
    key: _nextKey(),
    field: BulkPriceField.category,
    operator: BulkPriceOperator.inList,
  );

  void _setFilter(BulkPriceGroup filter) {
    _spec = _spec.copyWith(filter: filter);
    _changed();
  }

  // -- conditions (filter tree and every step's own tree) --------------------

  void addCondition(String groupKey) => _updateGroup(
    groupKey,
    (group) =>
        group.copyWith(children: [...group.children, _defaultCondition()]),
  );

  /// A nested group starts with one condition: an empty group would match
  /// everything, which is never what "add a group" means.
  void addGroup(String groupKey) => _updateGroup(
    groupKey,
    (group) => group.copyWith(
      children: [
        ...group.children,
        BulkPriceGroup(
          key: _nextKey(),
          match: group.match == BulkPriceMatch.all
              ? BulkPriceMatch.any
              : BulkPriceMatch.all,
          children: [_defaultCondition()],
        ),
      ],
    ),
  );

  void setGroupMatch(String groupKey, BulkPriceMatch match) =>
      _updateGroup(groupKey, (group) => group.copyWith(match: match));

  void updateCondition(
    String key,
    BulkPriceCondition Function(BulkPriceCondition condition) update,
  ) => _updateNode(
    key,
    (node) => node is BulkPriceCondition ? update(node) : node,
  );

  /// Removes a condition or a nested group. A group left with nothing in it
  /// is removed too, except a step's own condition, which is switched off.
  void removeNode(String key) {
    _updateNode(key, (_) => null);
  }

  void _updateGroup(
    String key,
    BulkPriceGroup Function(BulkPriceGroup group) update,
  ) => _updateNode(key, (node) => node is BulkPriceGroup ? update(node) : node);

  void _updateNode(String key, BulkPriceNode? Function(BulkPriceNode) update) {
    final filter = _prune(_spec.filter.updateNode(key, update));
    final steps = [
      for (final step in _spec.steps)
        if (step.when == null)
          step
        else
          step.copyWith(
            when: () {
              final updated = _prune(step.when!.updateNode(key, update));
              return updated.isEmpty ? null : updated;
            },
          ),
    ];
    _spec = _spec.copyWith(filter: filter, steps: steps);
    // Removing the last condition leaves nothing to narrow by: say so.
    if (filter.isEmpty) _scopeAll = true;
    _changed();
  }

  /// Drops nested groups that lost their last condition.
  BulkPriceGroup _prune(BulkPriceGroup group) {
    final children = <BulkPriceNode>[];
    var changed = false;
    for (final child in group.children) {
      if (child is BulkPriceGroup) {
        final pruned = _prune(child);
        if (pruned.isEmpty) {
          changed = true;
          continue;
        }
        if (!identical(pruned, child)) changed = true;
        children.add(pruned);
      } else {
        children.add(child);
      }
    }
    return changed ? group.copyWith(children: children) : group;
  }

  // -- steps ------------------------------------------------------------------

  void addStep(BulkPriceAction action, {String value = ''}) {
    if (!canAddStep) return;
    _spec = _spec.copyWith(
      steps: [
        ..._spec.steps,
        BulkPriceStep(
          key: _nextKey(),
          action: action,
          value: value,
          direction: action == BulkPriceAction.ending
              ? BulkPriceDirection.up
              : BulkPriceDirection.nearest,
        ),
      ],
    );
    _changed();
  }

  void updateStep(String key, BulkPriceStep Function(BulkPriceStep) update) {
    _spec = _spec.copyWith(
      steps: [
        for (final step in _spec.steps) step.key == key ? update(step) : step,
      ],
    );
    _changed();
  }

  void setStepAction(String key, BulkPriceAction action) => updateStep(
    key,
    (step) => step.copyWith(
      action: action,
      direction: action.hasDirection && !step.action.hasDirection
          ? (action == BulkPriceAction.ending
                ? BulkPriceDirection.up
                : BulkPriceDirection.nearest)
          : null,
    ),
  );

  void setStepConditional(String key, bool conditional) => updateStep(
    key,
    (step) => step.copyWith(
      when: () => conditional
          ? (step.when ??
                BulkPriceGroup(
                  key: _nextKey(),
                  children: [
                    BulkPriceCondition(
                      key: _nextKey(),
                      field: BulkPriceField.price,
                      operator: BulkPriceOperator.lt,
                    ),
                  ],
                ))
          : null,
    ),
  );

  void removeStep(String key) {
    _spec = _spec.copyWith(
      steps: [
        for (final step in _spec.steps)
          if (step.key != key) step,
      ],
    );
    _changed();
  }

  void moveStep(String key, int delta) {
    final steps = [..._spec.steps];
    final index = steps.indexWhere((step) => step.key == key);
    final target = index + delta;
    if (index < 0 || target < 0 || target >= steps.length) return;
    final step = steps.removeAt(index);
    steps.insert(target, step);
    _spec = _spec.copyWith(steps: steps);
    _changed();
  }

  void duplicateStep(String key) {
    if (!canAddStep) return;
    final index = _spec.steps.indexWhere((step) => step.key == key);
    if (index < 0) return;
    final source = _spec.steps[index];
    final copy = BulkPriceStep(
      key: _nextKey(),
      action: source.action,
      value: source.value,
      direction: source.direction,
      when: source.when == null ? null : _cloneGroup(source.when!),
      stop: source.stop,
    );
    _spec = _spec.copyWith(steps: [..._spec.steps]..insert(index + 1, copy));
    _changed();
  }

  BulkPriceGroup _cloneGroup(BulkPriceGroup group) => BulkPriceGroup(
    key: _nextKey(),
    match: group.match,
    children: [
      for (final child in group.children)
        switch (child) {
          BulkPriceGroup() => _cloneGroup(child),
          BulkPriceCondition() => BulkPriceCondition(
            key: _nextKey(),
            field: child.field,
            operator: child.operator,
            value: child.value,
            valueTo: child.valueTo,
            refs: child.refs,
          ),
        },
    ],
  );

  // -- safeguards ------------------------------------------------------------

  void setNeverBelowCost(bool value) {
    _spec = _spec.copyWith(neverBelowCost: value);
    _changed();
  }

  void setPackMode(BulkPricePackMode mode) {
    _spec = _spec.copyWith(packMode: mode);
    _changed();
  }

  // -- preview ----------------------------------------------------------------

  void _changed() {
    _dirty = true;
    notifyListeners();
    _debounce?.cancel();
    if (!isComplete) return;
    _debounce = Timer(previewDebounce, refreshPreview);
  }

  void setView(BulkPricePreviewView view) {
    if (_view == view) return;
    _view = view;
    notifyListeners();
    refreshPreview();
  }

  Future<void> refreshPreview() async {
    _debounce?.cancel();
    if (!isComplete || _disposed) {
      notifyListeners();
      return;
    }
    final generation = ++_previewGeneration;
    final key = _specKey;
    final spec = effectiveSpec;
    _isPreviewing = true;
    _previewFailed = false;
    notifyListeners();
    final result = await _catalogRepository.previewBulkPriceChange(
      spec: spec,
      view: _view,
    );
    // An edit made while this was in flight already asked for a newer one.
    if (_disposed || generation != _previewGeneration) return;
    _isPreviewing = false;
    switch (result) {
      case Ok(value: final preview):
        _preview = preview;
        _previewKey = key;
      case Error():
        _previewFailed = true;
    }
    notifyListeners();
  }

  Future<void> loadMore() async {
    final current = _preview;
    if (current == null || !current.hasMore || _isLoadingMore) return;
    if (!isPreviewFresh) return;
    final generation = _previewGeneration;
    _isLoadingMore = true;
    notifyListeners();
    final result = await _catalogRepository.previewBulkPriceChange(
      spec: effectiveSpec,
      view: _view,
      offset: current.rows.length,
    );
    if (_disposed) return;
    _isLoadingMore = false;
    if (generation == _previewGeneration) {
      if (result case Ok(value: final page)) {
        if (page.fingerprint == current.fingerprint) {
          _preview = current.withMoreRows(page);
        } else {
          // The catalog moved under the preview: start it over.
          unawaited(refreshPreview());
        }
      }
      // A failed page keeps what is shown and leaves "more" on offer.
    }
    notifyListeners();
  }

  // -- apply -------------------------------------------------------------------

  Future<Result<BulkPriceChangeRecord>> apply() async {
    final preview = _preview;
    if (!canApply || preview == null) {
      return Error(const BulkPriceException(BulkPriceFailure.stale));
    }
    _isApplying = true;
    notifyListeners();
    final result = await _catalogRepository.applyBulkPriceChange(
      spec: effectiveSpec,
      fingerprint: preview.fingerprint,
    );
    if (_disposed) return result;
    _isApplying = false;
    if (result case Ok(value: final record)) {
      _lastApplied = record;
      _dirty = false;
    }
    notifyListeners();
    // Applied or refused, the prices on screen are now history: show what the
    // same rules would do from here (after an apply that is "nothing").
    unawaited(refreshPreview());
    return result;
  }

  @override
  void dispose() {
    _disposed = true;
    _debounce?.cancel();
    super.dispose();
  }
}
