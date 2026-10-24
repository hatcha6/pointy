import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../core/money.dart';
import '../../data/models/catalog.dart';
import '../../design/cards_tokens.dart';
import '../../shared/card_art.dart';
import '../../shared/money_text.dart';

/// How an outcome should feel. None of them is red: when an order does not
/// end in a card, the customer's money is safe, and the screen says so
/// calmly before it says anything else.
enum OutcomeTone {
  /// Still on its way, or simply not paid: nothing to worry about.
  neutral,

  /// Settled in the customer's favour: the money is back in their credit.
  safe,

  /// A person is looking at it; worth knowing, nothing lost.
  attention,
}

/// One state of an order: the card, a badge that says how it went, what
/// happened in a sentence, where the money is, and what to do next.
class OrderOutcomePanel extends StatelessWidget {
  const OrderOutcomePanel({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    this.tone = OutcomeTone.neutral,
    this.brand,
    this.busy = false,
    this.credited,
    this.primaryLabel,
    this.onPrimary,
    this.secondaryLabel,
    this.onSecondary,
  });

  final IconData icon;
  final String title;
  final String body;
  final OutcomeTone tone;
  final CardBrand? brand;
  final bool busy;

  /// Money put back in the customer's credit, shown as its own line.
  final Money? credited;
  final String? primaryLabel;
  final VoidCallback? onPrimary;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final accent = switch (tone) {
      OutcomeTone.neutral => theme.colorScheme.primary,
      OutcomeTone.safe => theme.colorScheme.tertiary,
      OutcomeTone.attention => theme.colorScheme.secondary,
    };
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (brand != null) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: CardsSpace.xl),
            child: CardArt(brand: brand!, muted: !busy),
          ),
          const SizedBox(height: CardsSpace.xl),
        ],
        Center(
          child: busy
              ? const SizedBox(
                  width: 40,
                  height: 40,
                  child: CircularProgressIndicator(strokeWidth: 3),
                )
              : _Badge(icon: icon, color: accent),
        ),
        const SizedBox(height: CardsSpace.lg),
        Text(
          title,
          textAlign: TextAlign.center,
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: CardsSpace.sm),
        Text(
          body,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        if (credited != null) ...[
          const SizedBox(height: CardsSpace.lg),
          Center(
            child: _CreditLine(
              amount: formatMoney(l10n, credited!),
              label: l10n.refundedToCredit,
              color: accent,
            ),
          ),
        ],
        if (primaryLabel != null) ...[
          const SizedBox(height: CardsSpace.xl),
          FilledButton(onPressed: onPrimary, child: Text(primaryLabel!)),
        ],
        if (secondaryLabel != null) ...[
          const SizedBox(height: CardsSpace.sm),
          TextButton(onPressed: onSecondary, child: Text(secondaryLabel!)),
        ],
      ],
    );
  }
}

/// The outcome's icon in a soft disc of its colour, settling in with a small
/// spring as the outcome arrives.
class _Badge extends StatelessWidget {
  const _Badge({required this.icon, required this.color});

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.6, end: 1),
      duration: CardsMotion.emphasized,
      curve: CardsMotion.spring,
      builder: (context, scale, child) =>
          Transform.scale(scale: scale, child: child),
      child: Container(
        width: 76,
        height: 76,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, size: 38, color: color),
      ),
    );
  }
}

/// «+ 10.00 د.ل · أُضيف إلى رصيدك»: where the money went, in one glance.
class _CreditLine extends StatelessWidget {
  const _CreditLine({
    required this.amount,
    required this.label,
    required this.color,
  });

  final String amount;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: CardsSpace.lg,
        vertical: CardsSpace.sm,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(CardsRadii.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.account_balance_wallet_rounded, size: 18, color: color),
          const SizedBox(width: CardsSpace.sm),
          // One sentence that wraps on a narrow phone or large text.
          Flexible(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '+ $amount',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: color,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  TextSpan(text: '  $label'),
                ],
              ),
              style: theme.textTheme.bodyMedium?.copyWith(color: color),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}
