import 'package:flutter/material.dart';
import 'package:pointy_brand/pointy_brand.dart';

import '../../data/models/account_target.dart';
import '../../design/cards_tokens.dart';
import 'topup_text.dart';

/// Whose account an order goes to, as a soft capsule under its status: the
/// kind's mark and the account, left to right.
class AccountLine extends StatelessWidget {
  const AccountLine({super.key, required this.kind, required this.account});

  final TargetKind? kind;
  final String account;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: CardsSpace.lg,
          vertical: CardsSpace.sm,
        ),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(CardsRadii.pill),
          border: Border.all(color: scheme.outline),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(kindIcon(kind), size: 18, color: scheme.onSurfaceVariant),
            const SizedBox(width: CardsSpace.sm),
            Flexible(
              child: Text(
                accountShown(account),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textDirection: TextDirection.ltr,
                style: PointyTypography.numeric(theme.textTheme.titleSmall!)
                    .copyWith(fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
