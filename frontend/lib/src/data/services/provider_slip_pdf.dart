import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../shared/pdf/pdf.dart';
import '../../shared/printing/print_qr_code.dart';
import 'receipt_provider_slips.dart';

/// A provider's answer as a receipt roll prints it: a ruled box of its own
/// between the masthead and the invoice, every stroke pure black because a
/// thermal head prints any grey faint or not at all.
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
  final detail = pw.TextStyle(fontSize: detailFont, color: ink);
  final gap = pw.SizedBox(height: compact ? 2 : 3);
  final code = _qrCode(slip);
  final moduleDots = code == null
      ? 0
      : pdfQrModuleDots(code, contentWidth - 2 * (border + padding));
  final showsQr = code != null && moduleDots > 0;
  final logo = pdfLogoProvider(receiptSlipLogoBytes(slip));
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
          if (logo != null) ...[
            pw.Center(
              child: _slipLogo(
                logo,
                // 12 mm, as the thermal slip prints it (9 mm compact), and
                // never wider than most of the box: a long wordmark shrinks.
                maxHeight: compact ? _rollLogoHeightCompact : _rollLogoHeight,
                maxWidth: (contentWidth - 2 * (border + padding)) * 0.6,
              ),
            ),
            pw.SizedBox(height: compact ? 3 : 5),
          ],
          pw.Text(
            slip.title,
            textAlign: pw.TextAlign.center,
            style: pw.TextStyle(
              fontSize: emphasisFont + 1,
              fontWeight: pw.FontWeight.bold,
              color: ink,
            ),
          ),
          if (slip.notice.isNotEmpty) ...[
            gap,
            pw.Text(
              slip.notice,
              textAlign: pw.TextAlign.center,
              style: pw.TextStyle(
                fontSize: emphasisFont,
                fontWeight: pw.FontWeight.bold,
                color: ink,
              ),
            ),
          ],
          if (slip.pin.isNotEmpty) ...[
            gap,
            pw.Text(
              receiptPinLabel,
              textAlign: pw.TextAlign.center,
              style: detail,
            ),
            _unbrokenLine(slip.pin, fontSize: compact ? 14 : 16, color: ink),
          ],
          if (showsQr) ...[
            pw.Center(child: PointyPdfQrCode(code, moduleDots: moduleDots)),
            pw.Text(
              receiptScanToRedeem,
              textAlign: pw.TextAlign.center,
              style: detail,
            ),
          ],
          if (slip.dial.isNotEmpty) ...[
            gap,
            pw.Text(
              showsQr ? receiptOrDial : receiptDialToRedeem,
              textAlign: pw.TextAlign.center,
              style: detail,
            ),
            _unbrokenLine(slip.dial, fontSize: emphasisFont + 2, color: ink),
          ],
          if (slip.rows.isNotEmpty) ...[
            gap,
            for (final row in slip.rows) pw.Text(row, style: detail),
          ],
        ],
      ),
    ),
  );
}

/// A provider's answer as the A4 invoice prints it: a strip under the title,
/// three columns side by side so a page with a card or two on it still fits
/// its invoice — what was sold and its PIN on the reading side, the card's
/// details beside them, and its QR code at the far edge.
pw.Widget pdfPageProviderSlip(ReceiptProviderSlip slip) {
  const ink = PointyPdfPalette.ink;
  const detail = pw.TextStyle(fontSize: 9.5, color: ink);
  const muted = pw.TextStyle(fontSize: 8.5, color: PointyPdfPalette.muted);
  final code = _qrCode(slip);
  final logo = pdfLogoProvider(receiptSlipLogoBytes(slip));
  final sold = pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Text(
        slip.title,
        style: pw.TextStyle(
          fontSize: 13,
          fontWeight: pw.FontWeight.bold,
          color: ink,
        ),
      ),
      if (slip.notice.isNotEmpty) ...[
        pw.SizedBox(height: 4),
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
        pw.SizedBox(height: 5),
        pw.Text(receiptPinLabel, style: muted),
        // Scaled down rather than wrapped, as on the roll: a PIN broken over
        // two lines is a PIN typed wrong.
        pw.FittedBox(
          fit: pw.BoxFit.scaleDown,
          child: pw.Text(
            slip.pin,
            textDirection: pw.TextDirection.ltr,
            style: pw.TextStyle(
              fontSize: 20,
              fontWeight: pw.FontWeight.bold,
              color: ink,
            ),
          ),
        ),
      ],
      if (slip.dial.isNotEmpty) ...[
        pw.SizedBox(height: 3),
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
    child: pw.Text(row, style: detail),
  );
  return pw.Container(
    padding: const pw.EdgeInsets.symmetric(horizontal: 12, vertical: 9),
    decoration: pw.BoxDecoration(
      border: pw.Border.all(color: ink, width: 1.2),
      borderRadius: const pw.BorderRadius.all(pw.Radius.circular(8)),
    ),
    child: pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.center,
      children: [
        // The brand first, at the reading edge, the way the card is known.
        if (logo != null) ...[
          _slipLogo(logo, maxHeight: 44, maxWidth: 72),
          pw.SizedBox(width: 12),
        ],
        // The logo's room comes out of the card's details, not its PIN: the
        // PIN keeps the width it had at full size.
        pw.Expanded(flex: logo == null ? 1 : 3, child: sold),
        if (slip.rows.isNotEmpty) ...[
          pw.SizedBox(width: 14),
          pw.Expanded(
            flex: logo == null ? 1 : 2,
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
              pw.Text(
                receiptScanToRedeem,
                style: muted,
                textAlign: pw.TextAlign.center,
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

/// The roll slip's logo height: 12 mm, what the thermal slip prints.
const double _rollLogoHeight = 34;
const double _rollLogoHeightCompact = 26;

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

/// A PIN or a dial string: centred, on one line, scaled down rather than
/// wrapped when it is wider than the slip — a PIN broken over two lines is a
/// PIN typed wrong. Always left to right: in the roll's RTL the `*` and `#`
/// of a dial string would otherwise be moved to the wrong end.
pw.Widget _unbrokenLine(
  String text, {
  required double fontSize,
  required PdfColor color,
}) {
  return pw.Center(
    child: pw.FittedBox(
      fit: pw.BoxFit.scaleDown,
      child: pw.Text(
        text,
        textDirection: pw.TextDirection.ltr,
        style: pw.TextStyle(
          fontSize: fontSize,
          fontWeight: pw.FontWeight.bold,
          color: color,
        ),
      ),
    ),
  );
}
