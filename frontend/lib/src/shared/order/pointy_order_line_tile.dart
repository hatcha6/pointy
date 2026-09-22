import 'package:flutter/material.dart';

import '../catalog/catalog.dart';
import '../design/design.dart';
import 'pointy_quantity_stepper.dart';

class PointyOrderLineTile extends StatelessWidget {
  const PointyOrderLineTile({
    super.key,
    required this.title,
    required this.unitPriceLabel,
    this.onUnitPriceTap,
    required this.totalLabel,
    required this.quantity,
    required this.incrementTooltip,
    required this.decrementTooltip,
    required this.removeTooltip,
    this.subtitle,
    this.detail,
    this.imageUrl,
    this.onIncrement,
    this.onDecrement,
    this.onRemove,
    this.onQuantityTap,
  });

  final String title;
  final String? subtitle;
  final String? detail;
  final String unitPriceLabel;

  /// Makes the per-unit price tappable — used by the till to reprice a
  /// line in place. Null everywhere else, which is every other caller and
  /// every user without the right, so the price stays plain text.
  final VoidCallback? onUnitPriceTap;
  final String totalLabel;
  final double quantity;
  final String? imageUrl;
  final String incrementTooltip;
  final String decrementTooltip;
  final String removeTooltip;
  final VoidCallback? onIncrement;
  final VoidCallback? onDecrement;
  final VoidCallback? onRemove;
  final VoidCallback? onQuantityTap;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isCompact = constraints.maxWidth < 360;
        final content = _LineContent(
          title: title,
          subtitle: subtitle,
          detail: detail,
          unitPriceLabel: unitPriceLabel,
          onUnitPriceTap: onUnitPriceTap,
          totalLabel: totalLabel,
          quantity: quantity,
          imageUrl: imageUrl,
          incrementTooltip: incrementTooltip,
          decrementTooltip: decrementTooltip,
          removeTooltip: removeTooltip,
          onIncrement: onIncrement,
          onDecrement: onDecrement,
          onRemove: onRemove,
          onQuantityTap: onQuantityTap,
          isCompact: isCompact,
        );

        return Padding(
          padding: const EdgeInsetsDirectional.symmetric(vertical: 10),
          child: content,
        );
      },
    );
  }
}

class _LineContent extends StatelessWidget {
  const _LineContent({
    required this.title,
    required this.subtitle,
    required this.detail,
    required this.unitPriceLabel,
    this.onUnitPriceTap,
    required this.totalLabel,
    required this.quantity,
    required this.imageUrl,
    required this.incrementTooltip,
    required this.decrementTooltip,
    required this.removeTooltip,
    required this.onIncrement,
    required this.onDecrement,
    required this.onRemove,
    required this.isCompact,
    this.onQuantityTap,
  });

  final String title;
  final String? subtitle;
  final String? detail;
  final String unitPriceLabel;

  /// Makes the per-unit price tappable — used by the till to reprice a
  /// line in place. Null everywhere else, which is every other caller and
  /// every user without the right, so the price stays plain text.
  final VoidCallback? onUnitPriceTap;
  final String totalLabel;
  final double quantity;
  final String? imageUrl;
  final String incrementTooltip;
  final String decrementTooltip;
  final String removeTooltip;
  final VoidCallback? onIncrement;
  final VoidCallback? onDecrement;
  final VoidCallback? onRemove;
  final bool isCompact;
  final VoidCallback? onQuantityTap;

  @override
  Widget build(BuildContext context) {
    final info = _ProductInfo(
      title: title,
      subtitle: subtitle,
      detail: detail,
      unitPriceLabel: unitPriceLabel,
      onUnitPriceTap: onUnitPriceTap,
    );
    final actions = _LineActions(
      totalLabel: totalLabel,
      quantity: quantity,
      incrementTooltip: incrementTooltip,
      decrementTooltip: decrementTooltip,
      removeTooltip: removeTooltip,
      onIncrement: onIncrement,
      onDecrement: onDecrement,
      onRemove: onRemove,
      onQuantityTap: onQuantityTap,
      compact: isCompact,
    );

    if (isCompact) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _LineImage(imageUrl: imageUrl, fallbackText: title),
              const SizedBox(width: 10),
              Expanded(child: info),
            ],
          ),
          const SizedBox(height: 10),
          actions,
        ],
      );
    }

    return Row(
      children: [
        _LineImage(imageUrl: imageUrl, fallbackText: title),
        const SizedBox(width: 12),
        Expanded(child: info),
        const SizedBox(width: 12),
        actions,
      ],
    );
  }
}

class _LineImage extends StatelessWidget {
  const _LineImage({required this.imageUrl, required this.fallbackText});

  final String? imageUrl;
  final String fallbackText;

  @override
  Widget build(BuildContext context) {
    return PointyProductImageFrame(
      imageUrl: imageUrl,
      fallbackText: fallbackText,
      width: 64,
      height: 64,
      padding: const EdgeInsets.all(6),
    );
  }
}

