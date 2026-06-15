import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

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
    final textTheme = Theme.of(context).textTheme;

    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(
        spacing.lg,
        spacing.sm,
        spacing.lg,
        spacing.lg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.stockCountVarianceTitle,
            style: textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
          SizedBox(height: spacing.sm),
          Text(
            l10n.stockCountVarianceBody(expected, counted),
            style: textTheme.bodyLarge,
          ),
          SizedBox(height: spacing.lg),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: Text(l10n.stockCountRecount),
                ),
              ),
              SizedBox(width: spacing.sm),
              Expanded(
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: Text(l10n.stockCountConfirm),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
