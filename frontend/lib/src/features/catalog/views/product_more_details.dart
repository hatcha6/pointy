import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';

/// The rest of a new product, folded under one line: a shop entering its
/// shelves sets none of it for most products — a description, a picture, a
/// variant name, whether it is on sale, made to order or a service, its
/// add-ons. Opened once, it stays open for the shop that does use them.
class ProductMoreDetails extends StatelessWidget {
  const ProductMoreDetails({
    super.key,
    required this.expanded,
    required this.onToggle,
    required this.children,
  });

  final bool expanded;
  final VoidCallback onToggle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          button: true,
          expanded: expanded,
          child: InkWell(
            key: const ValueKey('product_form_more_details_toggle'),
            onTap: onToggle,
            borderRadius: BorderRadius.circular(PointyRadii.input),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  Icon(Icons.tune_outlined, color: colors.primaryStrong),
                  SizedBox(width: spacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.productMoreDetailsTitle,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        Text(
                          l10n.productMoreDetailsSummary,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colors.mutedInk,
                          ),
                        ),
                      ],
                    ),
                  ),
                  AnimatedRotation(
                    turns: expanded ? 0.5 : 0,
                    duration: PointyMotion.fast,
                    child: Icon(Icons.expand_more, color: colors.mutedInk),
                  ),
                ],
              ),
            ),
          ),
        ),
        AnimatedSize(
          duration: PointyMotion.fast,
          alignment: AlignmentDirectional.topCenter,
          child: expanded
              ? Padding(
                  padding: EdgeInsets.only(top: spacing.sm),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: children,
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}
