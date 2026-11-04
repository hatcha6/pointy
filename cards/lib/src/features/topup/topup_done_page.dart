import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_brand/pointy_brand.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../core/analytics/analytics.dart';
import '../../core/support.dart';
import '../../data/models/account_target.dart';
import '../../data/models/catalog.dart';
import '../../data/models/order.dart';
import '../../design/cards_tokens.dart';
import '../../shared/art_palette.dart';
import '../../shared/card_art.dart';
import '../../shared/cards_scope.dart';
import '../../shared/grouped.dart';
import '../../shared/haptics.dart';
import '../../shared/money_text.dart';
import '../../shared/name_text.dart';
import '../../shared/side_back.dart';
import '../../shared/success_seal.dart';
import '../brand/brand_page.dart';
import '../links/cards_link.dart';
import 'topup_text.dart';

/// A top-up that arrived: there is no code to turn over, so the moment is
/// the receipt itself. A seal, «تمّ الشحن», the card, whose account it went
/// to (field by field, as the game named them), what to do now, and the way
/// to top up again. Opened from «كروتي» it is the same receipt, without the
/// celebration.
class TopUpDonePage extends StatefulWidget {
  const TopUpDonePage({
    super.key,
    required this.order,
    this.brand,
    this.fromHistory = false,
  });

  final CardOrder order;
  final CardBrand? brand;
  final bool fromHistory;

  static Future<void> open(
    BuildContext context, {
    required CardOrder order,
    CardBrand? brand,
    bool fromHistory = false,
    bool replace = false,
  }) {
    final route = MaterialPageRoute<void>(
      settings: screenSettings('topped_up'),
      builder: (_) =>
          TopUpDonePage(order: order, brand: brand, fromHistory: fromHistory),
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
    if (widget.fromHistory || MediaQuery.of(context).disableAnimations) {
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

  Future<void> _help() async {
    final l10n = AppLocalizations.of(context);
    final url = Support.whatsAppUrl.replace(
      queryParameters: {'text': l10n.topUpHelpMessage(widget.order.id)},
    );
    await launchUrl(url, mode: LaunchMode.externalApplication);
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
    final history = widget.fromHistory;
    final width = math.min(MediaQuery.sizeOf(context).width * 0.64, 300.0);
    return SideBack(
      edgeToEdge: true,
      close: !history,
      tooltip: history ? null : l10n.closeAction,
      onPressed: history ? null : _done,
      child: Scaffold(
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          title: history ? NameText(order.name, maxLines: 1) : null,
          automaticallyImplyLeading: !SideBack.active(context),
          leading: history || SideBack.active(context)
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
                    _Receipt(order: order, target: target, player: _player),
                    const SizedBox(height: CardsSpace.lg),
                    _WhatNext(kind: kind, icon: kindIcon(target?.kind)),
                    const SizedBox(height: CardsSpace.xl),
                    if (!history)
                      FilledButton(
                        onPressed: _done,
                        child: Text(l10n.doneAction),
                      ),
                    if (brand != null && brand.items.isNotEmpty) ...[
                      if (!history) const SizedBox(height: CardsSpace.sm),
                      if (history)
                        FilledButton(
                          onPressed: () => _again(brand),
                          child: Text(l10n.topUpAgain(kind)),
                        )
                      else
                        OutlinedButton(
                          onPressed: () => _again(brand),
                          child: Text(l10n.topUpAgain(kind)),
                        ),
                    ],
                    const SizedBox(height: CardsSpace.sm),
                    TextButton.icon(
                      onPressed: _help,
                      icon: const Icon(Icons.support_agent_rounded, size: 18),
                      label: Text(l10n.topUpHelp),
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

/// The receipt: the account part by part under the game's own labels, the
/// player, what was paid, when, and the order's number to quote.
class _Receipt extends StatelessWidget {
  const _Receipt({
    required this.order,
    required this.target,
    required this.player,
  });

  final CardOrder order;
  final AccountTarget? target;
  final String player;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final local = MaterialLocalizations.of(context);
    final when = (order.completedAt ?? order.paidAt ?? order.createdAt)
        ?.toLocal();
    final values = order.accountValues;
    final fields = target?.fields
        .where((f) => (values[f.key] ?? '').isNotEmpty)
        .toList();
    return Grouped(
      children: [
        if (fields != null && fields.isNotEmpty)
          for (final field in fields)
            _Row(
              label: field.label,
              value: _shown(field, values[field.key]!),
              ltr: !field.isSelect,
            )
        else if (order.account.isNotEmpty)
          _Row(label: l10n.receiptTo, value: order.account, ltr: true),
        if (player.isNotEmpty)
          _Row(label: l10n.receiptPlayer, value: player, ltr: true),
        _Row(label: l10n.receiptPaid, value: formatMoney(l10n, order.total)),
        if (when != null)
          _Row(
            label: l10n.receiptWhen,
            // The app's digits are 0–9 throughout; the date names come in
            // the reader's language.
            value: asciiDigits(
              '${local.formatMediumDate(when)} · '
              '${local.formatTimeOfDay(TimeOfDay.fromDateTime(when))}',
            ),
          ),
        _Row(
          label: l10n.receiptOrder,
          value: order.id,
          ltr: true,
          small: true,
          onTap: () {
            Clipboard.setData(ClipboardData(text: order.id));
            Haptics.select();
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text(l10n.orderIdCopied)));
          },
        ),
      ],
    );
  }

  /// A value as the receipt shows it: a choice by its label, and an invite
  /// link by its friend code alone (its token is what lets anyone in).
  String _shown(TargetField field, String value) {
    if (field.isSelect) {
      return field.optionLabel(value);
    }
    if (target?.kind == TargetKind.steamInvite) {
      final match = RegExp(r's\.team/p/[^/\s]+').firstMatch(value);
      return match?.group(0) ?? value;
    }
    if (target?.kind == TargetKind.telegram) {
      return '@$value';
    }
    return value;
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.label,
    required this.value,
    this.ltr = false,
    this.small = false,
    this.onTap,
  });

  final String label;
  final String value;
  final bool ltr;
  final bool small;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = small
        ? theme.textTheme.bodySmall
        : theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: CardsSpace.lg,
          vertical: CardsSpace.md,
        ),
        child: Row(
          children: [
            Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: CardsSpace.lg),
            Expanded(
              child: Text(
                value,
                // Every value against the row's far edge, an ID's too.
                textAlign: Directionality.of(context) == TextDirection.rtl
                    ? TextAlign.left
                    : TextAlign.right,
                textDirection: ltr ? TextDirection.ltr : null,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: style == null ? null : PointyTypography.numeric(style),
              ),
            ),
            if (onTap != null) ...[
              const SizedBox(width: CardsSpace.sm),
              Icon(
                Icons.copy_rounded,
                size: 16,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _WhatNext extends StatelessWidget {
  const _WhatNext({required this.kind, required this.icon});

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
