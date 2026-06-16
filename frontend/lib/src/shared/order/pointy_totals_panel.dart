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
      children: [
        for (var index = 0; index < lines.length; index += 1) ...[
          if (index > 0 && lines[index].isStrong)
            Divider(height: compact ? 8 : 14, color: context.pointyColors.line),
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
    final TextStyle? style;
    if (line.isStrong) {
      style = (compact ? textTheme.titleMedium : textTheme.titleLarge)
          ?.copyWith(color: colors.ink, fontWeight: FontWeight.w800);
    } else if (line.isMuted) {
      style = (compact ? textTheme.bodySmall : textTheme.bodyMedium)?.copyWith(
        color: colors.mutedInk,
      );
    } else {
      style = (compact ? textTheme.bodySmall : textTheme.bodyMedium)?.copyWith(
        color: colors.ink,
      );
    }

    return Padding(
      padding: EdgeInsetsDirectional.symmetric(vertical: compact ? 1 : 3),
      child: Row(
        children: [
          Flexible(
            child: Text(
              line.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Align(
              alignment: AlignmentDirectional.centerEnd,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  line.value,
                  maxLines: 1,
                  textAlign: TextAlign.end,
                  style: style == null ? null : PointyTypography.numeric(style),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
