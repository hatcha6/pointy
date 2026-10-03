import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../data/models/wallet.dart';
import '../../../shared/components/components.dart';
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

/// The line under an SMS balance: how many SMS it pays for and what one
/// costs — or what it owes, when a message went out longer than it was held
/// for and took it below zero.
String smsWalletSummary(SmsWallet sms, AppLocalizations l10n) {
  if (!sms.configured) {
    return l10n.walletSmsNotReady;
  }
  if (sms.owed > 0) {
    return l10n.walletSmsOwed(formatWalletMoney(sms.owed));
  }
  return [
    l10n.walletSmsMessagesLeft(sms.messagesLeft),
    l10n.walletSmsPricePerMessage(formatWalletMoney(sms.price)),
  ].join(' · ');
}

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

/// A top-up method by its key, in Arabic. Keys this build does not know (a
/// method the company added later) fall back to the generic name.
String walletMethodLabel(String method, AppLocalizations l10n) {
  return switch (method) {
    WalletTopUpMethod.bankCards ||
    WalletTopUpMethod.legacyBankCards => l10n.walletMethodLocalBankCards,
    'dafa_sadad' => l10n.walletMethodSadad,
    'dafa_edfali' => l10n.walletMethodEdfali,
    'dafa_mobicash' => l10n.walletMethodMobiCash,
    'dafa_yussor_pay' => l10n.walletMethodYussorPay,
    'dafa_masrafi_pay' => l10n.walletMethodMasrafiPay,
    'dafa_sahara_pay' => l10n.walletMethodSaharaPay,
    _ => l10n.walletTopUpMethodTitle,
  };
}

/// The gateway's own name for a method — what its mark is filed under in
/// assets/payment_methods/ — read from the method key when the relay did not
/// say ("dafa_yussor_pay" is "yussor-pay").
String walletMethodProvider(String methodKey, {String provider = ''}) {
  if (provider.isNotEmpty) {
    return provider;
  }
  if (!methodKey.startsWith('dafa_')) {
    return '';
  }
  return methodKey.substring('dafa_'.length).replaceAll('_', '-');
}

/// The method's mark, or null for local bank cards, which are no one brand
/// and are drawn as a card.
String? walletMethodLogoAsset(String methodKey, {String provider = ''}) {
  final id = walletMethodProvider(methodKey, provider: provider);
  if (id.isEmpty || id == 'moamalat') {
    return null;
  }
  return 'assets/payment_methods/$id.png';
}

IconData walletMethodIcon(WalletPayer payer) {
  return switch (payer) {
    WalletPayer.none => Icons.credit_card,
    WalletPayer.phone => Icons.phone_iphone,
    WalletPayer.card => Icons.account_balance_wallet_outlined,
  };
}

/// What the payer will be asked for, under the method's name.
String walletMethodHint(WalletTopUpMethod method, AppLocalizations l10n) {
  if (!method.confirmsWithCode) {
    return l10n.walletMethodHintHostedPage;
  }
  return switch (method.payer) {
    WalletPayer.phone => l10n.walletMethodHintPhone,
    WalletPayer.card || WalletPayer.none => l10n.walletMethodHintCard,
  };
}

/// The method's mark on its chip, with an icon for one without artwork.
class WalletMethodMark extends StatelessWidget {
  const WalletMethodMark({
    super.key,
    required this.methodKey,
    this.provider = '',
    this.payer = WalletPayer.none,
    this.size = 36,
  });

  WalletMethodMark.of(WalletTopUpMethod method, {Key? key, double size = 36})
    : this(
        key: key,
        methodKey: method.key,
        provider: method.provider,
        payer: method.payer,
        size: size,
      );

  final String methodKey;
  final String provider;
  final WalletPayer payer;
  final double size;

  @override
  Widget build(BuildContext context) {
    return PointyBrandMark(
      asset: walletMethodLogoAsset(methodKey, provider: provider),
      fallbackIcon: walletMethodIcon(payer),
      size: size,
    );
  }
}

String walletEntryKindLabel(WalletEntryKind kind, AppLocalizations l10n) {
  return switch (kind) {
    WalletEntryKind.topUp => l10n.walletEntryTopUp,
    WalletEntryKind.charge => l10n.walletEntryCharge,
    WalletEntryKind.refund => l10n.walletEntryRefund,
    WalletEntryKind.transfer => l10n.walletEntryTransfer,
    WalletEntryKind.adjustment ||
    WalletEntryKind.unknown => l10n.walletEntryAdjustment,
  };
}

