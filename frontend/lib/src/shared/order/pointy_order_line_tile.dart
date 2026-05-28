import 'package:flutter/material.dart';

import '../catalog/catalog.dart';
import '../design/design.dart';
import 'pointy_quantity_stepper.dart';

class PointyOrderLineTile extends StatelessWidget {
  const PointyOrderLineTile({
    super.key,
    required this.title,
    required this.unitPriceLabel,
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
  });

  final String title;
  final String? subtitle;
  final String? detail;
  final String unitPriceLabel;
  final String totalLabel;
  final int quantity;
  final String? imageUrl;
  final String incrementTooltip;
  final String decrementTooltip;
  final String removeTooltip;
  final VoidCallback? onIncrement;
  final VoidCallback? onDecrement;
  final VoidCallback? onRemove;

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
          totalLabel: totalLabel,
          quantity: quantity,
          imageUrl: imageUrl,
          incrementTooltip: incrementTooltip,
          decrementTooltip: decrementTooltip,
          removeTooltip: removeTooltip,
          onIncrement: onIncrement,
          onDecrement: onDecrement,
          onRemove: onRemove,
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
  });

  final String title;
  final String? subtitle;
  final String? detail;
  final String unitPriceLabel;
  final String totalLabel;
  final int quantity;
  final String? imageUrl;
  final String incrementTooltip;
  final String decrementTooltip;
  final String removeTooltip;
  final VoidCallback? onIncrement;
  final VoidCallback? onDecrement;
  final VoidCallback? onRemove;
  final bool isCompact;

  @override
  Widget build(BuildContext context) {
    final info = _ProductInfo(
      title: title,
      subtitle: subtitle,
      detail: detail,
      unitPriceLabel: unitPriceLabel,
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
  });

  final String title;
  final String? subtitle;
  final String? detail;
  final String unitPriceLabel;

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
        Text(
          unitPriceLabel,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
        ),
      ],
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
  });

  final String totalLabel;
  final int quantity;
  final String incrementTooltip;
  final String decrementTooltip;
  final String removeTooltip;
  final VoidCallback? onIncrement;
  final VoidCallback? onDecrement;
  final VoidCallback? onRemove;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final amount = FittedBox(
      fit: BoxFit.scaleDown,
      alignment: AlignmentDirectional.centerEnd,
      child: Text(
        totalLabel,
        maxLines: 1,
        textAlign: TextAlign.end,
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
