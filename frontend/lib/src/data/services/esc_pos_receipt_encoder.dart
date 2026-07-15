import 'dart:convert';

import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import '../../shared/branding.dart';
import '../../shared/branding_assets.dart';
import '../models/print_job.dart';
import '../models/printer_config.dart';

/// Sendable bundle for the ESC/POS isolate: payload + endpoint are plain data,
/// the capability profile is loaded on the caller isolate and passed across, and
/// the brand-mark bytes for the closing tagline (a bundled asset) are loaded up
/// front too so the isolate never touches the asset bundle.
class _EscPosEncodeRequest {
  const _EscPosEncodeRequest({
    required this.payload,
    required this.endpoint,
    required this.profile,
    this.brandLogoBytes,
  });

  final Map<String, Object?> payload;
  final PrinterEndpoint endpoint;
  final CapabilityProfile profile;
  final Uint8List? brandLogoBytes;
}

/// Top-level isolate entry point. The encoder is stateless, so a const instance
/// runs the synchronous encode off the UI thread.
List<int> _encodeEscPosResolved(_EscPosEncodeRequest request) {
  return const EscPosReceiptEncoder()._encodeWithProfile(request);
}

/// Decoded + downscaled shop/station logos keyed by their base64 source, so a
/// busy printer doesn't re-decode the same image for every ticket.
final Map<String, img.Image?> _logoRasterCache = {};

/// Decoded + downscaled brand marks for the closing tagline, keyed by source
/// length + density, so the fixed brand asset is rasterised once per size.
final Map<String, img.Image?> _brandRasterCache = {};

/// The currency symbol the current receipt renders. Set per-encode from the
/// payload so it works inside the print isolate, where the main isolate's
/// configured currency global isn't visible.
String _receiptCurrencySymbol = 'د.ل';

class EscPosReceiptEncoder {
  const EscPosReceiptEncoder({
    this.brandLogoLoader = const PointyBrandLogoLoader(),
  });

  /// Loads the brand mark rendered in the closing tagline. Injectable so tests
  /// can stub it; the default reads the bundled asset (best-effort).
  final PointyBrandLogoLoader brandLogoLoader;

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
    // Loaded on the caller isolate (the asset bundle isn't available inside a
    // `compute` isolate); best-effort, so a missing asset just drops the mark.
    final brandLogoBytes = await brandLogoLoader.load();
    final request = _EscPosEncodeRequest(
      payload: payload,
      endpoint: endpoint,
      profile: profile,
      brandLogoBytes: brandLogoBytes,
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
    // A compact/dense receipt: tighter line spacing, single-height headings, and
    // trimmed blank feeds so the slip uses less paper. Kitchen chits stay large
    // on purpose (the line reads them across the pass), so they ignore this.
    final dense = endpoint.compactReceipt;
    final brandLogoBytes = request.brandLogoBytes;
    if (_string(payload['kind']) == 'kitchen') {
      return _encodeKitchenTicket(
        payload: payload,
        endpoint: endpoint,
        generator: generator,
        codeTable: codeTable,
      );
    }
    if (_string(payload['kind']) == 'payment_receipt') {
      return _encodePaymentReceipt(
        payload: payload,
        endpoint: endpoint,
        generator: generator,
        codeTable: codeTable,
        dense: dense,
        brandLogoBytes: brandLogoBytes,
      );
    }
    if (_string(payload['kind']) == 'z_report') {
      return _encodeZReport(
        payload: payload,
        endpoint: endpoint,
        generator: generator,
        codeTable: codeTable,
        dense: dense,
        brandLogoBytes: brandLogoBytes,
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
    bytes.addAll(
      _shopMasthead(
        generator,
        shop,
        codeTable,
        _charsPerLine(endpoint.paperWidthMm),
        dense: dense,
      ),
    );

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
          height: _emphasisHeight(dense),
          codeTable: codeTable,
        ),
      ),
    );

