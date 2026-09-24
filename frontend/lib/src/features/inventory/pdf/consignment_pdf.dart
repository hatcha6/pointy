import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../../data/models/consignment.dart';
import '../../../data/models/shop_settings.dart';
import '../../../data/models/stock_unit.dart';
import '../../../data/repositories/printing_repository.dart';
import '../../../shared/branding_assets.dart';
import '../../../shared/pdf/pdf.dart';
import 'consignment_document_content.dart';

/// The two pages a consignment actually turns on: *سند استلام أمانة*, signed
/// when the goods come in, and *سند صرف أمانة*, signed when the money goes out.
///
/// These exist because the agreement stores its liability clause **as it was
/// printed** — copied from the shop's editable sentence at submit and never
/// re-read — and a clause that is stored and never printed is a contract nobody
/// signed. The words on the page are the shop's own; nothing here generates a
/// sentence from an enum.
///
/// What goes on them is decided in [ConsignmentDocumentContent] and rendered
/// here, so there is exactly one answer to "what does this document say" and a
/// test can ask it. RTL and currency safety come from the shared toolkit
/// exactly as they do for the invoice and the Z-Report: never force LTR on a
/// money field, or "د.ل" mangles.
class ConsignmentDocumentPdfService {
  const ConsignmentDocumentPdfService({
    this.fontLoader = const PointyPdfFontLoader(),
    this.brandLogoLoader = const PointyBrandLogoLoader(),
  });

  final PointyPdfFontLoader fontLoader;
  final PointyBrandLogoLoader brandLogoLoader;

  // -- the intake voucher ---------------------------------------------------

  Future<Uint8List> buildVoucherBytes({
    required ConsignmentAgreement agreement,
    List<StockUnit> units = const [],
    ShopSettings? shopSettings,
    Uint8List? shopLogoBytes,
  }) {
    return _build(
      content: buildConsignmentVoucherContent(
        agreement: agreement,
        units: units,
      ),
      shopSettings: shopSettings,
      shopLogoBytes: shopLogoBytes,
      signatures: const ('توقيع المحل', 'توقيع صاحب الأمانة'),
    );
  }

  Future<bool> printVoucher({
    required ConsignmentAgreement agreement,
    List<StockUnit> units = const [],
    ShopSettings? shopSettings,
    Uint8List? shopLogoBytes,
    PrintingRepository? printingRepository,
  }) async {
    final bytes = await buildVoucherBytes(
      agreement: agreement,
      units: units,
      shopSettings: shopSettings,
      shopLogoBytes: shopLogoBytes,
    );
    return _layout(
      'consignment-${agreement.number}.pdf',
      bytes,
      printingRepository,
    );
  }

  // -- the payout receipt ---------------------------------------------------

  Future<Uint8List> buildPayoutBytes({
    required ConsignorPayout payout,
    ShopSettings? shopSettings,
    Uint8List? shopLogoBytes,
  }) {
    return _build(
      content: buildConsignorPayoutContent(payout: payout),
      shopSettings: shopSettings,
      shopLogoBytes: shopLogoBytes,
      signatures: const ('توقيع الكاشير', 'توقيع المستلم'),
    );
  }

  Future<bool> printPayout({
    required ConsignorPayout payout,
    ShopSettings? shopSettings,
    Uint8List? shopLogoBytes,
    PrintingRepository? printingRepository,
  }) async {
    final bytes = await buildPayoutBytes(
      payout: payout,
      shopSettings: shopSettings,
      shopLogoBytes: shopLogoBytes,
    );
    return _layout(
      'consignor-payout-${payout.number}.pdf',
      bytes,
      printingRepository,
    );
  }

  // -- rendering ------------------------------------------------------------

  Future<Uint8List> _build({
    required ConsignmentDocumentContent content,
    required ShopSettings? shopSettings,
    required Uint8List? shopLogoBytes,
    required (String, String) signatures,
  }) async {
    final fonts = await fontLoader.load();
    final brandLogoBytes = await brandLogoLoader.load();
    final pdf = pw.Document();
    pdf.addPage(
      buildPointyPdfMultiPage(
        fonts: fonts,
        header: (context) => _header(
          shopSettings: shopSettings,
          logoBytes: shopLogoBytes,
          content: content,
        ),
        footer: (context) => PointyPdfFooter(
          pageLabel: 'صفحة ${context.pageNumber} / ${context.pagesCount}',
          shopFooter: shopSettings?.receiptFooter.trim(),
          brandLogo: pdfLogoProvider(brandLogoBytes),
        ),
        build: (context) => _body(content, signatures),
      ),
    );
    return pdf.save();
  }

