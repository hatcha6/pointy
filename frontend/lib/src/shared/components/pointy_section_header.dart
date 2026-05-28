import 'package:flutter/material.dart';

import '../design/design.dart';
import '../responsive/responsive.dart';

class PointySectionHeader extends StatelessWidget {
  const PointySectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.actions = const [],
    this.padding,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final List<Widget> actions;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);
    final textTheme = Theme.of(context).textTheme;
    final colors = context.pointyColors;
    final resolvedPadding =
        padding ??
        EdgeInsetsDirectional.only(bottom: spacing.sm, top: spacing.xs);

    return Padding(
      padding: resolvedPadding,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final header = Row(
            children: [
              if (leading != null) ...[leading!, SizedBox(width: spacing.sm)],
              Expanded(
                child: _HeaderText(
                  title: title,
                  subtitle: subtitle,
                  titleStyle: textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                  subtitleStyle: textTheme.bodySmall?.copyWith(
                    color: colors.mutedInk,
                  ),
                ),
              ),
              if (trailing != null) ...[SizedBox(width: spacing.sm), trailing!],
            ],
          );

          if (actions.isEmpty) {
            return header;
          }

          if (constraints.maxWidth < AppBreakpoints.tabletMin) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                header,
                SizedBox(height: spacing.sm),
                Wrap(
                  spacing: spacing.sm,
                  runSpacing: spacing.sm,
                  alignment: WrapAlignment.end,
                  children: actions,
                ),
              ],
            );
          }

          return Row(
            children: [
              Expanded(child: header),
              SizedBox(width: spacing.md),
              Wrap(
                spacing: spacing.sm,
                runSpacing: spacing.sm,
                alignment: WrapAlignment.end,
                children: actions,
              ),
            ],
          );
        },
      ),
    );
  }
}

class _HeaderText extends StatelessWidget {
  const _HeaderText({
    required this.title,
    required this.subtitle,
    required this.titleStyle,
    required this.subtitleStyle,
  });

  final String title;
  final String? subtitle;
  final TextStyle? titleStyle;
  final TextStyle? subtitleStyle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: titleStyle,
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 4),
          Text(
            subtitle!,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: subtitleStyle,
          ),
        ],
      ],
    );
  }
}
