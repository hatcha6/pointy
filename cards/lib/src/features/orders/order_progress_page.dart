import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../core/result.dart';
import '../../shared/relay_error_text.dart';
import '../../data/models/catalog.dart';
import '../../data/models/order.dart';
import '../../design/cards_tokens.dart';
import '../../shared/art_palette.dart';
import '../../shared/cards_scope.dart';
import '../../shared/haptics.dart';
import '../../shared/money_text.dart';
import '../card_payment/card_payment_page.dart';
import '../card_payment/payment_page_view.dart';
import '../esim/esim_checkout.dart';
import '../esim/esim_page.dart';
import '../links/cards_link.dart';
import '../reveal/reveal_page.dart';
import '../topup/topup_done_page.dart';
import '../topup/account_line.dart';
import '../topup/topup_text.dart';
import '../../shared/side_back.dart';
import 'order_outcome_panel.dart';
import 'order_waiting_room.dart';
import '../runner/runner_game.dart';
import 'order_watcher.dart';
import '../../core/analytics/analytics.dart';
import '../../core/analytics/events.dart';
import '../../core/analytics/experiments.dart';
import '../../shared/glass_bar.dart';
import '../../shared/motion.dart';
import '../../shared/container_route.dart';

/// An order on its way: it watches the relay and turns into the card the
/// moment it arrives. The customer may leave; the card waits in «كروتي».
class OrderProgressPage extends StatefulWidget {
  const OrderProgressPage({
    super.key,
    required this.watcher,
    this.brand,
    this.openPaymentPage = true,
  });

  final OrderWatcher watcher;
  final CardBrand? brand;

  /// Opens the card form (or Dafa's card page) on arrival for a bank-card
  /// order.
  final bool openPaymentPage;

  /// Past this a card is late (most come in seconds), and the page says the
  /// customer need not wait for it. The relay sets it with each order
  /// ([CardOrder.wait]), as it pushes an ending only past the same time;
  /// this is for an older relay that does not say.
  static const slowAfter = Duration(minutes: 3);

  /// Past this the wait is long enough to be felt, and the page offers a
  /// game to pass it (most cards arrive well before).
  static const playAfter = Duration(seconds: 12);

  static Future<void> open(
    BuildContext context, {
    required CardOrder order,
    CardBrand? brand,
    bool fresh = false,

    /// The row it opens out of, and closes back into.
    BuildContext? from,
  }) {
    final dependencies = CardsScope.of(context);
    if (order.isEsim && order.status == OrderStatus.delivered) {
      return EsimPage.openDelivered(context, order, fresh: fresh, from: from);
    }
    if (order.toppedUp) {
      return TopUpDonePage.open(context, order: order, brand: brand);
    }
    if (order.status == OrderStatus.delivered && order.codes.isNotEmpty) {
      dependencies.vault.keep(order.id, order.codes);
      return Navigator.of(context).push(
        routeFrom<void>(
          from,
          settings: screenSettings('reveal'),
          builder: (_) => RevealPage(order: order, brand: brand),
        ),
      );
    }
    // No brand in the catalog is an eSIM's: its card has the flag.
    brand ??= order.isEsim ? esimBrandOfOrder(order) : null;
    final watcher = OrderWatcher(
      orders: dependencies.orders,
      vault: dependencies.vault,
      order: order,
    )..start();
    return Navigator.of(context)
        .push(
          routeFrom<void>(
            from,
            settings: screenSettings('order_progress'),
            builder: (_) => OrderProgressPage(watcher: watcher, brand: brand),
          ),
        )
        .whenComplete(watcher.dispose);
  }

  @override
  State<OrderProgressPage> createState() => _OrderProgressPageState();
}

