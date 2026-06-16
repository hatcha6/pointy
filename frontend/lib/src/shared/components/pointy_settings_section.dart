import 'package:flutter/material.dart';

import '../design/design.dart';
import '../responsive/responsive.dart';
import 'pointy_disclosure_chevron.dart';

class PointySettingsSection extends StatelessWidget {
  const PointySettingsSection({
    super.key,
    required this.children,
    this.framed = true,
  });

  final List<Widget> children;
  final bool framed;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final isRtl = Directionality.of(context) == TextDirection.rtl;
    final content = Column(
      children: [
        for (var index = 0; index < children.length; index++) ...[
          children[index],
          if (index != children.length - 1)
            Divider(
              height: 1,
              indent: isRtl ? 0 : 72,
              endIndent: isRtl ? 72 : 0,
            ),
        ],
      ],
    );

    if (!framed) {
      return content;
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: colors.line),
        borderRadius: BorderRadius.circular(PointyRadii.card),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(PointyRadii.card),
        child: content,
      ),
    );
  }
}

class PointySettingsTile extends StatelessWidget {
  const PointySettingsTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.iconColor,
    this.hasError = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final Color? iconColor;
  final bool hasError;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final resolvedColor = iconColor ?? colors.primaryStrong;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: EdgeInsetsDirectional.symmetric(
          horizontal: spacing.md,
          vertical: spacing.sm,
        ),
        child: Row(
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: resolvedColor.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(PointyRadii.card),
              ),
              child: SizedBox.square(
                dimension: 40,
                child: Icon(icon, color: resolvedColor),
              ),
            ),
            SizedBox(width: spacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  SizedBox(height: spacing.xs),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: hasError ? colors.danger : colors.mutedInk,
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(width: spacing.sm),
            PointyDisclosureChevron(color: colors.mutedInk),
          ],
        ),
      ),
    );
  }
}
