import 'package:flutter/material.dart';

import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/integration_card.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';
import '../../settings/views/integration_presentation.dart';

/// Pieces of the till's top-up screen, kept out of the screen file so each one
/// can be previewed and tested on its own.

String formatShortDate(DateTime value) {
  String two(int n) => n.toString().padLeft(2, '0');
  return ltrIsolated('${value.year}-${two(value.month)}-${two(value.day)}');
}

String cardHealthLabel(IntegrationCardHealth health, AppLocalizations l10n) {
  return switch (health) {
    IntegrationCardHealth.active => l10n.rechargeHealthActive,
    IntegrationCardHealth.expiringSoon => l10n.rechargeHealthExpiringSoon,
    IntegrationCardHealth.expired => l10n.rechargeHealthExpired,
    IntegrationCardHealth.locked => l10n.rechargeHealthLocked,
    IntegrationCardHealth.unknown => l10n.rechargeHealthUnknown,
  };
}

Color cardHealthColor(
  IntegrationCardHealth health,
  PointySemanticColors colors,
) {
  return switch (health) {
    IntegrationCardHealth.active => colors.success,
    IntegrationCardHealth.expiringSoon => colors.warning,
    IntegrationCardHealth.expired => colors.danger,
    IntegrationCardHealth.locked => colors.danger,
    IntegrationCardHealth.unknown => colors.mutedInk,
  };
}

/// The subscription at a glance: whose card, what shape it is in, when it ends.
class RechargeCardHero extends StatelessWidget {
  const RechargeCardHero({
    super.key,
    required this.card,
    this.balance,
    this.now,
  });

  final IntegrationCardInfo card;
  final double? balance;

  /// Injectable so a preview or a test renders a fixed "today".
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final health = card.health(now: now);
    final days = card.daysRemaining(now: now);

    return PointyDetailHero(
      icon: Icons.sim_card_outlined,
      title: ltrIsolated(card.cardNo),
      value: cardHealthLabel(health, l10n),
      valueSubtitle: days == null
          ? null
          : (days < 0
                ? l10n.rechargeDaysExpired(-days)
                : l10n.rechargeDaysRemaining(days)),
      description: card.packageName.isEmpty ? null : card.packageName,
      gradientColors: [
        cardHealthColor(health, colors),
        cardHealthColor(health, colors).withValues(alpha: 0.72),
      ],
      pills: [
        if (card.expireAt != null)
          PointyHeroPill(
            label: l10n.rechargeExpiresOn(formatShortDate(card.expireAt!)),
            icon: Icons.event_busy_outlined,
          ),
        if (card.startAt != null)
          PointyHeroPill(
            label: l10n.rechargeStartedOn(formatShortDate(card.startAt!)),
            icon: Icons.event_available_outlined,
          ),
        // The provider's own wording, verbatim — a cashier may be asked to
        // read it back over the phone.
        if (card.status.isNotEmpty)
          PointyHeroPill(
            label: providerStatusLabel(card.status, l10n),
            icon: Icons.info_outline,
          ),
        if (balance != null)
          PointyHeroPill(
            label: '${l10n.rechargeFloatLabel}: ${formatMoney(balance!)}',
            icon: Icons.account_balance_wallet_outlined,
          ),
      ],
    );
  }
}

/// The lines one search matched, when it matched more than one.
///
/// A household can hold several lines on one phone number — a live one beside
/// an expired one is ordinary — and the expired one is usually the reason they
/// walked in. Choosing for them would top up the wrong line and leave the
/// customer still cut off, so this asks, and shows each line's state next to
/// its name so the answer is obvious rather than a guess.
class RechargeLinePicker extends StatelessWidget {
  const RechargeLinePicker({
    super.key,
    required this.lines,
    required this.onSelect,
    this.now,
  });

  final List<IntegrationCardInfo> lines;
  final ValueChanged<IntegrationCardInfo> onSelect;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final theme = Theme.of(context);

    return PointyDetailSection(
      title: l10n.rechargeChooseLineHeading,
      icon: Icons.call_split,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.rechargeChooseLinePrompt(lines.length),
            style: theme.textTheme.bodySmall?.copyWith(color: colors.mutedInk),
          ),
          SizedBox(height: spacing.sm),
          for (final line in lines) ...[
            _LineRow(line: line, onTap: () => onSelect(line), now: now),
            SizedBox(height: spacing.xs),
          ],
        ],
      ),
    );
  }
}

class _LineRow extends StatelessWidget {
  const _LineRow({required this.line, required this.onTap, this.now});

  final IntegrationCardInfo line;
  final VoidCallback onTap;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final theme = Theme.of(context);
    final health = line.health(now: now);
    final tone = cardHealthColor(health, colors);

