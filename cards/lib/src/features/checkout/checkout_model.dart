import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../core/analytics/events.dart';
import '../../core/money.dart';
import '../../core/result.dart';
import '../../data/api/relay_api.dart';
import '../../data/models/catalog.dart';
import '../../data/models/offer.dart';
import '../../data/models/order.dart';
import '../../data/models/price_quote.dart';
import '../../data/repositories/orders_repository.dart';
import '../topup/account_form_model.dart';
import 'payment_memory.dart';

/// One checkout: what is bought, how it is paid, and the order it became.
///
/// Every figure shown before paying is worked out here the relay's way
/// (credit first, then the gateway fee on what Dafa collects); the relay's
/// own figures on the placed order are the ones charged.
///
/// The price is the relay's quote, not the shelf's: dollar cards follow a
/// moving exchange rate, so the sheet asks for the price an order placed now
/// is charged, keeps it fresh while it stays open, and sends the quote with
/// the order so the price shown is the price paid.
class CheckoutModel extends ChangeNotifier {
  CheckoutModel({
    required this.orders,
    required this.brand,
    required this.item,
    this.quantity = 1,
    this.payments,
    this.account,
    this.orderAccount = const {},
  }) : _key = _newKey(),
       unitPrice = item.price;

  final OrdersRepository orders;
  final CardBrand brand;
  final CardItem item;

  /// How this customer last paid, and the wallets' numbers they paid from:
  /// the way to pay offered first, and what is not asked again.
  final PaymentMemory? payments;
  int quantity;

  /// Where a top-up goes, as typed on the brand's page; null for a code.
  final AccountFormModel? account;

  /// What an eSIM order says about who it is for.
  final Map<String, String> orderAccount;

  /// One card's price: the shelf's until the relay quotes it, then the
  /// quote's.
  Money unitPrice;

  /// The relay's hold on [unitPrice]; null before it answers, or from a
  /// relay with no quotes (the shown price must then still be current).
  PriceQuote? quote;

  /// The price the sheet moved to while it was open (a fresh quote that
  /// differs from what was shown); null once the customer pays at it.
  Money? priceMovedTo;
  Timer? _quoteTimer;

  CheckoutOptions? options;
  Money credit = Money.zero;
  bool useCredit = true;

  /// The offers this customer can use; the best one for the order is taken
  /// unless they turn it off ([setUseOffer]).
  List<CardOffer> offers = const [];
  bool useOffer = true;
  PaymentMethod? method;
  bool busy = false;
  Object? error;
  CardOrder? order;

