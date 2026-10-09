// Dev-only fake of the shop backend's direct-services endpoints, for the
// preview harness, the capture test and the view-model tests: it answers from
// lib/dev/services_fixtures.dart, with artificial latency to show the loading
// states, a network the "relay" cannot place, and a quote it refuses.
// Not part of the shipping app. Safe to delete.
import 'dart:async';

import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/integration_card.dart';
import 'package:pointy_frontend/src/data/models/service_country_detail.dart';
import 'package:pointy_frontend/src/data/models/service_kinds.dart';
import 'package:pointy_frontend/src/data/models/service_quote.dart';
import 'package:pointy_frontend/src/data/models/services_directory.dart';
import 'package:pointy_frontend/src/data/models/voucher_menu.dart';
import 'package:pointy_frontend/src/data/repositories/integrations_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/pos/direct_services/arabic_search_text.dart';
import 'package:pointy_frontend/src/features/pos/direct_services/foreign_amount.dart';

import 'services_fixtures.dart';

class PreviewServicesRepository extends IntegrationsRepository {
  PreviewServicesRepository({
    this.menu,
    this.directoryDelay = Duration.zero,
    this.countryDelay = Duration.zero,
    this.detectDelay = Duration.zero,
    this.quoteDelay = Duration.zero,
  }) : super(PosApiService());

  /// What the voucher menu read answers; null leaves the base behaviour.
  VoucherMenu? menu;

  Duration directoryDelay;
  Duration countryDelay;
  Duration detectDelay;
  Duration quoteDelay;

  /// Answer the directory read with an error (the shop is offline).
  bool failDirectory = false;

  /// Countries whose read fails.
  final Set<String> failCountries = {};

  /// Answer every detection with a transport error.
  bool failDetect = false;

  /// Answer every quote with this refusal code, when set.
  String? refuseQuote;

  /// Answer every quote with a transport error.
  bool failQuote = false;

  /// Answer every airtime quote with this number as the one the server
  /// normalised (`+22399999999`), when set — a server that read the digits
  /// differently from the relay.
  String? quoteSubscriberRef;

  /// Answer quotes with this price, when set (a price that moved).
  double? quotePrice;

  /// Say every quote is dearer than the voucher balance holds.
  bool quoteExceedsFloat = false;

  /// The directory to serve; the harness's own when null.
  ServicesDirectory? directory;

  /// Say the relay is buying from its test supplier (`test_mode: true`) in the
  /// directory and in every country read.
  bool testMode = false;

  /// Never answer the directory read (the loading skeleton, held).
  bool holdDirectory = false;

  /// A shop that has sold no airtime yet: no recent recipients.
  bool noRecents = false;

  /// What performing a sale's provider lines answers, call after call (the
  /// last answer repeats). Empty answers every call with nothing to perform.
  List<Result<List<IntegrationChargeResult>>> chargeAnswers = const [];

  /// Holds every charge call until this completes, for a test or a screenshot
  /// of the till while a provider is being asked.
  Future<void>? chargeGate;
  int chargeCalls = 0;

  int directoryReads = 0;
  final Map<String, int> countryReads = {};
  final List<({String country, String phone})> detections = [];
  final List<ServiceQuoteRequest> quotes = [];
  int recentReads = 0;

  @override
  Future<Result<List<IntegrationChargeResult>>> charge({
    int? orderId,
    int? fulfillmentId,
  }) async {
    final index = chargeCalls < chargeAnswers.length
        ? chargeCalls
        : chargeAnswers.length - 1;
    chargeCalls++;
    await chargeGate;
    return index < 0 ? const Ok([]) : chargeAnswers[index];
  }

  @override
  Future<Result<VoucherMenu>> loadVoucherMenu() async {
    final menu = this.menu;
    return menu == null ? super.loadVoucherMenu() : Ok(menu);
  }

  @override
  Future<Result<ServicesDirectory>> loadServicesDirectory() async {
    directoryReads++;
    if (holdDirectory) {
      return Completer<Result<ServicesDirectory>>().future;
    }
    await _wait(directoryDelay);
    if (failDirectory) {
      return Error(Exception('offline (preview)'));
    }
    return Ok(directory ?? servicesPreviewDirectory(testMode: testMode));
  }

  @override
  Future<Result<ServiceCountryDetail>> loadServiceCountry(String code) async {
    final key = code.toUpperCase();
    countryReads.update(key, (reads) => reads + 1, ifAbsent: () => 1);
    await _wait(countryDelay);
    if (failCountries.contains(key)) {
      return Error(Exception('offline (preview)'));
    }
    try {
      return Ok(servicesPreviewCountry(key, testMode: testMode));
    } on StateError {
      return Error(Exception('no such country (preview)'));
    }
  }

