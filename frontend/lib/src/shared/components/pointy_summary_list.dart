import 'package:flutter/material.dart';

import '../design/design.dart';
import '../responsive/responsive.dart';

/// A single row in a [PointySummaryList].
class PointySummaryRow {
  const PointySummaryRow({
    required this.label,
    required this.value,
    this.emphasized = false,
    this.valueColor,
    this.dividerAbove = false,
  });

  final String label;
  final String value;

  /// Renders the row larger and bolder — use for the total / net line.
  final bool emphasized;

  /// Optional colour for the value (e.g. danger for a deduction).
  final Color? valueColor;

  /// Draws a hairline divider above this row — use to separate a total from
  /// the lines that feed it.
  final bool dividerAbove;
}

/// A compact ledger / calculation summary: left-aligned muted labels with
/// right-aligned tabular values, and optional emphasis for a total line.
///
/// The modern replacement for stacks of `PointyDetailRow` used as a running
/// calculation preview (payroll adjustments, register counts, payment
/// allocations).
class PointySummaryList extends StatelessWidget {
  const PointySummaryList({super.key, required this.rows});

  final List<PointySummaryRow> rows;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;

    final children = <Widget>[];
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      if (row.dividerAbove) {
        children.add(
          Padding(
            padding: EdgeInsets.symmetric(vertical: spacing.xs),
            child: Divider(height: 1, color: colors.line),
          ),
        );
      } else if (i > 0) {
        children.add(SizedBox(height: spacing.sm));
      }

      final labelStyle =
          (row.emphasized ? textTheme.titleSmall : textTheme.bodyMedium)
              ?.copyWith(
                color: row.emphasized ? colors.ink : colors.mutedInk,
                fontWeight: row.emphasized ? FontWeight.w800 : FontWeight.w500,
              );
      final baseValueStyle =
          (row.emphasized ? textTheme.titleMedium : textTheme.bodyMedium)
              ?.copyWith(
                color: row.valueColor ?? colors.ink,
                fontWeight: row.emphasized ? FontWeight.w800 : FontWeight.w700,
              );
      final valueStyle = baseValueStyle == null
          ? null
          : PointyTypography.numeric(baseValueStyle);

      children.add(
        Row(
          children: [
            Expanded(child: Text(row.label, style: labelStyle)),
            SizedBox(width: spacing.md),
            Text(row.value, style: valueStyle),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }
}
