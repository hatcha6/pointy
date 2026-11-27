import 'package:flutter/material.dart';
import 'package:pointy_brand/pointy_brand.dart';

import '../../l10n/generated/app_localizations.dart';
import '../data/models/order.dart';
import '../design/cards_theme.dart';
import '../features/checkout/payment_memory.dart';
import '../design/cards_tokens.dart';
import 'micro.dart';

/// A payment method's mark: its logo on a white chip (Moamalat's for bank
/// cards; a card icon for a method with no mark).
class MethodMark extends StatelessWidget {
  const MethodMark({
    super.key,
    required PaymentMethod method,
    this.width = 48,
    this.height = 32,
  }) : _method = method,
       _provider = null;

  /// The mark of a [provider] alone: a wallet kept from an earlier payment,
  /// with no method read for it.
  const MethodMark.provider(
    String provider, {
    super.key,
    this.width = 48,
    this.height = 32,
  }) : _method = null,
       _provider = provider;

  final PaymentMethod? _method;
  final String? _provider;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final mark = PaymentMethodMarks.of(_method?.provider ?? _provider ?? '');
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
    this.detail,
  });

  final PaymentMethod method;
  final bool selected;
  final VoidCallback onTap;

  /// A wallet's number kept from an earlier payment, under its name.
  final String? detail;

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
        subtitle: detail == null ? null : PayerNumber(detail!),
        trailing: MarkSwitcher(
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

/// A wallet's number as it is shown (0912 ••• 567): digits left to right in
/// any language, in the numbers' own type.
class PayerNumber extends StatelessWidget {
  const PayerNumber(this.masked, {super.key, this.style});

  final String masked;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base =
        style ??
        theme.textTheme.bodyMedium!.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        );
    // Read left to right, but lined up where the row's words start.
    final rtl = Directionality.of(context) == TextDirection.rtl;
    return Text(
      masked,
      textDirection: TextDirection.ltr,
      textAlign: rtl ? TextAlign.right : TextAlign.left,
      style: PointyTypography.numeric(base).copyWith(letterSpacing: 0.5),
    );
  }
}

/// The checkout's row under the way to pay, for a wallet: the number it is
/// paid from, and «تغيير» to pay from another this time.
class PayerRow extends StatelessWidget {
  const PayerRow({
    super.key,
    required this.payer,
    required this.method,
    required this.onChange,
  });

  final PayerDetails payer;
  final PaymentMethod method;
  final VoidCallback onChange;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: CardsSpace.lg),
      onTap: onChange,
      leading: SizedBox(
        width: 48,
        child: Icon(
          method.payer == 'card'
              ? Icons.credit_card_rounded
              : Icons.phone_iphone_rounded,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      title: Text(
        l10n.payFromLabel,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      subtitle: PayerNumber(
        payer.masked,
        style: theme.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w700,
        ),
      ),
      trailing: Text(
        l10n.changeAction,
        style: theme.textTheme.labelLarge?.copyWith(
          color: CardsTheme.link(theme),
        ),
      ),
    );
  }
}
