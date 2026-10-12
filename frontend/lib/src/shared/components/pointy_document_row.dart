import 'package:flutter/material.dart';

import '../design/design.dart';

/// A small icon + text fact under a document row's party name: the cashier,
/// the item count, the supplier's own invoice number.
class PointyDocumentMeta {
  const PointyDocumentMeta({required this.icon, required this.label});

  final IconData icon;
  final String label;
}

/// One invoice / purchase order / quotation in a list.
///
/// Built for scanning a long list, not for reading one row: the party (who)
/// and the amount (how much) are the two things the eye hunts for, so they
/// own the first line in the largest type. The document number and date sit
/// under them, status is a coloured pill *and* a coloured bar on the start
/// edge, and the remaining facts are small icon-labelled chips instead of one
/// long "a • b • c • d" sentence.
///
/// From [tableMinWidth] up the row lays out as table columns that line up with
/// [PointyDocumentListHeader], so amounts and statuses can be compared down
/// the page. Below it the same content stacks as a card.
class PointyDocumentRow extends StatelessWidget {
  const PointyDocumentRow({
    super.key,
    required this.party,
    required this.reference,
    required this.amount,
    this.date,
    this.amountLabel,
    this.amountColor,
    this.secondaryAmount,
    this.secondaryAmountColor,
    this.accentColor,
    this.badges = const [],
    this.meta = const [],
    this.menu,
    this.onTap,
    this.selected = false,
  });

  /// Rows narrower than this stack as a card.
  static const double tableMinWidth = 760;

  /// Customer or supplier name.
  final String party;

  /// Document number, e.g. the receipt or PO number.
  final String reference;

  /// The headline money figure, already formatted.
  final String amount;
  final String? date;

  /// A caption over [amount] for a list whose figure is not self-evident —
  /// "opening cash" against "counted cash" on drawer sessions.
  final String? amountLabel;
  final Color? amountColor;

  /// A second figure under the amount: balance due, profit.
  final String? secondaryAmount;
  final Color? secondaryAmountColor;

  /// Status colour for the start-edge bar. Defaults to the line colour.
  final Color? accentColor;
  final List<Widget> badges;
  final List<PointyDocumentMeta> meta;

  /// Row actions (print, share, edit), usually a [PopupMenuButton].
  final Widget? menu;
  final VoidCallback? onTap;

  /// The row open in a neighbouring detail pane.
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final radius = BorderRadius.circular(PointyRadii.card);

    // Not clipped, like PointyDataRow: a clipped Material costs a saveLayer
    // per row while the list scrolls.
    return Material(
      color: selected ? colors.primaryContainer : colors.surface,
      borderRadius: radius,
      child: InkWell(
        onTap: onTap,
        borderRadius: radius,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(
              color: selected ? colors.primaryStrong : colors.line,
            ),
            borderRadius: radius,
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final isTable = constraints.maxWidth >= tableMinWidth;
              // The bar is positioned over the padding rather than laid out
              // in a Row, so the row needs no IntrinsicHeight to match it.
              return Stack(
                children: [
                  Padding(
                    padding: const EdgeInsetsDirectional.fromSTEB(
                      24,
                      10,
                      4,
                      10,
                    ),
                    child: isTable
                        ? _tableContent(context)
                        : _cardContent(context),
                  ),
                  PositionedDirectional(
                    start: 8,
                    top: 10,
                    bottom: 10,
                    width: 4,
                    child: _AccentBar(color: accentColor ?? colors.line),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _cardContent(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsetsDirectional.only(end: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _PartyText(party),
                    const SizedBox(height: 2),
                    _ReferenceText(reference: reference, date: date),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              _AmountColumn(
                label: amountLabel,
                amount: amount,
                amountColor: amountColor,
                secondaryAmount: secondaryAmount,
                secondaryAmountColor: secondaryAmountColor,
              ),
            ],
          ),
        ),
        if (badges.isNotEmpty || meta.isNotEmpty || menu != null) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    ...badges,
                    for (final item in meta) _MetaChip(item),
                  ],
                ),
              ),
              ?menu,
            ],
          ),
        ],
      ],
    );
  }

  Widget _tableContent(BuildContext context) {
    return _DocumentColumns(
      document: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (reference.isNotEmpty)
            Text(
              reference,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: _numericStyle(
                Theme.of(context).textTheme.labelLarge,
                context.pointyColors.ink,
                FontWeight.w700,
              ),
            ),
          if (date != null) ...[const SizedBox(height: 2), _MutedText(date!)],
        ],
      ),
      party: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _PartyText(party),
          if (meta.isNotEmpty) ...[
            const SizedBox(height: 4),
            Wrap(
              spacing: 12,
              runSpacing: 4,
              children: [for (final item in meta) _MetaChip(item)],
            ),
          ],
        ],
      ),
      status: Align(
        alignment: AlignmentDirectional.centerStart,
        child: Wrap(spacing: 6, runSpacing: 6, children: badges),
      ),
      amount: Align(
        alignment: AlignmentDirectional.centerEnd,
        child: _AmountColumn(
          label: amountLabel,
          amount: amount,
          amountColor: amountColor,
          secondaryAmount: secondaryAmount,
          secondaryAmountColor: secondaryAmountColor,
        ),
      ),
      menu: Center(child: menu),
    );
  }
}

