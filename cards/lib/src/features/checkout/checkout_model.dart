import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/analytics/events.dart';
import '../../core/money.dart';
import '../../core/result.dart';
import '../../data/models/catalog.dart';
import '../../data/models/order.dart';
import '../../data/repositories/orders_repository.dart';
import '../topup/account_form_model.dart';

/// One checkout: what is bought, how it is paid, and the order it became.
///
/// Every figure shown before paying is worked out here the relay's way
/// (credit first, then the gateway fee on what Dafa collects); the relay's
/// own figures on the placed order are the ones charged.
class CheckoutModel extends ChangeNotifier {
  CheckoutModel({
    required this.orders,
    required this.brand,
    required this.item,
    this.quantity = 1,
    this.preferences,
    this.account,
    this.orderAccount = const {},
  }) : _key = _newKey();

  final OrdersRepository orders;
  final CardBrand brand;
  final CardItem item;
  final SharedPreferencesAsync? preferences;
  int quantity;

  /// Where a top-up goes, as typed on the brand's page; null for a code.
  final AccountFormModel? account;

  /// What an eSIM order says about who it is for.
  final Map<String, String> orderAccount;

  CheckoutOptions? options;
  Money credit = Money.zero;
  bool useCredit = true;
  PaymentMethod? method;
  bool busy = false;
  Object? error;
  CardOrder? order;

  /// One key per attempt: a retried tap replays the same order, never a
  /// second one. A closed attempt gets a new key.
  String _key;

  static const _methodKey = 'cards.last_method';

  static String _newKey() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  /// Reading the ways to pay and the credit.
  bool loading = false;

  /// The ways to pay could not be read: the sheet offers to read them again.
  bool get loadFailed => !loading && options == null;

  bool _started = false;
  bool _disposed = false;

  Future<void> load() async {
    if (loading) {
      return;
    }
    if (!_started) {
      _started = true;
      orders.analytics.checkoutStarted(brand, item, quantity);
    }
    loading = true;
    error = null;
    _notify();
    final results = await Future.wait([
      orders.checkoutOptions(),
      orders.credit(),
    ]);
    if (results[0] case Ok(:final value)) {
      options = value as CheckoutOptions;
      String? last;
      try {
        last = await preferences?.getString(_methodKey);
      } on Exception {
        // The first method, then.
      }
      method =
          options!.methods.where((m) => m.key == last).firstOrNull ??
          options!.methods.firstOrNull;
    } else if (results[0] case Error(:final exception)) {
      error = exception;
    }
    if (results[1] case Ok(:final value)) {
      credit = (value as CreditStatement).balance;
    }
    loading = false;
    _notify();
  }

  /// The sheet can close while the relay is still answering.
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

  /// The payment being placed, while it is: a sheet closed meanwhile hands
  /// its order on all the same.
  Future<CardOrder?>? placing;

  Money get total => item.price * quantity;
  Money get creditApplied {
    if (!useCredit || !credit.isPositive) {
      return Money.zero;
    }
    return credit.compareTo(total) >= 0 ? total : credit;
  }

  Money get due => total - creditApplied;
  Money get fee => options?.feeOn(due) ?? Money.zero;
  Money get toPay => due + fee;
  bool get creditCovers => !due.isPositive;

  /// The payer details the chosen method asks for before paying.
  bool get needsPayerDetails =>
      !creditCovers &&
      method != null &&
      (method!.payer.isNotEmpty || method!.birthYear);

  void setUseCredit(bool value) {
    useCredit = value;
    notifyListeners();
  }

  void choose(PaymentMethod value) {
    orders.analytics.paymentMethodSelected(value.key);
    method = value;
    error = null;
    notifyListeners();
  }

  void setQuantity(int value) {
    final max = options?.maxQuantity ?? 10;
    quantity = value.clamp(1, max == 0 ? 10 : max);
    notifyListeners();
  }

  /// Places the order and starts the payment.
  Future<CardOrder?> pay({String payer = '', String birthYear = ''}) {
    if (busy) {
      return placing ?? Future.value(order);
    }
    return placing = _pay(
      payer: payer,
      birthYear: birthYear,
    ).whenComplete(() => placing = null);
  }

  Future<CardOrder?> _pay({String payer = '', String birthYear = ''}) async {
    busy = true;
    error = null;
    _notify();
    final result = await orders.place(
      OrderRequest(
        itemKey: item.key,
        quantity: quantity,
        unitPrice: item.price,
        idempotencyKey: _key,
        useCredit: useCredit && credit.isPositive,
        method: creditCovers ? '' : method?.key ?? '',
        payerIdentifier: payer,
        birthYear: birthYear,
        account: account?.values ?? orderAccount,
      ),
    );
    busy = false;
    switch (result) {
      case Ok(:final value):
        order = value;
        try {
          if (method != null) {
            await preferences?.setString(_methodKey, method!.key);
          }
          // Topped up once, offered first next time.
          await account?.remember();
        } on Exception {
          // Remembering is a convenience: the order is placed either way.
        }
        if (!value.status.isOpen && value.status != OrderStatus.delivered) {
          _key = _newKey();
        }
      case Error(:final exception):
        error = exception;
        _key = _newKey();
        orders.analytics.orderPlaceFailed(
          errorCodeOf(exception),
          method: creditCovers ? 'credit' : method?.key ?? '',
        );
    }
    _notify();
    return order;
  }

  /// The wallet's code for an order paid by a mobile wallet.
  Future<CardOrder?> confirm(String otp) async {
    final current = order;
    if (current == null) {
      return null;
    }
    busy = true;
    error = null;
    _notify();
    final result = await orders.confirm(current.id, otp);
    busy = false;
    switch (result) {
      case Ok(:final value):
        order = value;
      case Error(:final exception):
        error = exception;
    }
    _notify();
    return order;
  }

  Future<void> cancel() async {
    final current = order;
    if (current == null) {
      return;
    }
    if (await orders.cancel(current.id) case Ok(:final value)) {
      order = value;
    }
    _key = _newKey();
    _notify();
  }
}
