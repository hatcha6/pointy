import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import '../../../../data/models/integration_card.dart';
import '../../../../data/models/integration_provider.dart';
import '../../../../data/models/service_kinds.dart';
import '../../../../data/models/service_quote.dart';
import '../../view_models/service_blocker.dart';
import '../../direct_services/foreign_amount.dart';
import 'service_card_art.dart';

/// The Arabic the direct-service screens read: one place, so a service's
/// name, promise and reasons are said the same wherever they appear.

String serviceCardTitle(AppLocalizations l10n, ServiceCardKind kind) =>
    switch (kind) {
      ServiceCardKind.airtime => l10n.posServicesAirtimeTitle,
      ServiceCardKind.electricity => l10n.posServicesElectricityTitle,
      ServiceCardKind.water => l10n.posServicesWaterTitle,
      ServiceCardKind.tv => l10n.posServicesTvTitle,
      ServiceCardKind.internet => l10n.posServicesInternetTitle,
    };

String serviceCardPromise(AppLocalizations l10n, ServiceCardKind kind) =>
    switch (kind) {
      ServiceCardKind.airtime => l10n.posServicesAirtimePromise,
      ServiceCardKind.electricity => l10n.posServicesElectricityPromise,
      ServiceCardKind.water => l10n.posServicesWaterPromise,
      ServiceCardKind.tv => l10n.posServicesTvPromise,
      ServiceCardKind.internet => l10n.posServicesInternetPromise,
    };

/// «126 دولة · 411 شبكة», or null when the menu gave no counts.
String? serviceCardCaption(
  AppLocalizations l10n,
  ServiceCardKind kind, {
  required int countries,
  required int providers,
}) {
  if (countries <= 0 && providers <= 0) {
    return null;
  }
  final reach = l10n.posServicesCountriesCount(countries);
  if (providers <= 0) {
    return reach;
  }
  final who = kind == ServiceCardKind.airtime
      ? l10n.posServicesNetworksCount(providers)
      : l10n.posServicesProvidersCount(providers);
  return countries <= 0 ? who : '$reach · $who';
}

/// The title of a type of bill: «فواتير الكهرباء».
String billTypeTitle(AppLocalizations l10n, BillType type) => switch (type) {
  BillType.electricity => l10n.posServicesElectricityTitle,
  BillType.water => l10n.posServicesWaterTitle,
  BillType.tv => l10n.posServicesTvTitle,
  BillType.internet => l10n.posServicesInternetTitle,
  _ => l10n.posServicesTabBills,
};

/// What to type in the number field of a bill, by type.
String billAccountLabel(AppLocalizations l10n, BillType type) => switch (type) {
  BillType.electricity => l10n.posBillAccountLabelElectricity,
  BillType.water => l10n.posBillAccountLabelWater,
  BillType.tv => l10n.posBillAccountLabelTv,
  _ => l10n.posBillAccountLabelInternet,
};

String billAccountExample(AppLocalizations l10n, BillType type) =>
    switch (type) {
      BillType.electricity => l10n.posBillAccountExampleElectricity,
      BillType.water => l10n.posBillAccountExampleWater,
      BillType.tv => l10n.posBillAccountExampleTv,
      _ => l10n.posBillAccountExampleInternet,
    };

/// The one line that says what the cashier needs in hand for this bill.
String billNeeds(AppLocalizations l10n, BillType type) => switch (type) {
  BillType.electricity => l10n.posBillNeedsElectricity,
  BillType.water => l10n.posBillNeedsWater,
  BillType.tv => l10n.posBillNeedsTv,
  _ => l10n.posBillNeedsInternet,
};

/// The reason an add is not possible yet, in Arabic. [accountLabel] names the
/// number a bill asks for.
String serviceBlockerText(
  AppLocalizations l10n,
  ServiceBlocker blocker, {
  String accountLabel = '',
  String currencyLabel = '',
}) {
  String amount(double? value) =>
      value == null ? '' : formatForeignAmount(value);
  return switch (blocker.reason) {
    ServiceBlockReason.notSellable => l10n.posServicesBlockNotSellable,
    ServiceBlockReason.noCountry => l10n.posServicesBlockNoCountry,
    ServiceBlockReason.loadingCountry => l10n.posServicesBlockLoadingCountry,
    ServiceBlockReason.countryFailed => l10n.posServicesBlockCountryFailed,
    ServiceBlockReason.noNumber => l10n.posServicesBlockNoNumber,
    ServiceBlockReason.numberTooShort => l10n.posServicesBlockNumberShort,
    ServiceBlockReason.numberTooLong => l10n.posServicesBlockNumberLong,
    ServiceBlockReason.chooseDialCountry =>
      l10n.posServicesBlockChooseDialCountry,
    ServiceBlockReason.numberInvalid => l10n.posServicesRefusalInvalidPhone,
    ServiceBlockReason.numberMismatch => l10n.posServicesBlockNumberMismatch,
    ServiceBlockReason.noNetwork => l10n.posServicesBlockNoNetwork,
    ServiceBlockReason.noProvider => l10n.posServicesBlockNoProvider,
    ServiceBlockReason.noAccount => l10n.posServicesBlockNoAccount(
      accountLabel,
    ),
    ServiceBlockReason.accountTooShort => l10n.posServicesBlockAccountShort(
      accountLabel,
    ),
    ServiceBlockReason.noInvoice => l10n.posServicesBlockNoInvoice,
    ServiceBlockReason.noAmount => l10n.posServicesBlockNoAmount,
    ServiceBlockReason.noPlan => l10n.posServicesBlockNoPlan,
    ServiceBlockReason.amountInvalid => l10n.posServicesBlockAmountInvalid,
    ServiceBlockReason.amountBelowMin => l10n.posServicesBlockAmountLow(
      amount(blocker.min),
    ),
    ServiceBlockReason.amountAboveMax => l10n.posServicesBlockAmountHigh(
      amount(blocker.max),
    ),
    ServiceBlockReason.quoting => l10n.posServicesPricing,
    ServiceBlockReason.quoteFailed => l10n.posServicesBlockQuoteFailed,
    ServiceBlockReason.quoteRefused => serviceRefusalText(
      l10n,
      blocker.code,
      min: blocker.min,
      max: blocker.max,
    ),
  };
}

