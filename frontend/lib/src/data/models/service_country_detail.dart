/// One country's networks and bill providers, with the amounts each takes and
/// what the customer pays for them.
///
/// `GET /api/integrations/services/countries/<CODE>/`: read when the cashier
/// picks the country, so the directory itself stays light. Prices are what the
/// customer pays in the shop's currency (`price`; the relay's `retail_price`
/// is accepted too); the shop's cost (`cost`) arrives only for a reader with
/// full visibility and is never needed to sell.
library;

import 'service_kinds.dart';
import 'services_directory.dart';
import 'tolerant_json.dart';

class ServiceCountryDetail {
  const ServiceCountryDetail({
    required this.country,
    this.operators = const [],
    this.billers = const [],
    this.available = true,
    this.errorCode = '',
    this.testMode = false,
  });

  factory ServiceCountryDetail.fromJson(Map<String, Object?> json) {
    final airtime = jsonMap(json['airtime']);
    final bills = jsonMap(json['bills']);
    return ServiceCountryDetail(
      available: json['available'] != false,
      errorCode: jsonText(json['error_code']),
      testMode: json['test_mode'] == true,
      country: ServiceCountry.fromJson(jsonMap(json['country']) ?? const {}),
      operators: jsonList(
        airtime?['operators'],
        AirtimeOperator.fromJson,
      ).where((operator) => operator.id != 0).toList(growable: false),
      billers: jsonList(
        bills?['billers'],
        BillBiller.fromJson,
      ).where((biller) => biller.id != 0).toList(growable: false),
    );
  }

  final ServiceCountry country;
  final List<AirtimeOperator> operators;
  final List<BillBiller> billers;

  /// The shop can sell here right now. False when the server answered but
  /// could not sell (switched off, not linked, no rate): [errorCode] says why,
  /// and there is nothing else in the answer.
  final bool available;
  final String errorCode;

  /// The relay is buying from its test supplier: nothing sent is real and
  /// nothing paid is paid.
  final bool testMode;

  AirtimeOperator? operator(int id) {
    for (final operator in operators) {
      if (operator.id == id) {
        return operator;
      }
    }
    return null;
  }

  /// The country's providers of one type of bill, in the order the server
  /// listed them.
  List<BillBiller> billersOf(BillType type) => [
    for (final biller in billers)
      if (biller.type == type) biller,
  ];

  BillBiller? biller(int id) {
    for (final biller in billers) {
      if (biller.id == id) {
        return biller;
      }
    }
    return null;
  }
}

/// A mobile network that takes airtime.
class AirtimeOperator {
  const AirtimeOperator({
    required this.id,
    this.name = '',
    this.nameEn = '',
    this.logo = '',
    this.mode = ServiceAmountMode.range,
    this.amountCurrency = '',
    this.receiveCurrency = '',
    this.approximate = false,
    this.min,
    this.max,
    this.amounts = const [],
    this.popularAmount,
  });

  factory AirtimeOperator.fromJson(Map<String, Object?> json) {
    final amountCurrency = jsonText(json['amount_currency']).toUpperCase();
    final receiveCurrency = jsonText(json['receive_currency']).toUpperCase();
    return AirtimeOperator(
      id: jsonInt(json['id']),
      name: jsonText(json['name']),
      nameEn: jsonText(json['name_en']),
      logo: jsonText(json['logo']),
      mode: serviceAmountModeFromJson(json['mode']),
      amountCurrency: amountCurrency,
      receiveCurrency: receiveCurrency.isNotEmpty
          ? receiveCurrency
          : amountCurrency,
      approximate: json['approximate'] == true,
      min: jsonDouble(json['min']),
      max: jsonDouble(json['max']),
      amounts: jsonList(
        json['amounts'],
        (entry) => AirtimeAmount.fromJson(
          entry,
          defaultReceiveCurrency: receiveCurrency.isNotEmpty
              ? receiveCurrency
              : amountCurrency,
        ),
      ).where((amount) => amount.amount.isNotEmpty).toList(growable: false),
      popularAmount: jsonText(json['popular_amount']).isEmpty
          ? null
          : jsonDecimalText(json['popular_amount']),
    );
  }

  final int id;

  /// Arabic.
  final String name;

  /// Search only: never shown.
  final String nameEn;
  final String logo;
  final ServiceAmountMode mode;

  /// The currency of [min], [max] and every amount a request carries.
  final String amountCurrency;

  /// What the recipient is credited in.
  final String receiveCurrency;

  /// The recipient's amount is converted at the supplier's rate, so what is
  /// shown for it is close to, not exactly, what arrives.
  final bool approximate;
  final double? min;
  final double? max;

  /// A fixed operator's every denomination; a range operator's round
  /// suggestions inside [min]..[max].
  final List<AirtimeAmount> amounts;
  final String? popularAmount;

  bool get isRange => mode == ServiceAmountMode.range;
  bool get isFixed => mode == ServiceAmountMode.fixed;

  String get label => serviceDisplayName(name, fallback: '#$id');

  /// Whether the cashier can type an amount of their own.
  bool get takesCustomAmount => isRange && (min != null || max != null);

  AirtimeAmount? amountFor(String amount) {
    final wanted = double.tryParse(amount);
    for (final candidate in amounts) {
      if (candidate.amount == amount ||
          (wanted != null && candidate.value == wanted)) {
        return candidate;
      }
    }
    return null;
  }

