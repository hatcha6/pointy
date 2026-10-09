import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/voucher_menu.dart';

/// The till's «كروت دفتر» menu, held for the length of the shift.
///
/// Read once and kept: picking the chip again shows what is held at once and
/// re-reads it behind the cashier, so a promotion that started or a card that
/// sold out arrives without the till ever waiting on it. A failed re-read
/// keeps what is on screen — stale beats blank — and only a menu that never
/// loaded shows the error.
class PosVoucherMenuController extends ChangeNotifier {
  PosVoucherMenuController({Future<Result<VoucherMenu>> Function()? load})
    : _load = load;

  /// Null in a till built without the integrations repository (tests, the
  /// learning sandbox): there is no menu to read, so the chip keeps the grid.
  final Future<Result<VoucherMenu>> Function()? _load;

  VoucherMenu? _menu;
  Future<void>? _inFlight;
  bool _failed = false;
  bool _disposed = false;

  /// Whether this till can show the menu at all.
  bool get isSupported => _load != null;

  /// The menu as last read; null until the first read lands.
  VoucherMenu? get menu => _menu;

  bool get isLoading => _inFlight != null;

  /// A re-read behind a menu already on screen.
  bool get isRefreshing => _inFlight != null && _menu != null;

  /// Nothing to show and the last read failed.
  bool get hasError => _failed && _menu == null && _inFlight == null;

  /// Reads the menu unless one is held or on its way.
  Future<void> ensureLoaded() {
    if (_menu != null) {
      return Future.value();
    }
    return refresh();
  }

  /// Re-reads the menu; whatever is on screen stays until the answer lands.
  Future<void> refresh() {
    final load = _load;
    if (load == null || _disposed) {
      return Future.value();
    }
    final inFlight = _inFlight;
    if (inFlight != null) {
      return inFlight;
    }
    late final Future<void> future;
    future = _read(load).whenComplete(() {
      if (identical(_inFlight, future)) {
        _inFlight = null;
        _notify();
      }
    });
    _inFlight = future;
    _failed = false;
    _notify();
    return future;
  }

  /// Re-reads the menu only when one was read before — what a catalog change
  /// pushed by the server asks for. A till that never opened the menu pays
  /// nothing for it.
  Future<void> refreshIfLoaded() {
    if (_menu == null) {
      return Future.value();
    }
    return refresh();
  }

  Future<void> _read(Future<Result<VoucherMenu>> Function() load) async {
    final result = await load();
    if (_disposed) {
      return;
    }
    switch (result) {
      case Ok<VoucherMenu>(:final value):
        _menu = value;
        _failed = false;
      case Error<VoucherMenu>():
        _failed = true;
    }
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
