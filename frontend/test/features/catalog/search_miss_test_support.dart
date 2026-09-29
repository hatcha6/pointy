import 'dart:async';

import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/search_miss.dart';
import 'package:pointy_frontend/src/data/repositories/search_miss_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';

/// A worklist row with the fields a test cares about.
SearchMiss miss(
  int id,
  String term, {
  int count = 1,
  SearchMissStatus status = SearchMissStatus.open,
  SearchMissSurface surface = SearchMissSurface.pos,
  DateTime? lastSeenAt,
  int? productId,
  String? productName,
}) {
  return SearchMiss(
    id: id,
    term: term,
    normalized: term,
    surface: surface,
    count: count,
    lastSeenAt:
        lastSeenAt ?? DateTime(2026, 9, 29, 10).subtract(Duration(minutes: id)),
    status: status,
    productId: productId,
    productName: productName,
  );
}

/// Answers like the server does: rows filtered by status, sorted most typed
/// first, cut into pages of [pageSize], and changed in place by the actions —
/// so a row resolved on page one moves every later row up, as it would there.
class FakeSearchMissRepository extends SearchMissRepository {
  FakeSearchMissRepository(List<SearchMiss> rows, {this.pageSize = 50})
    : _rows = [...rows],
      super(PosApiService(baseUrl: 'http://pointy.test/api'));

  final List<SearchMiss> _rows;
  final int pageSize;

  /// Every page asked for, in order, with the filter it was asked under.
  final List<({int page, SearchMissFilter filter})> pageRequests = [];

  /// Every action sent, e.g. `resolve 3 -> 42`, `dismiss 3`, `reopen 3`.
  final List<String> actions = [];

  /// Pages that fail while listed here.
  final Set<int> failingPages = {};

  /// Thrown by every action while set.
  Exception? actionError;

  /// Holds page loads until completed, for a test that needs one in flight.
  Completer<void>? loadGate;

  List<SearchMiss> get serverRows => List.unmodifiable(_rows);

  @override
  Future<Result<SearchMissPage>> loadMisses({
    int page = 1,
    SearchMissFilter filter = SearchMissFilter.open,
  }) async {
    pageRequests.add((page: page, filter: filter));
    final gate = loadGate;
    if (gate != null) {
      await gate.future;
    }
    if (failingPages.contains(page)) {
      return Error(Exception('page $page dropped'));
    }
    final visible = _rows.where((row) => filter.includes(row.status)).toList()
      ..sort(_serverOrder);
    final start = (page - 1) * pageSize;
    return Ok(
      SearchMissPage(
        misses: visible.skip(start).take(pageSize).toList(),
        hasMore: start + pageSize < visible.length,
      ),
    );
  }

  @override
  Future<Result<SearchMiss>> resolve(int id, {required int productId}) {
    return _change(
      id,
      'resolve $id -> $productId',
      (row) => _copy(
        row,
        status: SearchMissStatus.resolved,
        productId: productId,
        productName: 'منتج $productId',
      ),
    );
  }

  @override
  Future<Result<SearchMiss>> dismiss(int id) {
    return _change(
      id,
      'dismiss $id',
      (row) => _copy(row, status: SearchMissStatus.dismissed),
    );
  }

  @override
  Future<Result<SearchMiss>> reopen(int id) {
    return _change(
      id,
      'reopen $id',
      (row) => _copy(row, status: SearchMissStatus.open),
    );
  }

  Future<Result<SearchMiss>> _change(
    int id,
    String action,
    SearchMiss Function(SearchMiss row) apply,
  ) async {
    actions.add(action);
    final error = actionError;
    if (error != null) {
      return Error(error);
    }
    final index = _rows.indexWhere((row) => row.id == id);
    if (index == -1) {
      return Error(Exception('no row $id'));
    }
    final updated = apply(_rows[index]);
    _rows[index] = updated;
    return Ok(updated);
  }
}

int _serverOrder(SearchMiss a, SearchMiss b) {
  final byCount = b.count.compareTo(a.count);
  if (byCount != 0) return byCount;
  final bySeen = b.lastSeenAt!.compareTo(a.lastSeenAt!);
  if (bySeen != 0) return bySeen;
  return a.id.compareTo(b.id);
}

SearchMiss _copy(
  SearchMiss row, {
  required SearchMissStatus status,
  int? productId,
  String? productName,
}) {
  final resolved = status == SearchMissStatus.resolved;
  return SearchMiss(
    id: row.id,
    term: row.term,
    normalized: row.normalized,
    surface: row.surface,
    count: row.count,
    lastSeenAt: row.lastSeenAt,
    status: status,
    productId: resolved ? productId : null,
    productName: resolved ? productName : null,
    resolvedAt: status == SearchMissStatus.open ? null : DateTime(2026, 9, 29),
  );
}
