import 'dart:convert';

import 'package:archive/archive.dart';

/// Builds a receipt link exactly the way a Moamalat terminal prints one, so a
/// test can produce a slip for any amount, terminal or outcome instead of
/// leaning on one captured sample.
///
/// The payload shape is the terminal's own: `id;type;version;{json}`, deflated,
/// base64'd, and hung off the `query` parameter of the receipt host.
String moamalatReceiptUrl({
  required double amount,
  String terminalId = '0JA8Y13W',
  String receiptId = 'R0001',
  String status = 'تمت العملية بنجاح',
  String maskedPan = '639974*********8809',
  String reference = '615316000050',
}) {
  final payload = [
    receiptId,
    'Purchase',
    '1',
    jsonEncode({
      'Amount': amount.toStringAsFixed(2),
      'TransactionStatus': status,
      'TransactionType': 'Purchase',
      'MerchantName': 'متجر تجريبي',
      'TerminalId': terminalId,
      'CardType': 'Local',
      'PAN': maskedPan,
      'AuthorizationCode': '123456',
      'RRN': reference,
      'STAN': '000123',
      'BATCH': '000001',
      'InvoiceNumber': '000456',
      'DateTime': '2026-09-11 12:00:00',
    }),
  ].join(';');

  final deflated = const ZLibEncoder().encodeBytes(utf8.encode(payload));
  final query = Uri.encodeQueryComponent(base64.encode(deflated));
  return 'https://receipt.moamalat.net:9443/frontTicketDigital/#/digital/'
      'ticket?query=$query';
}
