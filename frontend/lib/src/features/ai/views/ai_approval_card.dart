import 'package:flutter/material.dart';

import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import '../../../data/models/ai_chat.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';
import '../../../shared/responsive/responsive.dart';

/// The approval card for a money-moving action the assistant asked to run.
///
/// The server paused the turn instead of running the action: nothing happens
/// until the user taps approve here, and what runs is exactly what the card
/// shows. After answering, the card stays as a recap of the decision so the
/// thread keeps a visible record of what was approved or refused.
class AiApprovalCard extends StatelessWidget {
  const AiApprovalCard({
    super.key,
    required this.question,
    required this.decision,
    required this.submitting,
    required this.onDecide,
  });

  final AiQuestion question;

  /// `true` approved, `false` refused, `null` still waiting for the user.
  final bool? decision;
  final bool submitting;
  final ValueChanged<bool> onDecide;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final textTheme = Theme.of(context).textTheme;
    final l10n = AppLocalizations.of(context)!;
    final details = question.approvalDetails;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(Icons.verified_user_outlined, size: 20, color: colors.primary),
            SizedBox(width: spacing.sm),
            Expanded(
              child: Text(
                question.prompt,
                style: textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        if (details.isNotEmpty) ...[
          SizedBox(height: spacing.sm),
          for (final detail in details) _DetailRow(detail: detail),
        ],
        SizedBox(height: spacing.md),
        if (decision == null)
          _Actions(
            question: question,
            submitting: submitting,
            onDecide: onDecide,
          )
        else
          _Outcome(approved: decision!, l10n: l10n),
        if (decision == null && question.help != null) ...[
          SizedBox(height: spacing.xs),
          Text(
            question.help!,
            style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
          ),
        ],
      ],
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.detail});

  final AiApprovalDetail detail;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final textTheme = Theme.of(context).textTheme;
    final amount = detail.isMoney ? double.tryParse(detail.value) : null;
    final value = amount != null ? formatMoney(amount) : detail.value;

    return Padding(
      padding: EdgeInsets.symmetric(vertical: spacing.xs / 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 2,
            child: Text(
              detail.label,
              style: textTheme.bodyMedium?.copyWith(color: colors.mutedInk),
            ),
          ),
          SizedBox(width: spacing.md),
          Expanded(
            flex: 3,
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Actions extends StatelessWidget {
  const _Actions({
    required this.question,
    required this.submitting,
    required this.onDecide,
  });

  final AiQuestion question;
  final bool submitting;
  final ValueChanged<bool> onDecide;

  @override
  Widget build(BuildContext context) {
    final spacing = AdaptiveSpacing.of(context);
    final l10n = AppLocalizations.of(context)!;
    return Wrap(
      spacing: spacing.sm,
      runSpacing: spacing.xs,
      children: [
        FilledButton.icon(
          key: const ValueKey('ai_approval_approve'),
          onPressed: submitting ? null : () => onDecide(true),
          icon: const Icon(Icons.check, size: 18),
          label: Text(question.confirmLabel ?? l10n.aiAssistantApprovalApprove),
        ),
        OutlinedButton(
          key: const ValueKey('ai_approval_cancel'),
          onPressed: submitting ? null : () => onDecide(false),
          child: Text(question.denyLabel ?? l10n.aiAssistantApprovalCancel),
        ),
      ],
    );
  }
}

class _Outcome extends StatelessWidget {
  const _Outcome({required this.approved, required this.l10n});

  final bool approved;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final spacing = AdaptiveSpacing.of(context);
    final color = approved ? colors.success : colors.mutedInk;
    return Row(
      children: [
        Icon(
          approved ? Icons.check_circle : Icons.block,
          size: 18,
          color: color,
        ),
        SizedBox(width: spacing.xs),
        Expanded(
          child: Text(
            approved
                ? l10n.aiAssistantApprovalApproved
                : l10n.aiAssistantApprovalCancelled,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}
