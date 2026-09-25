import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../data/models/balance_entry.dart';
import '../data/services/api_error_detail.dart';
import '../data/services/api_session.dart';

/// "عليه لنا" / "له علينا" — the words a shop ledger has always used, the same
/// for a customer, a supplier and an employee.
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

/// What an entry's row is called. A cash settlement names the money moving
/// — for an employee, whose account runs both ways, which way it moved.
String balanceEntryTitle(
  AppLocalizations l10n,
  BalanceParty party,
  BalanceEntry entry,
) {
  if (entry.isRefund) {
    if (party == BalanceParty.employee) {
      // A settlement is written the opposite way to what it settles: cash
      // paid to the employee is a debit on their account.
      return entry.direction == BalanceDirection.theyOweUs
          ? l10n.balanceKindEmployeePaidOut
          : l10n.balanceKindEmployeeCollected;
    }
    return balanceKindLabel(l10n, entry.kind);
  }
  return '${balanceKindLabel(l10n, entry.kind)} • '
      '${balanceDirectionLabel(l10n, entry.direction)}';
}

/// The words for settling one side of an account in cash: [settles] is the
/// side being settled — `weOweThem` pays the party, `theyOweUs` takes their
/// money in.
class BalanceCashWords {
  const BalanceCashWords({
    required this.button,
    required this.title,
    required this.hint,
    required this.saved,
  });

  final String button;
  final String title;
  final String hint;
  final String saved;

  factory BalanceCashWords.of(
    AppLocalizations l10n,
    BalanceParty party,
    BalanceDirection settles,
  ) {
    return switch ((party, settles)) {
      (BalanceParty.employee, BalanceDirection.weOweThem) => BalanceCashWords(
        button: l10n.employeePayOutButton,
        title: l10n.employeePayOutTitle,
        hint: l10n.employeePayOutHint,
        saved: l10n.employeePayOutSaved,
      ),
      (BalanceParty.employee, BalanceDirection.theyOweUs) => BalanceCashWords(
        button: l10n.employeeCollectButton,
        title: l10n.employeeCollectTitle,
        hint: l10n.employeeCollectHint,
        saved: l10n.employeeCollectSaved,
      ),
      (BalanceParty.supplier, _) => BalanceCashWords(
        button: l10n.supplierRefundButton,
        title: l10n.supplierRefundTitle,
        hint: l10n.supplierRefundHint,
        saved: l10n.supplierRefundSaved,
      ),
      (BalanceParty.customer, _) => BalanceCashWords(
        button: l10n.customerRefundButton,
        title: l10n.customerRefundTitle,
        hint: l10n.customerRefundHint,
        saved: l10n.customerRefundSaved,
      ),
    };
  }
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
