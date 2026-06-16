import 'package:flutter/material.dart';

import '../design/design.dart';

class PointyTotalLine {
  const PointyTotalLine({
    required this.label,
    required this.value,
    this.isStrong = false,
    this.isMuted = false,
  });

  final String label;
  final String value;
  final bool isStrong;

  /// Renders the line in a quieter tone — used for deductions (discounts) so
  /// the subtotal and grand total keep the visual hierarchy.
  final bool isMuted;
}

class PointyTotalsPanel extends StatelessWidget {
  const PointyTotalsPanel({
    super.key,
    required this.lines,
    this.compact = false,
  });

  final List<PointyTotalLine> lines;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var index = 0; index < lines.length; index += 1) ...[
          if (index > 0 && lines[index].isStrong)
            Divider(
              height: compact ? 10 : 16,
              color: context.pointyColors.line,
            ),
          _TotalLineView(line: lines[index], compact: compact),
        ],
      ],
    );
  }
}

class _TotalLineView extends StatelessWidget {
  const _TotalLineView({required this.line, required this.compact});

  final PointyTotalLine line;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;

    // Three tiers of emphasis: the grand total dominates (large, bold, primary
    // value), the subtotal is plain ink, and deductions recede in muted grey.
    final TextStyle? labelStyle;
    final TextStyle? valueStyle;
    if (line.isStrong) {
      labelStyle = (compact ? textTheme.titleMedium : textTheme.titleLarge)
          ?.copyWith(color: colors.ink, fontWeight: FontWeight.w800);
      valueStyle = (compact ? textTheme.titleLarge : textTheme.headlineSmall)
          ?.copyWith(color: colors.primaryStrong, fontWeight: FontWeight.w900);
    } else if (line.isMuted) {
      final base = compact ? textTheme.bodySmall : textTheme.bodyMedium;
      labelStyle = base?.copyWith(color: colors.mutedInk);
      valueStyle = base?.copyWith(
        color: colors.mutedInk,
        fontWeight: FontWeight.w600,
      );
    } else {
      final base = compact ? textTheme.bodyMedium : textTheme.bodyLarge;
      labelStyle = base?.copyWith(
        color: colors.mutedInk,
        fontWeight: FontWeight.w500,
      );
      valueStyle = base?.copyWith(
        color: colors.ink,
        fontWeight: FontWeight.w700,
      );
    }

    return Padding(
      padding: EdgeInsetsDirectional.symmetric(
        vertical: line.isStrong ? (compact ? 3 : 5) : (compact ? 2 : 3),
      ),
      child: Row(
        children: [
          // The label takes all the slack so the value is pushed hard to the
          // trailing edge (the far left in RTL) instead of floating mid-row.
          Expanded(
            child: Text(
              line.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: labelStyle,
            ),
          ),
          const SizedBox(width: 12),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              line.value,
              maxLines: 1,
              style: valueStyle == null
                  ? null
                  : PointyTypography.numeric(valueStyle),
            ),
          ),
        ],
      ),
    );
  }
}
