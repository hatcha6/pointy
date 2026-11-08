import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../core/analytics/analytics.dart';
import '../../data/models/catalog.dart';
import '../../data/models/order.dart';
import '../../data/models/order_report.dart';
import '../../design/cards_tokens.dart';
import '../../shared/card_art.dart';
import '../../shared/cards_scope.dart';
import '../../shared/money_text.dart';
import '../../shared/name_text.dart';
import '../brand/brand_page.dart';
import '../orders/order_progress_page.dart';
import '../orders/order_report_sheet.dart';
import '../orders/order_watcher.dart';
import 'topup_receipt.dart';
import 'topup_text.dart';
import 'topup_timeline.dart';

/// A top-up as it stands, opened from «كروتي» (or its notification): where it
/// is now, step by step, live while it moves; the receipt; and a way to tell
/// us something went wrong, with our reply once we answered.
///
/// While it is on its way the page follows it, and past the relay's waiting
/// time ([CardOrder.wait]) it says the supplier is slow this time, as the
/// waiting page after paying does.
class TopUpOrderPage extends StatefulWidget {
  const TopUpOrderPage({super.key, required this.watcher, this.brand});

  final OrderWatcher watcher;
  final CardBrand? brand;

  static Future<void> open(
    BuildContext context, {
    required CardOrder order,
    CardBrand? brand,
  }) {
    final dependencies = CardsScope.of(context);
    final watcher = OrderWatcher(
      orders: dependencies.orders,
      vault: dependencies.vault,
      order: order,
    );
    return Navigator.of(context)
        .push(
          MaterialPageRoute<void>(
            settings: screenSettings('topup_order'),
            builder: (_) => TopUpOrderPage(watcher: watcher, brand: brand),
          ),
        )
        .whenComplete(watcher.dispose);
  }

  @override
  State<TopUpOrderPage> createState() => _TopUpOrderPageState();
}

