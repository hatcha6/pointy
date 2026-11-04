import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/bulk_price_rule.dart';
import '../../../data/models/bulk_tracking_change.dart';
import '../../../data/repositories/catalog_repository.dart';
import 'bulk_price_filter_editing.dart';

/// Which slice of the preview the list shows.
enum BulkTrackingListView { change, blocked, same }

/// Moving products onto expiry tracking: a scope (the same rule tree the bulk
/// price editor builds), what to change, a server preview, then an apply sent
/// in batches so thirteen thousand products never ride in one request.
///
/// Apply is safe to repeat on the server, so a network failure just stops the
/// run: [remainingCount] products are still to send and [apply] picks up there.
class BulkTrackingViewModel extends ChangeNotifier
    implements BulkPriceFilterEditing {
  BulkTrackingViewModel({
    required CatalogRepository catalogRepository,
    List<BulkPriceRef> selectedProducts = const [],
    this.batchSize = 100,
    this.onChanged,
  }) : _catalogRepository = catalogRepository {
    _scopeAll = selectedProducts.isEmpty;
    _filter = BulkPriceGroup(
      key: _nextKey(),
      children: [
        if (selectedProducts.isNotEmpty)
          BulkPriceCondition(
            key: _nextKey(),
            field: BulkPriceField.product,
            operator: BulkPriceOperator.inList,
            refs: selectedProducts,
          ),
      ],
    );
  }

  final CatalogRepository _catalogRepository;

  /// Product ids per apply call. The server takes at most 200.
  final int batchSize;

  /// Runs once an apply run ends having changed something, whole or cut short.
  final VoidCallback? onChanged;

  int _keySeed = 0;
  String _nextKey() => 'n${_keySeed++}';

  late BulkPriceGroup _filter;
  bool _scopeAll = true;
  BulkTrackingAction _action = const BulkTrackingAction();

  BulkTrackingPreview? _preview;
  String? _previewKey;
  bool _isPreviewing = false;
  bool _previewFailed = false;
  int _previewGeneration = 0;
  BulkTrackingListView _view = BulkTrackingListView.change;
  bool _excludeEmptyShelf = true;

  bool _isApplying = false;
  bool _applyInterrupted = false;
  List<int> _queue = const [];
  int _sent = 0;
  BulkTrackingApplyResult _result = const BulkTrackingApplyResult();
  bool _hasResult = false;
  Map<int, String> _names = const {};
  bool _disposed = false;

  BulkPriceGroup get filter => _filter;
  bool get scopeAll => _scopeAll;
  BulkTrackingAction get action => _action;
  BulkTrackingPreview? get preview => _preview;
  bool get isPreviewing => _isPreviewing;
  bool get previewFailed => _previewFailed;
  BulkTrackingListView get view => _view;
  bool get excludeEmptyShelf => _excludeEmptyShelf;
  bool get isApplying => _isApplying;

  /// The run stopped on a network failure and can be resumed.
  bool get applyInterrupted => _applyInterrupted;
  BulkTrackingApplyResult get result => _result;

  /// An apply has run (or is running) and its numbers are on screen.
  bool get hasResult => _hasResult;

  /// The name a product had on the preview, for naming it in the result.
  String nameFor(int product) => _names[product] ?? '#$product';

  int get totalToApply => _sent + _queue.length;
  int get sentCount => _sent;
  int get remainingCount => _queue.length;
  double get progress => totalToApply == 0 ? 0 : _sent / totalToApply;

  BulkPriceGroup get _spec =>
      _scopeAll ? _filter.copyWith(children: const []) : _filter;

  /// What is actually sent: with "all products" chosen the conditions stay in
  /// the draft (switching back restores them) but are not part of the request.
  Map<String, Object?> get effectiveFilterJson => _spec.toJson();

  int get invalidCount => _spec.invalidCount;

  bool get isComplete => invalidCount == 0 && _action.isComplete;

  String get _requestKey => jsonEncode({
    'filter': effectiveFilterJson,
    'action': _action.toJson(filter: const {}),
  });

  /// The preview on screen describes the choices on screen.
  bool get isPreviewFresh =>
      _preview != null && _previewKey == _requestKey && !_isPreviewing;

  Iterable<BulkTrackingRow> get rows =>
      switch (_view) {
        BulkTrackingListView.change => _preview?.byOutcome(
          BulkTrackingOutcome.change,
        ),
        BulkTrackingListView.blocked => _preview?.byOutcome(
          BulkTrackingOutcome.blocked,
        ),
        BulkTrackingListView.same => _preview?.byOutcome(
          BulkTrackingOutcome.same,
        ),
      } ??
      const [];

  /// Products an apply would send: those that change, less the ones with no
  /// recorded stock when the owner chose to leave those out.
  List<int> get idsToApply => [
    for (final row
        in _preview?.byOutcome(BulkTrackingOutcome.change) ??
            const <BulkTrackingRow>[])
      if (!(_excludeEmptyShelf && row.isEmptyShelf)) row.product,
  ];

  int get skippedEmptyShelf => _excludeEmptyShelf
      ? (_preview?.byOutcome(BulkTrackingOutcome.change) ??
                const <BulkTrackingRow>[])
            .where((row) => row.isEmptyShelf)
            .length
      : 0;

  bool get canApply => isPreviewFresh && !_isApplying && idsToApply.isNotEmpty;

  // -- scope ------------------------------------------------------------------

  void setScopeAll(bool value) {
    if (_scopeAll == value) return;
    _scopeAll = value;
    if (!value && _filter.isEmpty) {
      _filter = _filter.copyWith(children: [_defaultCondition()]);
    }
    _changed();
  }

  BulkPriceCondition _defaultCondition() => BulkPriceCondition(
    key: _nextKey(),
    field: BulkPriceField.category,
    operator: BulkPriceOperator.inList,
  );

  @override
  void addCondition(String groupKey) => _updateNode(
    groupKey,
    (node) => node is BulkPriceGroup
        ? node.copyWith(children: [...node.children, _defaultCondition()])
        : node,
  );

  @override
  void addGroup(String groupKey) => _updateNode(
    groupKey,
    (node) => node is BulkPriceGroup
        ? node.copyWith(
            children: [
              ...node.children,
              BulkPriceGroup(
                key: _nextKey(),
                match: node.match == BulkPriceMatch.all
                    ? BulkPriceMatch.any
                    : BulkPriceMatch.all,
                children: [_defaultCondition()],
              ),
            ],
          )
        : node,
  );

  @override
  void setGroupMatch(String groupKey, BulkPriceMatch match) => _updateNode(
    groupKey,
    (node) => node is BulkPriceGroup ? node.copyWith(match: match) : node,
  );

  @override
  void updateCondition(
    String key,
    BulkPriceCondition Function(BulkPriceCondition condition) update,
  ) => _updateNode(
    key,
    (node) => node is BulkPriceCondition ? update(node) : node,
  );

  @override
  void removeNode(String key) => _updateNode(key, (_) => null);

  void _updateNode(String key, BulkPriceNode? Function(BulkPriceNode) update) {
    _filter = _prune(_filter.updateNode(key, update));
    // Removing the last condition leaves nothing to narrow by: say so.
    if (_filter.isEmpty) _scopeAll = true;
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

  // -- what to change ----------------------------------------------------------

  void setTracking(BulkTrackingTarget tracking) {
    _action = _action.copyWith(tracking: tracking);
    _changed();
  }

  void setReminderMode(BulkReminderMode mode) {
    _action = _action.copyWith(reminderMode: mode);
    _changed();
  }

  void setReminderDate(DateTime? date) {
    _action = _action.copyWith(reminderDate: () => date);
    _changed();
  }

  void _changed() {
    _hasResult = false;
    _applyInterrupted = false;
    _queue = const [];
    _sent = 0;
    notifyListeners();
  }

  // -- preview ----------------------------------------------------------------

  void setView(BulkTrackingListView view) {
    if (_view == view) return;
    _view = view;
    notifyListeners();
  }

  void setExcludeEmptyShelf(bool value) {
    if (_excludeEmptyShelf == value) return;
    _excludeEmptyShelf = value;
    notifyListeners();
  }

  Future<void> refreshPreview() async {
    if (!isComplete || _disposed || _isApplying) return;
    final generation = ++_previewGeneration;
    final key = _requestKey;
    _isPreviewing = true;
    _previewFailed = false;
    _hasResult = false;
    notifyListeners();
    final result = await _catalogRepository.previewBulkTrackingChange(
      action: _action,
      filter: _spec,
    );
    if (_disposed || generation != _previewGeneration) return;
    _isPreviewing = false;
    switch (result) {
      case Ok(value: final preview):
        _preview = preview;
        _previewKey = key;
        // Land on the list that has something in it.
        if (preview.summary.change == 0) {
          _view = preview.summary.blocked > 0
              ? BulkTrackingListView.blocked
              : BulkTrackingListView.same;
        } else {
          _view = BulkTrackingListView.change;
        }
      case Error():
        _previewFailed = true;
    }
    notifyListeners();
  }

  // -- apply -------------------------------------------------------------------

  /// Sends the products in batches, one after another. Called again after an
  /// interruption it carries on with what is left.
  Future<void> apply() async {
    if (_isApplying) return;
    if (!_applyInterrupted) {
      if (!canApply) return;
      _queue = idsToApply;
      _names = {
        for (final row in _preview?.rows ?? const <BulkTrackingRow>[])
          row.product: row.name,
      };
      _sent = 0;
      _result = const BulkTrackingApplyResult();
    } else if (_queue.isEmpty) {
      return;
    }
    _hasResult = true;
    _isApplying = true;
    _applyInterrupted = false;
    notifyListeners();

    final action = _action;
    final filter = _spec;
    var anyDone = false;
    while (_queue.isNotEmpty && !_disposed) {
      final end = _queue.length < batchSize ? _queue.length : batchSize;
      final batch = _queue.sublist(0, end);
      final response = await _catalogRepository.applyBulkTrackingChange(
        action: action,
        filter: filter,
        productIds: batch,
      );
      if (_disposed) return;
      switch (response) {
        case Ok(value: final batchResult):
          _result = _result.plus(batchResult);
          _queue = _queue.sublist(end);
          _sent += end;
          anyDone = anyDone || batchResult.done > 0;
        case Error():
          _applyInterrupted = true;
      }
      notifyListeners();
      if (_applyInterrupted) break;
    }
    _isApplying = false;
    // What was on the preview is history now.
    if (!_applyInterrupted) {
      _preview = null;
      _previewKey = null;
    }
    notifyListeners();
    if (anyDone || _result.done > 0) onChanged?.call();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
