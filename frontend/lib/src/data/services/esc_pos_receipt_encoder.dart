import 'dart:convert';

import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';

import '../models/print_job.dart';
import '../models/printer_config.dart';

class EscPosReceiptEncoder {
  const EscPosReceiptEncoder();

  Future<List<int>> encodeJob({
    required PrintJob job,
    required PrinterEndpoint endpoint,
  }) async {
    return encodePayload(payload: job.payload, endpoint: endpoint);
  }

  Future<List<int>> encodeTest(PrinterEndpoint endpoint) async {
    final payload = <String, Object?>{
      'shop': {'name': 'Pointy'},
      'order': {
        'receipt_number': 'TEST',
        'created_at': DateTime.now().toIso8601String(),
        'total': '0.00',
        'lines': [
          {
            'name': 'اختبار الطباعة',
            'quantity': 1,
            'unit_price': '0.00',
            'line_total': '0.00',
          },
        ],
      },
    };
    return encodePayload(payload: payload, endpoint: endpoint);
  }

  Future<List<int>> encodePayload({
    required Map<String, Object?> payload,
    required PrinterEndpoint endpoint,
  }) async {
    final profile = await CapabilityProfile.load();
    final generator = Generator(_paperSize(endpoint.paperWidthMm), profile);
    final codeTable = endpoint.codeTable.trim().isEmpty
        ? 'CP864'
        : endpoint.codeTable.trim();
    final order = _map(payload['order']);
    final shop = _map(payload['shop']);
    final receiptNumber = _string(order['receipt_number'], fallback: '-');
    final createdAt = _string(order['created_at'], fallback: '');
    final lines = _list(order['lines']);

    final bytes = <int>[];
    bytes.addAll(generator.reset());
    bytes.addAll(
      _text(
        generator,
        _string(shop['name'], fallback: 'Pointy'),
        styles: PosStyles(
          align: PosAlign.center,
          bold: true,
          height: PosTextSize.size2,
          width: PosTextSize.size2,
          codeTable: codeTable,
        ),
      ),
    );

    final header = _string(shop['receipt_header']);
    if (header.isNotEmpty) {
      for (final line in _wrap(header, _charsPerLine(endpoint.paperWidthMm))) {
        bytes.addAll(
          _text(
            generator,
            line,
            styles: PosStyles(align: PosAlign.center, codeTable: codeTable),
          ),
        );
      }
    }

    bytes.addAll(generator.hr());
    bytes.addAll(
      _text(
        generator,
        'إيصال: $receiptNumber',
        styles: PosStyles(align: PosAlign.right, codeTable: codeTable),
      ),
    );
    if (createdAt.isNotEmpty) {
      bytes.addAll(
        _text(
          generator,
          createdAt,
          styles: PosStyles(align: PosAlign.right, codeTable: codeTable),
        ),
      );
    }
    bytes.addAll(generator.hr());

    for (final rawLine in lines) {
      final line = _map(rawLine);
      final name = _string(line['name'], fallback: 'منتج');
      final quantity = _string(line['quantity'], fallback: '1');
      final total = _money(line['line_total']);
      for (final wrappedName in _wrap(
        name,
        _charsPerLine(endpoint.paperWidthMm),
      )) {
        bytes.addAll(
          _text(
            generator,
            wrappedName,
            styles: PosStyles(align: PosAlign.right, codeTable: codeTable),
          ),
        );
      }
      bytes.addAll(
        generator.row([
          PosColumn(
            text: total,
            width: 4,
            styles: PosStyles(align: PosAlign.left, codeTable: codeTable),
          ),
          PosColumn(
            text: 'x$quantity',
            width: 2,
            styles: PosStyles(align: PosAlign.center, codeTable: codeTable),
          ),
          PosColumn(
            text: _money(line['unit_price']),
            width: 6,
            styles: PosStyles(align: PosAlign.right, codeTable: codeTable),
          ),
        ]),
      );
    }

    bytes.addAll(generator.hr());
    bytes.addAll(
      _text(
        generator,
        'الإجمالي ${_money(order['total'])}',
        styles: PosStyles(
          align: PosAlign.right,
          bold: true,
          codeTable: codeTable,
        ),
      ),
    );

    final footer = _string(shop['receipt_footer']);
    if (footer.isNotEmpty) {
      bytes.addAll(generator.feed(1));
      for (final line in _wrap(footer, _charsPerLine(endpoint.paperWidthMm))) {
        bytes.addAll(
          _text(
            generator,
            line,
            styles: PosStyles(align: PosAlign.center, codeTable: codeTable),
          ),
        );
      }
    }

    bytes.addAll(generator.feed(2));
    bytes.addAll(generator.cut(mode: PosCutMode.partial));
    return bytes;
  }

  List<int> _text(
    Generator generator,
    String value, {
    required PosStyles styles,
    int linesAfter = 0,
  }) {
    try {
      return generator.text(value, styles: styles, linesAfter: linesAfter);
    } on ArgumentError {
      return [
        ...generator.setStyles(styles),
        ...generator.rawBytes(utf8.encode(value)),
        ...generator.emptyLines(linesAfter + 1),
      ];
    }
  }

  PaperSize _paperSize(int paperWidthMm) {
    if (paperWidthMm <= 58) {
      return PaperSize.mm58;
    }
    if (paperWidthMm <= 72) {
      return PaperSize.mm72;
    }
    return PaperSize.mm80;
  }

  int _charsPerLine(int paperWidthMm) {
    if (paperWidthMm <= 58) {
      return 32;
    }
    if (paperWidthMm <= 72) {
      return 42;
    }
    return 48;
  }

  List<String> _wrap(String value, int width) {
    final normalized = value.trim();
    if (normalized.isEmpty || normalized.length <= width) {
      return normalized.isEmpty ? const [] : [normalized];
    }
    final words = normalized.split(RegExp(r'\s+'));
    final lines = <String>[];
    var current = '';
    for (final word in words) {
      final next = current.isEmpty ? word : '$current $word';
      if (next.length > width && current.isNotEmpty) {
        lines.add(current);
        current = word;
      } else {
        current = next;
      }
    }
    if (current.isNotEmpty) {
      lines.add(current);
    }
    return lines;
  }
}

Map<String, Object?> _map(Object? value) {
  if (value is Map<String, Object?>) {
    return value;
  }
  if (value is Map) {
    return value.map((key, value) => MapEntry(key.toString(), value));
  }
  return const {};
}

List<Object?> _list(Object? value) {
  if (value is List<Object?>) {
    return value;
  }
  if (value is List) {
    return value.cast<Object?>();
  }
  return const [];
}

String _string(Object? value, {String fallback = ''}) {
  final stringValue = value?.toString() ?? '';
  return stringValue.isEmpty ? fallback : stringValue;
}

String _money(Object? value) {
  final number = num.tryParse(value?.toString() ?? '');
  if (number == null) {
    return _string(value, fallback: '0.00');
  }
  return number.toStringAsFixed(2);
}
