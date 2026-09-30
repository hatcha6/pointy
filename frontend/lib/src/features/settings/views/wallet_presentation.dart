import 'package:flutter/material.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/wallet.dart';
import '../../../shared/design/design.dart';
import '../../../shared/formatters.dart';

/// A wallet amount. Two places like the rest of the app, three only when the
/// dirhams need them — a service charged per message can cost 0.045.
String formatWalletMoney(double value) {
  final thousandths = (value * 1000).round();
  final decimals = thousandths % 10 == 0 ? 2 : 3;
  return '${value.toStringAsFixed(decimals)} $currencySymbol';
}

/// A gateway reference, DFW-XXXXXXXXXX, kept on one line and in its own order
/// inside an Arabic sentence: a plain hyphen is a line-break opportunity, and
/// a split reference is one support cannot read back.
String walletInvoiceText(String invoiceNo) =>
    ltrIsolated(invoiceNo.replaceAll('-', '‑'));

/// An amount as the top-up form shows a bound: no symbol, no trailing ".00".
String formatWalletBound(double value) {
  return value == value.roundToDouble()
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(2);
}

String walletTopUpStatusLabel(WalletTopUpStatus status, AppLocalizations l10n) {
  return switch (status) {
    WalletTopUpStatus.pending => l10n.walletTopUpStatusPending,
    WalletTopUpStatus.paid => l10n.walletTopUpStatusPaid,
    WalletTopUpStatus.canceled => l10n.walletTopUpStatusCanceled,
    WalletTopUpStatus.failed => l10n.walletTopUpStatusFailed,
    WalletTopUpStatus.expired => l10n.walletTopUpStatusExpired,
    WalletTopUpStatus.unknown => l10n.walletTopUpStatusUnknown,
  };
}

Color walletTopUpStatusColor(
  WalletTopUpStatus status,
  PointySemanticColors colors,
) {
  return switch (status) {
    WalletTopUpStatus.paid => colors.success,
    WalletTopUpStatus.pending => colors.primaryStrong,
    WalletTopUpStatus.expired => colors.warning,
    WalletTopUpStatus.failed => colors.danger,
    WalletTopUpStatus.canceled || WalletTopUpStatus.unknown => colors.mutedInk,
  };
}

IconData walletTopUpStatusIcon(WalletTopUpStatus status) {
  return switch (status) {
    WalletTopUpStatus.paid => Icons.check_circle_outline,
    WalletTopUpStatus.pending => Icons.hourglass_top_outlined,
    WalletTopUpStatus.expired => Icons.help_outline,
    WalletTopUpStatus.failed => Icons.error_outline,
    WalletTopUpStatus.canceled => Icons.cancel_outlined,
    WalletTopUpStatus.unknown => Icons.help_outline,
  };
}

String walletMethodLabel(String method, AppLocalizations l10n) {
  return switch (method) {
    WalletTopUpMethod.localBankCards => l10n.walletMethodLocalBankCards,
    _ => method,
  };
}

String walletEntryKindLabel(WalletEntryKind kind, AppLocalizations l10n) {
  return switch (kind) {
    WalletEntryKind.topUp => l10n.walletEntryTopUp,
    WalletEntryKind.charge => l10n.walletEntryCharge,
    WalletEntryKind.refund => l10n.walletEntryRefund,
    WalletEntryKind.adjustment ||
    WalletEntryKind.unknown => l10n.walletEntryAdjustment,
  };
}

IconData walletEntryKindIcon(WalletEntryKind kind) {
  return switch (kind) {
    WalletEntryKind.topUp => Icons.add_card_outlined,
    WalletEntryKind.charge => Icons.shopping_bag_outlined,
    WalletEntryKind.refund => Icons.undo_outlined,
    WalletEntryKind.adjustment ||
    WalletEntryKind.unknown => Icons.tune_outlined,
  };
}

/// The service a charge or refund was for, in Arabic; the raw key for a
/// service this build does not know yet.
String? walletServiceLabel(String service, AppLocalizations l10n) {
  if (service.trim().isEmpty) {
    return null;
  }
  return switch (service) {
    'subscription' => l10n.walletServiceSubscription,
    'sms' => l10n.walletServiceSms,
    'ai' => l10n.walletServiceAi,
    'vouchers' => l10n.walletServiceVouchers,
    _ => service,
  };
}

/// What to tell the owner about a refused wallet call. Codes this build knows
/// get its own sentence; anything else falls back to the backend's Arabic.
String walletErrorMessage(
  AppLocalizations l10n, {
  required String code,
  String message = '',
  double? minAmount,
  double? maxAmount,
}) {
  switch (code) {
    case 'not_configured':
      return l10n.walletErrorNotConfigured;
    case 'relay_unreachable':
      return l10n.walletErrorRelayUnreachable;
    case 'relay_unauthorized':
      return l10n.walletErrorRelayUnauthorized;
    case 'topups_unconfigured':
    case 'wallet_unavailable':
      return l10n.walletTopUpsUnavailable;
    case 'invalid_amount':
      if (minAmount != null && maxAmount != null) {
        return l10n.walletErrorAmountRange(
          formatWalletMoney(minAmount),
          formatWalletMoney(maxAmount),
        );
      }
      return l10n.walletErrorAmount;
    case 'amount_not_allowed':
      return l10n.walletErrorGatewayAmount;
    case 'gateway_busy':
    case 'rate_limited':
    case 'in_flight':
      return l10n.walletErrorBusy;
    case 'gateway_unauthorized':
      return l10n.walletErrorGatewayAccount;
    case 'gateway_rejected':
    case 'gateway_error':
    case 'outcome_unknown':
      return l10n.walletErrorGateway;
    case 'network':
      return l10n.walletErrorNetwork;
    case 'forbidden':
      return l10n.walletErrorForbidden;
  }
  return message.trim().isNotEmpty ? message.trim() : l10n.walletErrorGeneric;
}

String walletExceptionMessage(AppLocalizations l10n, WalletException error) {
  return walletErrorMessage(
    l10n,
    code: error.code,
    message: error.message,
    minAmount: error.minAmount,
    maxAmount: error.maxAmount,
  );
}
