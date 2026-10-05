import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show DateTimeRange;

import '../../../core/result.dart';
import '../../../data/models/consignment.dart';
import '../../../data/models/consignor_statement.dart';
import '../../../data/repositories/consignment_repository.dart';
import 'consignment_document_printer.dart';

/// كشف حساب صاحب الأمانة — one consignor, every agreement, every article.
///
/// Owns no money of its own: the headline arrives with every page, and every
/// action here re-reads rather than adjusting a local total. Lives as long as
/// the screen that opened it.
class ConsignorStatementViewModel extends ChangeNotifier {
  ConsignorStatementViewModel(
    this._repository, {
    required this.consignorId,
    String consignorName = '',
    ConsignmentDocumentPrinter printer = const ConsignmentDocumentPrinter(),
  }) : _printer = printer,
       _statement = ConsignorStatement(
         consignorId: consignorId,
         consignorName: consignorName,
       );

  final ConsignmentRepository _repository;
  final ConsignmentDocumentPrinter _printer;
  final int consignorId;

  /// The most a print reads, in pages of the server's size. A consignor with
  /// more articles than this is printed in part rather than freezing the till.
  static const maxPrintPages = 20;

  ConsignorStatement _statement;
  List<ConsignorStatementLine> _lines = const [];
  int _count = 0;
  int _page = 1;
  bool _hasMore = false;
  bool _hasLoaded = false;
  bool _isLoading = false;
  bool _isLoadingMore = false;
  bool _loadMoreFailed = false;
  bool _hasError = false;
  bool _isDisbursing = false;
  bool _isPrinting = false;
  DateTimeRange? _period;
  ConsignorLineFilter _filter = ConsignorLineFilter.all;
  final Set<int> _selected = <int>{};
  int _generation = 0;

  ConsignorStatement get statement => _statement;
  ConsignorStatementFigures get figures => _statement.figures;
  List<ConsignorStatementLine> get lines => _lines;
  int get count => _count;
  bool get hasMore => _hasMore;
  bool get hasLoaded => _hasLoaded;
  bool get isLoading => _isLoading;
  bool get isLoadingMore => _isLoadingMore;
  bool get loadMoreFailed => _loadMoreFailed;
  bool get hasError => _hasError;
  bool get isDisbursing => _isDisbursing;
  bool get isPrinting => _isPrinting;
  DateTimeRange? get period => _period;
  ConsignorLineFilter get filter => _filter;
  Set<int> get selected => Set.unmodifiable(_selected);

  /// The awaiting lines on screen — the ones a payout can settle.
  List<ConsignorStatementLine> get awaitingLines => [
    for (final line in _lines)
      if (line.isAwaiting) line,
  ];

  /// What the selected lines come to, net of any advance: what the voucher
  /// pays.
  double get selectedTotal {
    var total = 0.0;
    for (final line in _lines) {
      if (_selected.contains(line.unitId)) {
        total += line.netDue;
      }
    }
    return total;
  }

  bool get canDisburse => _selected.isNotEmpty && !_isDisbursing;

  Future<void> load() async {
    final generation = ++_generation;
    _isLoading = true;
    _loadMoreFailed = false;
    notifyListeners();
    final result = await _fetch(page: 1);
    if (generation != _generation) {
      return;
    }
    switch (result) {
      case Ok<ConsignorStatementPage>(:final value):
        _apply(value, append: false);
        _page = 1;
        _hasError = false;
        _hasLoaded = true;
        _selected.removeWhere(
          (id) =>
              !value.lines.any((line) => line.unitId == id && line.isAwaiting),
        );
      case Error<ConsignorStatementPage>():
        _hasError = true;
    }
    _isLoading = false;
    notifyListeners();
  }

  /// The next page, appended. A failed page keeps [hasMore] and offers a
  /// retry: one dropped request must not end the list (`load-more-dead-end`).
  Future<void> loadMore() async {
    if (_isLoadingMore || _isLoading || !_hasMore) {
      return;
    }
    final generation = _generation;
    _isLoadingMore = true;
    _loadMoreFailed = false;
    notifyListeners();
    final result = await _fetch(page: _page + 1);
    if (generation != _generation) {
      return;
    }
    switch (result) {
      case Ok<ConsignorStatementPage>(:final value):
        _page += 1;
        _apply(value, append: true);
      case Error<ConsignorStatementPage>():
        _loadMoreFailed = true;
    }
    _isLoadingMore = false;
    notifyListeners();
  }

  void setPeriod(DateTimeRange? period) {
    if (_period == period) {
      return;
    }
    _period = period;
    unawaited(load());
  }

  void setFilter(ConsignorLineFilter filter) {
    if (_filter == filter) {
      return;
    }
    _filter = filter;
    unawaited(load());
  }

  void toggle(ConsignorStatementLine line) {
    if (!line.isAwaiting) {
      return;
    }
    if (!_selected.remove(line.unitId)) {
      _selected.add(line.unitId);
    }
    notifyListeners();
  }

  /// Every awaiting line on screen: the ordinary visit, where the consignor
  /// collects for everything that sold.
  void selectAllAwaiting() {
    _selected
      ..clear()
      ..addAll(awaitingLines.map((line) => line.unitId));
    notifyListeners();
  }

  void clearSelection() {
    if (_selected.isEmpty) {
      return;
    }
    _selected.clear();
    notifyListeners();
  }

  /// Hand over the money for the selected lines, on one voucher.
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

  Future<bool> resendSaleSms(ConsignorStatementLine line) async {
    final result = await _repository.resendSaleSms(line.unitId);
    return result is Ok<bool> && result.value;
  }

  Future<bool> printPayout(ConsignorPayout payout) =>
      _printer.printPayout(payout);

  /// Print the consignor's copy: every line under the current filters, not
  /// only the pages scrolled so far.
  Future<bool> printStatement() async {
    if (_isPrinting) {
      return false;
    }
    _isPrinting = true;
    notifyListeners();
    try {
      final lines = <ConsignorStatementLine>[];
      var statement = _statement;
      for (var page = 1; page <= maxPrintPages; page++) {
        final result = await _fetch(page: page);
        if (result is! Ok<ConsignorStatementPage>) {
          return false;
        }
        statement = result.value.statement;
        lines.addAll(result.value.lines);
        if (!result.value.hasNext) {
          break;
        }
      }
      return await _printer.printStatement(
        statement: statement,
        lines: lines,
        start: _period?.start,
        end: _period?.end,
      );
    } finally {
      _isPrinting = false;
      notifyListeners();
    }
  }

  Future<Result<ConsignorStatementPage>> _fetch({required int page}) {
    return _repository.loadStatement(
      consignorId,
      start: _period?.start,
      end: _period?.end,
      states: _filter.states,
      page: page,
    );
  }

  void _apply(ConsignorStatementPage value, {required bool append}) {
    _statement = value.statement;
    _lines = append ? [..._lines, ...value.lines] : value.lines;
    _count = value.count;
    _hasMore = value.hasNext;
  }
}
