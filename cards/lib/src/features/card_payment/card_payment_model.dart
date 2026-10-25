import 'package:flutter/foundation.dart';

import '../../core/result.dart';
import '../../data/api/relay_api.dart';
import '../../data/models/order.dart';
import '../../data/repositories/orders_repository.dart';
import '../../data/vault/card_vault.dart';
import 'moamalat_client.dart';

enum CardPaymentStage {
  /// Asking the relay for the signed checkout and opening it at Moamalat.
  opening,

  /// The card form, waiting for the customer.
  form,

  /// Moamalat is charging the card.
  charging,

  /// The card's bank asks the payer to confirm: its own page, with the code
  /// it texted them.
  verifying,

  /// Paid at Moamalat; the relay is passing the receipt to Dafa.
  confirming,

  /// Over: [CardPaymentModel.order] says how. The order page takes it on.
  done,

  /// The form cannot be used for this order: pay on Dafa's page instead.
  fallback,
}

/// Why the form is showing again after a try.
enum CardPaymentProblem { declined, expiry, network, verification, expired }

/// One bank-card payment in the app's own form (dafa/cards.go on the relay
/// has the background). The card is kept only for the length of a charge,
/// because a charge the bank stops to verify is sent again with the bank's
/// answer; it is never stored or sent anywhere but Moamalat.
class CardPaymentModel extends ChangeNotifier {
  CardPaymentModel({
    required this.orders,
    required this.moamalat,
    required this.order,
    this.cards,
  });

  final OrdersRepository orders;
  final MoamalatClient moamalat;

  /// Where a card is kept when the customer asks; none on the web.
  final CardVault? cards;

  /// The order as the relay last told it.
  CardOrder order;

  CardPaymentStage stage = CardPaymentStage.opening;
  CardPaymentProblem? problem;

  /// The bank's page, while [stage] is [CardPaymentStage.verifying].
  Uri? verificationUrl;

  /// The amount Moamalat charges, in dirhams, once the checkout is open.
  int? amount;

  MoamalatCheckout? _checkout;
  CardDetails? _card;

  /// Keep the card being paid with once it has paid (never before: a card
  /// that fails is not worth keeping).
  bool _save = false;
  bool _disposed = false;

  Uri get returnUrl => orders.cardReturnUrl;

  /// Opens a fresh checkout. Any trouble here, before the customer has typed
  /// anything, sends them to Dafa's page: it is the same payment.
  Future<void> start() async {
    _set(CardPaymentStage.opening);
    final opened = await _open();
    if (_disposed || opened) {
      return;
    }
    if (stage == CardPaymentStage.opening) {
      _set(CardPaymentStage.fallback);
    }
  }

  /// true when a checkout is open; otherwise [stage] already says why not.
  Future<bool> _open() async {
    _checkout = null;
    final result = await orders.cardSession(order.id);
    if (_disposed) {
      return false;
    }
    switch (result) {
      case Ok(value: (final current, final session)):
        order = current;
        if (session == null) {
          _set(CardPaymentStage.done);
          return false;
        }
        try {
          _checkout = await moamalat.open(session);
          amount = session.amount;
          if (!_disposed && stage == CardPaymentStage.opening) {
            _set(CardPaymentStage.form);
          }
          return true;
        } on MoamalatException catch (error) {
          // Paid already on an earlier try: the order page will say so.
          if (error.message == MoamalatClient.paidOrder) {
            _set(CardPaymentStage.done);
          }
          return false;
        }
      case Error(:final exception):
        if (exception is RelayApiException && exception.isNetwork) {
          problem = CardPaymentProblem.network;
        }
        return false;
    }
  }

  Future<void> pay(CardDetails card, {bool save = false}) async {
    if (stage != CardPaymentStage.form) {
      return;
    }
    problem = null;
    _card = card;
    _save = save && (cards?.available ?? false);
    _set(CardPaymentStage.charging);
    // A try that failed spends its checkout: each try gets its own.
    if (_checkout == null && !await _reopen()) {
      return;
    }
    await _charge(null);
  }

  /// The bank's page reached the return address with its answer.
  Future<void> verified(Map<String, String> answer) async {
    if (stage != CardPaymentStage.verifying) {
      return;
    }
    verificationUrl = null;
    _set(CardPaymentStage.charging);
    await _charge(answer);
  }

  /// The payer closed the bank's page without finishing.
  void verificationAbandoned() {
    if (stage != CardPaymentStage.verifying) {
      return;
    }
    verificationUrl = null;
    _failed(CardPaymentProblem.verification);
  }

  Future<void> _charge(Map<String, String>? verification) async {
    final checkout = _checkout;
    final card = _card;
    if (checkout == null || card == null) {
      _failed(CardPaymentProblem.network);
      return;
    }
    try {
      final step = await moamalat.charge(
        checkout,
        card,
        returnUrl: returnUrl,
        verification: verification,
      );
      if (_disposed) {
        return;
      }
      switch (step) {
        case ChargeNeedsVerification(:final url):
          verificationUrl = url;
          _set(CardPaymentStage.verifying);
        case ChargeDone(:final receipt):
          if (_save) {
            await cards?.keep(
              number: card.number,
              name: card.name,
              expiryMonth: card.expiryMonth,
              expiryYear: card.expiryYear,
            );
          }
          _card = null;
          await _confirm(receipt);
      }
    } on MoamalatException catch (error) {
      if (_disposed) {
        return;
      }
      if (error.message == MoamalatClient.paidOrder) {
        _card = null;
        _set(CardPaymentStage.done);
        return;
      }
      _failed(switch (error.message) {
        -1 => CardPaymentProblem.network,
        MoamalatClient.invalidExpiry => CardPaymentProblem.expiry,
        MoamalatClient.orderExpired => CardPaymentProblem.expired,
        _ when verification != null => CardPaymentProblem.verification,
        _ => CardPaymentProblem.declined,
      });
    }
  }

  /// Paid at Moamalat. Whatever the relay answers, the order page carries
  /// on: Dafa confirms a paid card on its own too, and the relay finds it.
  Future<void> _confirm(Map<String, String> receipt) async {
    _set(CardPaymentStage.confirming);
    final result = await orders.completeCard(order.id, receipt);
    if (_disposed) {
      return;
    }
    if (result case Ok(:final value)) {
      order = value;
    }
    _set(CardPaymentStage.done);
  }

  Future<bool> _reopen() async {
    final opened = await _open();
    if (!opened && !_disposed && stage == CardPaymentStage.charging) {
      _failed(problem ?? CardPaymentProblem.network);
    }
    return opened;
  }

  void _failed(CardPaymentProblem why) {
    problem = why;
    _checkout = null;
    _card = null;
    _save = false;
    _set(CardPaymentStage.form);
  }

  void _set(CardPaymentStage next) {
    if (_disposed) {
      return;
    }
    stage = next;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _card = null;
    super.dispose();
  }
}