class _TopUpOrderPageState extends State<TopUpOrderPage>
    with WidgetsBindingObserver {
  /// The report filed from this page, until the order read back carries it.
  OrderReport? _filed;
  bool _slow = false;
  Timer? _slowTimer;
  VoidCallback? _unwatch;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.watcher.addListener(_onChange);
    // Read it now: the list's row may be minutes old, and a reply may have
    // come. An order still moving is then followed.
    widget.watcher.poll();
    _followSlowness();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Its own notification stays quiet while the order is on screen.
    _unwatch ??= CardsScope.of(context).push.watch(
      widget.watcher.order.id,
      () => mounted && (ModalRoute.of(context)?.isCurrent ?? false),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.watcher.removeListener(_onChange);
    _slowTimer?.cancel();
    _unwatch?.call();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      widget.watcher.poll();
    }
  }

  void _onChange() {
    final report = widget.watcher.order.report;
    if (report != null && report.id == _filed?.id) {
      _filed = null;
    }
    _followSlowness();
    setState(() {});
  }

  /// Turns the page to «slow» once the order outlasts the relay's wait.
  void _followSlowness() {
    final order = widget.watcher.order;
    final moving =
        order.status == OrderStatus.paid ||
        order.status == OrderStatus.fulfilling;
    if (!moving) {
      _slowTimer?.cancel();
      _slowTimer = null;
      _slow = false;
      return;
    }
    if (_slow || _slowTimer != null) {
      return;
    }
    final since = order.paidAt ?? order.createdAt ?? DateTime.now();
    final left =
        (order.wait ?? OrderProgressPage.slowAfter) -
        DateTime.now().difference(since);
    _slowTimer = Timer(left.isNegative ? Duration.zero : left, () {
      if (mounted) {
        setState(() => _slow = true);
      }
    });
  }

  Future<void> _report() async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final report = await showOrderReportSheet(
      context,
      widget.watcher.order,
      kind: kindKey(_brand?.target?.kind),
    );
    if (report == null || !mounted) {
      return;
    }
    setState(() => _filed = report);
    messenger.showSnackBar(SnackBar(content: Text(l10n.reportSent)));
  }

  CardBrand? get _brand =>
      widget.brand ??
      CardsScope.of(context).catalog.brandOf(widget.watcher.order.brandKey);

  void _again(CardBrand brand) {
    final order = widget.watcher.order;
    final item = brand.items.where((i) => i.key == order.itemKey).firstOrNull;
    BrandPage.open(context, brand, item: item);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final order = widget.watcher.order;
    final brand = _brand;
    final target = brand?.target;
    final kind = kindKey(target?.kind);
    final report = _filed ?? order.report;
    final reportable =
        order.status != OrderStatus.awaitingPayment &&
        order.status != OrderStatus.cancelled;
    final width = math.min(MediaQuery.sizeOf(context).width * 0.44, 200.0);
    return Scaffold(
      appBar: AppBar(title: NameText(order.name, maxLines: 1)),
      body: SafeArea(
        top: false,
        child: RefreshIndicator(
          onRefresh: widget.watcher.poll,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(
                  CardsSpace.gutter,
                  CardsSpace.sm,
                  CardsSpace.gutter,
                  CardsSpace.xxl,
                ),
                children: [
                  if (brand != null) ...[
                    Center(
                      child: SizedBox(
                        width: width,
                        child: CardArt(brand: brand),
                      ),
                    ),
                    const SizedBox(height: CardsSpace.lg),
                  ],
                  _StatusCard(order: order, kind: kind, slow: _slow),
                  if (report != null) ...[
                    const SizedBox(height: CardsSpace.md),
                    OrderReportCard(report: report, kind: kind),
                  ],
                  const SizedBox(height: CardsSpace.xl),
                  _Section(
                    title: l10n.orderStatusHeading,
                    child: TopUpTimeline(order: order, kind: kind),
                  ),
                  const SizedBox(height: CardsSpace.lg),
                  Text(
                    l10n.orderDetailsHeading,
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: CardsSpace.sm),
                  TopUpReceipt(order: order, target: target, player: ''),
                  const SizedBox(height: CardsSpace.xl),
                  // Again, once this one ended: not while it is still on its way.
                  if (brand != null &&
                      brand.items.isNotEmpty &&
                      !order.status.isOpen)
                    FilledButton(
                      onPressed: () => _again(brand),
                      child: Text(l10n.topUpAgain(kind)),
                    ),
                  if (reportable && (report == null || report.resolved)) ...[
                    const SizedBox(height: CardsSpace.sm),
                    OutlinedButton.icon(
                      onPressed: _report,
                      icon: const Icon(Icons.flag_outlined, size: 18),
                      label: Text(
                        report == null ? l10n.reportProblem : l10n.reportAgain,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Where the top-up is now, in a sentence: on its way, slow this time, on
/// the account, or the money back in the customer's credit.
class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.order,
    required this.kind,
    required this.slow,
  });

  final CardOrder order;
  final String kind;
  final bool slow;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final push = CardsScope.of(context).push;
    final (icon, tone, title, body) = switch (order.status) {
      OrderStatus.paid || OrderStatus.fulfilling when slow => (
        Icons.schedule_rounded,
        scheme.tertiary,
        l10n.topUpSlowTitle(kind),
        push.enabled ? l10n.preparingSlowNotify : l10n.preparingSlowLater,
      ),
      OrderStatus.paid || OrderStatus.fulfilling => (
        Icons.bolt_rounded,
        scheme.primary,
        l10n.topUpPreparingTitle(kind),
        l10n.topUpPreparingBody(
          kind,
          isolatedName(order.name),
          isolated(accountShown(order.account)),
        ),
      ),
      OrderStatus.delivered => (
        Icons.check_circle_rounded,
        scheme.primary,
        l10n.toppedUpTitle(kind),
        l10n.topUpNext(kind),
      ),
      OrderStatus.refunded => (
        Icons.verified_user_rounded,
        scheme.tertiary,
        l10n.topUpRefundedTitle(kind),
        l10n.topUpRefundedBody(kind, formatMoney(l10n, order.total)),
      ),
      _ when order.errorCode == 'payment_mismatch' => (
        Icons.manage_search_rounded,
        scheme.tertiary,
        l10n.paymentReviewTitle,
        l10n.paymentReviewBody,
      ),
      _ => (
        Icons.info_outline_rounded,
        scheme.onSurfaceVariant,
        l10n.unpaidTitle,
        l10n.unpaidBody,
      ),
    };
    final moving =
        order.status == OrderStatus.paid ||
        order.status == OrderStatus.fulfilling;
    return Container(
      padding: const EdgeInsets.all(CardsSpace.lg),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(CardsRadii.card),
        boxShadow: CardsShadows.raised,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: tone.withValues(alpha: 0.14),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: tone, size: 24),
              ),
              const SizedBox(width: CardsSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: CardsSpace.xs),
                    Text(
                      body,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (moving) ...[
            const SizedBox(height: CardsSpace.md),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                minHeight: 4,
                color: tone,
                backgroundColor: tone.withValues(alpha: 0.12),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A heading and its card.
class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: theme.textTheme.titleSmall),
        const SizedBox(height: CardsSpace.sm),
        Container(
          padding: const EdgeInsets.all(CardsSpace.lg),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(CardsRadii.card),
            boxShadow: CardsShadows.raised,
          ),
          child: child,
        ),
      ],
    );
  }
}
