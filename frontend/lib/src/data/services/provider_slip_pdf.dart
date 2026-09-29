import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../shared/pdf/pdf.dart';
import '../../shared/printing/print_qr_code.dart';
import 'receipt_provider_slips.dart';

/// A provider's answer as a receipt roll prints it: a ruled box of its own
/// between the masthead and the invoice, laid out like the thermal slip
/// (`ProviderSlipRasterizer`) — the logo beside the title and the provider's
/// mark at the far edge, the QR code beside the PIN, short facts two to a
/// line — with every stroke pure black, because a thermal head prints any
/// grey faint or not at all.
///
/// [contentWidth] is the roll's printable width; the fonts are the roll's own
/// detail and emphasis sizes, so a compact roll stays compact around it.
pw.Widget pdfRollProviderSlip(
  ReceiptProviderSlip slip, {
  required double contentWidth,
  required double detailFont,
  required double emphasisFont,
  required bool compact,
}) {
  const ink = PdfColors.black;
  const border = 1.2;
  const padding = 6.0;
  final inner = contentWidth - 2 * (border + padding);
  final detail = pw.TextStyle(fontSize: detailFont, color: ink);
  final gap = compact ? 2.0 : 3.0;
  final logo = pdfLogoProvider(receiptSlipLogoBytes(slip));
  final mark = pdfLogoProvider(receiptSlipProviderLogoBytes(slip));
  final code = _qrCode(slip);
  final place = code == null
      ? null
      : _rollCodePlace(slip, code, inner, compact);
  final printsCode = place != null && place.moduleDots > 0;

  List<pw.Widget> redeemLines(pw.Alignment alignment) => [
    if (slip.pin.isNotEmpty) ...[
      _aligned(pw.Text(receiptPinLabel, style: detail), alignment),
      _unbroken(slip.pin, fontSize: compact ? 14 : 16, alignment: alignment),
    ],
    if (slip.dial.isNotEmpty) ...[
      _aligned(
        pw.Text(
          printsCode ? receiptOrDial : receiptDialToRedeem,
          style: detail,
        ),
        alignment,
      ),
      _unbroken(slip.dial, fontSize: emphasisFont + 2, alignment: alignment),
    ],
  ];

  final body = <pw.Widget>[
    if (slip.notice.isNotEmpty)
      pw.Text(
        slip.notice,
        textAlign: pw.TextAlign.center,
        style: pw.TextStyle(
          fontSize: emphasisFont,
          fontWeight: pw.FontWeight.bold,
          color: ink,
        ),
      ),
  ];
  var facts = slip.rows;
  if (code != null && printsCode) {
    final qr = PointyPdfQrCode(code, moduleDots: place.moduleDots);
    final caption = pw.Text(slip.qrCaption, style: detail);
    if (place.beside) {
      // The short facts the column beside the code has room for: one under
      // a dial string, two without, none in a column too narrow to hold a
      // serial on one line. A long one (a help line) stays below.
      final room =
          inner -
          code.moduleCountWithQuietZone * place.moduleDots * _dotPoints -
          2 * gap;
      final share = room < 88
          ? 0
          : place.besidePin && slip.dial.isNotEmpty
          ? 1
          : 2;
      final column = facts
          .take(share)
          .takeWhile((row) => row.length <= 34)
          .toList();
      facts = facts.skip(column.length).toList();
      if (!place.besidePin) {
        body.addAll(redeemLines(pw.Alignment.center));
        body.add(pw.SizedBox(height: gap));
      }
      body.add(
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.center,
          children: [
            pw.Expanded(
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.stretch,
                children: [
                  if (place.besidePin) ...[
                    ...redeemLines(pw.Alignment.centerRight),
                    pw.SizedBox(height: gap),
                  ],
                  caption,
                  for (final row in column) _fact(row, detail),
                ],
              ),
            ),
            pw.SizedBox(width: 2 * gap),
            qr,
          ],
        ),
      );
    } else {
      body
        ..addAll(redeemLines(pw.Alignment.center))
        ..add(pw.SizedBox(height: gap))
        ..add(pw.Center(child: qr))
        ..add(pw.Center(child: caption));
    }
  } else {
    body.addAll(redeemLines(pw.Alignment.center));
  }
  if (facts.isNotEmpty) {
    body
      ..add(pw.SizedBox(height: gap))
      ..addAll(_pairedFacts(facts, detail, inner));
  }

  return pw.SizedBox(
    // Full width even on a paginated roll, whose pages hand their children a
    // loose one: the box is the roll's width, not its text's.
    width: double.infinity,
    child: pw.Container(
      padding: pw.EdgeInsets.symmetric(
        horizontal: padding,
        vertical: compact ? 4 : padding,
      ),
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: ink, width: border),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          _rollHeader(
            slip,
            logo: logo,
            mark: mark,
            inner: inner,
            titleSize: emphasisFont + 1,
            compact: compact,
          ),
          if (body.isNotEmpty) ...[
            pw.SizedBox(height: gap),
            pw.Container(height: 0.8, color: ink),
            pw.SizedBox(height: gap),
            ...body,
          ],
        ],
      ),
    ),
  );
}