    // Money status block: what this slip means. A quotation owes nothing, so it
    // reads "عرض سعر" + its validity date; a sale shows paid/partial/unpaid and
    // any remaining balance.
    final saleType = _string(order['sale_type']);
    final isQuotation = saleType == 'quotation';
    final statusText = _saleStatusText(_string(order['payment_status']));
    if (statusText.isNotEmpty) {
      bytes.addAll(
        _text(
          generator,
          'الحالة: $statusText',
          styles: PosStyles(
            align: PosAlign.right,
            bold: true,
            codeTable: codeTable,
          ),
        ),
      );
    }
    if (isQuotation) {
      final validUntil = _formatDateOnly(order['valid_until']);
      if (validUntil.isNotEmpty) {
        bytes.addAll(
          _text(
            generator,
            'صالح حتى: $validUntil',
            styles: PosStyles(align: PosAlign.right, codeTable: codeTable),
          ),
        );
      }
    } else {
      final balanceDue = num.tryParse(_string(order['balance_due'])) ?? 0;
      if (balanceDue > 0) {
        bytes.addAll(
          _text(
            generator,
            'المتبقّي: ${_money(order['balance_due'])}',
            styles: PosStyles(
              align: PosAlign.right,
              bold: true,
              codeTable: codeTable,
            ),
          ),
        );
      }
    }

    bytes.addAll(
      _shopFooter(
        generator,
        shop,
        codeTable,
        _charsPerLine(endpoint.paperWidthMm),
        dense: dense,
      ),
    );

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

    bytes.addAll(
      _brandTagline(generator, codeTable, brandLogoBytes, dense: dense),
    );

    bytes.addAll(_finishTicket(generator, endpoint));
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

