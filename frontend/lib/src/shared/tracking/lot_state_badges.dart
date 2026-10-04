import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../data/models/stock_batch.dart';
import '../components/pointy_status_pill.dart';
import '../design/design.dart';

/// Why a lot is stopped, said out loud: «محجورة» for a recall or any other
/// lock, «منتهية الصلاحية» once its date (or its status) says so.
///
/// For lists that deliberately offer stopped stock — a supplier return is how
/// a recalled lot leaves — so the buyer sees which rows are the recall rather
/// than guessing from a code. Renders nothing for a healthy lot.
class LotStateBadges extends StatelessWidget {
  const LotStateBadges({
    super.key,
    required this.isSellable,
    this.status = StockBatchStatus.active,
    this.expiryDate,
  });

  final bool isSellable;
  final String status;
  final DateTime? expiryDate;

  static bool isExpiredOn(DateTime? expiryDate, {DateTime? today}) {
    if (expiryDate == null) {
      return false;
    }
    final now = today ?? DateTime.now();
    return expiryDate.isBefore(DateTime(now.year, now.month, now.day));
  }

  bool get _isExpired =>
      status == StockBatchStatus.expired || isExpiredOn(expiryDate);

  /// Stopped for a reason other than its date: a quarantine or a lock.
  bool get _isQuarantined => !isSellable && status != StockBatchStatus.expired;

  /// Whether this lot would show any badge at all.
  bool get isStopped => _isExpired || _isQuarantined;

  @override
  Widget build(BuildContext context) {
    if (!isStopped) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context)!;
    final colors = context.pointyColors;
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        if (_isQuarantined)
          PointyStatusPill(
            label: l10n.stockBatchQuarantinedBadge,
            icon: Icons.block_outlined,
            color: colors.danger,
          ),
        if (_isExpired)
          PointyStatusPill(
            label: l10n.posBatchPickerExpired,
            icon: Icons.event_busy_outlined,
            color: colors.warning,
          ),
      ],
    );
  }
}
