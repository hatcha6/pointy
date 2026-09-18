import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/stock_transfer.dart';
import '../../../data/models/warehouse.dart';
import '../../../data/repositories/warehouse_repository.dart';

/// Moving stock between the shop's places.
///
/// The list is grouped rather than sorted, because the three groups are three
/// different jobs: something on the road is waiting for a person, a draft is
/// waiting for a decision, and a finished transfer is only history.
class TransfersViewModel extends ChangeNotifier {
  TransfersViewModel(this._repository);

  final WarehouseRepository _repository;

  List<StockTransfer> _transfers = const [];
  List<Warehouse> _places = const [];
  bool _isLoading = false;
  bool _isMutating = false;
  bool _hasLoadError = false;

  List<Warehouse> get places => _places;
  bool get isLoading => _isLoading;
  bool get isMutating => _isMutating;
  bool get hasLoadError => _hasLoadError;

  /// Transfers holding goods on the road. These lead the screen because they
  /// are the only ones where stock is somewhere nobody can sell it from.
  List<StockTransfer> get onTheRoad =>
      _transfers.where((transfer) => transfer.isOnTheRoad).toList();

  List<StockTransfer> get drafts =>
      _transfers.where((transfer) => transfer.isDraft).toList();

  List<StockTransfer> get settled => _transfers
      .where((transfer) => !transfer.isOnTheRoad && !transfer.isDraft)
      .toList();

  bool get isEmpty => _transfers.isEmpty;

  /// A transfer needs somewhere to go. One place means there is nothing this
  /// screen can do, and the entry point says so rather than opening onto a
  /// composer that cannot be completed.
  bool get canTransfer => _places.length > 1;

  Future<void> load() async {
    _isLoading = true;
    _hasLoadError = false;
    notifyListeners();

    final transfers = await _repository.loadTransfers();
    switch (transfers) {
      case Ok<List<StockTransfer>>():
        _transfers = transfers.value;
      case Error<List<StockTransfer>>():
        _hasLoadError = true;
    }

    final places = await _repository.loadWarehouses(activeOnly: true);
    if (places case Ok<List<Warehouse>>()) {
      // Transit is where goods sit between two places, never an end of a
      // journey — offering it as a destination would let a shop send stock to
      // the road and leave it there.
      _places = places.value.where((place) => place.sellsFrom).toList();
    }

    _isLoading = false;
    notifyListeners();
  }

  Future<String?> create(
    StockTransferDraft draft, {
    bool sendNow = false,
  }) async {
    return _mutate(() async {
      final created = await _repository.createTransfer(draft);
      if (created case Ok<StockTransfer>()) {
        if (!sendNow) return null;
        final sent = await _repository.dispatchTransfer(created.value.id);
        return sent is Error<StockTransfer> ? _message(sent) : null;
      }
      return _message(created);
    });
  }

  Future<String?> send(StockTransfer transfer) {
    return _mutate(() async {
      final result = await _repository.dispatchTransfer(transfer.id);
      return result is Error<StockTransfer> ? _message(result) : null;
    });
  }

  Future<String?> receive(
    StockTransfer transfer,
    Map<int, double> lines, {
    String note = '',
  }) {
    return _mutate(() async {
      final result = await _repository.receiveTransfer(
        transfer.id,
        lines,
        note: note,
      );
      return result is Error<StockTransfer> ? _message(result) : null;
    });
  }

  Future<String?> cancel(StockTransfer transfer, String reason) {
    return _mutate(() async {
      final result = await _repository.cancelTransfer(transfer.id, reason);
      return result is Error<StockTransfer> ? _message(result) : null;
    });
  }

  Future<String?> _mutate(Future<String?> Function() action) async {
    _isMutating = true;
    notifyListeners();
    final error = await action();
    _isMutating = false;
    // Reload either way: a failure part-way through a two-step create leaves a
    // draft that the shop should be able to see rather than lose.
    await load();
    return error;
  }

  String? _message(Object result) {
    final failure = result is Error ? result.exception : null;
    final text = failure?.toString() ?? '';
    return text.isEmpty ? null : text;
  }
}
