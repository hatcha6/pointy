import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../../data/repositories/sale_repository.dart';
import '../../../../shared/design/design.dart';
import '../../../../shared/formatters.dart';

/// Why an آجل sale was refused, as something the cashier can act on: the
/// down payment that would let it through, large; then where the customer
/// stands — what they owe, what this sale adds, and the limit it crosses —
/// drawn as one bar instead of four sentences of figures.
class CreditLimitBreakdown extends StatelessWidget {
  const CreditLimitBreakdown({super.key, required this.credit});

  final SaleCheckoutCreditLimitException credit;

  /// What the customer must pay now for the rest to fit under the limit.
  static double shortfall(SaleCheckoutCreditLimitException credit) =>
      math.max(0, credit.projected - credit.limit);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    final needed = shortfall(credit);

    return Column(
      key: const ValueKey('credit_limit_breakdown'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: Color.alphaBlend(
              colors.warning.withValues(alpha: 0.12),
              colors.surface,
            ),
            borderRadius: BorderRadius.circular(PointyRadii.input),
          ),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.account_balance_wallet_outlined,
                    size: 18,
                    color: colors.danger,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      l10n.creditLimitBlockedTitle,
                      key: const ValueKey('checkout_failure_reason'),
                      style: textTheme.titleSmall?.copyWith(
                        color: colors.danger,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                l10n.checkoutCreditNeededLabel,
                textAlign: TextAlign.center,
                style: textTheme.labelLarge?.copyWith(color: colors.ink),
              ),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  formatMoney(needed),
                  key: const ValueKey('credit_limit_needed'),
                  style: PointyTypography.numeric(
                    (textTheme.displaySmall ?? const TextStyle()).copyWith(
                      color: colors.warning,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
              Text(
                l10n.checkoutCreditNeededHint,
                textAlign: TextAlign.center,
                style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _CreditMeter(credit: credit),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _Figure(
                label: l10n.checkoutCreditOutstanding,
                amount: credit.outstanding,
                swatch: colors.mutedInk,
              ),
            ),
            Expanded(
              child: _Figure(
                label: l10n.checkoutCreditThisInvoice,
                amount: credit.newDebt,
                swatch: colors.warning,
              ),
            ),
            Expanded(
              child: _Figure(
                label: l10n.checkoutCreditLimitLabel,
                amount: credit.limit,
                swatch: colors.ink,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Owed, then this sale, on one track whose end is the larger of the limit
/// and where the debt would land; a tick marks the limit, and whatever lies
/// past it is the part the down payment has to cover.
class _CreditMeter extends StatelessWidget {
  const _CreditMeter({required this.credit});

  final SaleCheckoutCreditLimitException credit;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final scale = math.max(credit.projected, credit.limit);
    double share(double amount) =>
        scale <= 0 ? 0 : (amount / scale).clamp(0.0, 1.0);
    final owed = share(credit.outstanding);
    final withSale = share(credit.projected);
    final limitAt = share(credit.limit);

    return SizedBox(
      height: 22,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          // Laid out from the start edge, so the bar fills right-to-left on
          // an Arabic till exactly as the figures below it read.
          Widget segment(double from, double to, Color color) =>
              PositionedDirectional(
                start: width * from,
                width: math.max(0, width * (to - from)),
                top: 5,
                height: 12,
                child: ColoredBox(color: color),
              );
          return Stack(
            children: [
              PositionedDirectional(
                start: 0,
                end: 0,
                top: 5,
                height: 12,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: colors.subtleFill,
                    borderRadius: BorderRadius.circular(PointyRadii.pill),
                  ),
                ),
              ),
              PositionedDirectional(
                start: 0,
                end: 0,
                top: 5,
                height: 12,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(PointyRadii.pill),
                  child: Stack(
                    children: [
                      segment(0, owed, colors.mutedInk.withValues(alpha: 0.55)),
                      segment(
                        owed,
                        math.min(withSale, limitAt),
                        colors.warning,
                      ),
                      if (withSale > limitAt)
                        segment(limitAt, withSale, colors.danger),
                    ],
                  ),
                ),
              ),
              PositionedDirectional(
                start: math.max(0, width * limitAt - 1.5),
                top: 0,
                bottom: 0,
                width: 3,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: colors.ink,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Figure extends StatelessWidget {
  const _Figure({
    required this.label,
    required this.amount,
    required this.swatch,
  });

  final String label;
  final double amount;
  final Color swatch;

  @override
  Widget build(BuildContext context) {
    final colors = context.pointyColors;
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: swatch, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.bodySmall?.copyWith(color: colors.mutedInk),
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: AlignmentDirectional.centerStart,
          child: Text(
            formatMoney(amount),
            style: PointyTypography.numeric(
              (textTheme.titleSmall ?? const TextStyle()).copyWith(
                color: colors.ink,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
