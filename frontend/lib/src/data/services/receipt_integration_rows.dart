/// What a receipt prints beneath a line a provider performed.
///
/// A sale with a top-up or a provider's card prints one receipt, after the
/// provider has answered, and the answer goes beneath its line: a card's PIN,
/// serial and how to use it; a recharge's card or line, term and serial. The
/// thermal encoder and the document invoice both print it, from the same rows,
/// so the two can never disagree about what the customer was handed.
///
/// The server sends stable keys (`printed.code`, `printed.serial`, …); the
/// Arabic labels live here, like every other label on a receipt.
library;

/// One printed row. [emphasized] is the PIN — the one line the customer has
/// to be able to read at arm's length.
class ReceiptIntegrationRow {
  const ReceiptIntegrationRow(this.text, {this.emphasized = false});

  final String text;
  final bool emphasized;

  @override
  bool operator ==(Object other) =>
      other is ReceiptIntegrationRow &&
      other.text == text &&
      other.emphasized == emphasized;

  @override
  int get hashCode => Object.hash(text, emphasized);

  @override
  String toString() => emphasized ? '**$text**' : text;
}

/// Rows for a receipt payload's `line['integration']` map (thermal route).
List<ReceiptIntegrationRow> receiptIntegrationRowsFromPayload(Object? raw) {
  if (raw is! Map) {
    return const [];
  }
  final printed = raw['printed'];
  return receiptIntegrationRows(
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
  );
}

/// The rows themselves. Pure, so both print routes share them.
///
/// Honest about a provider that did not confirm: a line whose card was never
/// issued says so instead of printing as if it had been, because a receipt
/// that looks complete for a card nobody bought is worse than no receipt.
List<ReceiptIntegrationRow> receiptIntegrationRows({
  required String kind,
  required String status,
  required Map<String, String> printed,
  String subscriberRef = '',
  String reference = '',
  int months = 0,
}) {
  final rows = <ReceiptIntegrationRow>[];
  String field(String key) => (printed[key] ?? '').trim();
  final isVoucher = kind == 'voucher';

  if (status != 'confirmed') {
    rows.add(
      ReceiptIntegrationRow(switch (status) {
        // Sent, and the answer never came: whoever reads this must not
        // try again — a second attempt may be a second charge.
        'submitted' => 'تنبيه: لم تتأكد العملية بعد — لا تُعِد المحاولة',
        'cancelled' => 'أُلغيت العملية',
        _ => isVoucher ? 'لم يتم إصدار الكرت' : 'لم تتم عملية الشحن',
      }),
    );
    return rows;
  }

  if (isVoucher) {
    final code = field('code');
    if (code.isNotEmpty) {
      rows
        ..add(const ReceiptIntegrationRow('الرقم السري:'))
        ..add(ReceiptIntegrationRow(code, emphasized: true));
    }
    final serial = field('serial');
    if (serial.isNotEmpty) {
      rows.add(ReceiptIntegrationRow('الرقم التسلسلي: $serial'));
    }
    final ccv = field('ccv');
    if (ccv.isNotEmpty) {
      rows.add(ReceiptIntegrationRow('CCV: $ccv'));
    }
    final expiry = field('expiry');
    if (expiry.isNotEmpty) {
      rows.add(ReceiptIntegrationRow('صالح حتى: $expiry'));
    }
    final instructions = field('instructions');
    if (instructions.isNotEmpty) {
      rows.add(ReceiptIntegrationRow('طريقة الشحن: $instructions'));
    }
    final help = field('help');
    if (help.isNotEmpty) {
      rows.add(ReceiptIntegrationRow(help));
    }
    return rows;
  }

  // A top-up of a named line: whose line, what it bought, the provider's
  // own reference — what the provider's support asks for.
  final card = field('card_no').isNotEmpty ? field('card_no') : subscriberRef;
  final username = field('username');
  if (username.isNotEmpty) {
    rows.add(ReceiptIntegrationRow('المشترك: $username'));
  } else if (card.isNotEmpty) {
    rows.add(ReceiptIntegrationRow('رقم الكرت: $card'));
  }
  final package = field('package');
  if (package.isNotEmpty) {
    rows.add(ReceiptIntegrationRow('الباقة: $package'));
  }
  final amount = field('amount');
  if (amount.isNotEmpty) {
    rows.add(ReceiptIntegrationRow('قيمة الشحن: $amount'));
  }
  final termMonths = int.tryParse(field('months')) ?? months;
  if (termMonths > 0) {
    rows.add(ReceiptIntegrationRow('المدة: $termMonths شهر'));
  }
  final start = field('start_date');
  final end = field('end_date');
  if (start.isNotEmpty && end.isNotEmpty) {
    rows.add(ReceiptIntegrationRow('من $start إلى $end'));
  } else if (end.isNotEmpty) {
    rows.add(ReceiptIntegrationRow('ينتهي: $end'));
  }
  final serial = field('serial');
  if (serial.isNotEmpty) {
    rows.add(ReceiptIntegrationRow('الرقم التسلسلي: $serial'));
  } else if (reference.isNotEmpty) {
    rows.add(ReceiptIntegrationRow('المرجع: $reference'));
  }
  return rows;
}

/// No bidi isolates anywhere in these rows, deliberately: a thermal printer
/// on an Arabic code page cannot encode them, and a digit run already reads
/// left to right inside an Arabic line.
String _text(Object? value) => value == null ? '' : value.toString().trim();
