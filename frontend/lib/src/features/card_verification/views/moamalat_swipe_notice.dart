import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../shared/components/components.dart';
import '../../../shared/formatters.dart';
import '../view_models/swipe_plan.dart';
import 'moamalat_live_line.dart';

/// A correction the sheet already made: the terminal took less than the card
/// line, so the line now says what was taken and a new line holds the rest.
class SwipeCorrectionNotice extends StatelessWidget {
  const SwipeCorrectionNotice({
    super.key,
    required this.charged,
    required this.intended,
    required this.onUndo,
  });

  final double charged;
  final double intended;
  final VoidCallback onUndo;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return PointyInlineMessage.warning(
      key: const ValueKey('moamalat_correction_notice'),
      icon: Icons.call_split,
      message: l10n.moamalatShortfallApplied(
        formatMoney(charged),
        formatMoney(intended),
        formatMoney(intended - charged),
      ),
      trailing: TextButton(
        key: const ValueKey('moamalat_correction_undo'),
        onPressed: onUndo,
        child: Text(l10n.moamalatUndoAction),
      ),
    );
  }
}

/// Swipes nothing on the sheet accounts for, each with its one sensible
/// action — or none, when only the terminal can fix it (an overcharge).
class SwipeSuggestionsNotice extends StatelessWidget {
  const SwipeSuggestionsNotice({
    super.key,
    required this.suggestions,
    required this.tenderAmount,
    required this.onApply,
    required this.onIgnore,
  });

  final List<SwipeSuggestion> suggestions;

  /// The amount of the line each suggestion applies to.
  final double Function(SwipeSuggestion suggestion) tenderAmount;
  final ValueChanged<SwipeSuggestion> onApply;
  final ValueChanged<SwipeSuggestion> onIgnore;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      key: const ValueKey('moamalat_swipe_suggestions'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final suggestion in suggestions) ...[
          _row(context, l10n, suggestion),
          const SizedBox(height: 6),
        ],
      ],
    );
  }

  Widget _row(
    BuildContext context,
    AppLocalizations l10n,
    SwipeSuggestion suggestion,
  ) {
    final swipe = suggestion.swipe;
    final where = moamalatSwipeWhere(context, swipe);
    final amount = formatMoney(swipe.amount);
    final line = tenderAmount(suggestion);
    final (String message, String? action) = switch (suggestion.action) {
      SwipeAction.splitShortfall => (
        l10n.moamalatShortfallFound(amount, where, formatMoney(line)),
        l10n.moamalatUseThisSwipeAction,
      ),
      SwipeAction.useAsCard => (
        l10n.moamalatEarlierSwipeFound(amount, where),
        l10n.moamalatUseThisSwipeAction,
      ),
      SwipeAction.overcharged => (
        l10n.moamalatOverchargeFound(
          amount,
          where,
          formatMoney(line),
          formatMoney(swipe.amount - line),
        ),
        null,
      ),
    };
    return PointyInlineMessage.warning(
      icon: suggestion.action == SwipeAction.overcharged
          ? Icons.report_problem_outlined
          : Icons.credit_card,
      message: message,
      trailing: Wrap(
        spacing: 4,
        children: [
          if (action != null)
            TextButton(
              key: ValueKey('moamalat_use_${swipe.rrn}'),
              onPressed: () => onApply(suggestion),
              child: Text(action),
            ),
          TextButton(
            key: ValueKey('moamalat_ignore_${swipe.rrn}'),
            onPressed: () => onIgnore(suggestion),
            child: Text(l10n.moamalatNotThisSaleAction),
          ),
        ],
      ),
    );
  }
}