/// What a refused quote says, by the server's stable code.
String serviceRefusalText(
  AppLocalizations l10n,
  String code, {
  double? min,
  double? max,
}) {
  return switch (code) {
    ServiceRefusalCode.invalidPhone => l10n.posServicesRefusalInvalidPhone,
    ServiceRefusalCode.invalidAccount => l10n.posServicesRefusalInvalidAccount,
    ServiceRefusalCode.invoiceRequired =>
      l10n.posServicesRefusalInvoiceRequired,
    ServiceRefusalCode.invalidInvoice => l10n.posServicesRefusalInvalidInvoice,
    ServiceRefusalCode.amountOutOfRange =>
      min != null && max != null
          ? l10n.posServicesRefusalOutOfRangeLimits(
              formatForeignAmount(min),
              formatForeignAmount(max),
            )
          : l10n.posServicesRefusalOutOfRange,
    ServiceRefusalCode.amountNotOffered => l10n.posServicesRefusalNotOffered,
    ServiceRefusalCode.invalidAmount => l10n.posServicesRefusalInvalidAmount,
    ServiceRefusalCode.unknownOperator ||
    ServiceRefusalCode.unknownBiller => l10n.posServicesRefusalUnknown,
    ServiceRefusalCode.serviceUnavailable ||
    ServiceRefusalCode.unavailable => l10n.posServicesRefusalUnavailable,
    ServiceRefusalCode.rateUnset => l10n.posServicesRefusalRateUnset,
    ServiceRefusalCode.unreachable => l10n.posServicesRefusalUnreachable,
    ServiceRefusalCode.notConfigured => l10n.posServicesRefusalNotConfigured,
    ServiceRefusalCode.switchedOff => l10n.posServicesRefusalSwitchedOff,
    _ => l10n.posServicesRefusalOther,
  };
}

/// Why a provider did not perform an airtime top-up or a bill payment, in
/// plain words — never the card and agency wording of a subscriber's top-up.
/// The shop backend names the cause in its code or, for a refusal the relay
/// gave, in the detail.
String serviceChargeReason(AppLocalizations l10n, IntegrationChargeResult row) {
  final detail = row.errorDetail.toLowerCase();
  return switch (row.errorCode) {
    IntegrationErrorCode.insufficientFloat => l10n.posServiceReasonInsufficient,
    IntegrationErrorCode.priceChanged => l10n.posServiceReasonPriceChanged,
    IntegrationErrorCode.unreachable ||
    IntegrationErrorCode.unavailable ||
    IntegrationErrorCode.switchedOff ||
    IntegrationErrorCode.notConfigured => l10n.posServiceReasonUnavailable,
    _ when detail.contains('price_changed') =>
      l10n.posServiceReasonPriceChanged,
    _ when detail.contains('invalid') => l10n.posServiceReasonInvalidNumber,
    _ => l10n.posServiceReasonRefused,
  };
}

/// How long ago a service line was priced — «سُعّرت قبل 3 ساعات» — for a line
/// held in an invoice, whose price is that old. Null for a line priced a
/// moment ago, or one that never said when.
String? serviceQuoteAgeText(
  AppLocalizations l10n,
  DateTime? quotedAt, {
  DateTime? now,
}) {
  if (quotedAt == null) {
    return null;
  }
  final age = (now ?? DateTime.now()).difference(quotedAt);
  if (age < const Duration(minutes: 1)) {
    return null;
  }
  if (age < const Duration(hours: 1)) {
    return l10n.posServiceQuoteAgeMinutes(age.inMinutes);
  }
  if (age < const Duration(days: 1)) {
    return l10n.posServiceQuoteAgeHours(age.inHours);
  }
  return l10n.posServiceQuoteAgeDays(age.inDays);
}
