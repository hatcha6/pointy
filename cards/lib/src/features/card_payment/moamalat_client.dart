import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// A Moamalat checkout Dafa signed for one bank-card order, as the relay
/// hands it over (`POST /v1/customers/orders/{id}/card`).
@immutable
class CardSession {
  const CardSession({
    required this.mid,
    required this.tid,
    required this.amount,
    required this.merchantReference,
    required this.trxDateTime,
    required this.secureHash,
    required this.test,
  });

  factory CardSession.fromJson(Map<String, dynamic> json) => CardSession(
    mid: '${json['mid'] ?? ''}',
    tid: '${json['tid'] ?? ''}',
    amount: (json['amount'] as num?)?.toInt() ?? 0,
    merchantReference: '${json['merchant_reference'] ?? ''}',
    trxDateTime: '${json['trx_date_time'] ?? ''}',
    secureHash: '${json['secure_hash'] ?? ''}',
    test: json['test'] == true,
  );

  final String mid;
  final String tid;

  /// In dirhams, Moamalat's unit (1 dinar = 1000).
  final int amount;
  final String merchantReference;
  final String trxDateTime;
  final String secureHash;

  /// On Moamalat's test gateway.
  final bool test;

  /// The amount in dinars, the unit Moamalat's checkout calls take.
  num get dinars => amount / 1000;
}

/// The card the customer typed. It lives only in memory, for the length of
/// one payment, and goes only to Moamalat.
@immutable
class CardDetails {
  const CardDetails({
    required this.number,
    required this.expiryMonth,
    required this.expiryYear,
    required this.name,
  });

  /// Digits only.
  final String number;
  final int expiryMonth;

  /// Two digits (27 for 2027).
  final int expiryYear;

  /// As printed on the card. Local cards carry no CVV: the number, the
  /// name and the expiry are all Moamalat asks for.
  final String name;

  String get expiry =>
      '${expiryMonth.toString().padLeft(2, '0')}'
      '${expiryYear.toString().padLeft(2, '0')}';
}

/// Moamalat refused, in its own words. [message] is its code (see
/// [MoamalatClient.messages]); [detail] is the bank's text, when it sent one.
class MoamalatException implements Exception {
  const MoamalatException(this.message, [this.detail = '']);

  /// 0–17, or -1 for an answer that could not be read or a lost connection.
  final int message;
  final String detail;

  bool get isNetwork => message == -1;

  @override
  String toString() => 'MoamalatException($message, $detail)';
}

/// One step of a charge: either a signed receipt, or the bank's 3-D Secure
/// page the payer must answer first (the code their bank texts them).
sealed class ChargeStep {
  const ChargeStep();
}

class ChargeNeedsVerification extends ChargeStep {
  const ChargeNeedsVerification(this.url);

  /// The issuing bank's page. Only the bank may ask for and check its code,
  /// so this is shown as it is, inside the app.
  final Uri url;
}

class ChargeDone extends ChargeStep {
  const ChargeDone(this.receipt);

  /// Moamalat's signed receipt, in the shape of its LightBox's
  /// completeCallback, which is what Dafa's confirm takes.
  final Map<String, String> receipt;
}

