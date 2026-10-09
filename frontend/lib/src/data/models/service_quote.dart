/// What the shop backend answers the till about one airtime top-up or one bill
/// payment before it goes in the cart: the network the relay recognised for a
/// number, the exact price of one thing, the recipients sold to lately.
///
/// Refusals are ordinary answers here, not errors: a number the relay cannot
/// place, an amount outside a network's range. They carry stable codes
/// ([ServiceRefusalCode]); the Arabic wording is the till's own.
library;

import 'service_country_detail.dart';
import 'service_kinds.dart';
import 'tolerant_json.dart';

/// The stable codes of a refused detection or quote.
abstract final class ServiceRefusalCode {
  static const notDetected = 'not_detected';
  static const invalidPhone = 'invalid_phone';
  static const invalidAccount = 'invalid_account';
  static const invoiceRequired = 'invoice_required';

  /// The invoice number was given but is not one the provider takes (24
  /// letters, digits and `- _ /` at most).
  static const invalidInvoice = 'invalid_invoice';
  static const amountOutOfRange = 'amount_out_of_range';
  static const amountNotOffered = 'amount_not_offered';
  static const invalidAmount = 'invalid_amount';
  static const unknownOperator = 'unknown_operator';
  static const unknownBiller = 'unknown_biller';
  static const serviceUnavailable = 'service_unavailable';
  static const rateUnset = 'rate_unset';
  static const unreachable = 'unreachable';
  static const unavailable = 'unavailable';
  static const notConfigured = 'not_configured';
  static const switchedOff = 'switched_off';

  /// A refusal that may pass by itself — the relay could not be reached, the
  /// service is unavailable for the moment — as opposed to one that will be
  /// the same however often it is asked (an amount out of range, a number that
  /// is not one). Only the first kind is worth asking again.
  static bool isTransient(String code) =>
      code == unreachable || code == serviceUnavailable || code == unavailable;
}

/// A phone number as the relay normalised it.
class ServicePhone {
  const ServicePhone({this.e164 = '', this.national = '', this.country = ''});

  factory ServicePhone.fromJson(Map<String, Object?> json) {
    return ServicePhone(
      e164: jsonText(json['e164']),
      national: jsonText(json['national']),
      country: jsonText(json['country']).toUpperCase(),
    );
  }

  /// `+22370123456`.
  final String e164;
  final String national;
  final String country;
}

/// The network the relay recognised for a number.
class OperatorDetection {
  const OperatorDetection({
    required this.detected,
    this.reason = '',
    this.operator,
    this.phone,
  });

  factory OperatorDetection.fromJson(Map<String, Object?> json) {
    final operatorJson = jsonMap(json['operator']);
    final operator = operatorJson == null
        ? null
        : AirtimeOperator.fromJson(operatorJson);
    final phoneJson = jsonMap(json['phone']);
    final hasOperator = operator != null && operator.id != 0;
    return OperatorDetection(
      detected:
          (json['detected'] == true || json['detected'] == null) && hasOperator,
      reason: jsonText(json['reason']),
      operator: hasOperator ? operator : null,
      phone: phoneJson == null ? null : ServicePhone.fromJson(phoneJson),
    );
  }

  final bool detected;

  /// Why nothing was detected, as a [ServiceRefusalCode].
  final String reason;
  final AirtimeOperator? operator;
  final ServicePhone? phone;
}

/// What the till asks to have priced: one top-up or one bill payment.
class ServiceQuoteRequest {
  const ServiceQuoteRequest.airtime({
    required this.country,
    required int this.operatorId,
    required String this.phone,
    required this.amount,
    required this.amountCurrency,
  }) : kind = ServiceKind.airtime,
       billerId = null,
       account = null,
       amountId = null,
       invoiceId = null;

  const ServiceQuoteRequest.bill({
    required this.country,
    required int this.billerId,
    required String this.account,
    required this.amount,
    required this.amountCurrency,
    this.amountId,
    this.invoiceId,
  }) : kind = ServiceKind.bill,
       operatorId = null,
       phone = null;

