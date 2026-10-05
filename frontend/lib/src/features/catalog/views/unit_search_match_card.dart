import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../core/typed_lookup_text.dart';
import '../../../data/models/stock_unit.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/product_image_thumbnail.dart';
import '../../../shared/tracking/tracking_labels.dart';
import '../../../shared/tracking/unit_sale_band.dart';

/// After this long on a shelf a used handset is the ageing question, so its
/// days pill turns to the warning tone — the same line the assistant's card
/// draws.
const int _agedAfterDays = 90;

/// LTR isolate, so «3582…» and «AB-12» keep their order inside Arabic.
String _ltr(String value) => '\u2066$value\u2069';

/// The article(s) an identifier typed into the products search answered.
///
/// Leads with the one that matters — the live article, or the latest sale
/// when nothing is on the shelf — in full: what it is, its identifier, where
/// and for how much, or whose invoice it went out on and whether it is still
/// covered. Older articles that answered to the same number (a trade-in sold
/// twice) follow as one line each.
///
/// Pure and parameter-driven, so tests and previews draw every state without
/// a lookup behind them.
class UnitSearchMatchCard extends StatelessWidget {
  const UnitSearchMatchCard({
    super.key,
    required this.lookup,
    required this.onOpenUnit,
    this.typedCode = '',
    this.onOpenInvoice,
    this.onOpenCustomer,
  });

  final StockUnitLookup lookup;

  /// The typed identifier, normalised — to say so when it was the second IMEI.
  final String typedCode;
  final ValueChanged<StockUnit> onOpenUnit;

  /// Null hides the invoice as a link (the reader cannot open invoices).
  final ValueChanged<int>? onOpenInvoice;

  /// Null hides the buyer as a link (the reader cannot open contacts).
  final ValueChanged<int>? onOpenCustomer;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final matches = lookup.matches;
    if (matches.isEmpty) {
      return const SizedBox.shrink();
    }
    final lead = matches.first;
    final earlier = matches.skip(1).toList(growable: false);
    // The server's warranty answer is about the live unit, or the latest sale
    // when nothing is live — the lead either way.
    final warranty = lookup.warranty;
    final radius = BorderRadius.circular(PointyRadii.card);

    final sold = lead.status == StockUnitStatus.sold;