  /// The device's documents printer when one is set, else the system print
  /// dialog.
  Future<bool> _layout(
    String name,
    Uint8List bytes,
    PrintingRepository? printingRepository,
  ) {
    if (printingRepository != null) {
      return printingRepository.printDocumentPdf(
        jobName: name,
        usePrinterSettings: true,
        onLayout: (_) async => bytes,
      );
    }
    return Printing.layoutPdf(
      name: name,
      format: PdfPageFormat.a4,
      usePrinterSettings: true,
      onLayout: (_) async => bytes,
    );
  }

  List<pw.Widget> _body(
    ConsignmentDocumentContent content,
    (String, String) signatures,
  ) {
    return [
      _fields(content.fields),
      pw.SizedBox(height: 14),
      PointyPdfSectionTitle(
        content.total == null ? 'البضاعة المستلمة' : 'مقابل بيع',
      ),
      pw.SizedBox(height: 8),
      PointyPdfTable.invoice(
        columns: content.tableColumns,
        columnFlex: const [3, 2.4, 2.2, 1.6],
        emptyValue: 'لا توجد أصناف على هذا السند.',
        rows: content.tableRows,
      ).build(),
      if (content.termFields.isNotEmpty) ...[
        pw.SizedBox(height: 14),
        PointyPdfSectionTitle('شروط التسوية'),
        pw.SizedBox(height: 8),
        _fields(content.termFields),
      ],
      if (content.total != null) ...[
        pw.SizedBox(height: 14),
        PointyPdfFieldRow(
          label: content.total!.label,
          value: content.total!.value,
          highlighted: true,
        ),
      ],
      if (content.clause.isNotEmpty) ...[
        pw.SizedBox(height: 14),
        _clause(content.clause),
      ],
      if (content.notes.isNotEmpty) ...[
        pw.SizedBox(height: 10),
        PointyPdfFieldRow(label: 'ملاحظات', value: content.notes),
      ],
      pw.SizedBox(height: 20),
      _signatures(signatures),
    ];
  }

  pw.Widget _fields(List<ConsignmentDocumentField> fields) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        for (final field in fields)
          PointyPdfFieldRow(label: field.label, value: field.value),
      ],
    );
  }

  /// The contract line, in the panel that stops it reading as a footnote.
  pw.Widget _clause(String clause) {
    return pw.Container(
      width: double.infinity,
      padding: const pw.EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: const pw.BoxDecoration(
        color: PointyPdfPalette.highlight,
        borderRadius: pw.BorderRadius.all(pw.Radius.circular(6)),
      ),
      child: pw.Text(
        clause,
        style: const pw.TextStyle(color: PointyPdfPalette.ink, fontSize: 11),
        textAlign: pw.TextAlign.right,
      ),
    );
  }

  pw.Widget _header({
    required ShopSettings? shopSettings,
    required Uint8List? logoBytes,
    required ConsignmentDocumentContent content,
  }) {
    final shopName = (shopSettings?.shopName.trim().isNotEmpty ?? false)
        ? shopSettings!.shopName.trim()
        : 'نقطة البيع';
    return pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: 12),
      child: PointyPdfMasthead(
        boxed: true,
        leading: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(
              shopName,
              style: pw.TextStyle(
                fontSize: 16,
                fontWeight: pw.FontWeight.bold,
                color: PointyPdfPalette.ink,
              ),
            ),
            pw.SizedBox(height: 6),
            PointyPdfBadge('${content.badge} — ${content.number}'),
          ],
        ),
        trailing: PointyPdfLogo(logoBytes: logoBytes),
      ),
    );
  }

  /// Both parties sign. The whole reason this is paper and not a screen.
  pw.Widget _signatures((String, String) labels) {
    pw.Widget slot(String label) => pw.Expanded(
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          pw.Text(
            label,
            style: const pw.TextStyle(
              color: PointyPdfPalette.muted,
              fontSize: 10,
            ),
            textAlign: pw.TextAlign.right,
          ),
          pw.SizedBox(height: 28),
          pw.Container(height: 0.8, color: PointyPdfPalette.border),
        ],
      ),
    );

    return pw.Directionality(
      textDirection: pw.TextDirection.rtl,
      child: pw.Row(
        children: [slot(labels.$1), pw.SizedBox(width: 32), slot(labels.$2)],
      ),
    );
  }
}
