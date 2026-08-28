import 'package:flutter/material.dart';

import '../../../../l10n/generated/app_localizations.dart';
import '../../../data/models/money_position.dart';
import '../../../shared/components/components.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';

/// Shared vocabulary for the treasury surfaces: the Arabic label behind each
/// backend component code, the icon for each money source, and the two pills
/// every account card and detail sheet renders the same way.
///
/// Kept in one file so a card, a breakdown row and a movement row can never
/// name the same money differently.

/// The Arabic label for a backend component / movement source code.
String treasuryComponentLabel(AppLocalizations l10n, String code) {
  return switch (code) {
    'opening' => l10n.treasuryComponentOpening,
    'sales' => l10n.treasuryComponentSales,
    'drawer_in' => l10n.treasuryComponentDrawerIn,
    'drawer_out' => l10n.treasuryComponentDrawerOut,
    'expenses' => l10n.treasuryComponentExpenses,
    'suppliers' => l10n.treasuryComponentSuppliers,
    'payroll' => l10n.treasuryComponentPayroll,
    'commission' => l10n.treasuryComponentCommission,
    'transfer_in' => l10n.treasuryComponentTransferIn,
    'transfer_out' => l10n.treasuryComponentTransferOut,
    _ => code,
  };
}

IconData treasuryComponentIcon(String code) {
  return switch (code) {
    'opening' => Icons.flag_outlined,
    'sales' => Icons.point_of_sale_outlined,
    'drawer_in' => Icons.south_west,
    'drawer_out' => Icons.north_east,
    'expenses' => Icons.receipt_long_outlined,
    'suppliers' => Icons.local_shipping_outlined,
    'payroll' => Icons.badge_outlined,
    'commission' => Icons.percent,
    'transfer_in' => Icons.call_received,
    'transfer_out' => Icons.call_made,
    _ => Icons.circle_outlined,
  };
}

IconData treasuryAccountIcon(MoneyAccount account) {
  return account.isCash
      ? Icons.savings_outlined
      : Icons.account_balance_outlined;
}

// Bidi isolate marks, spelled as escapes so the source stays readable and the
// analyzer does not warn about invisible direction changes in a literal.
const _isolateStart = '\u2066'; // FIRST STRONG ISOLATE
const _isolateEnd = '\u2069'; // POP DIRECTIONAL ISOLATE

/// A signed money string that reads correctly in RTL.
///
/// The sign lives **inside** the bidi isolate with its number, not beside it.
/// Outside, the sign is a neutral character sitting between an Arabic label and
/// an isolated run, so the paragraph's own direction decides which side it
/// lands on — and a deduction can render with its minus visually attached to
/// the label instead of the amount. Isolating the whole signed quantity makes
/// the pairing structural. Same trap as the price checker's "rows x cols".
String treasurySignedMoney(double amount) {
  final sign = amount == 0 ? '' : (amount < 0 ? '\u2212' : '+');
  return '$_isolateStart$sign${formatMoney(amount.abs())}$_isolateEnd';
}

/// The pill describing an account's last count: never counted, matched, or the
/// variance it found.
PointyStatusPill treasuryCountPill(
  BuildContext context,
  AppLocalizations l10n,
  MoneyCount? count,
) {
  final colors = context.pointyColors;
  if (count == null) {
    return PointyStatusPill(
      label: l10n.treasuryNeverCounted,
      icon: Icons.help_outline,
      color: colors.mutedInk,
    );
  }
  if (!count.hasVariance) {
    return PointyStatusPill(
      label: l10n.treasuryVarianceMatched,
      icon: Icons.check_circle_outline,
      color: colors.success,
    );
  }
  final amount = formatMoney(count.variance.abs());
  return PointyStatusPill(
    label: count.isShort
        ? l10n.treasuryVarianceShort(amount)
        : l10n.treasuryVarianceOver(amount),
    icon: count.isShort ? Icons.trending_down : Icons.trending_up,
    color: count.isShort ? colors.danger : colors.warning,
  );
}

/// "جُرد في 12/08" — or nothing at all when the account has never been counted.
String? treasuryCountedOnLabel(AppLocalizations l10n, MoneyCount? count) {
  final countedAt = count?.countedAt;
  if (countedAt == null) {
    return null;
  }
  return l10n.treasuryCountedOn(formatDate(countedAt));
}