  /// One key per attempt: a retried tap replays the same order, never a
  /// second one. A closed attempt gets a new key.
  String _key;

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
      orders.offers(),
      Future<Object?>.value(payments?.load()),
      orders.quote(item.key),
    ]);
    if (results[4] case Ok(:final value)) {
      _takeQuote(value as PriceQuote?);
    }
    if (results[0] case Ok(:final value)) {
      options = value as CheckoutOptions;
      // The way that last went through, while it is still offered; else the
      // relay's first. A choice made in this sheet stands.
      final last = payments?.lastMethod;
      method =
          options!.methods.where((m) => m.key == method?.key).firstOrNull ??
          options!.methods.where((m) => m.key == last).firstOrNull ??
          options!.methods.firstOrNull;
    } else if (results[0] case Error(:final exception)) {
      error = exception;
    }
    if (results[1] case Ok(:final value)) {
      credit = (value as CreditStatement).balance;
    }
    // Without them the order is simply paid in full.
    if (results[2] case Ok(:final value)) {
      offers = value as List<CardOffer>;
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

  /// Takes a quote's price, telling the sheet when it is not the one shown,
  /// and asks for the next one before it lapses.
  void _takeQuote(PriceQuote? fresh) {
    _quoteTimer?.cancel();
    if (fresh == null || fresh.item != item.key) {
      return;
    }
    quote = fresh;
    if (fresh.unitPrice != unitPrice) {
      priceMovedTo = fresh.unitPrice;
      unitPrice = fresh.unitPrice;
    }
    _quoteTimer = Timer(fresh.refreshIn(DateTime.now()), _refreshQuote);
  }

  /// A new quote while the sheet stays open, so the one sent with the order
  /// is alive; none once the order is placed.
  Future<void> _refreshQuote() async {
    if (_disposed || order != null) {
      return;
    }
    if (busy) {
      _quoteTimer = Timer(const Duration(seconds: 20), _refreshQuote);
      return;
    }
    final result = await orders.quote(item.key);
    if (_disposed || order != null || busy) {
      return;
    }
    if (result case Ok(:final value)) {
      _takeQuote(value);
    } else {
      // Kept: the order then stands on the shown price matching the live one.
      _quoteTimer = Timer(const Duration(minutes: 1), _refreshQuote);
    }
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    _quoteTimer?.cancel();
    super.dispose();
  }

  /// The payment being placed, while it is: a sheet closed meanwhile hands
  /// its order on all the same.
  Future<CardOrder?>? placing;

  /// The order as an offer prices it: its card, how many, and what it covers.
  OfferLine get line => OfferLine(
    unitPrice: unitPrice,
    quantity: quantity,
    category: brand.category,
    brand: brand.key,
    item: item.key,
  );

  /// The order before any offer.
  Money get subtotal => line.subtotal;

  /// The offer taken off this order, if any.
  CardOffer? get offer => useOffer ? CardOffer.bestFor(offers, line) : null;

  /// The offer that would apply, whether or not it is taken: what the
  /// switch offers.
  CardOffer? get availableOffer => CardOffer.bestFor(offers, line);
  Money get discount => offer?.discountOn(line) ?? Money.zero;

  /// The offers that cover this card, the one that applies first: where a
  /// nudge to a better deal is looked for.
  List<CardOffer> get coveringOffers {
    final applying = availableOffer;
    return [
      ?applying,
      for (final offer in offers)
        if (offer != applying &&
            offer.scope.covers(
              category: brand.category,
              brand: brand.key,
              item: item.key,
            ))
          offer,
    ];
  }

  /// What the order costs: the subtotal less the offer.
  Money get total => subtotal - discount;
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

  /// Another number typed for this payment, over the one kept.
  PayerDetails? payerChoice;

  /// The number kept for the chosen way to pay, when it is whole (Sadad's
  /// birth year with it).
  PayerDetails? get savedPayer {
    final current = method;
    final kept = current == null ? null : payments?.payerFor(current.key);
    if (kept == null ||
        (current!.payer.isNotEmpty && kept.payer.isEmpty) ||
        (current.birthYear && kept.birthYear.isEmpty)) {
      return null;
    }
    return PayerDetails(payer: kept.payer, birthYear: kept.birthYear);
  }

  /// What this payment is paid from without asking: typed here, else kept.
  PayerDetails? get payer => payerChoice ?? savedPayer;

  /// Whether the payer must be asked before paying: the method wants one and
  /// none is known.
  bool get mustAskPayer => needsPayerDetails && payer == null;

  void choosePayer(PayerDetails details) {
    payerChoice = details;
    notifyListeners();
  }

  void setUseCredit(bool value) {
    useCredit = value;
    notifyListeners();
  }

  void setUseOffer(bool value) {
    useOffer = value;
    if (availableOffer case final offer?) {
      orders.analytics.offerToggled(offer, on: value);
    }
    notifyListeners();
  }

  final Set<String> _nudged = {};

  /// Tells analytics a nudge was shown, once per offer and kind.
  void nudgeShown(CardOffer offer, String kind) {
    if (_nudged.add('${offer.id}/$kind')) {
      orders.analytics.offerNudgeShown(offer, kind);
    }
  }

  void choose(PaymentMethod value) {
    orders.analytics.paymentMethodSelected(value.key);
    if (value.key != method?.key) {
      // A number typed for one wallet is not another's.
      payerChoice = null;
    }
    method = value;
    error = null;
    notifyListeners();
  }

  void setQuantity(int value) {
    final max = options?.maxQuantity ?? 10;
    quantity = value.clamp(1, max == 0 ? 10 : max);
    notifyListeners();
  }

  /// Places the order and starts the payment, from [payer] where the way to
  /// pay asks for one (else the one typed or kept).
  Future<CardOrder?> pay({PayerDetails? payer}) {
    if (busy) {
      return placing ?? Future.value(order);
    }
    if (payer != null) {
      payerChoice = payer;
    }
    final from = needsPayerDetails ? this.payer : null;
    return placing = _pay(from).whenComplete(() => placing = null);
  }

  Future<CardOrder?> _pay(PayerDetails? from) async {
    busy = true;
    error = null;
    priceMovedTo = null;
    _notify();
    final result = await orders.place(
      OrderRequest(
        itemKey: item.key,
        quantity: quantity,
        unitPrice: unitPrice,
        quote: quote?.token ?? '',
        idempotencyKey: _key,
        useCredit: useCredit && credit.isPositive,
        method: creditCovers ? '' : method?.key ?? '',
        payerIdentifier: from?.payer ?? '',
        birthYear: from?.birthYear ?? '',
        account: account?.values ?? orderAccount,
        offerId: offer?.id ?? '',
      ),
    );
    busy = false;
    switch (result) {
      case Ok(:final value):
        order = value;
        try {
          // Kept once the payment goes through ([PaymentMemory.paid]).
          if (!creditCovers && method != null && from != null) {
            await payments?.expect(
              value,
              method!,
              payer: from.payer,
              birthYear: from.birthYear,
              remember: from.remember,
            );
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
        if (exception is RelayApiException &&
            exception.code == 'price_changed') {
          // The refusal carries the new price and a quote for it: the next
          // tap is placed at that price, which the error shows.
          final moved = PriceQuote.fromJson(
            exception.body,
            item: item.key,
            now: DateTime.now(),
          );
          if (moved != null) {
            _takeQuote(moved);
          } else if (Money.parse(exception.body['unit_price'] as String?)
              case final price when price.isPositive) {
            // A relay from before quotes: its price alone.
            unitPrice = price;
          }
          // Told by the error, not twice.
          priceMovedTo = null;
        }
        if (exception is RelayApiException &&
            exception.code == 'offer_unavailable') {
          // Used up or ended since it was read: read them again, so the
          // next tap is priced without it.
          if (await orders.offers() case Ok(:final value)) {
            offers = value;
          }
        }
        orders.analytics.orderPlaceFailed(
          exception,
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