    return Semantics(
      button: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(PointyRadii.card),
        child: Container(
          padding: EdgeInsets.all(spacing.sm),
          decoration: BoxDecoration(
            color: colors.surface,
            border: Border.all(color: colors.line),
            borderRadius: BorderRadius.circular(PointyRadii.card),
          ),
          child: Row(
            children: [
              Container(
                width: 4,
                height: 38,
                decoration: BoxDecoration(
                  color: tone,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              SizedBox(width: spacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      ltrIsolated(line.cardNo),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall,
                    ),
                    if (line.packageName.isNotEmpty)
                      Text(
                        line.packageName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.mutedInk,
                        ),
                      ),
                  ],
                ),
              ),
              SizedBox(width: spacing.sm),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    cardHealthLabel(health, l10n),
                    style: theme.textTheme.labelMedium?.copyWith(color: tone),
                  ),
                  if (line.expireAt != null)
                    Text(
                      formatShortDate(line.expireAt!),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.mutedInk,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Somewhere to type an amount the quick-picks do not cover.
///
/// The provider takes any amount, so a till that only offered the buttons
/// would be less capable than the portal the shop already uses. The field
/// prices as it is typed and says why an amount cannot be sold rather than
/// silently refusing to select it.
class RechargeAmountField extends StatefulWidget {
  const RechargeAmountField({
    super.key,
    required this.spec,
    required this.onChanged,
    required this.problem,
    this.value,
  });

  final IntegrationOpenAmount spec;
  final ValueChanged<double?> onChanged;
  final IntegrationAmountProblem? problem;

  /// The amount currently selected, so tapping a quick-pick can clear this.
  final double? value;

  @override
  State<RechargeAmountField> createState() => _RechargeAmountFieldState();
}

class _RechargeAmountFieldState extends State<RechargeAmountField> {
  late final TextEditingController _controller = TextEditingController(
    text: _format(widget.value),
  );

  static String _format(double? value) {
    if (value == null) return '';
    return value == value.roundToDouble()
        ? value.toStringAsFixed(0)
        : value.toString();
  }

  @override
  void didUpdateWidget(RechargeAmountField old) {
    super.didUpdateWidget(old);
    // A quick-pick tap clears the typed amount upstream; follow it here so the
    // field cannot keep showing a number that is not what will be sold.
    if (widget.value == null && old.value != null && _controller.text.isNotEmpty) {
      _controller.clear();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String? _problemText(AppLocalizations l10n) {
    return switch (widget.problem) {
      IntegrationAmountProblem.belowMinimum => l10n.rechargeAmountBelowMinimum(
        formatMoney(widget.spec.minimum),
      ),
      IntegrationAmountProblem.aboveMaximum => l10n.rechargeAmountAboveMaximum(
        formatMoney(widget.spec.maximum ?? 0),
      ),
      IntegrationAmountProblem.notAMultiple => l10n.rechargeAmountNotWhole,
      IntegrationAmountProblem.notPositive => l10n.rechargeAmountInvalid,
      null => null,
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return TextField(
      controller: _controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      textDirection: TextDirection.ltr,
      decoration: InputDecoration(
        labelText: l10n.rechargeCustomAmountLabel,
        hintText: l10n.rechargeCustomAmountHint,
        prefixIcon: const Icon(Icons.edit_outlined),
        errorText: _problemText(l10n),
      ),
      onChanged: (raw) {
        final text = raw.trim();
        widget.onChanged(text.isEmpty ? null : double.tryParse(text));
      },
    );
  }
}

/// The price ladder, as big tap targets. Nothing is preselected: a default
/// duration is a sale waiting to be made by accident.
class RechargeOfferGrid extends StatelessWidget {
  const RechargeOfferGrid({
    super.key,
    required this.offers,
    required this.selected,
    required this.onSelect,
  });

  final List<IntegrationOffer> offers;
  final IntegrationOffer? selected;
  final ValueChanged<IntegrationOffer> onSelect;

  /// Narrowest a tile may get before the grid drops a column. Sized for a
  /// till: "12 شهراً" beside "245.00 د.ل" has to fit without eliding.
  static const double minTileWidth = 140;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        // Tiles are sized to fill the row rather than left at a fixed width:
        // a fixed width leaves a ragged edge wherever the pane is not an
        // exact multiple of it, which on a two-column till reads as a broken
        // layout rather than a deliberate one.
        final available = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : minTileWidth;
        final gap = spacing.sm;
        var columns = ((available + gap) / (minTileWidth + gap)).floor();
        columns = columns.clamp(1, offers.isEmpty ? 1 : offers.length);
        final width = (available - gap * (columns - 1)) / columns;

        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final offer in offers)
              SizedBox(
                width: width,
                child: _OfferCard(
                  offer: offer,
                  isSelected: selected?.code == offer.code,
                  onTap: () => onSelect(offer),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _OfferCard extends StatelessWidget {
  const _OfferCard({
    required this.offer,
    required this.isSelected,
    required this.onTap,
  });

  final IntegrationOffer offer;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final theme = Theme.of(context);

    // A duration card names the duration; a top-up card names the amount of
    // credit. Its provider label ("45 LYD") would otherwise repeat the price
    // underneath in a second currency notation, which reads as two numbers.
    final face = offer.faceValue;
    final title = offer.months > 0
        ? l10n.rechargeMonths(offer.months)
        : (offer.isTopUp && face != null ? formatMoney(face) : offer.label);
    // Only worth a second line when the shop charges something other than the
    // face value; otherwise one number is the whole truth.
    final showsPrice = !offer.isTopUp || face == null || offer.price != face;

    return Semantics(
      selected: isSelected,
      button: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(PointyRadii.card),
        child: Container(
          padding: EdgeInsets.all(spacing.sm),
          decoration: BoxDecoration(
            color: isSelected ? colors.primaryContainer : colors.surface,
            border: Border.all(
              color: isSelected ? colors.primaryStrong : colors.line,
              width: isSelected ? 2 : 1,
            ),
            borderRadius: BorderRadius.circular(PointyRadii.card),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: showsPrice
                          ? theme.textTheme.titleSmall
                          : theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                              color:
                                  isSelected ? colors.primaryDark : colors.ink,
                            ),
                    ),
                  ),
                  if (isSelected)
                    Icon(
                      Icons.check_circle,
                      size: 18,
                      color: colors.primaryStrong,
                    ),
                ],
              ),
              if (showsPrice) ...[
                SizedBox(height: spacing.xs),
                Text(
                  formatMoney(offer.price),
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: isSelected ? colors.primaryDark : colors.ink,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// One page of the card's history, with the provider's own paging.
class RechargeHistoryList extends StatelessWidget {
  const RechargeHistoryList({
    super.key,
    required this.page,
    required this.isLoading,
    required this.onPrevious,
    required this.onNext,
  });

  final IntegrationHistoryPage? page;
  final bool isLoading;
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final current = page;

    if (isLoading && current == null) {
      return const Column(
        children: [
          PointySkeletonListTile(),
          PointySkeletonListTile(),
          PointySkeletonListTile(),
        ],
      );
    }
    if (current == null || (!current.ok && current.length == 0)) {
      return PointyInlineMessage(
        message: current == null
            ? l10n.rechargeHistoryEmpty
            : l10n.rechargeHistoryError,
        icon: Icons.history_toggle_off_outlined,
        compact: true,
      );
    }
    if (current.length == 0) {
      return PointyInlineMessage(
        message: l10n.rechargeHistoryEmpty,
        icon: Icons.history_toggle_off_outlined,
        compact: true,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (current.kind == IntegrationHistoryKind.purchases)
          for (final entry in current.purchases) _PurchaseRow(entry: entry)
        else
          for (final entry in current.statuses) _StatusRow(entry: entry),
        SizedBox(height: spacing.sm),
        _Pager(
          page: current,
          isLoading: isLoading,
          onPrevious: onPrevious,
          onNext: onNext,
        ),
      ],
    );
  }
}

class _PurchaseRow extends StatelessWidget {
  const _PurchaseRow({required this.entry});

  final IntegrationPurchaseEntry entry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final theme = Theme.of(context);

    return Padding(
      padding: EdgeInsets.symmetric(vertical: spacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            entry.isOurs
                ? Icons.storefront_outlined
                : Icons.store_mall_directory_outlined,
            size: 18,
            // Whose sale it was is the point of showing this list at all.
            color: entry.isOurs ? colors.success : colors.mutedInk,
          ),
          SizedBox(width: spacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.months > 0
                      ? l10n.rechargeMonths(entry.months)
                      : entry.packageName,
                  style: theme.textTheme.bodyMedium,
                ),
                Text(
                  '${entry.isOurs ? l10n.rechargeHistoryOurs : l10n.rechargeHistoryOther}'
                  '${entry.operatorName.isEmpty ? '' : ' · ${entry.operatorName}'}'
                  '${entry.at == null ? '' : ' · ${formatShortDate(entry.at!)}'}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.mutedInk,
                  ),
                ),
              ],
            ),
          ),
          if (entry.cost != null)
            Text(
              formatMoney(entry.cost!),
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
        ],
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.entry});

  final IntegrationStatusEntry entry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final theme = Theme.of(context);

    return Padding(
      padding: EdgeInsets.symmetric(vertical: spacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            entry.isAutomatic ? Icons.schedule : Icons.person_outline,
            size: 18,
            color: colors.mutedInk,
          ),
          SizedBox(width: spacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.rechargeHistoryStatusChange(
                    providerStatusLabel(entry.fromStatus, l10n),
                    providerStatusLabel(entry.toStatus, l10n),
                  ),
                  style: theme.textTheme.bodyMedium,
                ),
                Text(
                  '${entry.isAutomatic ? l10n.rechargeHistoryAutomatic : entry.operatorName}'
                  '${entry.at == null ? '' : ' · ${formatShortDate(entry.at!)}'}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.mutedInk,
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

class _Pager extends StatelessWidget {
  const _Pager({
    required this.page,
    required this.isLoading,
    required this.onPrevious,
    required this.onNext,
  });

  final IntegrationHistoryPage page;
  final bool isLoading;
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // The history sits in a half-width column on a wide till and a full-width
    // one on a phone, so the pager has to survive being squeezed. The page
    // counter yields first; the two controls never do.
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        // chevron_left/right carry matchTextDirection: true, so Flutter
        // already flips them under RTL. Naming them by how they should *look*
        // in Arabic mirrors a second time and lands back pointing the wrong
        // way — so they are named in LTR-logical terms and left to Flutter.
        IconButton(
          onPressed: isLoading || !page.hasPrevious ? null : onPrevious,
          icon: const Icon(Icons.chevron_left),
          tooltip: l10n.rechargeHistoryPrevious,
        ),
        Flexible(
          child: Text(
            l10n.rechargeHistoryPage(page.pageNumber, page.pageCount),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: context.pointyColors.mutedInk,
            ),
          ),
        ),
        IconButton(
          onPressed: isLoading || !page.hasNext ? null : onNext,
          icon: const Icon(Icons.chevron_right),
          tooltip: l10n.rechargeHistoryNext,
        ),
      ],
    );
  }
}

/// Who this card belongs to — and a way to say, when nobody has.
///
/// The provider will not tell us: HD Box masks the subscriber's name and
/// phone from an agency login. So the card arrives anonymous, and the only
/// moment anyone can name it is while its owner is standing at the counter.
/// A card that stays anonymous is a renewal nobody can remind anyone about.
class RechargeSubscriberStrip extends StatefulWidget {
  const RechargeSubscriberStrip({
    super.key,
    required this.subscriber,
    required this.onName,
  });

  final IntegrationSubscriber? subscriber;
  final Future<bool> Function(String name) onName;

  @override
  State<RechargeSubscriberStrip> createState() =>
      _RechargeSubscriberStripState();
}

class _RechargeSubscriberStripState extends State<RechargeSubscriberStrip> {
  final _name = TextEditingController();
  bool _editing = false;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final value = _name.text.trim();
    if (value.isEmpty) return;
    setState(() => _saving = true);
    final ok = await widget.onName(value);
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (ok) _editing = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final theme = Theme.of(context);
    final subscriber = widget.subscriber;

    final facts = <String>[
      if (subscriber != null && subscriber.deviceModel.isNotEmpty)
        l10n.rechargeSubscriberDevice(subscriber.deviceModel),
      if (subscriber != null &&
          subscriber.purchaseCount > 0 &&
          subscriber.lifetimeSpend != null)
        l10n.rechargeSubscriberLifetime(
          subscriber.purchaseCount,
          formatMoney(subscriber.lifetimeSpend!),
        ),
    ];

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.subtleFill,
        borderRadius: BorderRadius.circular(PointyRadii.card),
      ),
      child: Padding(
        padding: EdgeInsets.all(spacing.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_editing)
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _name,
                      autofocus: true,
                      decoration: InputDecoration(
                        isDense: true,
                        labelText: l10n.rechargeSubscriberName,
                      ),
                      onSubmitted: (_) => _save(),
                    ),
                  ),
                  SizedBox(width: spacing.sm),
                  FilledButton(
                    onPressed: _saving ? null : _save,
                    child: Text(l10n.rechargeSubscriberSave),
                  ),
                ],
              )
            else
              Row(
                children: [
                  Icon(
                    subscriber?.isIdentified == true
                        ? Icons.person_outline
                        : Icons.person_add_alt_outlined,
                    size: 18,
                    color: colors.mutedInk,
                  ),
                  SizedBox(width: spacing.sm),
                  Expanded(
                    child: Text(
                      subscriber?.isIdentified == true
                          ? subscriber!.label
                          : l10n.rechargeSubscriberUnknown,
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                  TextButton(
                    onPressed: () {
                      _name.text = subscriber?.displayName ?? '';
                      setState(() => _editing = true);
                    },
                    child: Text(
                      subscriber?.isIdentified == true
                          ? l10n.integrationEdit
                          : l10n.rechargeSubscriberName,
                    ),
                  ),
                ],
              ),
            if (facts.isNotEmpty)
              Padding(
                padding: EdgeInsetsDirectional.only(start: spacing.lg),
                child: Text(
                  facts.join(' • '),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.mutedInk,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
