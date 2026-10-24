import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/result.dart';
import '../../data/models/order.dart';
import '../../data/repositories/orders_repository.dart';
import '../../data/vault/code_vault.dart';

/// Follows one order until it settles: every 2 s for the first minute (a
/// card usually arrives in seconds), then every 6 s. Codes that arrive go
/// into the vault at once.
class OrderWatcher extends ChangeNotifier {
  OrderWatcher({
    required this.orders,
    required this.vault,
    required CardOrder order,
  }) : _order = order {
    _remember(order);
  }

  final OrdersRepository orders;
  final CodeVault vault;
  CardOrder _order;
  Timer? _timer;
  DateTime? _startedAt;
  bool _disposed = false;

  CardOrder get order => _order;

  bool get settled =>
      !_order.status.isOpen &&
      !(_order.status == OrderStatus.delivered && _order.codes.isEmpty);

  void start() {
    _startedAt ??= DateTime.now();
    _schedule();
  }

  void _schedule() {
    if (_disposed || settled) {
      return;
    }
    final elapsed = DateTime.now().difference(_startedAt ?? DateTime.now());
    _timer = Timer(
      elapsed < const Duration(minutes: 1)
          ? const Duration(seconds: 2)
          : const Duration(seconds: 6),
      poll,
    );
  }

  /// Reads the order now (also on the app coming back to the front).
  Future<void> poll() async {
    _timer?.cancel();
    final result = await orders.order(_order.id);
    if (_disposed) {
      return;
    }
    if (result case Ok(:final value)) {
      _order = value;
      await _remember(value);
      notifyListeners();
    }
    _schedule();
  }

  Future<void> _remember(CardOrder order) async {
    if (order.status == OrderStatus.delivered && order.codes.isNotEmpty) {
      await vault.keep(order.id, order.codes);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
