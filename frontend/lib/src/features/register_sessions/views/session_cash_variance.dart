import 'package:flutter/material.dart';

import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';

/// How a closed drawer's count compared with what it should have held.
///
/// The server's variance is `closing - expected`, so a negative figure is a
/// shortage. A bare signed number read the same either way at a glance, so
/// every surface names the direction instead — «عجز» or «زيادة» — with the
/// amount always positive.
enum SessionCashVarianceKind { short, over, matched }

SessionCashVarianceKind sessionCashVarianceKind(double variance) {
  if (variance.abs() < 0.005) {
    return SessionCashVarianceKind.matched;
  }
  return variance < 0
      ? SessionCashVarianceKind.short
      : SessionCashVarianceKind.over;
}

/// Compact flag, e.g. «عجز 12.00 د.ل».
String sessionCashVarianceFlag(AppLocalizations l10n, double variance) {
  final amount = formatMoney(variance.abs());
  return switch (sessionCashVarianceKind(variance)) {
    SessionCashVarianceKind.short => l10n.sessionVarianceShort(amount),
    SessionCashVarianceKind.over => l10n.sessionVarianceOver(amount),
    SessionCashVarianceKind.matched => l10n.sessionCashMatchedValue,
  };
}

/// Row label for the variance line of a cash summary.
String sessionCashVarianceMetric(AppLocalizations l10n, double variance) {
  return switch (sessionCashVarianceKind(variance)) {
    SessionCashVarianceKind.short => l10n.sessionCashShortageMetric,
    SessionCashVarianceKind.over => l10n.sessionCashOverageMetric,
    SessionCashVarianceKind.matched => l10n.sessionCashVarianceMetric,
  };
}

/// Shortage is money missing (danger); overage is a count to check (warning).
Color sessionCashVarianceColor(BuildContext context, double variance) {
  final colors = context.pointyColors;
  return switch (sessionCashVarianceKind(variance)) {
    SessionCashVarianceKind.short => colors.danger,
    SessionCashVarianceKind.over => colors.warning,
    SessionCashVarianceKind.matched => colors.success,
  };
}
