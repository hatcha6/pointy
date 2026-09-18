import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/consignment.dart';
import '../../../data/repositories/consignment_repository.dart';

/// مستحقات الأمانات, and the position behind it.
///
/// Holds no money of its own: the payable, the commission and the custody
/// exposure all arrive computed, and every action here re-reads rather than
/// adjusting a local number. A screen that decremented its own total after a
/// payout would be a screen that can disagree with the drawer.
class ConsignmentViewModel extends ChangeNotifier {
  ConsignmentViewModel(this._repository);

  final ConsignmentRepository _repository;

  ConsignmentPayablePage _payables = const ConsignmentPayablePage();
  ConsignmentPosition _position = const ConsignmentPosition();
  bool _isLoading = false;
  bool _isDisbursing = false;
  bool _hasError = false;
  String _search = '';
  final Set<int> _selected = <int>{};

  List<ConsignmentPayable> get payables {
    final term = _search.trim().toLowerCase();
    if (term.isEmpty) {
      return _payables.rows;
    }
    return [
      for (final row in _payables.rows)
        if (row.consignorName.toLowerCase().contains(term) ||
            row.consignorPhone.contains(term) ||
            row.code.toLowerCase().contains(term) ||
            row.productName.toLowerCase().contains(term))
          row,
    ];
  }

  ConsignmentPosition get position => _position;
  bool get isLoading => _isLoading;
  bool get isDisbursing => _isDisbursing;
  bool get hasError => _hasError;
  bool get isEmpty => _payables.isEmpty;
  String get search => _search;
  double get totalDue => _payables.totalDue;

  Set<int> get selected => Set.unmodifiable(_selected);

  /// What the selected rows come to. One consignor collecting for three of
  /// their articles signs one voucher, so the screen adds them up before the
  /// drawer opens rather than after.
  double get selectedTotal {
    var total = 0.0;
    for (final row in _payables.rows) {
      if (_selected.contains(row.unitId)) {
        total += row.payoutDue;
      }
    }
    return total;
  }

  /// A voucher covers one consignor. Selecting a second one's article is not a
  /// mistake worth a dialog — it simply cannot be paid on the same page.
  bool get selectionIsOneConsignor {
    final owners = <int?>{};
    for (final row in _payables.rows) {
      if (_selected.contains(row.unitId)) {
        owners.add(row.consignorId);
      }
    }
    return owners.length <= 1;
  }

  bool get canDisburse =>
      _selected.isNotEmpty && selectionIsOneConsignor && !_isDisbursing;

  Future<void> load() async {
    _isLoading = true;
    notifyListeners();
    final results = await Future.wait([
      _repository.loadPayables(),
      _repository.loadPosition(),
    ]);
    switch (results[0]) {
      case Ok<ConsignmentPayablePage>(:final value):
        _payables = value;
        _hasError = false;
        _selected.removeWhere(
          (id) => !value.rows.any((row) => row.unitId == id),
        );
      case Error<ConsignmentPayablePage>():
        _hasError = true;
      default:
        break;
    }
    if (results[1] case Ok<ConsignmentPosition>(:final value)) {
      _position = value;
    }
    _isLoading = false;
    notifyListeners();
  }

  void setSearch(String term) {
    if (_search == term) {
      return;
    }
    _search = term;
    notifyListeners();
  }

  void toggle(ConsignmentPayable row) {
    if (!_selected.remove(row.unitId)) {
      // Picking a different consignor replaces the selection rather than
      // refusing it: the cashier has moved on to the next person at the
      // counter, and making them clear the last one first is friction for
      // nothing.
      if (_selected.isNotEmpty && !_sameConsignor(row)) {
        _selected.clear();
      }
      _selected.add(row.unitId);
    }
    notifyListeners();
  }

  bool _sameConsignor(ConsignmentPayable row) {
    for (final existing in _payables.rows) {
      if (_selected.contains(existing.unitId)) {
        return existing.consignorId == row.consignorId;
      }
    }
    return true;
  }

  void selectAllFor(ConsignmentPayable row) {
    _selected
      ..clear()
      ..addAll([
        for (final other in _payables.rows)
          if (other.consignorId == row.consignorId) other.unitId,
      ]);
    notifyListeners();
  }

  void clearSelection() {
    if (_selected.isEmpty) {
      return;
    }
    _selected.clear();
    notifyListeners();
  }

  /// Hand over the money. Returns the voucher, or null when it was refused —
  /// the caller shows the reason, because a refusal here is usually "no open
  /// till", which is a thing the cashier can fix.
  Future<ConsignorPayout?> disburse({String method = 'cash'}) async {
    if (!canDisburse) {
      return null;
    }
    _isDisbursing = true;
    notifyListeners();
    final ids = _selected.toList()..sort();
    final result = await _repository.disburse(
      unitId: ids.first,
      alsoUnitIds: ids.skip(1).toList(growable: false),
      method: method,
    );
    _isDisbursing = false;
    switch (result) {
      case Ok<ConsignorPayout>(:final value):
        _selected.clear();
        unawaited(load());
        return value;
      case Error<ConsignorPayout>():
        notifyListeners();
        return null;
    }
  }

  Future<bool> resendSms(ConsignmentPayable row) async {
    final result = await _repository.resendSaleSms(row.unitId);
    return result is Ok<bool> && result.value;
  }
}
