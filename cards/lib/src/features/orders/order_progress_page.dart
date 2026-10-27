import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

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
import '../reveal/reveal_page.dart';
import '../../shared/side_back.dart';
import 'order_outcome_panel.dart';
import 'order_watcher.dart';
import '../../core/analytics/analytics.dart';

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

  static Future<void> open(
    BuildContext context, {
    required CardOrder order,
    CardBrand? brand,
  }) {
    final dependencies = CardsScope.of(context);
    if (order.status == OrderStatus.delivered && order.codes.isNotEmpty) {
      dependencies.vault.keep(order.id, order.codes);
      return Navigator.of(context).push(
        MaterialPageRoute(
          settings: screenSettings('reveal'),
          builder: (_) => RevealPage(order: order, brand: brand),
        ),
      );
    }
    final watcher = OrderWatcher(
      orders: dependencies.orders,
      vault: dependencies.vault,
      order: order,
    )..start();
    return Navigator.of(context)
        .push(
          MaterialPageRoute(
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

  /// Dafa's page is open over the app (in-app browser).
  bool _paymentPageOpen = false;

  /// Dafa's page was opened for this order: the payer may have paid there,
  /// out of the app's sight, so the page waits for the relay to say.
  bool _usedPaymentPage = false;

  /// Calling the order off after the customer closed the card form.
  bool _cancelling = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _lastOutcome = _outcomeOf(widget.watcher.order);
    widget.watcher.addListener(_onChange);
    final order = widget.watcher.order;
    if (widget.openPaymentPage &&
        order.status == OrderStatus.awaitingPayment &&
        order.checkoutUrl.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _pay());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.watcher.removeListener(_onChange);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Back from Dafa's page or the SMS app: ask at once.
    if (state == AppLifecycleState.resumed) {
      widget.watcher.poll();
    }
  }

  void _onChange() {
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
    if (_paymentPageOpen && order.status != OrderStatus.awaitingPayment) {
      _closePaymentPage();
    }
    if (!_revealed &&
        order.status == OrderStatus.delivered &&
        order.codes.isNotEmpty) {
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
  /// for it, and on the web, which has no view for the bank's confirmation
  /// step.
  Future<void> _pay() async {
    if (kIsWeb) {
      return _openPaymentPage();
    }
    final result = await CardPaymentPage.open(context, widget.watcher.order);
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

  /// Dafa's bank-card page opens inside the app: Safari's sheet on iOS,
  /// a Chrome Custom Tab on Android (a real browser, so the bank's 3-D Secure
  /// step and the address bar work as the payer expects; a web view would
  /// hide the address and some banks refuse it). A web build has no in-app
  /// browser and opens a tab.
  Future<void> _openPaymentPage() async {
    final url = Uri.tryParse(widget.watcher.order.checkoutUrl);
    if (url != null) {
      setState(() => _usedPaymentPage = true);
      _paymentPageOpen = await launchUrl(
        url,
        mode: LaunchMode.inAppBrowserView,
      );
    }
  }

  /// Dafa only tells the relay, never sends the payer back, so its page
  /// would stay up over the result. Close it as soon as the payment is
  /// settled where the platform allows (iOS); an Android tab is closed by
  /// the payer, and coming back asks the relay at once.
  Future<void> _closePaymentPage() async {
    _paymentPageOpen = false;
    if (await supportsCloseForLaunchMode(LaunchMode.inAppBrowserView)) {
      await closeInAppWebView();
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

  Widget _panel(BuildContext context, CardOrder order) {
    final l10n = AppLocalizations.of(context);
    return switch (_outcomeOf(order)) {
      // Paying on Dafa's page: only the relay can tell when it is done.
      'paying' when _usedPaymentPage => OrderOutcomePanel(
        brand: widget.brand,
        busy: true,
        icon: Icons.credit_card_rounded,
        title: l10n.hostedTitle,
        body: l10n.hostedBody,
        secondaryLabel: order.checkoutUrl.isEmpty ? null : l10n.openPaymentPage,
        onSecondary: _pay,
      ),
      // The app's own card form, not finished: nothing is on its way, so
      // nothing spins. Pay, or call the order off.
      'paying' => OrderOutcomePanel(
        brand: widget.brand,
        busy: _cancelling,
        icon: Icons.credit_card_rounded,
        title: l10n.payNotFinishedTitle,
        body: l10n.payNotFinishedBody,
        primaryLabel: _cancelling ? null : l10n.finishPaying,
        onPrimary: _pay,
        secondaryLabel: _cancelling ? null : l10n.cancelOrder,
        onSecondary: _cancel,
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
        title: l10n.refundedTitle,
        body: l10n.refundedBody(formatMoney(l10n, order.total)),
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

  @override
  Widget build(BuildContext context) {
    return SideBack(
      edgeToEdge: true,
      child: Scaffold(
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          automaticallyImplyLeading: !SideBack.active(context),
        ),
        body: ListenableBuilder(
          listenable: widget.watcher,
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
                        // Each state cross-fades into the next as the relay
                        // answers, instead of snapping.
                        child: AnimatedSwitcher(
                          duration: CardsMotion.standard,
                          switchInCurve: CardsMotion.curve,
                          transitionBuilder: (child, animation) =>
                              FadeTransition(
                                opacity: animation,
                                child: ScaleTransition(
                                  scale: Tween(
                                    begin: 0.97,
                                    end: 1.0,
                                  ).animate(animation),
                                  child: child,
                                ),
                              ),
                          child: KeyedSubtree(
                            key: ValueKey(_outcomeOf(order)),
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