/// Column titles for a list of [PointyDocumentRow]s. Draws nothing below
/// [PointyDocumentRow.tableMinWidth], where the rows are cards.
class PointyDocumentListHeader extends StatelessWidget {
  const PointyDocumentListHeader({
    super.key,
    required this.documentLabel,
    required this.partyLabel,
    required this.statusLabel,
    required this.amountLabel,
  });

  final String documentLabel;
  final String partyLabel;
  final String statusLabel;
  final String amountLabel;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final style = Theme.of(context).textTheme.labelMedium?.copyWith(
      color: colors.mutedInk,
      fontWeight: FontWeight.w700,
    );
    Text label(String text, [TextAlign align = TextAlign.start]) => Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: align,
      style: style,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < PointyDocumentRow.tableMinWidth) {
          return const SizedBox.shrink();
        }
        // Same insets as a row (padding + bar + gap, and the border) so the
        // titles sit over their columns.
        return Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(25, 4, 5, 6),
          child: _DocumentColumns(
            document: label(documentLabel),
            party: label(partyLabel),
            status: label(statusLabel),
            amount: label(amountLabel, TextAlign.end),
            menu: const SizedBox.shrink(),
          ),
        );
      },
    );
  }
}

/// The one place the table column widths live, shared by rows and header.
class _DocumentColumns extends StatelessWidget {
  const _DocumentColumns({
    required this.document,
    required this.party,
    required this.status,
    required this.amount,
    required this.menu,
  });

  final Widget document;
  final Widget party;
  final Widget status;
  final Widget amount;
  final Widget menu;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(width: 168, child: document),
        const SizedBox(width: 16),
        Expanded(child: party),
        const SizedBox(width: 16),
        SizedBox(width: 196, child: status),
        const SizedBox(width: 16),
        SizedBox(width: 156, child: amount),
        SizedBox(width: 44, child: menu),
      ],
    );
  }
}

class _AccentBar extends StatelessWidget {
  const _AccentBar({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }
}

class _PartyText extends StatelessWidget {
  const _PartyText(this.party);

  final String party;

  @override
  Widget build(BuildContext context) {
    return Text(
      party,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(
        color: context.pointyColors.ink,
        fontWeight: FontWeight.w800,
      ),
    );
  }
}

class _ReferenceText extends StatelessWidget {
  const _ReferenceText({required this.reference, required this.date});

  final String reference;
  final String? date;

  @override
  Widget build(BuildContext context) {
    // Separate texts, so the number stays findable and copyable as itself.
    // Both flexible: on a narrow pane the date gives way before the row
    // overflows. An empty reference leaves the date alone.
    return Row(
      children: [
        if (reference.isNotEmpty) Flexible(child: _MutedText(reference)),
        if (reference.isNotEmpty && date != null) const _MutedText('  ·  '),
        if (date != null) Flexible(child: _MutedText(date!)),
      ],
    );
  }
}

class _MutedText extends StatelessWidget {
  const _MutedText(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: _numericStyle(
        Theme.of(context).textTheme.bodySmall,
        context.pointyColors.mutedInk,
        FontWeight.w500,
      ),
    );
  }
}

class _AmountColumn extends StatelessWidget {
  const _AmountColumn({
    required this.label,
    required this.amount,
    required this.amountColor,
    required this.secondaryAmount,
    required this.secondaryAmountColor,
  });

  final String? label;
  final String amount;
  final Color? amountColor;
  final String? secondaryAmount;
  final Color? secondaryAmountColor;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (label != null)
          Text(
            label!,
            maxLines: 1,
            style: textTheme.labelSmall?.copyWith(color: colors.mutedInk),
          ),
        Text(
          amount,
          maxLines: 1,
          style: _numericStyle(
            textTheme.titleMedium,
            amountColor ?? colors.ink,
            FontWeight.w800,
          ),
        ),
        if (secondaryAmount != null) ...[
          const SizedBox(height: 2),
          Text(
            secondaryAmount!,
            maxLines: 1,
            style: _numericStyle(
              textTheme.bodySmall,
              secondaryAmountColor ?? colors.mutedInk,
              FontWeight.w700,
            ),
          ),
        ],
      ],
    );
  }
}

class _MetaChip extends StatelessWidget {
  const _MetaChip(this.item);

  final PointyDocumentMeta item;

  @override
  Widget build(BuildContext context) {
    final color = context.pointyColors.mutedInk;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(item.icon, size: 14, color: color),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            item.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}

TextStyle? _numericStyle(TextStyle? base, Color color, FontWeight weight) {
  if (base == null) {
    return null;
  }
  return PointyTypography.numeric(
    base.copyWith(color: color, fontWeight: weight),
  );
}