IconData walletEntryKindIcon(WalletEntryKind kind) {
  return switch (kind) {
    WalletEntryKind.topUp => Icons.add_card_outlined,
    WalletEntryKind.charge => Icons.shopping_bag_outlined,
    WalletEntryKind.refund => Icons.undo_outlined,
    WalletEntryKind.transfer => Icons.swap_horiz,
    WalletEntryKind.adjustment ||
    WalletEntryKind.unknown => Icons.tune_outlined,
  };
}

/// A plan by its key, in Arabic.
String walletPlanTitle(String key, AppLocalizations l10n) {
  return switch (key) {
    WalletPlan.remoteAccess => l10n.walletPlanRemoteAccessTitle,
    WalletPlan.ai => l10n.walletPlanAiTitle,
    _ => key,
  };
}

IconData walletPlanIcon(String key) {
  return switch (key) {
    WalletPlan.remoteAccess => Icons.lan_outlined,
    WalletPlan.ai => Icons.auto_awesome_outlined,
    _ => Icons.workspace_premium_outlined,
  };
}

/// How long [periods] periods of [periodDays] days are, in words: whole
/// months when they are ("3 أشهر"), else days.
String walletPlanLength(int periodDays, int periods, AppLocalizations l10n) {
  final days = periodDays * periods;
  if (periodDays % 30 == 0) {
    return l10n.walletPlanMonths(days ~/ 30);
  }
  return l10n.walletPlanDays(days);
}

/// The service a charge or refund was for, in Arabic; the raw key for a
/// service this build does not know yet.
String? walletServiceLabel(String service, AppLocalizations l10n) {
  if (service.trim().isEmpty) {
    return null;
  }
  return switch (service) {
    'subscription' => l10n.walletServiceSubscription,
    'remote_access' => l10n.walletServiceRemoteAccess,
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
  String gatewayMessage = '',
  double? minAmount,
  double? maxAmount,
  double? balance,
}) {
  switch (code) {
    case 'insufficient_balance':
      return balance == null
          ? l10n.walletErrorInsufficientBalanceShort
          : l10n.walletErrorInsufficientBalance(formatWalletMoney(balance));
    case 'plan_unavailable':
      return l10n.walletErrorPlanUnavailable;
    case 'plan_included':
      return l10n.walletErrorPlanIncluded;
    case 'invalid_periods':
      return l10n.walletErrorInvalidPeriods;
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
    case 'invalid_phone':
      return l10n.walletErrorInvalidPhone;
    case 'invalid_card_number':
      return l10n.walletErrorInvalidCard;
    case 'invalid_birth_year':
      return l10n.walletErrorInvalidBirthYear;
    case 'unsupported_method':
    case 'method_unavailable':
      return l10n.walletErrorMethodUnavailable;
    case 'payer_rejected':
      // The provider's own sentence says which detail it refused.
      return arabicGatewayMessage(gatewayMessage) ??
          l10n.walletErrorPayerRejected;
    case 'invalid_otp':
      return l10n.walletCodeRequired;
    case 'otp_rejected':
      return l10n.walletCodeWrong;
    case 'confirm_unknown':
      return l10n.walletCodeUnknown;
    case 'otp_attempts_exceeded':
      return l10n.walletAttemptsExceededMessage;
    case 'declined':
      return arabicGatewayMessage(gatewayMessage) ?? l10n.walletDeclinedMessage;
    case 'topup_closed':
    case 'not_otp_method':
      return l10n.walletErrorTopUpClosed;
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
    gatewayMessage: error.gatewayMessage,
    minAmount: error.minAmount,
    maxAmount: error.maxAmount,
    balance: error.balance,
  );
}

/// The gateway's own sentence, when it is Arabic: Dafa writes its refusals
/// for the payer in Arabic, but a validation answer can come back in English,
/// and an Arabic screen never shows that.
String? arabicGatewayMessage(String message) {
  final trimmed = message.trim();
  if (trimmed.isEmpty || !RegExp(r'[\u0600-\u06FF]').hasMatch(trimmed)) {
    return null;
  }
  return trimmed;
}

/// Digits with at most [decimals] places — the gateway's own rule for a
/// top-up, the dirham's three for a transfer — accepting a comma for the
/// decimal point.
class WalletAmountFormatter extends TextInputFormatter {
  WalletAmountFormatter(int decimals)
    : _pattern = RegExp(
        decimals <= 0
            ? r'^\d{0,7}$'
            : '^\\d{0,7}([.,]\\d{0,${decimals.clamp(1, 3)}})?\$',
      );

  final RegExp _pattern;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    return newValue.text.isEmpty || _pattern.hasMatch(newValue.text)
        ? newValue
        : oldValue;
  }
}

/// A typed amount, read the way the formatter lets it be typed.
double? parseWalletAmount(String text) =>
    double.tryParse(text.trim().replaceAll(',', '.'));