/// The two calls behind Moamalat's LightBox, made from the phone
/// (tools/moamalat-capture/PAYFORM_SELF_HOSTED.md §3): open the checkout
/// Dafa signed, then charge the card. Called from the phone, not the relay,
/// so the card number never leaves the customer's hands for ours, and the
/// gateway (reachable from Libya) sees the customer's own connection.
class MoamalatClient {
  MoamalatClient({
    http.Client? client,
    this.timeout = const Duration(seconds: 40),
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final Duration timeout;

  static final Uri _test = Uri.parse('https://tnpg.moamalat.net:6008/api/');
  static final Uri _live = Uri.parse('https://npg.moamalat.net:6008/api/');

  /// Moamalat's `message` codes; 7 is success.
  static const int ok = 7;
  static const int paidOrder = 1;
  static const int alreadySubmitted = 3;
  static const int invalidExpiry = 14;
  static const int orderExpired = 16;

  /// Opens the checkout. Answers the session's bearer token and the
  /// merchant's details the charge repeats.
  Future<MoamalatCheckout> open(CardSession session) async {
    final answer = await _post(session, 'LightboxHostedCheckout', {
      'OrderID': '',
      'MID': session.mid,
      'TID': session.tid,
      'Amount': session.dinars,
      'Referrer': '',
      'PaymentMethodFromLightBox': 2,
      'MerchantReference': session.merchantReference,
      'SecureHashAnonymous': session.secureHash,
      'TrxDateTime': session.trxDateTime,
      'feeAmount': 0,
      'AdditionalCustomerDataReq': {'AdditionalFees': 0},
      'ReturnUrl': '',
    });
    final token = '${answer['token'] ?? ''}';
    final details = answer['orderDetailsModel'];
    if (token.isEmpty || details is! Map<String, dynamic>) {
      throw const MoamalatException(-1, 'no checkout session');
    }
    return MoamalatCheckout(
      session: session,
      token: token,
      merchantName: '${details['merchantName'] ?? ''}',
      currency: (details['currency'] as num?)?.toInt() ?? 434,
    );
  }

  /// Charges the card. With [verification] (the bank's 3-D Secure answer)
  /// it finishes a charge the bank stopped to verify.
  Future<ChargeStep> charge(
    MoamalatCheckout checkout,
    CardDetails card, {
    required Uri returnUrl,
    Map<String, String>? verification,
  }) async {
    final session = checkout.session;
    final answer = await _post(session, 'PayByCard', {
      'CardPaymentModel': {
        'amount': session.dinars,
        'currency': checkout.currency,
        'orderID': null,
        'terminalId': session.tid,
        'merchantId': session.mid,
        'merchantName': checkout.merchantName,
        'merchantReference': session.merchantReference,
        'cardNumber': card.number,
        'expiration': card.expiry,
        'nameOnCard': card.name,
        'cVV': '',
        'isSaveCard': false,
        'isTokenized': false,
        'deviceFingerPrint': jsonEncode(_device()),
        'ReturnURL': returnUrl.toString(),
        'additionalCustomerData': '{}',
        if (verification != null) 'vPCData': jsonEncode(verification),
      },
      'token': checkout.token,
      'amount': session.dinars,
      'customerPaymentOrderFields': const [],
    }, bearer: checkout.token);
    final receipt = answer['receiptModel'];
    if (receipt is Map<String, dynamic> &&
        '${receipt['secureHash'] ?? ''}'.isNotEmpty) {
      return ChargeDone(_completeCallback(receipt));
    }
    final threeDS = answer['threeDSSecureModel'];
    final url = threeDS is Map<String, dynamic>
        ? Uri.tryParse('${threeDS['threeDSURL'] ?? ''}')
        : null;
    if (url != null && url.hasScheme && verification == null) {
      return ChargeNeedsVerification(url);
    }
    throw MoamalatException(
      (answer['message'] as num?)?.toInt() ?? 13,
      '${answer['vpcMessage'] ?? answer['errorMessage'] ?? ''}',
    );
  }

  /// The receipt under the names Moamalat's LightBox hands its page, which
  /// Dafa's confirm reads.
  static Map<String, String> _completeCallback(Map<String, dynamic> receipt) {
    String field(String name) => '${receipt[name] ?? ''}';
    return {
      'TxnDate': field('txnDate'),
      'SystemReference': field('systemReference'),
      'NetworkReference': field('networkReference'),
      'MerchantReference': field('merchantReference'),
      'Amount': field('amount'),
      'Currency': field('currency'),
      'PaidThrough': field('paidThrough'),
      'PayerAccount': field('payerAccount'),
      'PayerName': field('payerName'),
      'ProviderSchemeName': field('providerSchemeName'),
      'SecureHash': field('secureHash'),
    };
  }

  /// What the checkout page reports about its browser, for the gateway's
  /// risk checks; advisory, best effort.
  static Map<String, Object> _device() {
    final now = DateTime.now();
    return {
      'timeOpened': now.toIso8601String(),
      'timezone': -now.timeZoneOffset.inMinutes ~/ 60,
      'browserName': 'DaftarCards',
      'browserLanguage': 'ar',
      'browserOnline': true,
      'browserPlatform': kIsWeb ? 'web' : Platform.operatingSystem,
      'javaEnabled': false,
      'dataCookiesEnabled': false,
    };
  }

  Future<Map<String, dynamic>> _post(
    CardSession session,
    String endpoint,
    Map<String, Object?> body, {
    String? bearer,
  }) async {
    final url = (session.test ? _test : _live).resolve(endpoint);
    final http.Response response;
    try {
      response = await _client
          .post(
            url,
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
              if (bearer != null) 'Authorization': 'Bearer $bearer',
            },
            body: jsonEncode(body),
          )
          .timeout(timeout);
    } on Object {
      throw const MoamalatException(-1);
    }
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      decoded = null;
    }
    if (decoded is! Map<String, dynamic>) {
      throw MoamalatException(-1, 'HTTP ${response.statusCode}');
    }
    final message = (decoded['message'] as num?)?.toInt();
    if (response.statusCode >= 400 || (message != null && message != ok)) {
      throw MoamalatException(
        message ?? -1,
        '${decoded['vpcMessage'] ?? decoded['errorMessage'] ?? ''}',
      );
    }
    return decoded;
  }
}

/// An open checkout: what [MoamalatClient.charge] needs.
@immutable
class MoamalatCheckout {
  const MoamalatCheckout({
    required this.session,
    required this.token,
    required this.merchantName,
    required this.currency,
  });

  final CardSession session;
  final String token;
  final String merchantName;
  final int currency;
}
