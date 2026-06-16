import 'package:flutter/material.dart';

import '../design/design.dart';

/// Shared scaffold for the filter / sort bottom sheets (product, invoice,
/// purchase order, discount, activity log). Built on the Pointy palette so the
/// sheets sit in lock-step with the rest of the app: a tinted header, quiet
/// section labels, grouped option cards, and a sturdy reset / apply row.
class QueryFilterSheet extends StatelessWidget {
  const QueryFilterSheet({
    super.key,
    required this.title,
    required this.children,
    required this.resetLabel,
    required this.applyLabel,
    required this.onReset,
    required this.onApply,
  });

  final String title;
  final List<Widget> children;
  final String resetLabel;
  final String applyLabel;
  final VoidCallback onReset;
  final VoidCallback onApply;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: ListView(
          padding: const EdgeInsetsDirectional.fromSTEB(20, 4, 20, 20),
          shrinkWrap: true,
          children: [
            Row(
              children: [
                _HeaderIcon(),
                const SizedBox(width: 12),
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(
                      title,
                      style: textTheme.titleLarge?.copyWith(
                        color: colors.ink,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            ...children,
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: onReset,
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(52),
                    ),
                    child: Text(resetLabel),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: onApply,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(52),
                    ),
                    child: Text(applyLabel),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _HeaderIcon extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: Color.alphaBlend(
          colors.primaryStrong.withValues(alpha: 0.10),
          colors.surface,
        ),
        borderRadius: BorderRadius.circular(PointyRadii.card),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Icon(Icons.tune, color: colors.primaryStrong),
      ),
    );
  }
}

class QueryFilterSection extends StatelessWidget {
  const QueryFilterSection({
    super.key,
    required this.title,
    required this.children,
  });

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsetsDirectional.only(start: 2, bottom: 8),
          child: Semantics(
            header: true,
            child: Text(
              title,
              style: textTheme.labelLarge?.copyWith(
                color: colors.mutedInk,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(PointyRadii.card),
            border: Border.all(color: colors.line),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(PointyRadii.card),
            child: Column(
              children: [
                for (final (index, child) in children.indexed) ...[
                  if (index > 0)
                    Divider(
                      height: 1,
                      indent: 14,
                      endIndent: 14,
                      color: colors.line,
                    ),
                  child,
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class QueryFilterOptionTile extends StatelessWidget {
  const QueryFilterOptionTile({
    super.key,
    required this.label,
    required this.icon,
    required this.isSelected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final foreground = isSelected ? colors.primaryDark : colors.ink;
    final selectedFill = Color.alphaBlend(
      colors.primaryStrong.withValues(alpha: 0.10),
      colors.surface,
    );

    return Semantics(
      button: true,
      selected: isSelected,
      label: label,
      child: Material(
        color: isSelected ? selectedFill : Colors.transparent,
        child: InkWell(
          onTap: onTap,
          overlayColor: PointyComponentStyles.inkOverlay,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 20,
                  color: isSelected ? colors.primaryStrong : colors.mutedInk,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.bodyLarge?.copyWith(
                      color: foreground,
                      fontWeight: isSelected
                          ? FontWeight.w700
                          : FontWeight.w500,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Icon(
                  isSelected
                      ? Icons.check_circle
                      : Icons.radio_button_unchecked,
                  size: 22,
                  color: isSelected ? colors.primaryStrong : colors.lineStrong,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
