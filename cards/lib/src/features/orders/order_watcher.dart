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

  /// Done moving: a top-up once it is on the account, a card once its codes
  /// are in hand.
  bool get settled =>
      !_order.status.isOpen &&
      !(_order.status == OrderStatus.delivered &&
          _order.codes.isEmpty &&
          !_order.toAccount &&
          !_order.isEsim);

  void start() {
    _startedAt ??= DateTime.now();
    _schedule();
  }

  void _schedule() {
    // One timer at a time: two polls finishing together (the clock's, and
    // the app coming back to the front) would otherwise each leave one
    // running, and the order would be asked about twice as often for good.
    _timer?.cancel();
    _timer = null;
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
  Future<void> poll() => _polling ??= _poll().whenComplete(() {
    _polling = null;
  });

  /// The poll on its way: asking again meanwhile waits for its answer.
  Future<void>? _polling;

  Future<void> _poll() async {
    _timer?.cancel();
    final result = await orders.order(_order.id);
    if (_disposed) {
      return;
    }
    if (result case Ok(:final value)) {
      _order = value;
      await _remember(value);
      if (_disposed) {
        return;
      }
      notifyListeners();
    }
    _schedule();
  }

  /// A keychain that will not take the codes costs the saved copy only: the
  /// order still moves on, and the relay hands the codes over again.
  Future<void> _remember(CardOrder order) async {
    if (order.status == OrderStatus.delivered && order.codes.isNotEmpty) {
      try {
        await vault.keep(order.id, order.codes);
      } on Object {
        // Read from the relay next time.
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
