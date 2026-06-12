import 'package:flutter/material.dart';

import '../design/design.dart';
import '../responsive/responsive.dart';

class PointyDetailSection extends StatelessWidget {
  const PointyDetailSection({
    super.key,
    required this.title,
    required this.icon,
    required this.child,
    this.trailing,
    this.minHeight,
  });

  final String title;
  final IconData icon;
  final Widget child;
  final Widget? trailing;
  final double? minHeight;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;

    final section = DecoratedBox(
      decoration: const BoxDecoration(
        borderRadius: BorderRadius.all(Radius.circular(PointyRadii.card)),
        boxShadow: PointyShadows.raised,
      ),
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: spacing.compactPadding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(icon, color: colors.primaryStrong),
                  SizedBox(width: spacing.sm),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  ?trailing,
                ],
              ),
              SizedBox(height: spacing.sm),
              child,
            ],
          ),
        ),
      ),
    );

    if (minHeight == null) {
      return section;
    }

    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: minHeight!),
      child: section,
    );
  }
}

class PointyDetailRow extends StatelessWidget {
  const PointyDetailRow({super.key, required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);

    return Row(
      children: [
        Text(label, style: Theme.of(context).textTheme.labelLarge),
        SizedBox(width: spacing.md),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.end,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
