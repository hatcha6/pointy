import 'dart:convert';

import 'package:archive/archive.dart';

/// Who printed a receipt, and — because the two differ in kind — how much a
/// till can learn from it without a network.
enum CardReceiptProvider {
  /// The whole receipt travels inside the QR. Decoded offline, instantly.
  moamalat,

  /// The QR is an opaque token; the receipt lives on the issuer's server. A
  /// till can recognise one but cannot read a single field off it.
  madfoatech,
}

class CardPaymentReceipt {
  const CardPaymentReceipt({
    required this.sourceUrl,
    required this.receiptId,
    required this.amount,
    required this.amountLabel,
    required this.transactionStatus,
    required this.transactionType,
    required this.merchantName,
    required this.terminalId,
    required this.cardType,
    required this.maskedPan,
    required this.authorizationCode,
    required this.rrn,
    required this.stan,
    required this.batch,
    required this.invoiceNumber,
    required this.transactionDateTime,
    this.provider = CardReceiptProvider.moamalat,
    this.isPending = false,
  });

  /// A receipt the till has recognised but cannot read.
  ///
  /// Everything is blank on purpose. The link carries an opaque token, so any
  /// value here would be invented, and an invented amount is exactly what the
  /// amount check exists to catch. The backend settles it against the issuer
  /// after the sale.
  const CardPaymentReceipt.pending({
    required this.sourceUrl,
    required this.receiptId,
    required this.provider,
  }) : amount = 0,
       amountLabel = '',
       transactionStatus = '',
       transactionType = '',
       merchantName = '',
       terminalId = '',
       cardType = '',
       maskedPan = '',
       authorizationCode = '',
       rrn = '',
       stan = '',
       batch = '',
       invoiceNumber = '',
       transactionDateTime = '',
       isPending = true;

  /// Which acquirer printed this slip.
  final CardReceiptProvider provider;

  /// Whether the receipt still has to be proved against its issuer, so nothing
  /// on it may be treated as fact yet.
  final bool isPending;

  final String sourceUrl;
  final String receiptId;
  final double amount;
  final String amountLabel;
  final String transactionStatus;
  final String transactionType;
  final String merchantName;
  final String terminalId;
  final String cardType;
  final String maskedPan;
  final String authorizationCode;
  final String rrn;
  final String stan;
  final String batch;
  final String invoiceNumber;
  final String transactionDateTime;

  String get reference {
    for (final value in [rrn, stan, authorizationCode, invoiceNumber]) {
      final trimmed = value.trim();
      if (trimmed.isNotEmpty) {
        return trimmed;
      }
    }
    return receiptId;
  }

  bool get isSuccessful {
    final normalized = transactionStatus.trim().toLowerCase();
    return normalized.contains('بنجاح') ||
        normalized.contains('success') ||
        normalized.contains('approved');
  }

  /// Whether this receipt can be checked against a payment amount at all.
  ///
  /// False for a pending receipt: it has no amount, and treating "unknown" as
  /// "fine" is how an unchecked slip comes to stand for a payment it never
  /// covered.
  bool get canProveAmount => !isPending;

  bool amountMatches(double expected) {
    if (!canProveAmount) {
      return false;
    }
    return _minorUnits(amount) == _minorUnits(expected);
  }

  static int _minorUnits(double value) => (value * 100).round();
}

class CardPaymentReceiptException implements Exception {
  const CardPaymentReceiptException(this.code, {this.receipt});

  final CardPaymentReceiptErrorCode code;

  /// The decoded receipt, when the payload itself was readable and it was a
  /// check *against the payment* that failed (wrong amount, unknown terminal).
  /// The message shown to the cashier quotes its values, so it has to travel
  /// with the failure rather than be re-parsed by whoever catches it.
  final CardPaymentReceipt? receipt;
}

enum CardPaymentReceiptErrorCode {
  invalidUrl,
  missingQuery,
  decodeFailed,
  invalidPayload,
  invalidAmount,
  unsuccessfulTransaction,
  missingReference,

  /// The receipt is genuine but proves a different amount than this payment.
  amountMismatch,

  /// The receipt comes from a terminal the shop has not listed as its own.
  terminalNotTrusted,
}

class MoamalatReceiptParser {
  const MoamalatReceiptParser();

  static const receiptHost = 'receipt.moamalat.net';

  /// Whether [url] is a receipt link at all — nothing about whether it is a
  /// *good* one.
  ///
  /// This is the question a till has to answer before it can react to a scan:
  /// a counter is scanned with product barcodes, loyalty cards and the odd
  /// stray QR, and only something addressed to the receipt host is worth
  /// treating — or complaining about — as a card receipt.
  bool handles(String url) {
    final uri = Uri.tryParse(url.trim());
    return uri != null && uri.scheme == 'https' && uri.host == receiptHost;
  }

