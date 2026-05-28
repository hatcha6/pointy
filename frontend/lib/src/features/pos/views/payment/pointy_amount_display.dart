import 'package:flutter/material.dart';

import '../../../../shared/design/design.dart';

enum PointyAmountDisplayTone { neutral, primary, success, warning }

class PointyAmountDisplay extends StatelessWidget {
  const PointyAmountDisplay({
    super.key,
    required this.label,
    required this.value,
    this.tone = PointyAmountDisplayTone.neutral,
    this.emphasized = false,
  });

  final String label;
  final String value;
  final PointyAmountDisplayTone tone;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final amountColor = switch (tone) {
      PointyAmountDisplayTone.neutral => colors.ink,
      PointyAmountDisplayTone.primary => colors.primaryStrong,
      PointyAmountDisplayTone.success => colors.success,
      PointyAmountDisplayTone.warning => colors.warning,
    };

    return DecoratedBox(
      decoration: BoxDecoration(
        color: emphasized
            ? Theme.of(context).colorScheme.primaryContainer
            : colors.subtleFill,
        border: Border.all(color: colors.line),
        borderRadius: BorderRadius.circular(PointyRadii.card),
      ),
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
            ),
            const SizedBox(height: 4),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: AlignmentDirectional.centerStart,
              child: Text(
                value,
                maxLines: 1,
                style:
                    (emphasized
                            ? textTheme.headlineSmall
                            : textTheme.titleLarge)
                        ?.copyWith(
                          color: amountColor,
                          fontWeight: FontWeight.w800,
                        ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
