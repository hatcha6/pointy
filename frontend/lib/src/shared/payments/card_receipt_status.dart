import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../components/components.dart';
import '../design/design.dart';

/// How well a card payment is backed by a receipt the shop can stand behind.
///
/// One vocabulary for every surface that shows it — the invoice list badge, the
/// shift summary, the receipt viewer — so a colour or a word never means two
/// different things in two places.
///
/// The order below is deliberate: it is worst-first, and
/// [CardReceiptStatus.worstOf] relies on it. A badge exists to surface the rows
/// that need a person, so an invoice holding one proved receipt and one the
/// issuer disowned reads as a problem, not a success.
enum CardReceiptStatus {
  /// The issuer disowned a receipt, or it proves a different amount.
  flagged,

  /// Scanned, still waiting on the issuer.
  pending,

  /// The issuer could not be reached. Says nothing about the receipt.
  unavailable,

  /// Card money taken with no receipt scanned at all.
  noReceipt,

  /// Proved, and for the amount charged.
  verified,

  /// Nothing to say: no card payment on this sale.
  none;

  static CardReceiptStatus parse(Object? value) {
    return switch (value?.toString()) {
      'flagged' => CardReceiptStatus.flagged,
      'pending' => CardReceiptStatus.pending,
      'unavailable' => CardReceiptStatus.unavailable,
      'no_receipt' => CardReceiptStatus.noReceipt,
      'verified' => CardReceiptStatus.verified,
      _ => CardReceiptStatus.none,
    };
  }

  /// The most serious status in [statuses], or [none] when there are none.
  static CardReceiptStatus worstOf(Iterable<CardReceiptStatus> statuses) {
    var worst = CardReceiptStatus.none;
    for (final status in statuses) {
      if (status.index < worst.index) {
        worst = status;
      }
    }
    return worst;
  }

  /// Whether this is worth drawing at all. A cash-only sale shows no badge
  /// rather than an empty one — a list of ticks teaches a cashier to stop
  /// reading them.
  bool get isVisible => this != CardReceiptStatus.none;

  /// Whether a person needs to look at this.
  bool get needsAttention => this == CardReceiptStatus.flagged;

  IconData get icon => switch (this) {
    CardReceiptStatus.verified => Icons.verified_outlined,
    CardReceiptStatus.pending => Icons.schedule_outlined,
    CardReceiptStatus.flagged => Icons.report_gmailerrorred_outlined,
    CardReceiptStatus.unavailable => Icons.cloud_off_outlined,
    CardReceiptStatus.noReceipt => Icons.receipt_long_outlined,
    CardReceiptStatus.none => Icons.circle_outlined,
  };

  Color color(PointySemanticColors colors) => switch (this) {
    CardReceiptStatus.verified => colors.success,
    CardReceiptStatus.pending => colors.mutedInk,
    CardReceiptStatus.flagged => colors.danger,
    CardReceiptStatus.unavailable => colors.warning,
    CardReceiptStatus.noReceipt => colors.mutedInk,
    CardReceiptStatus.none => colors.mutedInk,
  };

  String label(AppLocalizations l10n) => switch (this) {
    CardReceiptStatus.verified => l10n.cardReceiptStatusVerified,
    CardReceiptStatus.pending => l10n.cardReceiptStatusPending,
    CardReceiptStatus.flagged => l10n.cardReceiptStatusFlagged,
    CardReceiptStatus.unavailable => l10n.cardReceiptStatusUnavailable,
    CardReceiptStatus.noReceipt => l10n.cardReceiptStatusNoReceipt,
    CardReceiptStatus.none => '',
  };

  /// The sentence a viewer shows to explain the state, not just name it.
  String description(AppLocalizations l10n) => switch (this) {
    CardReceiptStatus.verified => l10n.cardReceiptStatusVerifiedDetail,
    CardReceiptStatus.pending => l10n.cardReceiptStatusPendingDetail,
    CardReceiptStatus.flagged => l10n.cardReceiptStatusFlaggedDetail,
    CardReceiptStatus.unavailable => l10n.cardReceiptStatusUnavailableDetail,
    CardReceiptStatus.noReceipt => l10n.cardReceiptStatusNoReceiptDetail,
    CardReceiptStatus.none => '',
  };
}

/// The pill marking how a sale's card money is backed.
///
/// Renders through [PointyStatusPill] rather than styling its own chip: an
/// invoice row already carries status and due-date pills, and a badge that sat
/// a pixel off them would read as a different kind of thing. One place decides
/// the icon, colour and word for a status; this is where they get drawn.
///
/// Returns nothing for [CardReceiptStatus.none]. A cash sale shows no badge —
/// a column of ticks on every row teaches a cashier to stop reading them.
class CardReceiptStatusBadge extends StatelessWidget {
  const CardReceiptStatusBadge({super.key, required this.status});

  final CardReceiptStatus status;

  @override
  Widget build(BuildContext context) {
    if (!status.isVisible) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context)!;
    final label = status.label(l10n);
    return Tooltip(
      message: status.description(l10n),
      child: PointyStatusPill(
        label: label,
        icon: status.icon,
        color: status.color(context.pointyColors),
      ),
    );
  }
}
