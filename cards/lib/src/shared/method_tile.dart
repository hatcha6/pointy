import 'package:flutter/material.dart';
import 'package:pointy_brand/pointy_brand.dart';

import '../../l10n/generated/app_localizations.dart';
import '../data/models/order.dart';
import '../design/cards_tokens.dart';

/// A payment method's mark: its logo on a white chip (a card icon for bank
/// cards, which are no one brand).
class MethodMark extends StatelessWidget {
  const MethodMark({
    super.key,
    required this.method,
    this.width = 48,
    this.height = 32,
  });

  final PaymentMethod method;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final mark = PaymentMethodMarks.of(method.provider);
    return Container(
      width: width,
      height: height,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0x1A101828)),
      ),
      child: mark != null
          ? Image(image: mark, fit: BoxFit.contain)
          : const Icon(
              Icons.credit_card_rounded,
              size: 20,
              color: PointyColors.primary,
            ),
    );
  }
}

/// The name a method is shown under.
String methodName(BuildContext context, PaymentMethod method) =>
    method.provider == 'moamalat'
    ? AppLocalizations.of(context).bankCards
    : method.name;

/// One row of the method picker: mark, name, and a radio check.
class MethodRow extends StatelessWidget {
  const MethodRow({
    super.key,
    required this.method,
    required this.selected,
    required this.onTap,
  });

  final PaymentMethod method;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      selected: selected,
      inMutuallyExclusiveGroup: true,
      child: ListTile(
        onTap: onTap,
        contentPadding: const EdgeInsets.symmetric(horizontal: CardsSpace.lg),
        leading: MethodMark(method: method),
        title: Text(
          methodName(context, method),
          style: theme.textTheme.titleMedium,
        ),
        trailing: AnimatedSwitcher(
          duration: CardsMotion.fast,
          child: Icon(
            selected ? Icons.check_circle_rounded : Icons.circle_outlined,
            key: ValueKey(selected),
            color: selected ? PointyColors.primary : theme.colorScheme.outline,
          ),
        ),
      ),
    );
  }
}
