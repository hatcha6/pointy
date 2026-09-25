import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../data/models/balance_entry.dart';
import '../data/services/api_error_detail.dart';
import '../data/services/api_session.dart';

/// "عليه لنا" / "له علينا" — the words a shop ledger has always used, the same
/// for a customer and a supplier.
String balanceDirectionLabel(
  AppLocalizations l10n,
  BalanceDirection direction,
) {
  return switch (direction) {
    BalanceDirection.theyOweUs => l10n.balanceDirectionTheyOweUs,
    BalanceDirection.weOweThem => l10n.balanceDirectionWeOweThem,
  };
}

/// The same choice, spelled out for whose account it is on.
String balanceDirectionHint(
  AppLocalizations l10n,
  BalanceParty party,
  BalanceDirection direction,
) {
  return switch ((party, direction)) {
    (BalanceParty.customer, BalanceDirection.theyOweUs) =>
      l10n.customerBalanceTheyOweUsHint,
    (BalanceParty.customer, BalanceDirection.weOweThem) =>
      l10n.customerBalanceWeOweThemHint,
    (BalanceParty.supplier, BalanceDirection.theyOweUs) =>
      l10n.supplierBalanceTheyOweUsHint,
    (BalanceParty.supplier, BalanceDirection.weOweThem) =>
      l10n.supplierBalanceWeOweThemHint,
  };
}

IconData balanceDirectionIcon(BalanceDirection direction) {
  return switch (direction) {
    BalanceDirection.theyOweUs => Icons.call_received_rounded,
    BalanceDirection.weOweThem => Icons.call_made_rounded,
  };
}

String balanceKindLabel(AppLocalizations l10n, BalanceEntryKind kind) {
  return switch (kind) {
    BalanceEntryKind.opening => l10n.balanceKindOpening,
    BalanceEntryKind.adjustment => l10n.balanceKindAdjustment,
    BalanceEntryKind.refund => l10n.balanceKindRefund,
  };
}

/// Why the server refused a balance write, in the terms the screen explains.
enum BalanceFailure {
  openingExists,
  futureDate,
  periodLocked,
  forbidden,

  /// Something has already been collected, paid or spent against the entry.
  settled,

  /// A refund moves cash through the caller's own open drawer.
  sessionRequired,

  /// More than the party is owed, or owes.
  exceedsCredit,

  /// A refund handed cash over; it is never cancelled.
  refundFinal,
  generic,
}

BalanceFailure classifyBalanceFailure(Object? error) {
  final code = apiErrorCode(error);
  if (code == 'opening_balance_exists') {
    return BalanceFailure.openingExists;
  }
  if (code == 'document_blocked') {
    return BalanceFailure.settled;
  }
  if (code == 'register_session_required') {
    return BalanceFailure.sessionRequired;
  }
  if (code == 'refund_exceeds_credit') {
    return BalanceFailure.exceedsCredit;
  }
  if (code == 'refund_is_final') {
    return BalanceFailure.refundFinal;
  }
  final body = error is PosApiException ? error.decodedBody : null;
  if (body is Map) {
    // A form that creates a party nests the balance's own errors under it.
    final nested = body['opening_balance'];
    if (body.containsKey('effective_date') ||
        (nested is Map && nested.containsKey('effective_date'))) {
      return BalanceFailure.futureDate;
    }
  }
  if (apiStatusCode(error) == 403) {
    // The period lock is a refusal to *this user*, like a missing permission,
    // and the server says which in its sentence rather than in a code.
    final detail = apiErrorDetail(error).toLowerCase();
    if (detail.contains('books are closed') ||
        detail.contains('closed period')) {
      return BalanceFailure.periodLocked;
    }
    return BalanceFailure.forbidden;
  }
  return BalanceFailure.generic;
}

String balanceFailureMessage(
  AppLocalizations l10n,
  BalanceFailure failure, {
  required String fallback,
}) {
  return switch (failure) {
    BalanceFailure.openingExists => l10n.balanceEntryOpeningExistsError,
    BalanceFailure.futureDate => l10n.balanceEntryFutureDateError,
    BalanceFailure.periodLocked => l10n.balanceEntryPeriodLockedError,
    BalanceFailure.forbidden => l10n.balanceEntryPermissionError,
    BalanceFailure.settled => l10n.balanceEntryCancelBlockedError,
    BalanceFailure.sessionRequired => l10n.balanceRefundSessionRequiredError,
    BalanceFailure.exceedsCredit => l10n.balanceRefundExceedsCreditError,
    BalanceFailure.refundFinal => l10n.balanceRefundFinalError,
    BalanceFailure.generic => fallback,
  };
}
