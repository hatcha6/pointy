import 'package:flutter/material.dart';

import '../design/design.dart';
import '../responsive/responsive.dart';

class PointyDataRow extends StatelessWidget {
  const PointyDataRow({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.actions = const [],
    this.badges = const [],
    this.onTap,
    this.selected = false,
    this.padding,
    this.minHeight = 72,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final List<Widget> actions;
  final List<Widget> badges;
  final VoidCallback? onTap;
  final bool selected;
  final EdgeInsetsGeometry? padding;
  final double minHeight;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final colorScheme = Theme.of(context).colorScheme;
    final spacing = AdaptiveSpacing.of(context);
    final radius = BorderRadius.circular(PointyRadii.card);
    final rowColor = selected ? colorScheme.primaryContainer : colors.surface;

    return Material(
      color: rowColor,
      borderRadius: radius,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(
              color: selected ? colors.primaryStrong : colors.line,
            ),
            borderRadius: radius,
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: minHeight),
            child: Padding(
              padding:
                  padding ??
                  EdgeInsetsDirectional.fromSTEB(
                    spacing.md,
                    spacing.sm,
                    spacing.sm,
                    spacing.sm,
                  ),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final isCompact =
                      constraints.maxWidth < AppBreakpoints.tabletMin;
                  if (isCompact) {
                    return _CompactDataRowContent(
                      title: title,
                      subtitle: subtitle,
                      leading: leading,
                      trailing: trailing,
                      actions: actions,
                      badges: badges,
                    );
                  }
                  return _WideDataRowContent(
                    title: title,
                    subtitle: subtitle,
                    leading: leading,
                    trailing: trailing,
                    actions: actions,
                    badges: badges,
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _WideDataRowContent extends StatelessWidget {
  const _WideDataRowContent({
    required this.title,
    required this.subtitle,
    required this.leading,
    required this.trailing,
    required this.actions,
    required this.badges,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final List<Widget> actions;
  final List<Widget> badges;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (leading != null) ...[leading!, const SizedBox(width: 12)],
        Expanded(
          child: _DataRowText(title: title, subtitle: subtitle, badges: badges),
        ),
        if (trailing != null) ...[const SizedBox(width: 12), trailing!],
        if (actions.isNotEmpty) ...[
          const SizedBox(width: 8),
          Wrap(spacing: 4, runSpacing: 4, children: actions),
        ],
      ],
    );
  }
}

class _CompactDataRowContent extends StatelessWidget {
  const _CompactDataRowContent({
    required this.title,
    required this.subtitle,
    required this.leading,
    required this.trailing,
    required this.actions,
    required this.badges,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final List<Widget> actions;
  final List<Widget> badges;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            if (leading != null) ...[leading!, const SizedBox(width: 12)],
            Expanded(
              child: _DataRowText(
                title: title,
                subtitle: subtitle,
                badges: badges,
              ),
            ),
            if (trailing != null) ...[const SizedBox(width: 8), trailing!],
          ],
        ),
        if (actions.isNotEmpty) ...[
          const SizedBox(height: 8),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: Wrap(spacing: 4, runSpacing: 4, children: actions),
          ),
        ],
      ],
    );
  }
}

class _DataRowText extends StatelessWidget {
  const _DataRowText({
    required this.title,
    required this.subtitle,
    required this.badges,
  });

  final String title;
  final String? subtitle;
  final List<Widget> badges;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(
            context,
          ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
        ),
        if (subtitle != null && subtitle!.trim().isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            subtitle!,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: colors.mutedInk),
          ),
        ],
        if (badges.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 6, children: badges),
        ],
      ],
    );
  }
}