class _OrderProgressPageState extends State<OrderProgressPage>
    with WidgetsBindingObserver {
  bool _revealed = false;

  /// The screen last shown, so arriving at a new one is felt once. Set when
  /// the page opens: an order that is already refunded then is not news.
  late String _lastOutcome;

  /// Dafa's page, while it is open over this one.
  Route<PaymentPageResult>? _paymentRoute;

  /// Dafa's page said paid («المتابعة»): the page waits for the relay to
  /// confirm it, and then the card arrives as after any payment.
  bool _confirming = false;

  /// Asking the relay after the payer closed Dafa's page by hand.
  bool _checking = false;

  /// Calling the order off after the customer closed the card form.
  bool _cancelling = false;

  /// Stops telling the app this order is on screen.
  VoidCallback? _unwatch;

  /// The order and the push switch, which changes what a late card's panel
  /// says. Built once: a new one each build would subscribe again, even to
  /// a watcher disposed while the page animates away.
  Listenable? _changes;

  /// The card is taking long enough that the customer is told they need
  /// not wait for it here.
  bool _slow = false;
  Timer? _slowTimer;

  /// When this page first saw the card on its way, for an order whose
  /// payment time is not known.
  DateTime? _preparingSince;

  /// The wait is long enough for the game.
  bool _playable = false;
  Timer? _playTimer;

  /// The game, asked whether a run is under way when the order lands.
  final _game = GlobalKey<RunnerGameState>();

  /// The order landed mid-run: the game says so and waits for the customer.
  bool _orderReady = false;

  /// The customer chose to leave the game for the order.
  bool _leaveGame = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _lastOutcome = _outcomeOf(widget.watcher.order);
    widget.watcher.addListener(_onChange);
    _followSlowness();
    final order = widget.watcher.order;
    if (widget.openPaymentPage &&
        order.status == OrderStatus.awaitingPayment &&
        order.checkoutUrl.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _pay());
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The order's own notification stays quiet while this page is in front:
    // the page turns into the card itself.
    final push = CardsScope.of(context).push;
    _unwatch ??= push.watch(
      widget.watcher.order.id,
      () => mounted && (ModalRoute.of(context)?.isCurrent ?? false),
    );
    _changes ??= Listenable.merge([widget.watcher, push]);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.watcher.removeListener(_onChange);
    _unwatch?.call();
    _slowTimer?.cancel();
    _playTimer?.cancel();
    super.dispose();
  }

  /// Starts the clocks on a card on its way, and stops them once it is not.
  void _followSlowness() {
    final order = widget.watcher.order;
    if (_outcomeOf(order) != 'preparing') {
      _slowTimer?.cancel();
      _slowTimer = null;
      _playTimer?.cancel();
      _playTimer = null;
      return;
    }
    final now = DateTime.now();
    _preparingSince ??= now;
    final waited = now.difference(order.paidAt ?? _preparingSince!);
    Timer after(Duration wait, VoidCallback then) {
      final left = wait - waited;
      return Timer(left.isNegative ? Duration.zero : left, () {
        if (mounted && _outcomeOf(widget.watcher.order) == 'preparing') {
          setState(then);
        }
      });
    }

    if (!_slow && _slowTimer == null) {
      _slowTimer = after(
        order.wait ?? OrderProgressPage.slowAfter,
        () => _slow = true,
      );
    }
    if (!_playable && waited >= OrderProgressPage.playAfter) {
      // Already a long wait (opened again from «كروتي»): straight to the
      // game, with no other panel first. Every caller builds next.
      _showGame();
    } else if (!_playable && _playTimer == null) {
      _playTimer = after(OrderProgressPage.playAfter, _showGame);
    }
  }

  void _showGame() {
    _playable = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        CardsScope.of(context).analytics.runnerShown(widget.watcher.order);
      }
    });
  }

  /// The order has landed. A run under way is not cut short: the game
  /// pauses to say so, and the customer goes to it when they choose.
  bool _heldByGame() {
    if (_leaveGame || !(_game.currentState?.inRun ?? false)) {
      return false;
    }
    if (!_orderReady) {
      setState(() => _orderReady = true);
    }
    return true;
  }

  /// From the game, to the order that landed.
  void _showOrder() {
    _leaveGame = true;
    _onChange();
  }

  Future<void> _turnOnNotifications() async {
    await CardsScope.of(context).push.setEnabled(true);
  }

  /// Leaves the wait for «كروتي», where the card lands.
  void _toMyCards() =>
      CardsScope.of(context).links.deliver(const TabLink(CardsTab.myCards));

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Back from Dafa's page or the SMS app: ask at once.
    if (state == AppLifecycleState.resumed) {
      widget.watcher.poll();
    }
  }

  void _onChange() {
    _followSlowness();
    final order = widget.watcher.order;
    final outcome = _outcomeOf(order);
    if (outcome != _lastOutcome) {
      _lastOutcome = outcome;
      // The order ended without a card: feel it once, gently. The money is
      // safe, so it is a warning, never an error.
      if (const {'refunded', 'review', 'unpaid'}.contains(outcome)) {
        Haptics.warning();
      }
    }
    if (order.status != OrderStatus.awaitingPayment) {
      _closePaymentPage();
    }
    if (!_revealed && order.toppedUp) {
      if (_heldByGame()) {
        return;
      }
      // On the account: the receipt takes this page's place.
      _revealed = true;
      TopUpDonePage.open(
        context,
        order: order,
        brand: widget.brand,
        replace: true,
      );
      return;
    }
    if (!_revealed && order.isEsim && order.status == OrderStatus.delivered) {
      if (_heldByGame()) {
        return;
      }
      _revealed = true;
      EsimPage.openDelivered(context, order, replace: true);
      return;
    }
    if (!_revealed &&
        order.status == OrderStatus.delivered &&
        order.codes.isNotEmpty) {
      if (_heldByGame()) {
        return;
      }
      _revealed = true;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          settings: screenSettings('reveal'),
          builder: (_) => RevealPage(order: order, brand: widget.brand),
        ),
      );
    }
  }

  /// A bank-card order is paid in the app's own card form. Dafa's page is
  /// the way when the form cannot take the order, when the customer asks
  /// for it, on the web, which has no view for the bank's confirmation
  /// step, and for customers in the experiment's arm that pays there
  /// ([Experiments.cardPaymentForm]).
  Future<void> _pay() async {
    if (kIsWeb) {
      return _openPaymentPage();
    }
    final analytics = CardsScope.of(context).analytics;
    final order = widget.watcher.order;
    if (order.checkoutUrl.isNotEmpty &&
        await analytics.variant(Experiments.cardPaymentForm) ==
            Experiments.hostedPaymentPage) {
      analytics.paymentFormShown('hosted');
      return _openPaymentPage();
    }
    if (!mounted) {
      return;
    }
    analytics.paymentFormShown('native');
    final result = await CardPaymentPage.open(context, order);
    if (!mounted) {
      return;
    }
    switch (result) {
      case CardPaymentResult.usePaymentPage:
        await _openPaymentPage();
      case CardPaymentResult.settled:
        await widget.watcher.poll();
      case CardPaymentResult.closed:
        // The customer backed out of the card form: nothing to wait for.
        await _cancel();
    }
  }

  /// Calls the order off and goes back to the card. The relay asks Dafa
  /// first, so an order that did get paid is shown as paid instead.
  Future<void> _cancel() async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _cancelling = true);
    final result = await CardsScope.of(context).orders
        .cancel(widget.watcher.order.id);
    if (!mounted) {
      return;
    }
    setState(() => _cancelling = false);
    switch (result) {
      case Ok(:final value) when value.status == OrderStatus.cancelled:
        Haptics.select();
        messenger.showSnackBar(SnackBar(content: Text(l10n.orderCancelled)));
        Navigator.of(context).pop();
      case Ok():
        await widget.watcher.poll();
      case Error(:final exception):
        messenger.showSnackBar(
          SnackBar(content: Text(relayErrorText(l10n, exception))),
        );
    }
  }

  /// Dafa's bank-card page, inside the app on every platform
  /// ([PaymentPageView]), over this page, which follows the order all along.
  /// However it closes, the checkout carries on here: a payment the relay
  /// heard of goes on to the card, «المتابعة» waits for the relay to confirm,
  /// and a page closed by hand asks the relay once, then offers to pay again
  /// or call the order off.
  Future<void> _openPaymentPage() async {
    final address = widget.watcher.order.checkoutUrl;
    final url = address.isEmpty ? null : Uri.tryParse(address);
    if (url == null || !mounted) {
      return;
    }
    final analytics = CardsScope.of(context).analytics;
    final opened = DateTime.now();
    final result = await PaymentPageView.open(
      context,
      url: url,
      changes: widget.watcher,
      settled: () => widget.watcher.order.status != OrderStatus.awaitingPayment,
      onRoute: (route) => _paymentRoute = route,
      onLoadFailed: (reason) =>
          analytics.paymentPageLoadFailed(widget.watcher.order, reason),
    );
    _paymentRoute = null;
    analytics.paymentPageClosed(
      widget.watcher.order,
      result: result.name,
      open: DateTime.now().difference(opened),
    );
    if (!mounted) {
      return;
    }
    switch (result) {
      case PaymentPageResult.settled:
        return;
      case PaymentPageResult.returned:
        setState(() => _confirming = true);
        await widget.watcher.poll();
      case PaymentPageResult.closed:
        setState(() => _checking = true);
        await widget.watcher.poll();
        if (mounted) {
          setState(() => _checking = false);
        }
    }
  }

  /// Takes the payment page away at once, so the card's own page replaces
  /// this one rather than the payment page above it.
  void _closePaymentPage() {
    final route = _paymentRoute;
    _paymentRoute = null;
    if (route != null && route.isActive) {
      Navigator.of(context).removeRoute(route, PaymentPageResult.settled);
    }
  }

  /// Which screen an order is on: the switcher animates only when this
  /// changes, not on every poll.
  static String _outcomeOf(CardOrder order) => switch (order.status) {
    OrderStatus.awaitingPayment => 'paying',
    OrderStatus.paid ||
    OrderStatus.fulfilling ||
    OrderStatus.delivered => 'preparing',
    OrderStatus.refunded => 'refunded',
    _ when order.errorCode == 'payment_mismatch' => 'review',
    _ => 'unpaid',
  };

  void _backToShop() =>
      Navigator.of(context).popUntil((route) => route.isFirst);

  /// The brand's account kind, for an order sent to an account: its copy
  /// speaks of a top-up, not a card.
  ({String kind, String item, Widget? account})? _topUp(
    BuildContext context,
    CardOrder order,
  ) {
    final brand =
        widget.brand ?? CardsScope.of(context).catalog.brandOf(order.brandKey);
    if (!order.toAccount && brand?.target == null) {
      return null;
    }
    final item = brand?.items.where((i) => i.key == order.itemKey).firstOrNull;
    return (
      kind: kindKey(brand?.target?.kind),
      item: item == null || item.label.isEmpty ? order.name : item.label,
      account: order.account.isEmpty
          ? null
          : AccountLine(kind: brand?.target?.kind, account: order.account),
    );
  }

  Widget _panel(BuildContext context, CardOrder order) {
    final l10n = AppLocalizations.of(context);
    final topUp = _topUp(context, order);
    return switch (_outcomeOf(order)) {
      // Dafa's page said paid: the relay is confirming it.
      'paying' when _confirming => OrderOutcomePanel(
        brand: widget.brand,
        busy: true,
        icon: Icons.credit_card_rounded,
        title: l10n.hostedTitle,
        body: l10n.hostedBody,
      ),
      // Paying not finished (the card form or Dafa's page closed): nothing
      // is on its way, so nothing spins once the relay has said so. Pay, or
      // call the order off.
      // A wallet's order, left before its code was typed: there is no card
      // to finish paying with, and a wallet's code is asked for when the
      // order is placed. It can only be called off, and bought again.
      'paying' when order.nextAction == 'otp' && order.checkoutUrl.isEmpty =>
        OrderOutcomePanel(
          brand: widget.brand,
          busy: _cancelling,
          icon: Icons.account_balance_wallet_rounded,
          title: l10n.payNotFinishedTitle,
          body: l10n.payNotFinishedWalletBody,
          secondaryLabel: _cancelling ? null : l10n.cancelOrder,
          onSecondary: _cancel,
        ),
      'paying' => OrderOutcomePanel(
        brand: widget.brand,
        busy: _cancelling || _checking,
        icon: Icons.credit_card_rounded,
        title: l10n.payNotFinishedTitle,
        body: l10n.payNotFinishedBody,
        primaryLabel: _cancelling || _checking ? null : l10n.finishPaying,
        onPrimary: _pay,
        secondaryLabel: _cancelling || _checking ? null : l10n.cancelOrder,
        onSecondary: _cancel,
      ),
      'preparing' when _playable => _waitingRoom(context, order, topUp),
      // An eSIM has no code, and may take a moment longer: the same words stay.
      'preparing' when order.isEsim => OrderOutcomePanel(
        brand: widget.brand,
        busy: true,
        icon: Icons.sim_card_rounded,
        title: l10n.esimPreparingTitle,
        body: l10n.esimPreparingBody,
      ),
      'preparing' when _slow => _slowPanel(context, topUp?.kind),
      'preparing' when topUp != null => OrderOutcomePanel(
        brand: widget.brand,
        busy: true,
        icon: Icons.bolt_rounded,
        title: l10n.topUpPreparingTitle(topUp.kind),
        body: l10n.topUpPreparingBody(
          topUp.kind,
          isolatedName(topUp.item),
          isolated(accountShown(order.account)),
        ),
        detail: topUp.account,
      ),
      'preparing' => OrderOutcomePanel(
        brand: widget.brand,
        busy: true,
        icon: Icons.check_circle_rounded,
        title: l10n.preparingTitle,
        body: l10n.preparingBody,
      ),
      'refunded' => OrderOutcomePanel(
        brand: widget.brand,
        tone: OutcomeTone.safe,
        icon: Icons.verified_user_rounded,
        title: order.isEsim
            ? l10n.esimRefundedTitle
            : topUp == null
            ? l10n.refundedTitle
            : l10n.topUpRefundedTitle(topUp.kind),
        body: topUp == null
            ? l10n.refundedBody(formatMoney(l10n, order.total))
            : l10n.topUpRefundedBody(
                topUp.kind,
                formatMoney(l10n, order.total),
              ),
        detail: topUp?.account,
        credited: order.total,
        primaryLabel: l10n.backToShop,
        onPrimary: _backToShop,
      ),
      'review' => OrderOutcomePanel(
        brand: widget.brand,
        tone: OutcomeTone.attention,
        icon: Icons.manage_search_rounded,
        title: l10n.paymentReviewTitle,
        body: l10n.paymentReviewBody,
        secondaryLabel: l10n.backToShop,
        onSecondary: _backToShop,
      ),
      _ => OrderOutcomePanel(
        brand: widget.brand,
        icon: Icons.replay_rounded,
        title: l10n.unpaidTitle,
        body: l10n.unpaidBody,
        primaryLabel: l10n.tryAgain,
        onPrimary: () => Navigator.of(context).pop(),
        secondaryLabel: l10n.backToShop,
        onSecondary: _backToShop,
      ),
    };
  }

  /// A long wait: a game under the order's line. Once the relay's wait has
  /// passed it says, as the slow panel does, that the customer may go and
  /// hears when it lands; before that, only that the order shows up here.
  Widget _waitingRoom(
    BuildContext context,
    CardOrder order,
    ({String kind, String item, Widget? account})? topUp,
  ) {
    final l10n = AppLocalizations.of(context);
    final push = CardsScope.of(context).push;
    final ask = _slow && push.available && !push.enabled;
    final analytics = CardsScope.of(context).analytics;
    return OrderWaitingRoom(
      gameKey: _game,
      brand: widget.brand,
      title: !_slow
          ? l10n.waitPlayTitle
          : topUp != null
          ? l10n.topUpSlowTitle(topUp.kind)
          : l10n.preparingSlowTitle,
      body: !_slow
          ? l10n.waitPlayBody
          : push.enabled
          ? l10n.preparingSlowNotify
          : ask
          ? l10n.preparingSlowAsk
          : l10n.preparingSlowLater,
      detail: topUp?.account,
      orderReady: _orderReady,
      onShowOrder: _showOrder,
      onRunEnded: (run, {required best, required took}) =>
          analytics.runnerPlayed(
            score: run.score,
            coins: run.coins,
            best: best,
            took: took,
          ),
      primaryLabel: ask ? l10n.onboardingNotifyAllow : null,
      onPrimary: ask ? _turnOnNotifications : null,
      secondaryLabel: l10n.goToMyCards,
      onSecondary: _toMyCards,
    );
  }

  /// A card running late: the customer may go, and hears when it lands.
  /// [topUpKind] is the account's kind for a top-up, null for a card.
  Widget _slowPanel(BuildContext context, String? topUpKind) {
    final l10n = AppLocalizations.of(context);
    final push = CardsScope.of(context).push;
    final ask = push.available && !push.enabled;
    return OrderOutcomePanel(
      brand: widget.brand,
      busy: true,
      icon: Icons.schedule_rounded,
      title: topUpKind != null
          ? l10n.topUpSlowTitle(topUpKind)
          : l10n.preparingSlowTitle,
      body: push.enabled
          ? l10n.preparingSlowNotify
          : ask
          ? l10n.preparingSlowAsk
          : l10n.preparingSlowLater,
      primaryLabel: ask ? l10n.onboardingNotifyAllow : null,
      onPrimary: ask ? _turnOnNotifications : null,
      secondaryLabel: l10n.goToMyCards,
      onSecondary: _toMyCards,
    );
  }

  @override
  Widget build(BuildContext context) {
    return SideBack(
      edgeToEdge: true,
      child: Scaffold(
        extendBodyBehindAppBar: true,
        appBar: const GlassBar(clear: true),
        body: ListenableBuilder(
          listenable: _changes!,
          builder: (context, _) {
            final order = widget.watcher.order;
            final theme = Theme.of(context);
            return ArtPaletteBuilder(
              brand: widget.brand,
              builder: (context, palette) => DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.center,
                    colors: [
                      palette.tint.withValues(
                        alpha: theme.brightness == Brightness.dark
                            ? 0.35
                            : 0.14,
                      ),
                      theme.scaffoldBackgroundColor,
                    ],
                  ),
                ),
                child: SafeArea(
                  child: Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(CardsSpace.xl),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 420),
                        // Each state fades through to the next as the relay
                        // answers, instead of snapping.
                        child: CardsSwitcher(
                          child: KeyedSubtree(
                            // The game keeps its place (and its run) as the
                            // wait turns long.
                            key: ValueKey(
                              '${_outcomeOf(order)}'
                              '${_playable
                                  ? '-play'
                                  : _slow
                                  ? '-slow'
                                  : ''}',
                            ),
                            child: _panel(context, order),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
