import 'package:flutter/material.dart';

import '../design/design.dart';
import '../responsive/responsive.dart';

class PointyPermissionDeniedView extends StatelessWidget {
  const PointyPermissionDeniedView({
    super.key,
    required this.title,
    required this.message,
    this.hint,
    this.homeLabel,
    this.onGoHome,
    this.compact = false,
  });

  final String title;
  final String message;

  /// Optional secondary line, e.g. "ask a manager to grant access".
  final String? hint;

  /// Label for the "back to home" action. The action only renders when this is
  /// provided and either [onGoHome] is set or the navigator can pop.
  final String? homeLabel;
  final VoidCallback? onGoHome;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final canGoHome =
        homeLabel != null &&
        (onGoHome != null || Navigator.of(context).canPop());

    return Center(
      child: SingleChildScrollView(
        padding: EdgeInsets.all(compact ? spacing.sm : spacing.xl),
        child: AdaptiveMaxWidth(
          width: AppContentWidth.compact,
          expand: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.danger.withOpacity(0.10),
                  borderRadius: BorderRadius.circular(PointyRadii.card),
                  border: Border.all(
                    color: colors.danger.withOpacity(0.18),
                  ),
                ),
                child: Padding(
                  padding: EdgeInsets.all(compact ? spacing.sm : spacing.md),
                  child: Icon(
                    Icons.lock_person_outlined,
                    size: compact ? 32 : 44,
                    color: colors.danger,
                  ),
                ),
              ),
              SizedBox(height: spacing.md),
              Text(
                title,
                textAlign: TextAlign.center,
                style:
                    (compact ? textTheme.titleMedium : textTheme.headlineSmall)
                        ?.copyWith(fontWeight: FontWeight.w800),
              ),
              SizedBox(height: spacing.sm),
              Text(
                message,
                textAlign: TextAlign.center,
                style: textTheme.bodyMedium?.copyWith(color: colors.mutedInk),
              ),
              if (hint != null && hint!.isNotEmpty) ...[
                SizedBox(height: spacing.sm),
                Text(
                  hint!,
                  textAlign: TextAlign.center,
                  style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
                ),
              ],
              if (canGoHome) ...[
                SizedBox(height: spacing.lg),
                FilledButton.tonalIcon(
                  onPressed: onGoHome ?? () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.home_outlined),
                  label: Text(homeLabel!),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