/// The logo at the reading edge, the title beside it, a card's provider's
/// mark at the far edge; the title centred when there is no logo.
pw.Widget _rollHeader(
  ReceiptProviderSlip slip, {
  required pw.ImageProvider? logo,
  required pw.ImageProvider? mark,
  required double inner,
  required double titleSize,
  required bool compact,
}) {
  final title = pw.Text(
    slip.title,
    textAlign: logo == null ? pw.TextAlign.center : pw.TextAlign.right,
    style: pw.TextStyle(
      fontSize: titleSize,
      fontWeight: pw.FontWeight.bold,
      color: PdfColors.black,
    ),
  );
  return pw.Row(
    crossAxisAlignment: pw.CrossAxisAlignment.center,
    children: [
      if (logo != null) ...[
        // 9 mm, as the thermal slip prints it (7 mm compact).
        _slipLogo(logo, maxHeight: compact ? 20 : 25.5, maxWidth: inner * 0.4),
        pw.SizedBox(width: 6),
      ],
      pw.Expanded(child: title),
      if (mark != null) ...[
        pw.SizedBox(width: 6),
        _slipLogo(mark, maxHeight: compact ? 11.5 : 14, maxWidth: inner * 0.22),
      ],
    ],
  );
}

/// Where a roll slip's code goes, and at how many dots a module.
class _RollCodePlace {
  const _RollCodePlace(
    this.moduleDots, {
    required this.beside,
    required this.besidePin,
  });

  /// 0 when the code does not fit the roll at all.
  final int moduleDots;

  /// Something sits beside the code; else it is alone, centred.
  final bool beside;

  /// The PIN and dial string sit beside it; else they run across the top.
  final bool besidePin;
}

/// The thermal slip's rule, in points: the code beside the PIN while the PIN
/// keeps a readable size in what is left; else the PIN across the top and
/// the code beside the facts; else the code alone under the PIN.
_RollCodePlace _rollCodePlace(
  ReceiptProviderSlip slip,
  PrintQrCode code,
  double inner,
  bool compact,
) {
  const dot = _dotPoints;
  final modules = code.moduleCountWithQuietZone;
  int? largest;
  for (var dots = compact ? 7 : 8; dots >= 5; dots--) {
    final side = modules * dots * dot;
    if (side > inner * 0.52) {
      continue;
    }
    largest ??= dots;
    final room = inner - side - 6;
    // 30 and 22 printer dots: the smallest the thermal slip prints either.
    if (_fits(slip.pin, 30 * dot, room) && _fits(slip.dial, 22 * dot, room)) {
      return _RollCodePlace(dots, beside: true, besidePin: true);
    }
  }
  if (largest != null) {
    return _RollCodePlace(largest, beside: true, besidePin: false);
  }
  final dots = (inner / dot).floor() ~/ modules;
  return _RollCodePlace(
    dots < 4 ? 0 : (dots > (compact ? 5 : 6) ? (compact ? 5 : 6) : dots),
    beside: false,
    besidePin: false,
  );
}

/// A thermal printer's dot (203 dpi) in points.
const double _dotPoints = PdfPageFormat.inch / 203;

/// Whether a PIN or dial string fits [room] points at [size]: its digits run
/// about 0.62 em apiece in the roll's bold face.
bool _fits(String text, double size, double room) =>
    text.length * 0.62 * size <= room;