    // The shadow sits on an outer box that carries the surface colour: drawn
    // inside the Material by a colourless box, it would grey the whole card.
    return DecoratedBox(
      key: const ValueKey('unit_search_match_card'),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: radius,
        boxShadow: PointyShadows.raised,
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: () => onOpenUnit(lead),
          borderRadius: radius,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: radius,
              border: Border.all(
                color: colors.primaryStrong.withValues(alpha: 0.35),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Eyebrow(
                    label: matches.length == 1
                        ? l10n.unitSearchMatchTitle
                        : l10n.unitSearchMatchCount(matches.length),
                    showEnterHint: matches.length == 1,
                  ),
                  const SizedBox(height: 10),
                  _LeadHeader(unit: lead, typedCode: typedCode),
                  // Sold says itself in the band below; a row holding only a
                  // «مباعة» pill would be height spent on nothing new.
                  if (!sold) ...[
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: _pills(context, lead),
                    ),
                  ],
                  if (sold) ...[
                    const SizedBox(height: 10),
                    UnitSaleBand(
                      unit: lead,
                      warranty: warranty,
                      onOpenInvoice: onOpenInvoice,
                      onOpenCustomer: onOpenCustomer,
                    ),
                  ],
                  if (earlier.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(
                      l10n.unitSearchEarlier,
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: colors.mutedInk,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    for (final unit in earlier)
                      _EarlierRow(unit: unit, onTap: () => onOpenUnit(unit)),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _pills(BuildContext context, StockUnit unit) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final days = unit.daysInStock;
    return [
      PointyStatusPill(
        label: stockUnitStatusLabel(l10n, unit.status),
        color: stockUnitStatusColor(colors, unit.status),
      ),
      if (unit.isOnHand && unit.warehouseName.isNotEmpty)
        PointyStatusPill(
          label: unit.warehouseName,
          icon: Icons.storefront_outlined,
          color: colors.mutedInk,
        ),
      if (unit.isOnHand && days != null)
        PointyStatusPill(
          label: l10n.posUnitPickerDaysInStock(days),
          icon: Icons.schedule_rounded,
          color: days >= _agedAfterDays ? colors.warning : colors.mutedInk,
        ),
      if (unit.isConsignment)
        PointyStatusPill(
          label: l10n.stockUnitConsignmentBadge,
          icon: Icons.handshake_outlined,
          color: colors.accentAmber,
        ),
      if (unit.batchCode.isNotEmpty)
        PointyStatusPill(
          label: l10n.posCartLineBatchBadge(unit.batchCode),
          color: colors.mutedInk,
        ),
    ];
  }
}

/// «جهاز بهذا الرقم» — why this card sits above the products — and, when
/// Enter would open it, that it would.
class _Eyebrow extends StatelessWidget {
  const _Eyebrow({required this.label, required this.showEnterHint});

  final String label;
  final bool showEnterHint;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    return Row(
      children: [
        Icon(
          Icons.qr_code_scanner_rounded,
          size: 18,
          color: colors.primaryStrong,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: textTheme.labelLarge?.copyWith(
              color: colors.primaryStrong,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        if (showEnterHint)
          DecoratedBox(
            decoration: BoxDecoration(
              color: colors.surfaceSunken,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: colors.line),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              child: Text(
                l10n.unitSearchEnterHint,
                style: textTheme.labelSmall?.copyWith(color: colors.mutedInk),
              ),
            ),
          ),
      ],
    );
  }
}

/// Face, name, identifier and price of the leading article.
class _LeadHeader extends StatelessWidget {
  const _LeadHeader({required this.unit, required this.typedCode});

  final StockUnit unit;
  final String typedCode;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final title = unit.variantName.isNotEmpty
        ? unit.variantName
        : unit.productName;
    final secondMatched =
        typedCode.isNotEmpty &&
        unit.secondaryCode.isNotEmpty &&
        normalizeUnitIdentifier(unit.secondaryCode) == typedCode &&
        normalizeUnitIdentifier(unit.code) != typedCode;
    final sold = unit.status == StockUnitStatus.sold;
    final price = sold ? unit.soldPrice : (unit.askingPrice ?? unit.listPrice);
    final cover = unit.coverPhoto;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (cover != null)
          ProductImageThumbnail(
            imageUrl: cover.previewUrl,
            fallbackText: title,
            size: 56,
            borderRadius: PointyRadii.card,
          )
        else
          _UnitGlyph(muted: !unit.isOnHand),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                _ltr(unit.code),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: PointyTypography.numeric(
                  textTheme.bodyMedium!.copyWith(color: colors.mutedInk),
                ),
              ),
              if (secondMatched)
                Text(
                  l10n.unitSearchSecondCode(_ltr(unit.secondaryCode)),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: PointyTypography.numeric(
                    textTheme.bodySmall!.copyWith(
                      color: colors.primaryStrong,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (price != null) ...[
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                formatMoney(price),
                style: PointyTypography.numeric(
                  textTheme.titleMedium!.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              Text(
                sold
                    ? l10n.stockUnitSoldFor
                    : unit.listPrice != null
                    ? l10n.stockUnitOwnPrice
                    : l10n.stockUnitVariantPrice,
                style: textTheme.labelSmall?.copyWith(color: colors.mutedInk),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _UnitGlyph extends StatelessWidget {
  const _UnitGlyph({required this.muted});

  final bool muted;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final accent = muted ? colors.mutedInk : colors.primaryStrong;
    return Container(
      width: 56,
      height: 56,
      decoration: BoxDecoration(
        color: Color.alphaBlend(accent.withValues(alpha: 0.10), colors.surface),
        borderRadius: BorderRadius.circular(PointyRadii.card),
      ),
      child: Icon(Icons.qr_code_2_rounded, size: 28, color: accent),
    );
  }
}

/// An older article that answered to the same number, in one line: what
/// became of it, when, and — when sold — to whom on which invoice.
class _EarlierRow extends StatelessWidget {
  const _EarlierRow({required this.unit, required this.onTap});

  final StockUnit unit;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final name = unit.customerName ?? '';
    final receipt = unit.soldReceiptNumber ?? '';
    final summary = [
      stockUnitStatusLabel(l10n, unit.status),
      if (unit.soldAt != null) formatDate(unit.soldAt!),
      if (name.isNotEmpty) name,
      if (receipt.isNotEmpty) l10n.unitSearchInvoice(_ltr(receipt)),
    ].join(' · ');
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(PointyRadii.chip),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
        child: Row(
          children: [
            Icon(Icons.history_rounded, size: 18, color: colors.mutedInk),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                summary,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.bodySmall?.copyWith(color: colors.ink),
              ),
            ),
            const SizedBox(width: 8),
            PointyDisclosureChevron(size: 18, color: colors.mutedInk),
          ],
        ),
      ),
    );
  }
}
