import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/models/order.dart';
import '../../data/vault/payer_vault.dart';

/// What the app remembers of how the customer pays: the way to pay that
/// last went through, offered first at the next checkout, and each wallet's
/// number, so it is not asked again.
///
/// Both are learnt from payments that went through, never from attempts: an
/// order paid by a wallet whose code was never entered, or a bank page left
/// half way, teaches nothing. [paid] is told by the orders repository the
/// moment it sees an order of this phone's become paid, however it was paid
/// (a wallet's code, a bank card here, the bank's page, after a restart).
class PaymentMemory extends ChangeNotifier {
  PaymentMemory({required this.payers, this.preferences});

  final PayerVault payers;
  final SharedPreferencesAsync? preferences;

  /// The key the app always kept its last method under: kept, so a phone
  /// updated from an older build starts from the same choice.
  static const _methodKey = 'cards.last_method';

  String? _lastMethod;
  List<SavedPayer> _saved = const [];
  Future<void>? _loading;

  /// The way to pay that last went through, by its key; null before any.
  String? get lastMethod => _lastMethod;

  /// The wallets' kept payers, the latest first.
  List<SavedPayer> get saved => _saved;

  SavedPayer? payerFor(String method) =>
      _saved.where((p) => p.method == method).firstOrNull;

  /// Reads what is kept, once; later calls wait for the same read.
  Future<void> load() => _loading ??= _read();

  Future<void> _read() async {
    try {
      _lastMethod = await preferences?.getString(_methodKey);
    } on Exception {
      // The first method, then.
    }
    _saved = await payers.payers();
    notifyListeners();
  }

  /// The payer each order was placed with, until it is paid.
  final Map<String, _Pending> _pending = {};

  /// Orders seen paid before the checkout said what they were paid from.
  final Set<String> _paidFirst = {};

  /// The checkout placed [order] with [method], from [payer] (and
  /// [birthYear]) where the method asks, to be kept if [remember].
  Future<void> expect(
    CardOrder order,
    PaymentMethod method, {
    String payer = '',
    String birthYear = '',
    bool remember = true,
  }) async {
    if (payer.isEmpty || !remember) {
      return;
    }
    final pending = _Pending(method, payer, birthYear);
    if (_paidFirst.remove(order.id)) {
      await _keep(pending);
    } else {
      _pending[order.id] = pending;
    }
  }

  /// [order] was paid: its way to pay is the one offered first from now on,
  /// and the payer it was paid from is kept.
  Future<void> paid(CardOrder order) async {
    await load();
    if (order.method.isEmpty) {
      // Paid with credit alone: no way to pay was used.
      return;
    }
    _lastMethod = order.method;
    try {
      await preferences?.setString(_methodKey, order.method);
    } on Exception {
      // Remembered for this run, at least.
    }
    final pending = _pending.remove(order.id);
    if (pending != null) {
      await _keep(pending);
    } else {
      _paidFirst.add(order.id);
    }
    notifyListeners();
  }

  Future<void> _keep(_Pending pending) async {
    await payers.keep(
      SavedPayer(
        method: pending.method.key,
        provider: pending.method.provider,
        methodName: pending.method.name,
        payer: pending.payer,
        birthYear: pending.birthYear,
        kind: pending.method.payer,
      ),
    );
    _saved = await payers.payers();
    notifyListeners();
  }

  /// Forgets the payer kept for [method]: it is asked again next time.
  Future<void> forget(String method) async {
    await payers.remove(method);
    _saved = await payers.payers();
    notifyListeners();
  }

  /// Everything, on deleting the account.
  Future<void> clear() async {
    await payers.clear();
    _saved = const [];
    _lastMethod = null;
    _pending.clear();
    _paidFirst.clear();
    try {
      await preferences?.remove(_methodKey);
    } on Exception {
      // Nothing kept.
    }
    notifyListeners();
  }
}

/// What a wallet payment is paid from, as the payer typed it or as it was
/// kept: its number, Sadad's birth year, and whether to keep it.
@immutable
class PayerDetails {
  const PayerDetails({
    required this.payer,
    this.birthYear = '',
    this.remember = true,
  });

  final String payer;
  final String birthYear;
  final bool remember;

  /// The number as it may be shown (see [SavedPayer.masked]).
  String get masked => SavedPayer(
    method: '',
    provider: '',
    methodName: '',
    payer: payer,
    kind: '',
  ).masked;
}

class _Pending {
  const _Pending(this.method, this.payer, this.birthYear);

  final PaymentMethod method;
  final String payer;
  final String birthYear;
}