class _ProductInfo extends StatelessWidget {
  const _ProductInfo({
    required this.title,
    required this.subtitle,
    required this.detail,
    required this.unitPriceLabel,
    this.onUnitPriceTap,
  });

  final String title;
  final String? subtitle;
  final String? detail;
  final String unitPriceLabel;

  /// Makes the per-unit price tappable — used by the till to reprice a
  /// line in place. Null everywhere else, which is every other caller and
  /// every user without the right, so the price stays plain text.
  final VoidCallback? onUnitPriceTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final resolvedSubtitle = subtitle?.trim() ?? '';
    final resolvedDetail = detail?.trim() ?? '';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: textTheme.titleSmall?.copyWith(
            color: colors.ink,
            fontWeight: FontWeight.w700,
          ),
        ),
        if (resolvedSubtitle.isNotEmpty) ...[
          const SizedBox(height: 3),
          Text(
            resolvedSubtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
          ),
        ],
        if (resolvedDetail.isNotEmpty) ...[
          const SizedBox(height: 3),
          Text(
            resolvedDetail,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
          ),
        ],
        const SizedBox(height: 4),
        // Tap the price to change it, when the caller allows it. The pencil
        // used to sit on a row of its own beneath the line, which spent a
        // whole row saying one thing; beside the number it changes, it needs
        // neither a row nor a caption.
        _UnitPrice(
          label: unitPriceLabel,
          onTap: onUnitPriceTap,
          style: switch (textTheme.bodySmall?.copyWith(
            color: onUnitPriceTap == null
                ? colors.mutedInk
                : colors.primaryStrong,
            fontWeight: onUnitPriceTap == null ? null : FontWeight.w700,
          )) {
            final style? => PointyTypography.numeric(style),
            null => null,
          },
        ),
      ],
    );
  }
}

class _UnitPrice extends StatelessWidget {
  const _UnitPrice({required this.label, required this.style, this.onTap});

  final String label;
  final TextStyle? style;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final text = Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: style,
    );
    if (onTap == null) return text;
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: InkWell(
        key: const ValueKey('order_line_unit_price_tap'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(PointyRadii.chip),
        child: Padding(
          padding: const EdgeInsetsDirectional.only(end: 4, top: 2, bottom: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(child: text),
              const SizedBox(width: 4),
              Icon(
                Icons.edit_outlined,
                size: 13,
                color: context.pointyColors.primaryStrong,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LineActions extends StatelessWidget {
  const _LineActions({
    required this.totalLabel,
    required this.quantity,
    required this.incrementTooltip,
    required this.decrementTooltip,
    required this.removeTooltip,
    required this.onIncrement,
    required this.onDecrement,
    required this.onRemove,
    required this.compact,
    this.onQuantityTap,
  });

  final String totalLabel;
  final double quantity;
  final String incrementTooltip;
  final String decrementTooltip;
  final String removeTooltip;
  final VoidCallback? onIncrement;
  final VoidCallback? onDecrement;
  final VoidCallback? onRemove;
  final bool compact;
  final VoidCallback? onQuantityTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    // Aligned to the START when this row is on a line of its own.
    //
    // Beside the product info it reads as a column of totals, so it hugs the
    // stepper. Wrapped onto its own line it did the same and left the far edge
    // empty — the line total floating in the middle of the row with dead space
    // beside it. On its own line it belongs at the far edge, with the stepper
    // at the other, so the row visibly spans the width it occupies.
    final amount = FittedBox(
      fit: BoxFit.scaleDown,
      alignment: compact
          ? AlignmentDirectional.centerStart
          : AlignmentDirectional.centerEnd,
      child: Text(
        totalLabel,
        maxLines: 1,
        textAlign: compact ? TextAlign.start : TextAlign.end,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
          color: colors.ink,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
    final stepper = PointyQuantityStepper(
      quantity: quantity,
      incrementTooltip: incrementTooltip,
      decrementTooltip: decrementTooltip,
      onIncrement: onIncrement,
      onDecrement: onDecrement,
      onQuantityTap: onQuantityTap,
    );
    final removeButton = IconButton.filledTonal(
      tooltip: removeTooltip,
      onPressed: onRemove,
      visualDensity: VisualDensity.compact,
      style: IconButton.styleFrom(
        fixedSize: const Size.square(PointyDimensions.iconButton),
        minimumSize: const Size.square(PointyDimensions.iconButton),
        padding: EdgeInsets.zero,
        foregroundColor: colors.danger,
        shape: PointyComponentStyles.shape(PointyRadii.button),
      ),
      iconSize: 18,
      icon: const Icon(Icons.close),
    );

    if (compact) {
      return Row(
        children: [
          Expanded(child: amount),
          const SizedBox(width: 8),
          stepper,
          const SizedBox(width: 6),
          removeButton,
        ],
      );
    }

    return SizedBox(
      width: 250,
      child: Row(
        children: [
          Expanded(child: amount),
          const SizedBox(width: 10),
          stepper,
          const SizedBox(width: 6),
          removeButton,
        ],
      ),
    );
  }
}
