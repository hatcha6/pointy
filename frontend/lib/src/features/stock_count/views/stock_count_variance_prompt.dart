import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../shared/design/design.dart';
import '../../../shared/responsive/responsive.dart';

/// The single quiet variance question. Returns `true` to recount, `false`/null
/// to confirm (accept the entered count).
Future<bool?> showStockCountVariancePrompt(
  BuildContext context, {
  required String expected,
  required String counted,
}) {
  return showAdaptiveModalBottomSheet<bool>(
    context: context,
    size: AdaptiveModalSize.compact,
    builder: (context) =>
        _VariancePromptSheet(expected: expected, counted: counted),
  );
}

class _VariancePromptSheet extends StatelessWidget {
  const _VariancePromptSheet({required this.expected, required this.counted});

  final String expected;
  final String counted;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;

    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(
        spacing.lg,
        spacing.xs,
        spacing.lg,
        spacing.lg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: colors.warning.withOpacity(0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.compare_arrows_rounded,
                  color: colors.warning,
                  size: 22,
                ),
              ),
              SizedBox(width: spacing.sm),
              Expanded(
                child: Text(
                  l10n.stockCountVarianceTitle,
                  style: textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: spacing.lg),
          Row(
            children: [
              Expanded(
                child: _CompareCard(
                  label: l10n.stockCountColumnExpected,
                  value: expected,
                  emphasized: false,
                ),
              ),
              SizedBox(width: spacing.sm),
              Expanded(
                child: _CompareCard(
                  label: l10n.stockCountYourCount,
                  value: counted,
                  emphasized: true,
                ),
              ),
            ],
          ),
          SizedBox(height: spacing.lg),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 52,
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(true),
                    child: Text(l10n.stockCountRecount),
                  ),
                ),
              ),
              SizedBox(width: spacing.sm),
              Expanded(
                child: SizedBox(
                  height: 52,
                  child: FilledButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: Text(l10n.stockCountConfirm),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CompareCard extends StatelessWidget {
  const _CompareCard({
    required this.label,
    required this.value,
    required this.emphasized,
  });

  final String label;
  final String value;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final accent = emphasized ? PointyColors.primary : colors.mutedInk;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: emphasized
            ? Color.alphaBlend(
                PointyColors.primary.withOpacity(0.06),
                colors.surface,
              )
            : colors.surfaceSunken,
        border: Border.all(
          color: emphasized
              ? PointyColors.primary.withOpacity(0.30)
              : colors.line,
        ),
        borderRadius: BorderRadius.circular(PointyRadii.input),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          vertical: spacing.md,
          horizontal: spacing.md,
        ),
        child: Column(
          children: [
            Text(
              label,
              style: textTheme.labelMedium?.copyWith(
                color: colors.mutedInk,
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(height: spacing.xs),
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: PointyTypography.numeric(
                textTheme.headlineSmall ?? const TextStyle(),
              ).copyWith(color: accent, fontWeight: FontWeight.w800),
            ),
          ],
        ),
      ),
    );
  }
}
