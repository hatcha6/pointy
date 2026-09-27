/// What a receipt prints for a line a provider performed, as its own block.
///
/// A sale with a top-up or a provider's card prints one receipt, after the
/// provider has answered, and each answer prints as a slip of its own at the
/// top of that receipt — above the invoice, so a long basket can never bury
/// the PIN the customer came for. The thermal encoder and the document
/// invoice (A4 and roll) build them here, from the same fields, so the two
/// can never disagree about what the customer was handed.
///
/// The server sends stable keys (`printed.code`, `printed.dial`, …); the
/// Arabic wording lives here, like every other label on a receipt.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../../shared/printing/print_qr_code.dart';

/// Labels the renderers print around a slip's PIN and its dial string.
const String receiptPinLabel = 'الرقم السري';
const String receiptScanToRedeem = 'امسح الرمز بكاميرا الهاتف للشحن';
const String receiptDialToRedeem = 'للشحن اطلب:';
const String receiptOrDial = 'أو اطلب:';

/// One provider answer, ready to print.
class ReceiptProviderSlip {
  const ReceiptProviderSlip({
    required this.title,
    this.notice = '',
    this.pin = '',
    this.dial = '',
    this.qrData,
    this.rows = const [],
    this.logo = '',
  });

  /// What was sold, as the invoice's item list names the line.
  final String title;

  /// The card's brand logo as receipts print it — a base64 PNG, grey on
  /// white, trimmed to its ink — at the head of the slip; empty for a top-up
  /// and a brand without one. See [receiptSlipLogoBytes].
  final String logo;

  /// Set when the provider did not confirm; the slip then prints this and
  /// nothing that could pass for a card someone can use.
  final String notice;

  /// A card's PIN: the line the customer must read at arm's length.
  final String pin;

  /// What to dial to redeem the card, exactly as written, when its operator
  /// redeems by dialling (Almadar's `*112*PIN#`, Libyana's `120PIN`).
  final String dial;

  /// The QR code to print beside the PIN — a `tel:` link to [dial] — or null
  /// when the shop prints none or the card is not dialled.
  final String? qrData;

  /// Everything else, a printed line each: a card's serial and expiry, a
  /// top-up's line, term and reference, the provider's help line.
  final List<String> rows;

  @override
  bool operator ==(Object other) =>
      other is ReceiptProviderSlip &&
      other.title == title &&
      other.notice == notice &&
      other.pin == pin &&
      other.dial == dial &&
      other.qrData == qrData &&
      other.logo == logo &&
      _sameRows(other.rows, rows);

  @override
  int get hashCode =>
      Object.hash(title, notice, pin, dial, qrData, logo, Object.hashAll(rows));

  @override
  String toString() =>
      'ReceiptProviderSlip($title, notice: $notice, pin: $pin, dial: $dial, '
      'qr: $qrData, rows: $rows, logo: ${logo.length} chars)';
}

/// The slip's logo as image bytes, or null when it has none or it is not
/// valid base64. The renderers still decode the picture itself defensively: a
/// logo that cannot be drawn costs the slip its logo, never the receipt.
Uint8List? receiptSlipLogoBytes(ReceiptProviderSlip slip) {
  if (slip.logo.isEmpty) {
    return null;
  }
  try {
    final bytes = base64Decode(slip.logo);
    return bytes.isEmpty ? null : bytes;
  } on FormatException {
    return null;
  }
}

bool _sameRows(List<String> a, List<String> b) {
  if (a.length != b.length) {
    return false;
  }
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
}

/// Slips for the receipt payload's lines (thermal route), in line order.
/// Lines no provider performed have none.
List<ReceiptProviderSlip> receiptProviderSlipsFromPayload(
  Object? lines, {
  required bool printQrCodes,
}) {
  if (lines is! List) {
    return const [];
  }
  final slips = <ReceiptProviderSlip>[];
  for (final line in lines) {
    if (line is! Map) {
      continue;
    }
    final raw = line['integration'];
    if (raw is! Map) {
      continue;
    }
    final printed = raw['printed'];
    final productName = _text(line['product_name']);
    slips.add(
      receiptProviderSlip(
        title: productName.isNotEmpty ? productName : _text(line['name']),
        kind: _text(raw['kind']),
        status: _text(raw['status']),
        subscriberRef: _text(raw['subscriber_ref']),
        reference: _text(raw['reference']),
        months: int.tryParse(_text(raw['months'])) ?? 0,
        printed: {
          if (printed is Map)
            for (final entry in printed.entries)
              entry.key.toString(): _text(entry.value),
        },
        printQrCodes: printQrCodes,
        logo: _text(raw['receipt_logo']),
      ),
    );
  }
  return slips;
}

