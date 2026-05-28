import 'package:flutter/material.dart';

import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';

class ProductFormSection extends StatelessWidget {
  const ProductFormSection({
    super.key,
    required this.title,
    required this.icon,
    required this.children,
  });

  final String title;
  final IconData icon;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;

    return Column(
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
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
            ),
          ],
        ),
        SizedBox(height: spacing.md),
        ...children,
      ],
    );
  }
}