  /// A request read back from [toJson]: a line held in an invoice keeps the
  /// request it was priced from, so it can be priced again.
  factory ServiceQuoteRequest.fromJson(Map<String, Object?> json) {
    final kind = serviceKindFromJson(json['kind']) ?? ServiceKind.airtime;
    final country = jsonText(json['country']);
    final amount = jsonDecimalText(json['amount']);
    final currency = jsonText(json['amount_currency']);
    if (kind == ServiceKind.airtime) {
      return ServiceQuoteRequest.airtime(
        country: country,
        operatorId: jsonInt(json['operator_id']),
        phone: jsonText(json['phone']),
        amount: amount,
        amountCurrency: currency,
      );
    }
    return ServiceQuoteRequest.bill(
      country: country,
      billerId: jsonInt(json['biller_id']),
      account: jsonText(json['account']),
      amount: amount,
      amountCurrency: currency,
      amountId: json['amount_id'] == null ? null : jsonInt(json['amount_id']),
      invoiceId: jsonText(json['invoice_id']).isEmpty
          ? null
          : jsonText(json['invoice_id']),
    );
  }

  final ServiceKind kind;
  final String country;
  final int? operatorId;
  final int? billerId;
  final String? phone;
  final String? account;

  /// The amount as a plain decimal string, in [amountCurrency].
  final String amount;
  final String amountCurrency;

  /// The plan, for a bill that takes fixed amounts.
  final int? amountId;

  /// The invoice being paid, for a bill that needs one.
  final String? invoiceId;

  Map<String, Object?> toJson() => {
    'kind': serviceKindToJson(kind),
    'country': country,
    if (operatorId != null) 'operator_id': operatorId,
    if (billerId != null) 'biller_id': billerId,
    if (phone != null) 'phone': phone,
    if (account != null) 'account': account,
    'amount': amount,
    'amount_currency': amountCurrency,
    if (amountId != null) 'amount_id': amountId,
    if (invoiceId != null && invoiceId!.isNotEmpty) 'invoice_id': invoiceId,
  };

  /// Two requests that would be answered alike: what a newer request replaces.
  String get signature =>
      '${serviceKindToJson(kind)}|$country|$operatorId|'
      '$billerId|$phone|$account|$amount|$amountCurrency|$amountId|$invoiceId';
}

/// The exact price of one thing, sealed by the server: the cart line carries
/// [quote] to checkout, where the server opens it and charges the price again.
class ServiceQuote {
  const ServiceQuote({
    required this.kind,
    required this.optionCode,
    required this.optionLabel,
    required this.subscriberRef,
    required this.price,
    required this.receiveAmount,
    required this.receiveCurrency,
    required this.quote,
    required this.serviceVariantId,
    this.approximate = false,
    this.exceedsFloat = false,
    this.cost,
    this.request,
  });

  /// The server does not have to say what kind of thing it priced: the option
  /// code it builds starts `air:` or `bill:`, and [kind] is what the till asked
  /// for. A bill quote must never be taken for airtime.
  factory ServiceQuote.fromJson(
    Map<String, Object?> json, {
    ServiceKind? kind,
  }) {
    final receive = jsonMap(json['receive']);
    final optionCode = jsonText(json['option_code']);
    return ServiceQuote(
      kind:
          serviceKindFromJson(json['kind']) ??
          kind ??
          (optionCode.toLowerCase().startsWith('bill:')
              ? ServiceKind.bill
              : ServiceKind.airtime),
      optionCode: optionCode,
      optionLabel: jsonText(json['option_label']),
      subscriberRef: jsonText(json['subscriber_ref']),
      price: jsonDouble(json['price']) ?? 0,
      receiveAmount: jsonDecimalText(receive?['amount']),
      receiveCurrency: jsonText(receive?['currency']).toUpperCase(),
      approximate: json['approximate'] == true,
      quote: jsonText(json['quote']),
      serviceVariantId: jsonInt(json['service_variant_id']),
      exceedsFloat: json['exceeds_float'] == true,
      cost: jsonDouble(json['cost']),
    );
  }

  final ServiceKind kind;

  /// `air:289:5000:XOF`, `bill:5:2000:NGN` — built by the server, never here.
  final String optionCode;
  final String optionLabel;

  /// The number or account as the server normalised it (`+22370123456`).
  final String subscriberRef;

  /// What the customer pays, in the shop's currency.
  final double price;

  /// What the recipient is credited.
  final String receiveAmount;
  final String receiveCurrency;
  final bool approximate;

