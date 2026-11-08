import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../core/analytics/analytics.dart';
import '../../data/models/catalog.dart';
import '../../data/models/order.dart';
import '../../design/cards_tokens.dart';
import '../../shared/art_palette.dart';
import '../../shared/card_art.dart';
import '../../shared/cards_scope.dart';
import '../../shared/haptics.dart';
import '../../shared/name_text.dart';
import '../../shared/side_back.dart';
import '../../shared/success_seal.dart';
import '../brand/brand_page.dart';
import '../links/cards_link.dart';
import '../orders/order_report_sheet.dart';
import 'topup_receipt.dart';
import 'topup_text.dart';

/// A top-up that arrived: there is no code to turn over, so the moment is
/// the receipt itself. A seal, «تمّ الشحن», the card, whose account it went
/// to (field by field, as the game named them), what to do now, and the way
/// to top up again. Opened later from «كروتي», a top-up is [TopUpOrderPage].
class TopUpDonePage extends StatefulWidget {
  const TopUpDonePage({super.key, required this.order, this.brand});

  final CardOrder order;
  final CardBrand? brand;

  static Future<void> open(
    BuildContext context, {
    required CardOrder order,
    CardBrand? brand,
    bool replace = false,
  }) {
    final route = MaterialPageRoute<void>(
      settings: screenSettings('topped_up'),
      builder: (_) => TopUpDonePage(order: order, brand: brand),
    );
    final navigator = Navigator.of(context);
    return replace ? navigator.pushReplacement(route) : navigator.push(route);
  }

  @override
  State<TopUpDonePage> createState() => _TopUpDonePageState();
}

class _TopUpDonePageState extends State<TopUpDonePage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _seal = AnimationController(
    vsync: this,
    duration: CardsMotion.emphasized,
  );

  /// The player's nickname, when the game gave it as the account was kept.
  String _player = '';

  /// Stops telling the app this order is on screen.
  VoidCallback? _unwatch;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The order's own «تمّ الشحن» notification stays quiet while this is up.
    _unwatch ??= CardsScope.of(context).push.watch(
      widget.order.id,
      () => mounted && (ModalRoute.of(context)?.isCurrent ?? false),
    );
  }

  @override
  void dispose() {
    _unwatch?.call();
    _seal.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    if (!mounted) {
      return;
    }
    final dependencies = CardsScope.of(context);
    if (MediaQuery.of(context).disableAnimations) {
      _seal.value = 1;
    } else {
      Haptics.success();
      unawaited(_seal.forward());
      // It went through: now a notification is worth something.
      unawaited(dependencies.push.offer());
    }
    final values = widget.order.accountValues;
    if (values.isEmpty) {
      return;
    }
    final saved = await dependencies.accounts.of(widget.order.brandKey);
    final known = saved.where((a) => a.same(values)).firstOrNull;
    if (mounted && known != null && known.name.isNotEmpty) {
      setState(() => _player = known.name);
    }
  }

  CardBrand? get _brand =>
      widget.brand ??
      CardsScope.of(context).catalog.brandOf(widget.order.brandKey);

  void _done() => Navigator.of(context).popUntil((route) => route.isFirst);

  /// The same card again, to the same account: the brand's page, which
  /// already has the account filled in. Back to it when it is under this
  /// receipt, opened fresh otherwise.
  void _again(CardBrand brand) {
    final navigator = Navigator.of(context);
    final location = BrandLink(brand.key).location;
    var found = false;
    navigator.popUntil((route) {
      found = route.settings.name == location;
      return found || route.isFirst;
    });
    if (!found) {
      final item = brand.items
          .where((i) => i.key == widget.order.itemKey)
          .firstOrNull;
      BrandPage.open(context, brand, item: item);
    }
  }

  Future<void> _report() async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final report = await showOrderReportSheet(
      context,
      widget.order,
      kind: kindKey(_brand?.target?.kind),
    );
    if (report != null) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.reportSent)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final brand = _brand;
    return ArtPaletteBuilder(
      brand: brand,
      builder: (context, palette) => _page(context, brand, palette),
    );
  }

  Widget _page(BuildContext context, CardBrand? brand, ArtPalette palette) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final order = widget.order;
    final target = brand?.target;
    final kind = kindKey(target?.kind);
    final width = math.min(MediaQuery.sizeOf(context).width * 0.64, 300.0);
    return SideBack(
      edgeToEdge: true,
      close: true,
      tooltip: l10n.closeAction,
      onPressed: _done,
      child: Scaffold(
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          automaticallyImplyLeading: !SideBack.active(context),
          leading: SideBack.active(context)
              ? null
              : IconButton(
                  tooltip: l10n.closeAction,
                  icon: const Icon(Icons.close_rounded),
                  onPressed: _done,
                ),
        ),
        body: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.center,
              colors: [
                palette.tint.withValues(
                  alpha: theme.brightness == Brightness.dark ? 0.35 : 0.16,
                ),
                theme.scaffoldBackgroundColor,
              ],
            ),
          ),
          child: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(
                    CardsSpace.gutter,
                    CardsSpace.sm,
                    CardsSpace.gutter,
                    CardsSpace.xxl,
                  ),
                  children: [
                    SuccessSeal(animation: _seal),
                    const SizedBox(height: CardsSpace.md),
                    Text(
                      l10n.toppedUpTitle(kind),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineSmall,
                    ),
                    NameText(
                      order.name,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    if (brand != null) ...[
                      const SizedBox(height: CardsSpace.xl),
                      Center(
                        child: SizedBox(
                          width: width,
                          child: CardArt(brand: brand),
                        ),
                      ),
                    ],
                    const SizedBox(height: CardsSpace.xl),
                    TopUpReceipt(order: order, target: target, player: _player),
                    const SizedBox(height: CardsSpace.lg),
                    TopUpWhatNext(kind: kind, icon: kindIcon(target?.kind)),
                    const SizedBox(height: CardsSpace.xl),
                    FilledButton(
                      onPressed: _done,
                      child: Text(l10n.doneAction),
                    ),
                    if (brand != null && brand.items.isNotEmpty) ...[
                      const SizedBox(height: CardsSpace.sm),
                      OutlinedButton(
                        onPressed: () => _again(brand),
                        child: Text(l10n.topUpAgain(kind)),
                      ),
                    ],
                    const SizedBox(height: CardsSpace.sm),
                    TextButton.icon(
                      onPressed: _report,
                      icon: const Icon(Icons.flag_outlined, size: 18),
                      label: Text(l10n.reportProblem),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// What to do now that the top-up went through.
class TopUpWhatNext extends StatelessWidget {
  const TopUpWhatNext({super.key, required this.kind, required this.icon});

  final String kind;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(CardsSpace.lg),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(CardsRadii.card),
        boxShadow: CardsShadows.raised,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer,
              shape: BoxShape.circle,
            ),
            child: Icon(
              icon,
              size: 22,
              color: theme.colorScheme.onPrimaryContainer,
            ),
          ),
          const SizedBox(width: CardsSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.whatNextTitle,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: CardsSpace.xs),
                Text(
                  l10n.topUpNext(kind),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