  CardPaymentReceipt parse(String url) {
    final trimmedUrl = url.trim();
    final uri = Uri.tryParse(trimmedUrl);
    if (uri == null || !handles(trimmedUrl)) {
      throw const CardPaymentReceiptException(
        CardPaymentReceiptErrorCode.invalidUrl,
      );
    }

    final encodedQuery = _receiptQueryParameter(uri);
    final payloadText = _inflatePayload(encodedQuery);
    final parts = payloadText.split(';');
    if (parts.length < 4) {
      throw const CardPaymentReceiptException(
        CardPaymentReceiptErrorCode.invalidPayload,
      );
    }

    final fields = _decodeFields(parts.sublist(3).join(';'));
    final receipt = CardPaymentReceipt(
      sourceUrl: trimmedUrl,
      receiptId: parts[0].trim(),
      amount: _parseAmount(fields['Amount']),
      amountLabel: _stringField(fields, 'Amount'),
      transactionStatus: _stringField(fields, 'TransactionStatus'),
      transactionType: _stringField(fields, 'TransactionType').isNotEmpty
          ? _stringField(fields, 'TransactionType')
          : parts[1].trim(),
      merchantName: _stringField(fields, 'MerchantName'),
      terminalId: _stringField(fields, 'TerminalId'),
      cardType: _stringField(fields, 'CardType'),
      maskedPan: _stringField(fields, 'PAN'),
      authorizationCode: _stringField(fields, 'AuthorizationCode'),
      rrn: _stringField(fields, 'RRN'),
      stan: _stringField(fields, 'STAN'),
      batch: _stringField(fields, 'BATCH'),
      invoiceNumber: _stringField(fields, 'InvoiceNumber'),
      transactionDateTime: _stringField(fields, 'DateTime'),
    );
    if (!receipt.isSuccessful) {
      throw const CardPaymentReceiptException(
        CardPaymentReceiptErrorCode.unsuccessfulTransaction,
      );
    }
    if (receipt.maskedPan.isEmpty || receipt.reference.isEmpty) {
      throw const CardPaymentReceiptException(
        CardPaymentReceiptErrorCode.missingReference,
      );
    }
    return receipt;
  }

  String _receiptQueryParameter(Uri uri) {
    var query = uri.queryParameters['query'];
    if ((query == null || query.isEmpty) && uri.fragment.contains('?')) {
      final fragmentUri = Uri.tryParse(uri.fragment);
      query = fragmentUri?.queryParameters['query'];
    }
    if (query == null || query.trim().isEmpty) {
      throw const CardPaymentReceiptException(
        CardPaymentReceiptErrorCode.missingQuery,
      );
    }
    return query.trim();
  }

  String _inflatePayload(String encodedQuery) {
    var normalized = encodedQuery.replaceAll(' ', '+');
    normalized += ''.padLeft((4 - normalized.length % 4) % 4, '=');
    try {
      final compressed = base64.decode(normalized);
      final inflated = ZLibDecoder().decodeBytes(compressed);
      return utf8.decode(inflated);
    } on Exception {
      throw const CardPaymentReceiptException(
        CardPaymentReceiptErrorCode.decodeFailed,
      );
    }
  }

  Map<String, Object?> _decodeFields(String jsonPayload) {
    try {
      final decoded = jsonDecode(jsonPayload);
      if (decoded is Map<String, Object?>) {
        return decoded;
      }
    } on FormatException {
      // Report a stable domain error below.
    }
    throw const CardPaymentReceiptException(
      CardPaymentReceiptErrorCode.invalidPayload,
    );
  }

  String _stringField(Map<String, Object?> fields, String key) {
    return fields[key]?.toString().trim() ?? '';
  }

  double _parseAmount(Object? value) {
    final match = RegExp(
      r'\d+(?:[\.,]\d+)*',
    ).firstMatch(value?.toString() ?? '');
    if (match == null) {
      throw const CardPaymentReceiptException(
        CardPaymentReceiptErrorCode.invalidAmount,
      );
    }
    var amountText = match.group(0)!.replaceAll(',', '.');
    final parts = amountText.split('.');
    if (parts.length > 2) {
      amountText = '${parts.sublist(0, parts.length - 1).join()}.${parts.last}';
    }
    final amount = double.tryParse(amountText);
    if (amount == null) {
      throw const CardPaymentReceiptException(
        CardPaymentReceiptErrorCode.invalidAmount,
      );
    }
    return amount;
  }
}