/// A provider's answer as the A4 invoice prints it: a strip under the title,
/// three columns side by side so a page with a card or two on it still fits
/// its invoice — what was sold and its PIN on the reading side, the card's
/// details beside them, and its QR code at the far edge. The brand's logo
/// opens it, the provider's mark under it.
pw.Widget pdfPageProviderSlip(ReceiptProviderSlip slip) {
  const ink = PointyPdfPalette.ink;
  const detail = pw.TextStyle(fontSize: 9.5, color: ink);
  const muted = pw.TextStyle(fontSize: 8.5, color: PointyPdfPalette.muted);
  final code = _qrCode(slip);
  final logo = pdfLogoProvider(receiptSlipLogoBytes(slip));
  final mark = pdfLogoProvider(receiptSlipProviderLogoBytes(slip));
  final sold = pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Text(
        slip.title,
        style: pw.TextStyle(
          fontSize: 12.5,
          fontWeight: pw.FontWeight.bold,
          color: ink,
        ),
      ),
      if (slip.notice.isNotEmpty) ...[
        pw.SizedBox(height: 3),
        pw.Text(
          slip.notice,
          style: pw.TextStyle(
            fontSize: 11,
            fontWeight: pw.FontWeight.bold,
            color: ink,
          ),
        ),
      ],
      if (slip.pin.isNotEmpty) ...[
        pw.SizedBox(height: 3),
        pw.Text(receiptPinLabel, style: muted),
        // Scaled down rather than wrapped, as on the roll: a PIN broken over
        // two lines is a PIN typed wrong.
        pw.FittedBox(
          fit: pw.BoxFit.scaleDown,
          child: pw.Text(
            slip.pin,
            textDirection: pw.TextDirection.ltr,
            style: pw.TextStyle(
              fontSize: 19,
              fontWeight: pw.FontWeight.bold,
              color: ink,
            ),
          ),
        ),
      ],
      if (slip.dial.isNotEmpty) ...[
        pw.SizedBox(height: 2),
        // Two texts, never one: an Arabic label and a dial string in a
        // single run would let bidi move the `*`s and `#` around.
        pw.Row(
          mainAxisSize: pw.MainAxisSize.min,
          children: [
            pw.Text(
              code == null ? receiptDialToRedeem : receiptOrDial,
              style: detail,
            ),
            pw.SizedBox(width: 5),
            pw.Text(
              slip.dial,
              textDirection: pw.TextDirection.ltr,
              style: pw.TextStyle(
                fontSize: 12,
                fontWeight: pw.FontWeight.bold,
                color: ink,
              ),
            ),
          ],
        ),
      ],
    ],
  );
  // Short facts two to a line, as a top-up's are; a long one (a provider's
  // help line) keeps a line to itself.
  final paired =
      slip.rows.length > 2 && slip.rows.every((row) => row.length <= 34);
  pw.Widget fact(String row) => pw.Padding(
    padding: const pw.EdgeInsets.symmetric(vertical: 1),
    child: _fact(row, detail),
  );
  return pw.Container(
    padding: const pw.EdgeInsets.symmetric(horizontal: 12, vertical: 7),
    decoration: pw.BoxDecoration(
      border: pw.Border.all(color: ink, width: 1.2),
      borderRadius: const pw.BorderRadius.all(pw.Radius.circular(8)),
    ),
    child: pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.center,
      children: [
        // The brand first, at the reading edge, the way the card is known;
        // the provider it came from under it, smaller.
        if (logo != null) ...[
          pw.Column(
            mainAxisSize: pw.MainAxisSize.min,
            children: [
              _slipLogo(logo, maxHeight: 44, maxWidth: 72),
              if (mark != null) ...[
                pw.SizedBox(height: 4),
                _slipLogo(mark, maxHeight: 14, maxWidth: 48),
              ],
            ],
          ),
          pw.SizedBox(width: 12),
        ],
        // The logo's room comes out of the card's details, not its PIN: the
        // PIN keeps the width it had at full size. A top-up has no PIN, and
        // its facts take the room.
        pw.Expanded(
          flex: slip.pin.isEmpty ? 2 : (logo == null ? 1 : 3),
          child: sold,
        ),
        if (slip.rows.isNotEmpty) ...[
          pw.SizedBox(width: 14),
          pw.Expanded(
            flex: slip.pin.isEmpty ? 4 : (logo == null ? 1 : 2),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                if (!paired)
                  for (final row in slip.rows) fact(row)
                else
                  for (var i = 0; i < slip.rows.length; i += 2)
                    pw.Row(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Expanded(child: fact(slip.rows[i])),
                        pw.SizedBox(width: 10),
                        pw.Expanded(
                          child: i + 1 < slip.rows.length
                              ? fact(slip.rows[i + 1])
                              : pw.SizedBox(),
                        ),
                      ],
                    ),
              ],
            ),
          ),
        ],
        if (code != null) ...[
          pw.SizedBox(width: 14),
          pw.Column(
            mainAxisSize: pw.MainAxisSize.min,
            children: [
              // 6 dots (0.75 mm) at 203 dpi: a page goes to an office printer,
              // whose far finer dots need no more to read at a glance.
              PointyPdfQrCode(code, moduleDots: 6),
              pw.SizedBox(
                width: 90,
                child: pw.Text(
                  slip.qrCaption,
                  style: muted,
                  textAlign: pw.TextAlign.center,
                ),
              ),
            ],
          ),
        ],
      ],
    ),
  );
}

