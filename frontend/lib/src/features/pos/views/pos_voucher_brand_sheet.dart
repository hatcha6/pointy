import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/product_variant.dart';
import '../../../data/models/voucher_menu.dart';
import '../../../shared/components/components.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';
import 'voucher_card_art.dart';
import 'voucher_country_flag.dart';

/// One brand's cards, to pick one: its countries as flagged chips when it
/// sells for more than one, then its denominations. Resolves to the variant
/// the cart line points at — whose name the server wrote as country and
/// denomination («الولايات المتحدة · 10 دولار»), so the line says exactly
/// what was sold.
Future<ProductVariant?> showPosVoucherBrandSheet(
  BuildContext context, {
  required VoucherBrand brand,
  required VoucherMenu menu,
  required bool showsProfit,
}) {
  return showAdaptiveModalBottomSheet<ProductVariant>(
    context: context,
    builder: (sheetContext) => PosVoucherBrandPicker(
      brand: brand,
      countryFor: menu.country,
      balance: menu.balance,
      showsProfit: showsProfit,
      onPicked: (variant) => Navigator.of(sheetContext).pop(variant),
    ),
  );
}

/// Public, and callback-driven, so the preview harness and widget tests can
/// draw every state without a till behind it.
class PosVoucherBrandPicker extends StatefulWidget {
  const PosVoucherBrandPicker({
    super.key,
    required this.brand,
    required this.countryFor,
    required this.onPicked,
    this.balance,
    this.initialCountry,
    this.showsProfit = true,
  });

  final VoucherBrand brand;
  final VoucherCountry Function(String code) countryFor;
  final ValueChanged<ProductVariant> onPicked;

  /// The voucher balance the cards are paid from, as last read.
  final double? balance;

  /// The country to open on; the brand's first otherwise.
  final String? initialCountry;

  /// Whether each card's profit is shown — when the server sent its cost
  /// (owners) AND cost is revealed at the till (F9), like the cart's margin:
  /// the screen faces customers too.
  final bool showsProfit;

  @override
  State<PosVoucherBrandPicker> createState() => _PosVoucherBrandPickerState();
}

class _PosVoucherBrandPickerState extends State<PosVoucherBrandPicker> {
  String? _country;