  /// Whether [value] is one the operator takes.
  bool accepts(double value) {
    if (isFixed) {
      return amounts.any((amount) => amount.value == value);
    }
    final min = this.min;
    final max = this.max;
    return (min == null || value >= min) && (max == null || value <= max);
  }
}

/// One airtime amount: what is sent, what the recipient gets, what it costs
/// the customer.
class AirtimeAmount {
  const AirtimeAmount({
    required this.amount,
    this.receive = '',
    this.receiveCurrency = '',
    this.price,
    this.cost,
  });

  factory AirtimeAmount.fromJson(
    Map<String, Object?> json, {
    String defaultReceiveCurrency = '',
  }) {
    final receiveCurrency = jsonText(json['receive_currency']).toUpperCase();
    return AirtimeAmount(
      amount: jsonDecimalText(json['amount']),
      receive: jsonDecimalText(json['receive']),
      receiveCurrency: receiveCurrency.isNotEmpty
          ? receiveCurrency
          : defaultReceiveCurrency,
      price: jsonDouble(json['price'] ?? json['retail_price']),
      cost: jsonDouble(json['cost']),
    );
  }

  /// In the operator's amount currency, as the relay writes it.
  final String amount;

  /// What the recipient is credited, when it differs from [amount].
  final String receive;
  final String receiveCurrency;

  /// What the customer pays, in the shop's currency; null when the relay
  /// cannot price yet.
  final double? price;
  final double? cost;

  double get value => double.tryParse(amount) ?? 0;

  /// The recipient's amount as text: [receive], else [amount].
  String get received => receive.isNotEmpty ? receive : amount;

  double get receivedValue => double.tryParse(received) ?? value;
}

/// A bill provider: an electricity company, a water company, a television
/// operator, an internet provider.
class BillBiller {
  const BillBiller({
    required this.id,
    this.name = '',
    this.nameEn = '',
    this.type = BillType.other,
    this.service = BillService.unknown,
    this.mode = ServiceAmountMode.range,
    this.requiresInvoice = false,
    this.amountCurrency = '',
    this.min,
    this.max,
    this.suggested = const [],
    this.plans = const [],
  });

  factory BillBiller.fromJson(Map<String, Object?> json) {
    return BillBiller(
      id: jsonInt(json['id']),
      name: jsonText(json['name']),
      nameEn: jsonText(json['name_en']),
      type: billTypeFromJson(json['type']),
      service: billServiceFromJson(json['service']),
      mode: serviceAmountModeFromJson(json['mode']),
      requiresInvoice: json['requires_invoice'] == true,
      amountCurrency: jsonText(json['amount_currency']).toUpperCase(),
      min: jsonDouble(json['min']),
      max: jsonDouble(json['max']),
      suggested: jsonList(
        json['suggested'],
        BillAmount.fromJson,
      ).where((amount) => amount.amount.isNotEmpty).toList(growable: false),
      plans: jsonList(
        json['plans'],
        BillPlan.fromJson,
      ).where((plan) => plan.amount.isNotEmpty).toList(growable: false),
    );
  }

  final int id;

  /// Arabic.
  final String name;

  /// Search only: never shown.
  final String nameEn;
  final BillType type;
  final BillService service;
  final ServiceAmountMode mode;

  /// The order must name the invoice being paid (a postpaid bill): the cashier
  /// types the invoice number as well as the account, and the invoice total.
  final bool requiresInvoice;
  final String amountCurrency;
  final double? min;
  final double? max;
  final List<BillAmount> suggested;
  final List<BillPlan> plans;

  bool get isRange => mode == ServiceAmountMode.range;
  bool get isFixed => mode == ServiceAmountMode.fixed;
  bool get isPrepaid => service == BillService.prepaid;
  bool get isPostpaid => service == BillService.postpaid;

  String get label => serviceDisplayName(name, fallback: '#$id');

  BillPlan? plan(int id) {
    for (final plan in plans) {
      if (plan.id == id) {
        return plan;
      }
    }
    return null;
  }

  bool accepts(double value) {
    final min = this.min;
    final max = this.max;
    return (min == null || value >= min) && (max == null || value <= max);
  }
}

/// A round amount suggested for a bill that takes any amount in a range.
class BillAmount {
  const BillAmount({required this.amount, this.price, this.cost});

  factory BillAmount.fromJson(Map<String, Object?> json) {
    return BillAmount(
      amount: jsonDecimalText(json['amount']),
      price: jsonDouble(json['price'] ?? json['retail_price']),
      cost: jsonDouble(json['cost']),
    );
  }

  final String amount;
  final double? price;
  final double? cost;

  double get value => double.tryParse(amount) ?? 0;
}

/// One plan of a bill that takes only fixed amounts: a television package, a
/// subscription.
class BillPlan {
  const BillPlan({
    required this.id,
    required this.amount,
    this.description = '',
    this.descriptionEn = '',
    this.price,
    this.cost,
  });

  factory BillPlan.fromJson(Map<String, Object?> json) {
    return BillPlan(
      id: jsonInt(json['id']),
      amount: jsonDecimalText(json['amount']),
      description: jsonText(json['description']),
      descriptionEn: jsonText(json['description_en']),
      price: jsonDouble(json['price'] ?? json['retail_price']),
      cost: jsonDouble(json['cost']),
    );
  }

  final int id;
  final String amount;

  /// Arabic.
  final String description;

  /// Search only: never shown.
  final String descriptionEn;
  final double? price;
  final double? cost;

  double get value => double.tryParse(amount) ?? 0;

  String get label => serviceDisplayName(description, fallback: '#$id');
}