PrintQrCode? _qrCode(ReceiptProviderSlip slip) {
  final data = slip.qrData;
  return data == null ? null : PrintQrCode.tryEncode(data);
}

/// Short facts two to a line, the first at the reading edge and the second
/// across from it, as the invoice header pairs its own; a long one alone.
List<pw.Widget> _pairedFacts(
  List<String> rows,
  pw.TextStyle style,
  double inner,
) {
  // About half an em a character in the bold face, Arabic and digits alike.
  final columns = inner / (0.55 * (style.fontSize ?? 8));
  final widgets = <pw.Widget>[];
  var i = 0;
  while (i < rows.length) {
    if (i + 1 < rows.length &&
        rows[i].length + rows[i + 1].length + 4 <= columns) {
      widgets.add(
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [_fact(rows[i], style), _fact(rows[i + 1], style)],
        ),
      );
      i += 2;
      continue;
    }
    widgets.add(_fact(rows[i], style));
    i++;
  }
  return widgets;
}

/// One fact. A `label: value` whose value is Latin or digits prints as two
/// texts, the value left to right: in one run with the Arabic label, the pdf
/// package's bidi can reverse a date or scatter a serial's punctuation. The
/// value moves under its label when the two do not fit side by side.
pw.Widget _fact(String row, pw.TextStyle style) {
  final colon = row.indexOf(': ');
  final value = colon < 0 ? '' : row.substring(colon + 2);
  if (value.isEmpty || !_latin.hasMatch(value)) {
    return pw.Text(row, style: style);
  }
  return pw.Wrap(
    spacing: 3,
    children: [
      pw.Text(row.substring(0, colon + 1), style: style),
      // Shrunk rather than broken: a serial split over two lines is a
      // serial read wrong.
      pw.FittedBox(
        fit: pw.BoxFit.scaleDown,
        child: pw.Text(
          value,
          textDirection: pw.TextDirection.ltr,
          style: style,
        ),
      ),
    ],
  );
}

final RegExp _latin = RegExp(r'^[\x20-\x7E]+$');

/// A brand logo fitted into [maxWidth] × [maxHeight], its proportions kept:
/// a square mark fills the height, a long wordmark the width.
pw.Widget _slipLogo(
  pw.ImageProvider logo, {
  required double maxHeight,
  required double maxWidth,
}) {
  return pw.ConstrainedBox(
    constraints: pw.BoxConstraints(maxWidth: maxWidth, maxHeight: maxHeight),
    child: pw.Image(logo, fit: pw.BoxFit.contain),
  );
}

pw.Widget _aligned(pw.Widget child, pw.Alignment alignment) =>
    pw.Align(alignment: alignment, child: child);

/// A PIN or a dial string: on one line, scaled down rather than wrapped when
/// it is wider than its room — a PIN broken over two lines is a PIN typed
/// wrong. Always left to right: in the roll's RTL the `*` and `#` of a dial
/// string would otherwise be moved to the wrong end.
pw.Widget _unbroken(
  String text, {
  required double fontSize,
  required pw.Alignment alignment,
}) {
  return pw.Align(
    alignment: alignment,
    child: pw.FittedBox(
      fit: pw.BoxFit.scaleDown,
      child: pw.Text(
        text,
        textDirection: pw.TextDirection.ltr,
        style: pw.TextStyle(
          fontSize: fontSize,
          fontWeight: pw.FontWeight.bold,
          color: PdfColors.black,
        ),
      ),
    ),
  );
}