  @override
  void initState() {
    super.initState();
    final codes = widget.brand.countryCodes;
    final initial = widget.initialCountry;
    _country = initial != null && codes.contains(initial)
        ? initial
        : codes.firstOrNull;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final brand = widget.brand;
    final codes = brand.countryCodes;
    final items = codes.length > 1 ? brand.itemsFor(_country) : brand.items;
    final balance = widget.balance;

    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(spacing.md, 0, spacing.md, spacing.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(
              brand: brand,
              // One country: no chips to pick from, but the customer is
              // still told which country the card is for.
              country: codes.length == 1
                  ? widget.countryFor(codes.single)
                  : null,
            ),
            if (codes.length > 1) ...[
              SizedBox(height: spacing.md),
              _SectionTitle(text: l10n.posVoucherMenuCountryTitle),
              SizedBox(height: spacing.xs),
              Wrap(
                spacing: spacing.xs,
                runSpacing: spacing.xs,
                children: [
                  for (final code in codes)
                    _CountryChip(
                      key: ValueKey('voucher_country_$code'),
                      country: widget.countryFor(code),
                      selected: code == _country,
                      onSelected: () => setState(() => _country = code),
                    ),
                ],
              ),
            ],
            SizedBox(height: spacing.md),
            _SectionTitle(text: l10n.posVoucherMenuDenominationTitle),
            SizedBox(height: spacing.xs),
            Flexible(
              child: SingleChildScrollView(
                child: _DenominationGrid(
                  brand: brand,
                  items: items,
                  showsProfit: widget.showsProfit,
                  onPicked: widget.onPicked,
                ),
              ),
            ),
            if (balance != null) ...[
              SizedBox(height: spacing.sm),
              Row(
                children: [
                  Icon(
                    Icons.account_balance_wallet_outlined,
                    size: 16,
                    color: colors.mutedInk,
                  ),
                  SizedBox(width: spacing.xs),
                  Expanded(
                    child: Text(
                      l10n.posVoucherMenuBalance(formatMoney(balance)),
                      style: PointyTypography.numeric(
                        (textTheme.bodySmall ?? const TextStyle()).copyWith(
                          color: colors.mutedInk,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.brand, this.country});

  final VoucherBrand brand;

  /// The one country every card of the brand is for, when there is one.
  final VoucherCountry? country;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final featured = brand.badge.isNotEmpty
        ? brand.badge
        : (brand.featured ? l10n.posVoucherMenuFeatured : null);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 88,
          child: AspectRatio(
            aspectRatio: kVoucherArtAspectRatio,
            child: VoucherCardArt(brand: brand, radius: 8),
          ),
        ),
        SizedBox(width: spacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: spacing.xs,
                runSpacing: 2,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    brand.displayName,
                    style: textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: colors.ink,
                    ),
                  ),
                  if (featured != null)
                    VoucherSticker(
                      tone: VoucherStickerTone.featured,
                      label: featured,
                    ),
                ],
              ),
              if (brand.redeemHint.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  brand.redeemHint,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
                ),
              ],
              if (country case final country?) ...[
                const SizedBox(height: 6),
                Row(
                  children: [
                    VoucherCountryFlag(country: country, width: 21, height: 14),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        country.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.labelMedium?.copyWith(
                          color: colors.ink,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: Theme.of(context).textTheme.labelLarge?.copyWith(
        color: context.pointyColors.mutedInk,
        fontWeight: FontWeight.w700,
      ),
    );
  }
}

class _CountryChip extends StatelessWidget {
  const _CountryChip({
    super.key,
    required this.country,
    required this.selected,
    required this.onSelected,
  });

  final VoucherCountry country;
  final bool selected;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    return ChoiceChip(
      avatar: VoucherCountryFlag(country: country),
      label: Text(country.label, maxLines: 1, overflow: TextOverflow.ellipsis),
      selected: selected,
      showCheckmark: false,
      onSelected: (_) => onSelected(),
      side: BorderSide(
        color: selected ? colors.primaryStrong : colors.line,
        width: selected ? 1.5 : 1,
      ),
      labelStyle: Theme.of(context).textTheme.labelLarge?.copyWith(
        color: selected ? colors.primaryDark : colors.ink,
        fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
      ),
    );
  }
}

/// The denominations in rows of equal height, so a card on promotion — with
/// its struck price and badge — never leaves its neighbours ragged.
class _DenominationGrid extends StatelessWidget {
  const _DenominationGrid({
    required this.brand,
    required this.items,
    required this.showsProfit,
    required this.onPicked,
  });

  final VoucherBrand brand;
  final List<VoucherItem> items;
  final bool showsProfit;
  final ValueChanged<ProductVariant> onPicked;

  static const double _minTile = 140;
  static const int _maxPerRow = 4;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    if (items.isEmpty) {
      return Padding(
        padding: EdgeInsets.symmetric(vertical: spacing.lg),
        child: PointyEmptyState(
          title: l10n.posVoucherNoneLeft,
          icon: Icons.remove_shopping_cart_outlined,
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final gap = spacing.sm;
        final perRow = ((constraints.maxWidth + gap) / (_minTile + gap))
            .floor()
            .clamp(2, _maxPerRow);
        final rows = <List<VoucherItem>>[
          for (var start = 0; start < items.length; start += perRow)
            items.sublist(start, (start + perRow).clamp(0, items.length)),
        ];
        return Column(
          children: [
            for (final (index, row) in rows.indexed) ...[
              if (index > 0) SizedBox(height: gap),
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var slot = 0; slot < perRow; slot++) ...[
                      if (slot > 0) SizedBox(width: gap),
                      Expanded(
                        child: slot < row.length
                            ? _DenominationTile(
                                key: ValueKey('voucher_item_${row[slot].key}'),
                                item: row[slot],
                                variant: brand.variantFor(row[slot]),
                                showsProfit: showsProfit,
                                onPicked: onPicked,
                              )
                            : const SizedBox.shrink(),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _DenominationTile extends StatelessWidget {
  const _DenominationTile({
    super.key,
    required this.item,
    required this.variant,
    required this.showsProfit,
    required this.onPicked,
  });

  final VoucherItem item;
  final bool showsProfit;

  /// Null when the card cannot be sold (withdrawn since the menu was read).
  final ProductVariant? variant;
  final ValueChanged<ProductVariant> onPicked;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final variant = this.variant;
    final sellable = item.available && variant != null;
    // Warned, not refused: the balance is as old as the last read, and the
    // owner may have moved money in since.
    final beyond = sellable && item.exceedsFloat;
    final profit = showsProfit ? item.profit : null;
    final regular = item.regularPrice;

    final tile = Material(
      color: colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(PointyRadii.input),
        side: BorderSide(
          color: beyond
              ? colors.warning
              : (item.isOnPromo && sellable
                    ? colors.accentAmber.withValues(alpha: 0.75)
                    : colors.line),
          width: beyond || (item.isOnPromo && sellable) ? 1.4 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: sellable ? () => onPicked(variant) : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (item.isOnPromo && sellable) ...[
                VoucherSticker(
                  tone: VoucherStickerTone.promo,
                  label: item.badge.isNotEmpty
                      ? item.badge
                      : l10n.posVoucherMenuPromo,
                ),
                const SizedBox(height: 6),
              ],
              Text(
                item.displayLabel,
                maxLines: 2,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: PointyTypography.numeric(
                  (textTheme.titleLarge ?? const TextStyle()).copyWith(
                    fontWeight: FontWeight.w800,
                    color: sellable ? colors.ink : colors.mutedInk,
                    height: 1.2,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Wrap(
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 6,
                children: [
                  Text(
                    formatMoney(item.price),
                    style: PointyTypography.numeric(
                      (textTheme.titleSmall ?? const TextStyle()).copyWith(
                        fontWeight: FontWeight.w800,
                        color: sellable
                            ? colors.primaryStrong
                            : colors.mutedInk,
                      ),
                    ),
                  ),
                  if (item.isDiscounted && regular != null)
                    Semantics(
                      label: l10n.posVoucherMenuWasPrice(formatMoney(regular)),
                      child: ExcludeSemantics(
                        child: Text(
                          formatMoney(regular),
                          style: PointyTypography.numeric(
                            (textTheme.bodySmall ?? const TextStyle()).copyWith(
                              color: colors.mutedInk,
                              decoration: TextDecoration.lineThrough,
                              decorationColor: colors.mutedInk,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              if (profit != null && sellable) ...[
                const SizedBox(height: 4),
                Text(
                  l10n.posVoucherMenuProfit(formatMoney(profit)),
                  textAlign: TextAlign.center,
                  style: PointyTypography.numeric(
                    (textTheme.labelMedium ?? const TextStyle()).copyWith(
                      color: colors.success,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
              if (beyond) ...[
                const SizedBox(height: 4),
                Text(
                  l10n.posVoucherMenuBeyondBalance,
                  textAlign: TextAlign.center,
                  style: textTheme.labelSmall?.copyWith(
                    color: colors.warning,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
              if (!sellable) ...[
                const SizedBox(height: 4),
                Text(
                  l10n.posVoucherMenuUnavailable,
                  textAlign: TextAlign.center,
                  style: textTheme.labelSmall?.copyWith(
                    color: colors.mutedInk,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
    return sellable ? tile : Opacity(opacity: 0.6, child: tile);
  }
}
