import 'dart:convert';

import 'package:archive/archive.dart';

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
  });

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

  bool amountMatches(double expected) {
    return _minorUnits(amount) == _minorUnits(expected);
  }

  static int _minorUnits(double value) => (value * 100).round();
}

class CardPaymentReceiptException implements Exception {
  const CardPaymentReceiptException(this.code);

  final CardPaymentReceiptErrorCode code;
}

enum CardPaymentReceiptErrorCode {
  invalidUrl,
  missingQuery,
  decodeFailed,
  invalidPayload,
  invalidAmount,
  unsuccessfulTransaction,
  missingReference,
}

class MoamalatReceiptParser {
  const MoamalatReceiptParser();

  static const receiptHost = 'receipt.moamalat.net';

  CardPaymentReceipt parse(String url) {
    final trimmedUrl = url.trim();
    final uri = Uri.tryParse(trimmedUrl);
    if (uri == null || uri.scheme != 'https' || uri.host != receiptHost) {
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
