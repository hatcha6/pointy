import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../core/result.dart';
import '../../data/models/esim.dart';
import '../../data/models/order.dart';
import '../../design/cards_layout.dart';
import '../../design/cards_tokens.dart';
import '../../shared/card_art.dart';
import '../../shared/cards_scope.dart';
import '../../shared/empty_state.dart';
import '../../shared/glass_edge_header.dart';
import '../../shared/grouped.dart';
import '../../shared/pill.dart';
import '../../shared/pressable.dart';
import '../../shared/section_header.dart';
import '../../shared/money_text.dart';
import '../../shared/native_glass_chips.dart';
import '../../shared/relay_error_text.dart';
import '../../shared/skeleton.dart';
import '../esim/esim_page.dart';
import '../esim/esim_store_page.dart';
import '../orders/order_progress_page.dart';
import '../reveal/reveal_page.dart';
import '../topup/topup_order_page.dart';
import '../topup/topup_text.dart';
import '../sign_in/sign_in_sheet.dart';
import '../../shared/haptics.dart';
import '../shell/cards_tab_bar.dart';
import '../../core/analytics/analytics.dart';
import '../../shared/name_text.dart';

/// What the list shows. «الكل» is the cards themselves: purchases that did
/// not go through only clutter it, so they wait under their own filter.
enum _Filter {
  all('square.stack'),
  unused('creditcard'),
  used('checkmark.circle'),
  incomplete('exclamationmark.circle');

  const _Filter(this.symbol);

  /// Its SF Symbol on the system's glass chips.
  final String symbol;

  String label(AppLocalizations l10n) => switch (this) {
    all => l10n.allCategories,
    unused => l10n.filterUnused,
    used => l10n.filterUsed,
    incomplete => l10n.filterIncomplete,
  };
}

/// Every card the customer bought, on any device: open orders first, then the
/// cards, newest first. Codes stay behind the lock until asked for.
class MyCardsPage extends StatefulWidget {
  const MyCardsPage({super.key, this.onBrowse});

  final VoidCallback? onBrowse;

  @override
  State<MyCardsPage> createState() => _MyCardsPageState();
}