/// Recognises a Madfoatech (مدفوعاتك) receipt link, which is all a till can do
/// with one.
///
/// `https://rms.lpco.ly/RCP/Dwl/<token>` carries 40 bytes of opaque binary and
/// nothing about the payment, so unlike Moamalat there is no payload to decode:
/// the amount lives on the issuer's server and takes a slow round trip to
/// fetch. The till therefore recognises the slip, attaches it, and lets the
/// backend prove it after the sale rather than holding a queue open for it.
class MadfoatechReceiptParser {
  const MadfoatechReceiptParser();

  static const receiptHost = 'rms.lpco.ly';
  static const receiptPathPrefix = '/RCP/Dwl/';

  bool handles(String url) {
    final uri = Uri.tryParse(url.trim());
    return uri != null &&
        uri.scheme == 'https' &&
        uri.host == receiptHost &&
        uri.path.startsWith(receiptPathPrefix);
  }

  CardPaymentReceipt parse(String url) {
    final trimmedUrl = url.trim();
    if (!handles(trimmedUrl)) {
      throw const CardPaymentReceiptException(
        CardPaymentReceiptErrorCode.invalidUrl,
      );
    }
    final token = Uri.parse(
      trimmedUrl,
    ).path.substring(receiptPathPrefix.length).replaceAll('/', '');
    if (token.isEmpty) {
      throw const CardPaymentReceiptException(
        CardPaymentReceiptErrorCode.missingReference,
      );
    }
    return CardPaymentReceipt.pending(
      sourceUrl: trimmedUrl,
      receiptId: token,
      provider: CardReceiptProvider.madfoatech,
    );
  }
}

/// Decides whether a scanned receipt link may stand in for a card payment.
///
/// Both ways of matching a card payment run these same checks: the cashier
/// opening the match dialog, and the payment sheet noticing a receipt scanned
/// straight into it. A receipt the dialog would refuse therefore cannot slip
/// in by being scanned instead — there is one definition of "this receipt
/// proves this payment", not two that can drift apart.
class CardReceiptMatcher {
  const CardReceiptMatcher({
    this.parser = const MoamalatReceiptParser(),
    this.madfoatechParser = const MadfoatechReceiptParser(),
  });

  final MoamalatReceiptParser parser;
  final MadfoatechReceiptParser madfoatechParser;

  /// Whether [value] is a receipt link at all. Anything else a till is scanned
  /// with is none of this matcher's business.
  bool isReceiptLink(String value) =>
      parser.handles(value) || madfoatechParser.handles(value);

  CardPaymentReceipt _parse(String value) {
    if (madfoatechParser.handles(value)) {
      return madfoatechParser.parse(value);
    }
    return parser.parse(value);
  }

  /// The checks that do not depend on a payment line: the payload decodes into
  /// a successful receipt from a terminal the shop owns.
  ///
  /// Split out from [match] because a receipt can arrive *before* the payment
  /// it belongs to exists — the payment sheet accepts one scanned while the
  /// cashier is still setting the tender up, and only then asks which line it
  /// fits.
  CardPaymentReceipt verify(
    String value, {
    required List<String> trustedTerminalIds,
  }) {
    final receipt = _parse(value);
    _requireTrustedTerminal(receipt, trustedTerminalIds);
    return receipt;
  }

  /// [verify], plus the receipt having been rung up for [expectedAmount].
  CardPaymentReceipt match(
    String value, {
    required double expectedAmount,
    required List<String> trustedTerminalIds,
  }) {
    final receipt = _parse(value);
    // A pending receipt has no amount to check and no terminal to trust: both
    // live on the issuer's server. Refusing it here would reject every genuine
    // Madfoatech slip; the backend runs the same two checks once it has the
    // real values, and flags the payment if either fails.
    if (receipt.canProveAmount && !receipt.amountMatches(expectedAmount)) {
      throw CardPaymentReceiptException(
        CardPaymentReceiptErrorCode.amountMismatch,
        receipt: receipt,
      );
    }
    _requireTrustedTerminal(receipt, trustedTerminalIds);
    return receipt;
  }

  /// An empty list means the shop has not named its terminals, so any terminal
  /// passes — the check tightens as the shop configures it, and never turns
  /// into a hard stop for a shop that never did.
  void _requireTrustedTerminal(
    CardPaymentReceipt receipt,
    List<String> trustedTerminalIds,
  ) {
    if (receipt.isPending) {
      // The slip does not say which terminal printed it; only the issuer does.
      return;
    }
    final trusted = trustedTerminalIds
        .map((terminalId) => terminalId.trim().toUpperCase())
        .where((terminalId) => terminalId.isNotEmpty)
        .toSet();
    if (trusted.isEmpty ||
        trusted.contains(receipt.terminalId.trim().toUpperCase())) {
      return;
    }
    throw CardPaymentReceiptException(
      CardPaymentReceiptErrorCode.terminalNotTrusted,
      receipt: receipt,
    );
  }
}