/// The slip itself. Pure, so both print routes share it.
///
/// Honest about a provider that did not confirm: a card that was never
/// issued says so instead of printing as if it had been, because a receipt
/// that looks complete for a card nobody bought is worse than no receipt.
ReceiptProviderSlip receiptProviderSlip({
  required String title,
  required String kind,
  required String status,
  required Map<String, String> printed,
  String subscriberRef = '',
  String reference = '',
  int months = 0,
  bool printQrCodes = true,
  String logo = '',
}) {
  String field(String key) => (printed[key] ?? '').trim();
  final isVoucher = kind == 'voucher';
  // Only a card has a brand to show; whatever became of it, the slip opens
  // on the logo the customer knows the card by.
  final brandLogo = isVoucher ? logo.trim() : '';

  if (status != 'confirmed') {
    return ReceiptProviderSlip(
      title: title,
      logo: brandLogo,
      notice: switch (status) {
        // Sent, and the answer never came: whoever reads this must not try
        // again — a second attempt may be a second charge.
        'submitted' => 'تنبيه: لم تتأكد العملية بعد — لا تُعِد المحاولة',
        'cancelled' => 'أُلغيت العملية',
        _ => isVoucher ? 'لم يتم إصدار الكرت' : 'لم تتم عملية الشحن',
      },
    );
  }

  if (isVoucher) {
    final pin = field('code');
    // Only a card with a PIN is dialled; the server sends the string, and it
    // is checked again here before a phone is told to call it.
    final dial = pin.isEmpty ? '' : field('dial');
    final qrData = dial.isEmpty ? null : dialQrData(dial);
    return ReceiptProviderSlip(
      title: title,
      logo: brandLogo,
      pin: pin,
      dial: qrData == null ? '' : dial,
      qrData: printQrCodes ? qrData : null,
      rows: [
        if (field('serial').isNotEmpty) 'الرقم التسلسلي: ${field('serial')}',
        if (field('ccv').isNotEmpty) 'CCV: ${field('ccv')}',
        if (field('expiry').isNotEmpty) 'صالح حتى: ${field('expiry')}',
        // The provider's own "how to use it" only where there is no dial
        // string: beside one it is a second, differently worded instruction
        // (Qareeb's Libyana slip even names a different code).
        if (qrData == null && field('instructions').isNotEmpty)
          'طريقة الشحن: ${field('instructions')}',
        if (field('help').isNotEmpty) field('help'),
      ],
    );
  }

  // A top-up of a named line: whose line, what it bought, the provider's own
  // reference — what the provider's support asks for.
  final rows = <String>[];
  final card = field('card_no').isNotEmpty ? field('card_no') : subscriberRef;
  final username = field('username');
  if (username.isNotEmpty) {
    rows.add('المشترك: $username');
  } else if (card.isNotEmpty) {
    rows.add('رقم الكرت: $card');
  }
  if (field('package').isNotEmpty) {
    rows.add('الباقة: ${field('package')}');
  }
  if (field('amount').isNotEmpty) {
    rows.add('قيمة الشحن: ${field('amount')}');
  }
  final termMonths = int.tryParse(field('months')) ?? months;
  if (termMonths > 0) {
    rows.add('المدة: $termMonths شهر');
  }
  final start = field('start_date');
  final end = field('end_date');
  if (start.isNotEmpty && end.isNotEmpty) {
    rows.add('من $start إلى $end');
  } else if (end.isNotEmpty) {
    rows.add('ينتهي: $end');
  }
  if (field('serial').isNotEmpty) {
    rows.add('الرقم التسلسلي: ${field('serial')}');
  } else if (reference.isNotEmpty) {
    rows.add('المرجع: $reference');
  }
  return ReceiptProviderSlip(title: title, rows: rows);
}

/// No bidi isolates anywhere in these strings, deliberately: a thermal
/// printer on an Arabic code page cannot encode them, and a digit run already
/// reads left to right inside an Arabic line.
String _text(Object? value) => value == null ? '' : value.toString().trim();
