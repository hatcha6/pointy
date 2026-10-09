import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../data/models/balance_entry.dart';
import '../data/services/api_error_detail.dart';
import '../data/services/api_session.dart';

/// «دين عليه» / «رصيد له»: which way a balance written without money runs —
/// the same for a customer, a supplier and an employee.
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
    (BalanceParty.employee, BalanceDirection.theyOweUs) =>
      l10n.employeeBalanceTheyOweUsHint,
    (BalanceParty.employee, BalanceDirection.weOweThem) =>
      l10n.employeeBalanceWeOweThemHint,
  };
}

/// What an entry's row is called, in the words of the buttons that write it:
/// money moving is «استلام مبلغ» or «دفع مبلغ», named from the shop's side —
/// a refund written `theyOweUs` paid the party, `weOweThem` took their money
/// in. An adjustment is the same action recorded without money; an opening
/// balance says which way it runs.
String balanceEntryTitle(
  AppLocalizations l10n,
  BalanceParty party,
  BalanceEntry entry,
) {
  if (entry.isOpening) {
    return '${l10n.balanceKindOpening} • '
        '${balanceDirectionLabel(l10n, entry.direction)}';
  }
  final action = entry.direction == BalanceDirection.theyOweUs
      ? l10n.accountPayMoneyButton
      : l10n.accountReceiveMoneyButton;
  return entry.isRefund ? action : '$action • ${l10n.balanceRowAccountOnly}';
}

/// Where a refund's money moved, for its row; null for an entry that moved
/// none.
String? balanceSettledThrough(AppLocalizations l10n, BalanceEntry entry) {
  return switch (entry.settledThrough) {
    'drawer' => l10n.balanceSettledThroughDrawer,
    'cash_box' => l10n.balanceSettledThroughCashBox,
    'bank' => l10n.balanceSettledThroughBank(entry.moneyAccountName),
    _ => null,
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
    return apiRefusedForClosedPeriod(error)
        ? BalanceFailure.periodLocked
        : BalanceFailure.forbidden;
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