  @override
  Future<Result<OperatorDetection>> detectServiceOperator({
    required String country,
    required String phone,
  }) async {
    detections.add((country: country, phone: phone));
    await _wait(detectDelay);
    if (failDetect) {
      return Error(Exception('relay unreachable (preview)'));
    }
    return Ok(_detect(country.toUpperCase(), phone));
  }

  @override
  Future<Result<ServiceQuoteOutcome>> quoteService(
    ServiceQuoteRequest request,
  ) async {
    quotes.add(request);
    await _wait(quoteDelay);
    if (failQuote) {
      return Error(Exception('relay unreachable (preview)'));
    }
    final refusal = refuseQuote;
    if (refusal != null) {
      return Ok(
        ServiceQuoteOutcome.refused(ServiceQuoteRefusal(errorCode: refusal)),
      );
    }
    return Ok(_quote(request));
  }

  @override
  Future<Result<List<RecentRecipient>>> loadServiceRecents(
    ServiceKind kind,
  ) async {
    recentReads++;
    if (kind != ServiceKind.airtime || noRecents) {
      return const Ok([]);
    }
    return Ok([
      for (final row in servicesPreviewRecentsJson())
        RecentRecipient.fromJson(row),
    ]);
  }

  Future<void> _wait(Duration delay) =>
      delay > Duration.zero ? Future<void>.delayed(delay) : Future.value();

  // --- detection ---------------------------------------------------------------

  OperatorDetection _detect(String country, String phone) {
    final detail = servicesPreviewCountry(country);
    final national = _nationalOf(detail.country, phone);
    if (national.endsWith('8888')) {
      // A number the relay says is not a number in this country.
      return const OperatorDetection(
        detected: false,
        reason: ServiceRefusalCode.invalidPhone,
      );
    }
    if (national.endsWith('0000') || detail.operators.isEmpty) {
      return const OperatorDetection(
        detected: false,
        reason: ServiceRefusalCode.notDetected,
      );
    }
    if (national.endsWith('9999')) {
      return const OperatorDetection(
        detected: false,
        reason: ServiceRefusalCode.unavailable,
      );
    }
    final id = _operatorIdFor(country, national, detail.operators);
    final operator = id == null ? null : detail.operator(id);
    if (operator == null) {
      return const OperatorDetection(
        detected: false,
        reason: ServiceRefusalCode.notDetected,
      );
    }
    return OperatorDetection(
      detected: true,
      operator: operator,
      phone: ServicePhone(
        e164: '+${detail.country.primaryDial}$national',
        national: national,
        country: country,
      ),
    );
  }

  /// The number without a calling code or a trunk zero in front.
  static String _nationalOf(ServiceCountry country, String phone) {
    var digits = digitsOnly(phone);
    for (final dial in country.dial) {
      if (digits.startsWith(dial) && digits.length - dial.length >= 7) {
        digits = digits.substring(dial.length);
        break;
      }
    }
    if (digits.startsWith('0') && digits.length - 1 >= 6) {
      digits = digits.substring(1);
    }
    return digits;
  }

  static int? _operatorIdFor(
    String country,
    String national,
    List<AirtimeOperator> operators,
  ) {
    String prefix(int length) =>
        national.length >= length ? national.substring(0, length) : national;
    switch (country) {
      case 'ML':
        return switch (prefix(1)) {
          '7' => 289,
          '6' => 290,
          '9' || '8' => 291,
          _ => 289,
        };
      case 'NE':
        return switch (prefix(1)) {
          '9' => 301,
          '8' => 302,
          _ => 303,
        };
      case 'NG':
        const mtn = {'803', '806', '810', '813', '814', '816', '903', '703'};
        const airtel = {'802', '808', '812', '701', '902', '708'};
        const glo = {'805', '807', '705', '815', '905'};
        const nine = {'809', '817', '818', '909'};
        final three = prefix(3);
        if (mtn.contains(three)) return 310;
        if (airtel.contains(three)) return 311;
        if (glo.contains(three)) return 312;
        if (nine.contains(three)) return 313;
        return null;
      case 'EG':
        return switch (prefix(2)) {
          '10' => 320,
          '12' => 321,
          '11' => 322,
          '15' => 323,
          _ => null,
        };
    }
    final sum = national.codeUnits.fold<int>(0, (a, b) => a + b);
    return operators[sum % operators.length].id;
  }

  // --- quotes ------------------------------------------------------------------

