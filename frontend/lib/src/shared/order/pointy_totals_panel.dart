import 'package:flutter/material.dart';

import '../design/design.dart';

class PointyTotalLine {
  const PointyTotalLine({
    required this.label,
    required this.value,
    this.isStrong = false,
  });

  final String label;
  final String value;
  final bool isStrong;
}

class PointyTotalsPanel extends StatelessWidget {
  const PointyTotalsPanel({super.key, required this.lines});

  final List<PointyTotalLine> lines;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var index = 0; index < lines.length; index += 1) ...[
          if (index > 0 && lines[index].isStrong)
            Divider(height: 14, color: context.pointyColors.line),
          _TotalLineView(line: lines[index]),
        ],
      ],
    );
  }
}

class _TotalLineView extends StatelessWidget {
  const _TotalLineView({required this.line});

  final PointyTotalLine line;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final style = line.isStrong
        ? Theme.of(context).textTheme.titleLarge?.copyWith(
            color: colors.ink,
            fontWeight: FontWeight.w800,
          )
        : Theme.of(context).textTheme.bodyMedium?.copyWith(color: colors.ink);

    return Padding(
      padding: const EdgeInsetsDirectional.symmetric(vertical: 3),
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
                  style: style,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
