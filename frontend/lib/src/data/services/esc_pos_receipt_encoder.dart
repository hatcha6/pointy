import 'dart:convert';

import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import '../../shared/branding.dart';
import '../models/print_job.dart';
import '../models/printer_config.dart';

/// Sendable bundle for the ESC/POS isolate: payload + endpoint are plain data,
/// and the capability profile is loaded on the caller isolate and passed across.
class _EscPosEncodeRequest {
  const _EscPosEncodeRequest({
    required this.payload,
    required this.endpoint,
    required this.profile,
  });

  final Map<String, Object?> payload;
  final PrinterEndpoint endpoint;
  final CapabilityProfile profile;
}

/// Top-level isolate entry point. The encoder is stateless, so a const instance
/// runs the synchronous encode off the UI thread.
List<int> _encodeEscPosResolved(_EscPosEncodeRequest request) {
  return const EscPosReceiptEncoder()._encodeWithProfile(request);
}

/// Decoded + downscaled shop/station logos keyed by their base64 source, so a
/// busy printer doesn't re-decode the same image for every ticket.
final Map<String, img.Image?> _logoRasterCache = {};

/// The currency symbol the current receipt renders. Set per-encode from the
/// payload so it works inside the print isolate, where the main isolate's
/// configured currency global isn't visible.
String _receiptCurrencySymbol = 'د.ل';

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
      'shop': {'name': 'نقطة البيع'},
      'order': {
        'receipt_number': 'اختبار',
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

  Future<List<int>> encodeKitchenTest(PrinterEndpoint endpoint) async {
    final payload = <String, Object?>{
      'kind': 'kitchen',
      'station': {'name': 'الشواية'},
      'order': {
        'receipt_number': 'اختبار',
        'created_at': DateTime.now().toIso8601String(),
        'document_title': 'تذكرة المطبخ',
        'lines': [
          {
            'name': 'برجر',
            'quantity': 2,
            'notes': 'بدون بصل',
            'option_values': [
              {'option_name': 'الحجم', 'value_name': 'كبير'},
            ],
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
    final profile = await _loadProfile(endpoint);
    final request = _EscPosEncodeRequest(
      payload: payload,
      endpoint: endpoint,
      profile: profile,
    );
    // Encoding (text layout, QR generation, and logo raster) is heavy and fully
    // synchronous; run it in a background isolate so a checkout never blocks the
    // UI. The web target has no isolates, so it runs inline.
    if (kIsWeb) {
      return _encodeWithProfile(request);
    }
    return compute(_encodeEscPosResolved, request);
  }

  /// Synchronous encode against an already-loaded [CapabilityProfile]. Public so
  /// the isolate entry point can reach it; call [encodePayload] instead.
  List<int> _encodeWithProfile(_EscPosEncodeRequest request) {
    final payload = request.payload;
    final endpoint = request.endpoint;
    final generator = Generator(
      _paperSize(endpoint.paperWidthMm),
      request.profile,
    );
    final codeTable = endpoint.codeTable.trim().isEmpty
        ? 'CP864'
        : endpoint.codeTable.trim();
    if (_string(payload['kind']) == 'kitchen') {
      return _encodeKitchenTicket(
        payload: payload,
        endpoint: endpoint,
        generator: generator,
        codeTable: codeTable,
      );
    }
    final order = _map(payload['order']);
    final shop = _map(payload['shop']);
    _receiptCurrencySymbol = _string(shop['currency_symbol'], fallback: 'د.ل');
    final receiptNumber = _string(order['receipt_number'], fallback: '-');
    final documentTitle = _string(order['document_title'], fallback: 'إيصال');
    final totalLabel = _string(order['total_label'], fallback: 'الإجمالي');
    final createdAt = _formatDateTime(order['created_at']);
    final lines = _list(order['lines']);
    final publicInvoiceUrl = _string(order['public_invoice_url']);

    final bytes = <int>[];
    bytes.addAll(generator.reset());
    bytes.addAll(_logoRaster(generator, shop['logo_bytes']));
    bytes.addAll(
      _text(
        generator,
        _string(shop['name'], fallback: 'نقطة البيع'),
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
        '$documentTitle: $receiptNumber',
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
      final name = _string(
        line['product_name'],
        fallback: _string(line['name'], fallback: 'منتج'),
      );
      final quantity = _string(line['quantity'], fallback: '1');
      final unitLabel = _string(line['unit_label'], fallback: '');
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
      // "2 صندوق × 12.000 = 24.000" — the unit makes pack sales unambiguous.
      final quantityLabel = unitLabel.isEmpty
          ? quantity
          : '$quantity $unitLabel';
      final lineDetails =
          '$quantityLabel × ${_money(line['unit_price'])} = ${_money(line['line_total'])}';
      for (final wrappedDetail in _wrap(
        lineDetails,
        _charsPerLine(endpoint.paperWidthMm),
      )) {
        bytes.addAll(
          _text(
            generator,
            wrappedDetail,
            styles: PosStyles(align: PosAlign.right, codeTable: codeTable),
          ),
        );
      }
    }

    bytes.addAll(generator.hr());
    bytes.addAll(
      _text(
        generator,
        '$totalLabel: ${_money(order['total'])}',
        styles: PosStyles(
          align: PosAlign.right,
          bold: true,
          height: PosTextSize.size2,
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

    if (publicInvoiceUrl.isNotEmpty) {
      bytes.addAll(generator.feed(1));
      bytes.addAll(generator.hr());
      bytes.addAll(
        _text(
          generator,
          'امسح الرمز لعرض الفاتورة',
          styles: PosStyles(align: PosAlign.center, codeTable: codeTable),
        ),
      );
      bytes.addAll(
        generator.qrcode(
          publicInvoiceUrl,
          align: PosAlign.center,
          size: _qrSize(endpoint.paperWidthMm),
          cor: QRCorrection.M,
        ),
      );
      bytes.addAll(generator.feed(1));
      for (final line in _wrap(
        publicInvoiceUrl,
        _charsPerLine(endpoint.paperWidthMm),
      )) {
        bytes.addAll(
          _text(
            generator,
            line,
            styles: PosStyles(align: PosAlign.center, codeTable: codeTable),
          ),
        );
      }
    }

    bytes.addAll(generator.feed(1));
    bytes.addAll(
      _text(
        generator,
        pointyPrintCreditLine,
        styles: PosStyles(align: PosAlign.center, codeTable: codeTable),
      ),
    );

    bytes.addAll(generator.feed(endpoint.feedLines.clamp(0, 12)));
    switch (endpoint.cutMode) {
      case ReceiptCutMode.partial:
        bytes.addAll(generator.cut(mode: PosCutMode.partial));
      case ReceiptCutMode.full:
        bytes.addAll(generator.cut(mode: PosCutMode.full));
      case ReceiptCutMode.none:
        // Printer has no cutter: feed enough paper to tear by hand.
        bytes.addAll(generator.feed(2));
    }
    return bytes;
  }

  /// Renders a kitchen chit: what to cook, never what to charge. Big, bold
  /// item lines with options and the free-text note; no prices, totals, QR,
  /// logo or footer. Reuses the receipt encoder's Arabic/CP864 text + wrapping.
  List<int> _encodeKitchenTicket({
    required Map<String, Object?> payload,
    required PrinterEndpoint endpoint,
    required Generator generator,
    required String codeTable,
  }) {
    final order = _map(payload['order']);
    final station = _map(payload['station']);
    final width = _charsPerLine(endpoint.paperWidthMm);
    final documentTitle = _string(
      order['document_title'],
      fallback: 'تذكرة المطبخ',
    );
    final stationName = _string(station['name']);
    final receiptNumber = _string(order['receipt_number'], fallback: '-');
    final createdAt = _formatDateTime(order['created_at']);
    final customerName = _string(order['customer_name']);
    final lines = _list(order['lines']);

    final bytes = <int>[];
    bytes.addAll(generator.reset());

    // Title + station: big and bold so the line reads it across the pass.
    bytes.addAll(
      _text(
        generator,
        documentTitle,
        styles: PosStyles(
          align: PosAlign.center,
          bold: true,
          height: PosTextSize.size2,
          width: PosTextSize.size2,
          codeTable: codeTable,
        ),
      ),
    );
    if (stationName.isNotEmpty) {
      bytes.addAll(
        _text(
          generator,
          stationName,
          styles: PosStyles(
            align: PosAlign.center,
            bold: true,
            height: PosTextSize.size2,
            codeTable: codeTable,
          ),
        ),
      );
    }

    bytes.addAll(generator.hr());
    bytes.addAll(
      _text(
        generator,
        receiptNumber,
        styles: PosStyles(
          align: PosAlign.right,
          bold: true,
          height: PosTextSize.size2,
          codeTable: codeTable,
        ),
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
    if (customerName.isNotEmpty) {
      for (final wrapped in _wrap(customerName, width)) {
        bytes.addAll(
          _text(
            generator,
            wrapped,
            styles: PosStyles(align: PosAlign.right, codeTable: codeTable),
          ),
        );
      }
    }
    bytes.addAll(generator.hr());

    // One block per made-to-order line: quantity × name (large/bold), then any
    // variant options, then the free-text note (emphasized).
    for (final rawLine in lines) {
      final line = _map(rawLine);
      final name = _string(
        line['name'],
        fallback: _string(line['parent_product_name'], fallback: 'منتج'),
      );
      final quantity = _string(line['quantity'], fallback: '1');
      for (final wrapped in _wrap('$quantity × $name', width)) {
        bytes.addAll(
          _text(
            generator,
            wrapped,
            styles: PosStyles(
              align: PosAlign.right,
              bold: true,
              height: PosTextSize.size2,
              codeTable: codeTable,
            ),
          ),
        );
      }
      for (final rawOption in _list(line['option_values'])) {
        final option = _map(rawOption);
        final optionName = _string(option['option_name']);
        final valueName = _string(option['value_name']);
        final label = optionName.isEmpty
            ? valueName
            : '$optionName: $valueName';
        if (label.isEmpty) {
          continue;
        }
        for (final wrapped in _wrap('- $label', width)) {
          bytes.addAll(
            _text(
              generator,
              wrapped,
              styles: PosStyles(align: PosAlign.right, codeTable: codeTable),
            ),
          );
        }
      }
      final note = _string(line['notes']);
      if (note.isNotEmpty) {
        for (final wrapped in _wrap('** $note', width)) {
          bytes.addAll(
            _text(
              generator,
              wrapped,
              styles: PosStyles(
                align: PosAlign.right,
                bold: true,
                height: PosTextSize.size2,
                codeTable: codeTable,
              ),
            ),
          );
        }
      }
      bytes.addAll(generator.hr());
    }

    bytes.addAll(generator.feed(endpoint.feedLines.clamp(0, 12)));
    switch (endpoint.cutMode) {
      case ReceiptCutMode.partial:
        bytes.addAll(generator.cut(mode: PosCutMode.partial));
      case ReceiptCutMode.full:
        bytes.addAll(generator.cut(mode: PosCutMode.full));
      case ReceiptCutMode.none:
        bytes.addAll(generator.feed(2));
    }
    return bytes;
  }

  Future<CapabilityProfile> _loadProfile(PrinterEndpoint endpoint) async {
    final name = endpoint.capabilityProfile.trim();
    if (name.isEmpty || name == 'default') {
      return CapabilityProfile.load();
    }
    try {
      return await CapabilityProfile.load(name: name);
    } on Object {
      // Unknown profile names fall back to the generic profile instead of
      // failing the print job.
      return CapabilityProfile.load();
    }
  }

  /// Prints the shop logo as a raster image when the payload carries
  /// `shop.logo_bytes` (base64). Raster images work on effectively every
  /// ESC/POS printer, regardless of code page support.
  List<int> _logoRaster(Generator generator, Object? logoBytes) {
    final encoded = logoBytes?.toString() ?? '';
    if (encoded.isEmpty) {
      return const [];
    }
    try {
      final img.Image? image;
      if (_logoRasterCache.containsKey(encoded)) {
        image = _logoRasterCache[encoded];
      } else {
        final decoded = img.decodeImage(base64Decode(encoded));
        image = decoded == null
            ? null
            : (decoded.width > 384
                  ? img.copyResize(decoded, width: 384)
                  : decoded);
        _logoRasterCache[encoded] = image;
      }
      if (image == null) {
        return const [];
      }
      return [
        ...generator.imageRaster(image, align: PosAlign.center),
        ...generator.feed(1),
      ];
    } on Object {
      return const [];
    }
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

  QRSize _qrSize(int paperWidthMm) {
    if (paperWidthMm <= 58) {
      return QRSize.size4;
    }
    return QRSize.size5;
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
    final fallback = _string(value, fallback: '0.00');
    return fallback.contains(_receiptCurrencySymbol)
        ? fallback
        : '$fallback $_receiptCurrencySymbol';
  }
  return '${number.toStringAsFixed(2)} $_receiptCurrencySymbol';
}

String _formatDateTime(Object? value) {
  final raw = value?.toString().trim() ?? '';
  if (raw.isEmpty) {
    return '';
  }
  final parsed = DateTime.tryParse(raw);
  if (parsed == null) {
    return raw;
  }
  final local = parsed.toLocal();
  return '${local.year}/${_two(local.month)}/${_two(local.day)} '
      '${_two(local.hour)}:${_two(local.minute)}';
}

String _two(int value) => value.toString().padLeft(2, '0');