  /// The sealed copy of the price, handed back at checkout.
  final String quote;

  /// The system service product the cart line points at.
  final int serviceVariantId;

  /// The voucher balance, as last read, cannot pay for it.
  final bool exceedsFloat;
  final double? cost;

  /// The request this answers, set by whoever asked: what a line needs to be
  /// priced again later (a held invoice's quote does not last).
  final ServiceQuoteRequest? request;

  /// This quote, remembering the [request] it answers.
  ServiceQuote withRequest(ServiceQuoteRequest request) => ServiceQuote(
    kind: kind,
    optionCode: optionCode,
    optionLabel: optionLabel,
    subscriberRef: subscriberRef,
    price: price,
    receiveAmount: receiveAmount,
    receiveCurrency: receiveCurrency,
    quote: quote,
    serviceVariantId: serviceVariantId,
    approximate: approximate,
    exceedsFloat: exceedsFloat,
    cost: cost,
    request: request,
  );

  double get receiveValue => double.tryParse(receiveAmount) ?? 0;

  /// A quote the till can build a cart line from: it names what it prices, it
  /// is sealed, and its price is a real one — a line priced at nothing would
  /// be sold for nothing.
  bool get isUsable =>
      optionCode.isNotEmpty &&
      quote.isNotEmpty &&
      subscriberRef.isNotEmpty &&
      price.isFinite &&
      price > 0;
}

/// A quote the server declined to give, and why.
class ServiceQuoteRefusal {
  const ServiceQuoteRefusal({
    required this.errorCode,
    this.min,
    this.max,
    this.reason = '',
  });

  factory ServiceQuoteRefusal.fromJson(Map<String, Object?> json) {
    return ServiceQuoteRefusal(
      errorCode: jsonText(json['error_code'] ?? json['code']),
      min: jsonDouble(json['min']),
      max: jsonDouble(json['max']),
      reason: jsonText(json['reason']),
    );
  }

  /// A [ServiceRefusalCode].
  final String errorCode;
  final double? min;
  final double? max;
  final String reason;

  /// Asking again may be answered differently.
  bool get isTransient => ServiceRefusalCode.isTransient(errorCode);
}

/// Either a [quote] or the [refusal] that took its place.
class ServiceQuoteOutcome {
  const ServiceQuoteOutcome.quoted(ServiceQuote this.quote) : refusal = null;

  const ServiceQuoteOutcome.refused(ServiceQuoteRefusal this.refusal)
    : quote = null;

  factory ServiceQuoteOutcome.fromJson(
    Map<String, Object?> json, {
    ServiceKind? kind,
  }) {
    if (json['ok'] == false || json['error_code'] != null) {
      return ServiceQuoteOutcome.refused(ServiceQuoteRefusal.fromJson(json));
    }
    final quote = ServiceQuote.fromJson(json, kind: kind);
    if (!quote.isUsable) {
      // A reply that is neither a price nor a reason is not a price.
      return const ServiceQuoteOutcome.refused(
        ServiceQuoteRefusal(errorCode: ServiceRefusalCode.unreachable),
      );
    }
    return ServiceQuoteOutcome.quoted(quote);
  }

  final ServiceQuote? quote;
  final ServiceQuoteRefusal? refusal;

  bool get isQuoted => quote != null;
}

/// A recipient sold to lately, so a repeat customer is one tap.
class RecentRecipient {
  const RecentRecipient({
    required this.phone,
    this.country = '',
    this.operatorId = 0,
    this.operatorName = '',
    this.amount = '',
    this.currency = '',
    this.at,
  });

  factory RecentRecipient.fromJson(Map<String, Object?> json) {
    return RecentRecipient(
      phone: jsonText(json['phone']),
      country: jsonText(json['country']).toUpperCase(),
      operatorId: jsonInt(json['operator_id']),
      operatorName: jsonText(json['operator_name']),
      amount: jsonDecimalText(json['amount']),
      currency: jsonText(json['currency']).toUpperCase(),
      at: jsonDate(json['at']),
    );
  }

  /// `+22370123456`.
  final String phone;
  final String country;
  final int operatorId;

  /// Arabic.
  final String operatorName;

  /// The last amount sent, in [currency].
  final String amount;
  final String currency;
  final DateTime? at;
}
