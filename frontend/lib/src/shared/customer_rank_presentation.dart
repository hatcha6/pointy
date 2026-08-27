import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../data/models/contact.dart';
import 'design/design.dart';

/// Localized label + themed color/icon for an RFM customer rank. Shared by the
/// contacts list (filter chips + per-row badge) and the discount form (rank
/// targeting picker) so a rank looks the same everywhere it appears.
class RankStyle {
  const RankStyle({
    required this.label,
    required this.color,
    required this.icon,
  });

  final String label;
  final Color color;
  final IconData icon;
}

RankStyle customerRankStyle(BuildContext context, CustomerRank rank) {
  final l10n = AppLocalizations.of(context)!;
  final colors = context.pointyColors;
  switch (rank) {
    case CustomerRank.champion:
      return RankStyle(
        label: l10n.customerRankChampion,
        color: colors.accentAmber,
        icon: Icons.workspace_premium_outlined,
      );
    case CustomerRank.loyal:
      return RankStyle(
        label: l10n.customerRankLoyal,
        color: colors.success,
        icon: Icons.favorite_outline,
      );
    case CustomerRank.potentialLoyalist:
      return RankStyle(
        label: l10n.customerRankPotentialLoyalist,
        color: colors.success,
        icon: Icons.trending_up_outlined,
      );
    case CustomerRank.newCustomer:
      return RankStyle(
        label: l10n.customerRankNew,
        color: colors.primaryStrong,
        icon: Icons.fiber_new_outlined,
      );
    case CustomerRank.promising:
      return RankStyle(
        label: l10n.customerRankPromising,
        color: colors.primaryStrong,
        icon: Icons.auto_awesome_outlined,
      );
    case CustomerRank.needsAttention:
      return RankStyle(
        label: l10n.customerRankNeedsAttention,
        color: colors.warning,
        icon: Icons.notifications_active_outlined,
      );
    case CustomerRank.atRisk:
      return RankStyle(
        label: l10n.customerRankAtRisk,
        color: colors.warning,
        icon: Icons.warning_amber_outlined,
      );
    case CustomerRank.cantLose:
      return RankStyle(
        label: l10n.customerRankCantLose,
        color: colors.danger,
        icon: Icons.priority_high_outlined,
      );
    case CustomerRank.hibernating:
      return RankStyle(
        label: l10n.customerRankHibernating,
        color: colors.mutedInk,
        icon: Icons.bedtime_outlined,
      );
    case CustomerRank.lost:
      return RankStyle(
        label: l10n.customerRankLost,
        color: colors.danger,
        icon: Icons.person_off_outlined,
      );
    case CustomerRank.inactive:
      return RankStyle(
        label: l10n.customerRankInactive,
        color: colors.mutedInk,
        icon: Icons.hourglass_empty_outlined,
      );
  }
}