class _MyCardsPageState extends State<MyCardsPage> {
  List<CardOrder>? _orders;
  Object? _error;
  Set<String> _used = {};
  _Filter _filter = _Filter.all;
  Map<String, List<CardCode>> _saved = {};
  List<CustomerEsim> _esims = const [];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_orders == null && _error == null) {
      _load();
    }
  }

  Future<void> _load() async {
    final dependencies = CardsScope.of(context);
    if (!dependencies.auth.isSignedIn) {
      return;
    }
    final result = await dependencies.orders.orders();
    final esims = await dependencies.esim.esims();
    final used = await dependencies.vault.usedCodes();
    final saved = <String, List<CardCode>>{};
    if (result case Ok(:final value)) {
      for (final order in value.where(
        (o) => o.status == OrderStatus.delivered,
      )) {
        final codes = await dependencies.vault.codes(order.id);
        if (codes != null) {
          saved[order.id] = codes;
        }
      }
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _used = used;
      _saved = saved;
      if (esims case Ok(:final value)) {
        _esims = value;
      }
      switch (result) {
        case Ok(:final value):
          // A delivered eSIM lives in its own section, not as a card.
          _orders = value
              .where(
                (o) =>
                    o.status != OrderStatus.cancelled &&
                    !(o.isEsim && o.status == OrderStatus.delivered),
              )
              .toList();
          _error = null;
        case Error(:final exception):
          _error = exception;
      }
    });
  }

  /// Nothing of it is left to use: every code marked used, or a top-up
  /// already on its account.
  bool _allUsed(CardOrder order) {
    if (order.toAccount) {
      return true;
    }
    final codes = _saved[order.id];
    return codes != null &&
        codes.isNotEmpty &&
        codes.every((c) => _used.contains(c.code));
  }

  Future<void> _open(CardOrder order) async {
    await openCardOrder(context, order);
    if (mounted) {
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = CardsScope.of(context).auth;
    // Read outside the safe area: the header's fade reaches up under it.
    final padding = MediaQuery.paddingOf(context);
    return SafeArea(
      bottom: false,
      child: ValueListenableBuilder(
        valueListenable: auth.session,
        // A quick cross-fade from the placeholders to what came back, so a
        // fast answer reads as the page settling, not as a flicker.
        builder: (context, session, _) => AnimatedSwitcher(
          duration: CardsMotion.standard,
          switchInCurve: CardsMotion.curve,
          switchOutCurve: CardsMotion.curve,
          child: _page(context, session, padding),
        ),
      ),
    );
  }

  Widget _page(BuildContext context, Object? session, EdgeInsets padding) {
    final l10n = AppLocalizations.of(context);
    if (session == null) {
      return EmptyState(
        key: const ValueKey('signed-out'),
        icon: Icons.style_rounded,
        title: l10n.tabMyCards,
        body: l10n.myCardsSignedOutBody,
        actionLabel: l10n.signInAction,
        onAction: () async {
          if (await ensureSignedIn(context)) {
            await _load();
          }
        },
      );
    }
    final orders = _orders;
    if (orders == null && _error != null) {
      return EmptyState(
        key: const ValueKey('failed'),
        icon: Icons.cloud_off_rounded,
        title: l10n.catalogLoadFailedTitle,
        body: relayErrorText(l10n, _error!),
        actionLabel: l10n.retryAction,
        onAction: _load,
      );
    }
    if (orders != null && orders.isEmpty && _esims.isEmpty) {
      return EmptyState(
        key: const ValueKey('empty'),
        icon: Icons.style_rounded,
        title: l10n.myCardsEmptyTitle,
        body: l10n.myCardsEmptyBody,
        actionLabel: l10n.browseAction,
        onAction: widget.onBrowse,
      );
    }
    final open = (orders ?? const <CardOrder>[])
        .where((o) => o.status.isOpen)
        .toList();
    final done =
        (orders ?? const <CardOrder>[]).where((order) {
          if (order.status.isOpen) {
            return false;
          }
          if (order.status != OrderStatus.delivered) {
            return _filter == _Filter.incomplete;
          }
          return switch (_filter) {
            _Filter.all => true,
            _Filter.unused => !_allUsed(order),
            _Filter.used => _allUsed(order),
            _Filter.incomplete => false,
          };
        }).toList()..sort(
          (a, b) => (b.createdAt ?? DateTime(0)).compareTo(
            a.createdAt ?? DateTime(0),
          ),
        );
    final theme = Theme.of(context);
    return RefreshIndicator(
      key: const ValueKey('orders'),
      onRefresh: _load,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final column = CardsLayout.column(constraints.maxWidth);
          final inColumn = EdgeInsets.only(
            left: column.left,
            right: column.right,
          );
          final filters = CardsTabBar.nativeGlass
              // The glass chips run edge to edge, the first in line
              // with the page.
              ? NativeGlassChips(
                  gutter: column.left,
                  chips: [
                    for (final filter in _Filter.values)
                      (
                        key: filter.name,
                        label: filter.label(l10n),
                        symbol: filter.symbol,
                      ),
                  ],
                  selected: _filter.name,
                  onSelect: (key) =>
                      setState(() => _filter = _Filter.values.byName(key)),
                )
              : Padding(
                  padding: inColumn,
                  child: Center(
                    child: SegmentedPill<_Filter>(
                      segments: [
                        for (final filter in _Filter.values)
                          (filter, filter.label(l10n)),
                      ],
                      selected: _filter,
                      onChanged: (value) {
                        Haptics.select();
                        setState(() => _filter = value);
                      },
                    ),
                  ),
                );
          return CustomScrollView(
            // Unclipped where the header's fade reaches up under the
            // status bar: the cards run on beneath it.
            clipBehavior: CardsTabBar.nativeGlass ? Clip.none : Clip.hardEdge,
            slivers: [
              SliverPadding(
                padding: inColumn.copyWith(
                  top: GlassEdgeHeader.topFor(padding) + CardsSpace.xl,
                  bottom: CardsSpace.md,
                ),
                sliver: SliverToBoxAdapter(
                  child: Text(
                    l10n.tabMyCards,
                    style: theme.textTheme.headlineLarge,
                  ),
                ),
              ),
              // The filters stay in reach, pinned like the shelf's
              // categories.
              SliverPersistentHeader(
                pinned: true,
                delegate: GlassEdgeHeader(
                  top: GlassEdgeHeader.topFor(padding),
                  statusBar: padding.top,
                  childHeight: NativeGlassChips.height,
                  child: filters,
                ),
              ),
              SliverPadding(
                padding: inColumn.copyWith(
                  bottom: CardsTabBar.clearance(context),
                ),
                sliver: SliverToBoxAdapter(
                  child: AnimatedSwitcher(
                    duration: CardsMotion.standard,
                    switchInCurve: CardsMotion.curve,
                    switchOutCurve: CardsMotion.curve,
                    layoutBuilder: (current, previous) => Stack(
                      alignment: Alignment.topCenter,
                      children: [...previous, ?current],
                    ),
                    child: Column(
                      key: ValueKey(orders == null),
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (orders == null)
                          for (var i = 0; i < 4; i++)
                            const Padding(
                              padding: EdgeInsets.only(top: CardsSpace.md),
                              child: Skeleton(
                                height: 92,
                                radius: CardsRadii.card,
                              ),
                            ),
                        // The filters are about cards' codes; an eSIM is neither.
                        if (_esims.isNotEmpty && _filter == _Filter.all) ...[
                          SectionHeader(
                            title: l10n.esimMineTitle,
                            padding: const EdgeInsets.only(
                              top: CardsSpace.md,
                              bottom: CardsSpace.sm,
                            ),
                          ),
                          EsimMineList(esims: _esims, onChanged: _load),
                        ],
                        if (open.isNotEmpty) ...[
                          SectionHeader(
                            title: l10n.inProgressSection,
                            padding: const EdgeInsets.only(
                              top: CardsSpace.md,
                              bottom: CardsSpace.sm,
                            ),
                          ),
                          for (final order in open)
                            Padding(
                              padding: const EdgeInsets.only(
                                bottom: CardsSpace.md,
                              ),
                              child: _OrderRow(
                                order: order,
                                used: false,
                                onTap: () => _open(order),
                              ),
                            ),
                        ],
                        if (done.isNotEmpty) ...[
                          SectionHeader(
                            title: l10n.myCardsSection,
                            padding: EdgeInsets.only(
                              top: open.isEmpty ? CardsSpace.md : CardsSpace.xl,
                              bottom: CardsSpace.sm,
                            ),
                          ),
                          for (final order in done)
                            Padding(
                              padding: const EdgeInsets.only(
                                bottom: CardsSpace.md,
                              ),
                              child: _OrderRow(
                                order: order,
                                used: _allUsed(order),
                                onTap: () => _open(order),
                              ),
                            ),
                        ],
                        // A filter with nothing in it says why, rather than
                        // leaving a blank page.
                        if (orders != null &&
                            done.isEmpty &&
                            _filter != _Filter.all)
                          _FilterEmpty(filter: _filter),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// What an empty filter says: what would be there, and how it gets there.
class _FilterEmpty extends StatelessWidget {
  const _FilterEmpty({required this.filter});

  final _Filter filter;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final (icon, title, body) = switch (filter) {
      _Filter.unused => (
        Icons.credit_card_rounded,
        l10n.myCardsNoneUnusedTitle,
        l10n.myCardsNoneUnusedBody,
      ),
      _Filter.used => (
        Icons.check_circle_outline_rounded,
        l10n.myCardsNoneUsedTitle,
        l10n.myCardsNoneUsedBody,
      ),
      _Filter.incomplete || _Filter.all => (
        Icons.verified_outlined,
        l10n.myCardsNoneIncompleteTitle,
        l10n.myCardsNoneIncompleteBody,
      ),
    };
    return Padding(
      key: ValueKey('filter-empty-${filter.name}'),
      padding: const EdgeInsets.symmetric(
        horizontal: CardsSpace.xl,
        vertical: CardsSpace.xxl,
      ),
      child: Column(
        children: [
          Icon(icon, size: 40, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(height: CardsSpace.md),
          Text(
            title,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: CardsSpace.xs),
          Text(
            body,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _OrderRow extends StatelessWidget {
  const _OrderRow({
    required this.order,
    required this.used,
    required this.onTap,
  });

  final CardOrder order;
  final bool used;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final brand = CardsScope.of(context).catalog.brandOf(order.brandKey);
    final kind = kindKey(brand?.target?.kind);
    final (status, tone) = switch (order.status) {
      OrderStatus.delivered when order.toAccount => (
        l10n.statusToppedUp(kind),
        PillTone.success,
      ),
      OrderStatus.delivered => (used ? l10n.usedBadge : null, PillTone.muted),
      OrderStatus.awaitingPayment => (
        l10n.statusAwaitingPayment,
        PillTone.warning,
      ),
      OrderStatus.paid || OrderStatus.fulfilling when order.toAccount => (
        l10n.statusToppingUp,
        PillTone.info,
      ),
      OrderStatus.paid ||
      OrderStatus.fulfilling => (l10n.statusPreparing, PillTone.info),
      OrderStatus.refunded => (l10n.statusRefunded, PillTone.success),
      _ when order.errorCode == 'payment_mismatch' => (
        l10n.statusReview,
        PillTone.warning,
      ),
      _ => (l10n.statusUnpaid, PillTone.danger),
    };
    return Pressable(
      semanticLabel: order.name,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(CardsSpace.md),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(CardsRadii.card),
          boxShadow: CardsShadows.raised,
        ),
        child: Row(
          children: [
            SizedBox(
              width: 104,
              child: brand == null
                  ? const Skeleton(aspectRatio: kCardAspect)
                  : CardArt(
                      brand: brand,
                      radius: 10,
                      shadow: false,
                      // A top-up on its account is done, not spent.
                      muted: used && !order.toAccount,
                    ),
            ),
            const SizedBox(width: CardsSpace.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  NameText(
                    order.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    order.toAccount && order.account.isNotEmpty
                        ? '${l10n.orderTo(isolated(accountShown(order.account)))} · ${formatMoney(l10n, order.total)}'
                        : '${l10n.cardCount(order.quantity)} · ${formatMoney(l10n, order.total)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (status != null) ...[
                    const SizedBox(height: CardsSpace.sm),
                    // Smaller rather than cut off in a narrow row at a large
                    // text size.
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: AlignmentDirectional.centerStart,
                      child: Pill(text: status, tone: tone),
                    ),
                  ],
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

/// Opens one order as «كروتي» does: a delivered card shows its code (behind
/// the phone's lock, when the customer set one), and an order still on its
/// way shows how it is going.
Future<void> openCardOrder(BuildContext context, CardOrder order) async {
  if (order.isEsim && order.status == OrderStatus.delivered) {
    await EsimPage.openDelivered(context, order);
    return;
  }
  final brand = CardsScope.of(context).catalog.brandOf(order.brandKey);
  // A top-up past paying: where it stands, live, with a way to report it.
  if (order.toAccount && order.status != OrderStatus.awaitingPayment) {
    await TopUpOrderPage.open(context, order: order, brand: brand);
  } else if (order.status == OrderStatus.delivered) {
    await Navigator.of(context).push(
      MaterialPageRoute(
        settings: screenSettings('card'),
        builder: (_) =>
            RevealPage(order: order, brand: brand, fromHistory: true),
      ),
    );
  } else {
    await OrderProgressPage.open(context, order: order, brand: brand);
  }
}