  ServiceQuoteOutcome _quote(ServiceQuoteRequest request) {
    final detail = servicesPreviewCountry(request.country);
    return request.kind == ServiceKind.airtime
        ? _quoteAirtime(request, detail)
        : _quoteBill(request, detail);
  }

  static ServiceQuoteOutcome _refused(
    String code, {
    double? min,
    double? max,
    String reason = '',
  }) => ServiceQuoteOutcome.refused(
    ServiceQuoteRefusal(errorCode: code, min: min, max: max, reason: reason),
  );

  ServiceQuoteOutcome _quoteAirtime(
    ServiceQuoteRequest request,
    ServiceCountryDetail detail,
  ) {
    final operator = detail.operator(request.operatorId ?? 0);
    if (operator == null) {
      return _refused(ServiceRefusalCode.unknownOperator);
    }
    final amount = double.tryParse(request.amount);
    if (amount == null || amount <= 0) {
      return _refused(ServiceRefusalCode.invalidAmount);
    }
    final national = _nationalOf(detail.country, request.phone ?? '');
    if (national.length < 6) {
      return _refused(ServiceRefusalCode.invalidPhone);
    }
    final listed = operator.amountFor(request.amount);
    if (operator.isFixed && listed == null) {
      return _refused(ServiceRefusalCode.amountNotOffered);
    }
    if (operator.isRange && !operator.accepts(amount)) {
      return _refused(
        ServiceRefusalCode.amountOutOfRange,
        min: operator.min,
        max: operator.max,
      );
    }
    final price =
        quotePrice ??
        listed?.price ??
        servicesPreviewPrice(amount, operator.amountCurrency);
    final received = listed?.received ?? request.amount;
    final currencyName = detail.country.currencyLabel;
    final label =
        '${operator.name} · ${formatForeignAmountText(received)} $currencyName';
    final code =
        'air:${operator.id}:${request.amount}:${request.amountCurrency}';
    return ServiceQuoteOutcome.quoted(
      ServiceQuote(
        kind: ServiceKind.airtime,
        optionCode: code,
        optionLabel: label,
        subscriberRef:
            quoteSubscriberRef ?? '+${detail.country.primaryDial}$national',
        price: price,
        receiveAmount: received,
        receiveCurrency: operator.receiveCurrency,
        approximate: operator.approximate,
        quote: 'sealed.$code.${price.toStringAsFixed(2)}',
        serviceVariantId: 9301,
        exceedsFloat: quoteExceedsFloat,
      ),
    );
  }

  ServiceQuoteOutcome _quoteBill(
    ServiceQuoteRequest request,
    ServiceCountryDetail detail,
  ) {
    final biller = detail.biller(request.billerId ?? 0);
    if (biller == null) {
      return _refused(ServiceRefusalCode.unknownBiller);
    }
    final account = (request.account ?? '').trim();
    if (account.length < 4) {
      return _refused(ServiceRefusalCode.invalidAccount);
    }
    if (biller.requiresInvoice && (request.invoiceId ?? '').trim().isEmpty) {
      return _refused(ServiceRefusalCode.invoiceRequired);
    }
    final amount = double.tryParse(request.amount);
    if (amount == null || amount <= 0) {
      return _refused(ServiceRefusalCode.invalidAmount);
    }
    final plan = request.amountId == null
        ? null
        : biller.plan(request.amountId!);
    if (biller.isFixed && plan == null) {
      return _refused(ServiceRefusalCode.amountNotOffered);
    }
    if (biller.isRange && !biller.accepts(amount)) {
      return _refused(
        ServiceRefusalCode.amountOutOfRange,
        min: biller.min,
        max: biller.max,
      );
    }
    final price =
        quotePrice ??
        plan?.price ??
        servicesPreviewPrice(amount, biller.amountCurrency);
    final currencyName = detail.country.currencyLabel;
    final label =
        '${biller.name} · ${formatForeignAmountText(request.amount)} $currencyName';
    final invoice = (request.invoiceId ?? '').trim();
    final code =
        'bill:${biller.id}:${request.amount}:${request.amountCurrency}'
        '${plan != null || invoice.isNotEmpty ? ':${plan?.id ?? ''}' : ''}'
        '${invoice.isNotEmpty ? ':$invoice' : ''}';
    return ServiceQuoteOutcome.quoted(
      ServiceQuote(
        kind: ServiceKind.bill,
        optionCode: code,
        optionLabel: label,
        subscriberRef: account,
        price: price,
        receiveAmount: request.amount,
        receiveCurrency: request.amountCurrency,
        quote: 'sealed.$code.${price.toStringAsFixed(2)}',
        serviceVariantId: 9302,
        exceedsFloat: quoteExceedsFloat,
      ),
    );
  }
}