    bytes.addAll(_finishTicket(generator, endpoint));
    return bytes;
  }

  /// Renders a proof-of-payment slip (سند قبض / سند صرف) for a single payment:
  /// shop masthead, the document title, the party, the related invoice/PO, and
  /// the payment particulars (amount/method/commission/reference/handler and
  /// the running balance). No line items, totals math, or QR. Structurally
  /// modeled on [_encodeKitchenTicket]; reuses the same Arabic/CP864 text path.
  List<int> _encodePaymentReceipt({
    required Map<String, Object?> payload,
    required PrinterEndpoint endpoint,
    required Generator generator,
    required String codeTable,
    bool dense = false,
    Uint8List? brandLogoBytes,
  }) {
    final shop = _map(payload['shop']);
    final proof = _map(payload['proof']);
    _receiptCurrencySymbol = _string(shop['currency_symbol'], fallback: 'د.ل');
    final width = _charsPerLine(endpoint.paperWidthMm);
    final title = _string(proof['title'], fallback: 'سند قبض');
    final reference = _string(proof['reference_number']);
    final createdAt = _formatDateTime(proof['created_at']);

    final bytes = <int>[];
    bytes.addAll(_shopMasthead(generator, shop, codeTable, width, dense: dense));

    bytes.addAll(generator.hr());
    // Document title, big and bold: this slip is a receipt/disbursement.
    bytes.addAll(
      _text(
        generator,
        title,
        styles: PosStyles(
          align: PosAlign.center,
          bold: true,
          height: _emphasisHeight(dense),
          codeTable: codeTable,
        ),
      ),
    );
    if (reference.isNotEmpty) {
      bytes.addAll(
        _text(
          generator,
          reference,
          styles: PosStyles(align: PosAlign.center, codeTable: codeTable),
        ),
      );
    }
    if (createdAt.isNotEmpty) {
      bytes.addAll(
        _text(
          generator,
          createdAt,
          styles: PosStyles(align: PosAlign.center, codeTable: codeTable),
        ),
      );
    }
    bytes.addAll(generator.hr());

    // Party (received-from / paid-to) and the related document, each a labeled
    // line wrapped to the paper width.
    _addPaymentReceiptRow(
      bytes,
      generator,
      codeTable,
      width,
      _string(proof['party_label']),
      _string(proof['party_name']),
    );
    _addPaymentReceiptRow(
      bytes,
      generator,
      codeTable,
      width,
      _string(proof['related_label']),
      _string(proof['related_number']),
    );

    bytes.addAll(generator.hr());

    // The amount stands out — bold and (unless compact) double height.
    final amountLabel = _string(proof['amount_label'], fallback: 'المبلغ');
    bytes.addAll(
      _text(
        generator,
        '$amountLabel: ${_money(proof['amount'])}',
        styles: PosStyles(
          align: PosAlign.right,
          bold: true,
          height: _emphasisHeight(dense),
          codeTable: codeTable,
        ),
      ),
    );
    _addPaymentReceiptRow(
      bytes,
      generator,
      codeTable,
      width,
      _string(proof['method_label']),
      _string(proof['method']),
    );
    final commission = num.tryParse(_string(proof['commission'])) ?? 0;
    if (commission > 0) {
      _addPaymentReceiptRow(
        bytes,
        generator,
        codeTable,
        width,
        _string(proof['commission_label']),
        _money(proof['commission']),
      );
    }
    _addPaymentReceiptRow(
      bytes,
      generator,
      codeTable,
      width,
      _string(proof['reference_label']),
      _string(proof['reference']),
    );
    _addPaymentReceiptRow(
      bytes,
      generator,
      codeTable,
      width,
      _string(proof['handled_label']),
      _string(proof['handled_by']),
    );

    final balanceAfter = _string(proof['balance_after']);
    if (balanceAfter.isNotEmpty) {
      bytes.addAll(generator.hr());
      bytes.addAll(
        _text(
          generator,
          '${_string(proof['balance_label'], fallback: 'الرصيد بعد الدفع')}: '
          '${_money(proof['balance_after'])}',
          styles: PosStyles(
            align: PosAlign.right,
            bold: true,
            codeTable: codeTable,
          ),
        ),
      );
    }

    bytes.addAll(_shopFooter(generator, shop, codeTable, width, dense: dense));

    bytes.addAll(
      _brandTagline(generator, codeTable, brandLogoBytes, dense: dense),
    );

    bytes.addAll(_finishTicket(generator, endpoint));
    return bytes;
  }

  /// Renders an end-of-shift Z-Report: shop masthead, the report title and
  /// session meta, then a series of labeled sections (sales totals, payment
  /// methods, sales by category, cash reconciliation). The values arrive
  /// fully formatted from [PrintingRepository._zReportPayload] (currency symbol
  /// already attached), so this only lays them out — no money math here. Reuses
  /// the same Arabic/CP864 text path as the sale receipt.
  List<int> _encodeZReport({
    required Map<String, Object?> payload,
    required PrinterEndpoint endpoint,
    required Generator generator,
    required String codeTable,
    bool dense = false,
    Uint8List? brandLogoBytes,
  }) {
    final shop = _map(payload['shop']);
    final report = _map(payload['report']);
    _receiptCurrencySymbol = _string(shop['currency_symbol'], fallback: 'د.ل');
    final width = _charsPerLine(endpoint.paperWidthMm);

    final bytes = <int>[];
    bytes.addAll(_shopMasthead(generator, shop, codeTable, width, dense: dense));

    bytes.addAll(generator.hr());
    bytes.addAll(
      _text(
        generator,
        _string(report['title'], fallback: 'تقرير إغلاق الوردية'),
        styles: PosStyles(
          align: PosAlign.center,
          bold: true,
          height: _emphasisHeight(dense),
          codeTable: codeTable,
        ),
      ),
    );
    for (final rawMeta in _list(report['meta'])) {
      final meta = _string(rawMeta);
      if (meta.isEmpty) {
        continue;
      }
      for (final wrapped in _wrap(meta, width)) {
        bytes.addAll(
          _text(
            generator,
            wrapped,
            styles: PosStyles(align: PosAlign.center, codeTable: codeTable),
          ),
        );
      }
    }

    for (final rawSection in _list(report['sections'])) {
      final section = _map(rawSection);
      final rows = _list(section['rows']);
      final total = _map(section['total']);
      final hasTotal = _string(total['label']).isNotEmpty;
      if (rows.isEmpty && !hasTotal) {
        continue;
      }
      bytes.addAll(generator.hr());
      final sectionTitle = _string(section['title']);
      if (sectionTitle.isNotEmpty) {
        bytes.addAll(
          _text(
            generator,
            sectionTitle,
            styles: PosStyles(
              align: PosAlign.right,
              bold: true,
              codeTable: codeTable,
            ),
          ),
        );
      }
      for (final rawRow in rows) {
        final row = _map(rawRow);
        _addReportRow(
          bytes,
          generator,
          codeTable,
          width,
          _string(row['label']),
          _string(row['value']),
          emphasize: row['emphasize'] == true,
        );
      }
      if (hasTotal) {
        _addReportRow(
          bytes,
          generator,
          codeTable,
          width,
          _string(total['label']),
          _string(total['value']),
          emphasize: true,
        );
      }
    }

    bytes.addAll(_shopFooter(generator, shop, codeTable, width, dense: dense));
    bytes.addAll(
      _brandTagline(generator, codeTable, brandLogoBytes, dense: dense),
    );
    bytes.addAll(_finishTicket(generator, endpoint));
    return bytes;
  }

  /// Appends a right-aligned "label: value" line (wrapped to [width]) to a
  /// Z-Report. Either side may be empty (a heading-only or value-only row);
  /// [emphasize] bolds it for totals and the variance.
  void _addReportRow(
    List<int> bytes,
    Generator generator,
    String codeTable,
    int width,
    String label,
    String value, {
    bool emphasize = false,
  }) {
    final trimmedLabel = label.trim();
    final trimmedValue = value.trim();
    if (trimmedLabel.isEmpty && trimmedValue.isEmpty) {
      return;
    }
    final text = trimmedValue.isEmpty
        ? trimmedLabel
        : trimmedLabel.isEmpty
        ? trimmedValue
        : '$trimmedLabel: $trimmedValue';
    for (final wrapped in _wrap(text, width)) {
      bytes.addAll(
        _text(
          generator,
          wrapped,
          styles: PosStyles(
            align: PosAlign.right,
            bold: emphasize,
            codeTable: codeTable,
          ),
        ),
      );
    }
  }

  /// Reset + logo + bold shop name, and (by default) the wrapped `receipt_header`
  /// lines. Shared by the sale receipt and the payment-proof slip so the masthead
  /// is identical and maintained once.
  List<int> _shopMasthead(
    Generator generator,
    Map<String, Object?> shop,
    String codeTable,
    int width, {
    bool includeHeaderLines = true,
    bool dense = false,
  }) {
    final bytes = <int>[];
    bytes.addAll(generator.reset());
    // `reset()` restores the printer's default line spacing; re-tighten it for a
    // compact slip. Placed after every masthead reset so it governs the whole
    // ticket. Safe because dense mode never enlarges a line beyond single height.
    bytes.addAll(_tightLineSpacing(generator, dense));
    bytes.addAll(_logoRaster(generator, shop['logo_bytes']));
    bytes.addAll(
      _text(
        generator,
        _string(shop['name'], fallback: 'نقطة البيع'),
        styles: PosStyles(
          align: PosAlign.center,
          bold: true,
          height: _emphasisHeight(dense),
          width: _emphasisWidth(dense),
          codeTable: codeTable,
        ),
      ),
    );
    if (includeHeaderLines) {
      final header = _string(shop['receipt_header']);
      if (header.isNotEmpty) {
        for (final line in _wrap(header, width)) {
          bytes.addAll(
            _text(
              generator,
              line,
              styles: PosStyles(align: PosAlign.center, codeTable: codeTable),
            ),
          );
        }
      }
    }
    return bytes;
  }

  /// The optional centered `receipt_footer` block. Shared by the sale receipt and
  /// the payment-proof slip.
  List<int> _shopFooter(
    Generator generator,
    Map<String, Object?> shop,
    String codeTable,
    int width, {
    bool dense = false,
  }) {
    final footer = _string(shop['receipt_footer']);
    if (footer.isEmpty) {
      return const [];
    }
    final bytes = <int>[];
    // A compact slip skips the blank separator before the footer message.
    if (!dense) {
      bytes.addAll(generator.feed(1));
    }
    for (final line in _wrap(footer, width)) {
      bytes.addAll(
        _text(
          generator,
          line,
          styles: PosStyles(align: PosAlign.center, codeTable: codeTable),
        ),
      );
    }
    return bytes;
  }

  /// The closing brand stamp: the small "دُوِّنَ في دفتر" tagline. ESC/POS can't
  /// inline an image mid-text, so the mark stacks centered above the line (where
  /// the PDF path renders it inline). Falls back to text alone when the brand
  /// asset is unavailable. Shared across the sale receipt, payment slip and
  /// Z-Report.
  List<int> _brandTagline(
    Generator generator,
    String codeTable,
    Uint8List? brandLogoBytes, {
    bool dense = false,
  }) {
    final bytes = <int>[];
    if (!dense) {
      bytes.addAll(generator.feed(1));
    }
    bytes.addAll(_brandLogoRaster(generator, brandLogoBytes, dense: dense));
    bytes.addAll(
      _text(
        generator,
        pointyPrintTagline,
        styles: PosStyles(align: PosAlign.center, codeTable: codeTable),
      ),
    );
    return bytes;
  }

  /// Reduced ESC/POS line spacing (`ESC 3 n`) for a compact slip, else nothing.
  /// 26/203" ≈ 3.2mm — tight but with a hair of leading; the printer default is
  /// ~30–34 dots. Only emitted in dense mode, where every line is single height.
  List<int> _tightLineSpacing(Generator generator, bool dense) {
    if (!dense) {
      return const [];
    }
    return generator.rawBytes([0x1b, 0x33, 26]);
  }

  /// Enlarged-text height for headings/totals: double height normally, single
  /// height in a compact slip (so the reduced line spacing never overlaps).
  PosTextSize _emphasisHeight(bool dense) =>
      dense ? PosTextSize.size1 : PosTextSize.size2;

  /// Enlarged-text width for the shop name: double width normally, single in a
  /// compact slip.
  PosTextSize _emphasisWidth(bool dense) =>
      dense ? PosTextSize.size1 : PosTextSize.size2;

  /// The small centered brand mark for the closing tagline. Downscaled to a few
  /// dozen dots (smaller still in compact mode) and cached per size, so the fixed
  /// asset rasterises once. Renders nothing when bytes are missing/undecodable.
  List<int> _brandLogoRaster(
    Generator generator,
    Uint8List? bytes, {
    required bool dense,
  }) {
    if (bytes == null || bytes.isEmpty) {
      return const [];
    }
    try {
      final image = _brandRasterFor(bytes, dense: dense);
      if (image == null) {
        return const [];
      }
      return generator.imageRaster(image, align: PosAlign.center);
    } on Object {
      return const [];
    }
  }

  /// Trailing feed + cut sequence, honoring the endpoint's feed lines and cut
  /// mode. Shared by the sale receipt, kitchen ticket, and payment-proof slip.
  List<int> _finishTicket(Generator generator, PrinterEndpoint endpoint) {
    final bytes = <int>[];
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

  /// Appends a "label: value" line (wrapped to [width]) to a payment slip, only
  /// when both the label and value are non-empty.
  void _addPaymentReceiptRow(
    List<int> bytes,
    Generator generator,
    String codeTable,
    int width,
    String label,
    String value,
  ) {
    final trimmedLabel = label.trim();
    final trimmedValue = value.trim();
    if (trimmedLabel.isEmpty || trimmedValue.isEmpty) {
      return;
    }
    for (final wrapped in _wrap('$trimmedLabel: $trimmedValue', width)) {
      bytes.addAll(
        _text(
          generator,
          wrapped,
          styles: PosStyles(align: PosAlign.right, codeTable: codeTable),
        ),
      );
    }
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

/// Decodes + downscales the brand mark for the closing tagline, cached by source
/// length and density. Target ~48 dots dense / ~64 dots normal — a discreet
/// stamp, not a masthead. Returns null when the bytes can't be decoded.
img.Image? _brandRasterFor(Uint8List bytes, {required bool dense}) {
  final key = '${bytes.length}:${dense ? 'd' : 'n'}';
  if (_brandRasterCache.containsKey(key)) {
    return _brandRasterCache[key];
  }
  img.Image? resized;
  try {
    final decoded = img.decodeImage(bytes);
    final target = dense ? 48 : 64;
    if (decoded != null) {
      resized = decoded.width > target
          ? img.copyResize(decoded, width: target)
          : decoded;
    }
  } on Object {
    resized = null;
  }
  _brandRasterCache[key] = resized;
  return resized;
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

/// Date-only formatter for the quotation expiry (`valid_until` is an ISO date,
/// not a timestamp, so we never append a time component).
String _formatDateOnly(Object? value) {
  final raw = value?.toString().trim() ?? '';
  if (raw.isEmpty) {
    return '';
  }
  final parsed = DateTime.tryParse(raw);
  if (parsed == null) {
    return raw;
  }
  return '${parsed.year}/${_two(parsed.month)}/${_two(parsed.day)}';
}

/// Arabic money-status text for a thermal slip, keyed on the server's
/// `payment_status` (`paid` | `partial` | `unpaid` | `quotation`).
String _saleStatusText(String paymentStatus) {
  return switch (paymentStatus) {
    'paid' => 'مدفوعة بالكامل',
    'partial' => 'مدفوعة جزئيًا',
    'unpaid' => 'آجل — غير مدفوعة',
    'quotation' => 'عرض سعر',
    _ => '',
  };
}

String _two(int value) => value.toString().padLeft(2, '0');
