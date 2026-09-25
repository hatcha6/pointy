import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../../data/models/register_session_summary.dart';
import '../../../data/models/shop_settings.dart';
import '../../../data/repositories/printing_repository.dart';
import '../../../data/services/z_report_integrations.dart';
import '../../../shared/branding_assets.dart';
import '../../../shared/date_formatters.dart';
import '../../../shared/formatters.dart';
import '../../../shared/pdf/pdf.dart';

/// Builds and delivers the A4 PDF Z-Report for a register session — the
/// archive/share counterpart to the thermal drawer copy
/// (`PrintingRepository.printRegisterZReport`). Same numbers, richer layout:
/// the payment-method and category breakdowns become full tables.
///
/// Rendered on the calling isolate (the report is small and triggered
/// explicitly, never during checkout) so [formatMoney] uses the app's
/// configured currency symbol. RTL + currency safety comes from the shared
/// toolkit ([PointyPdfFieldRow]/[PointyPdfTable]); never force LTR or the
/// Arabic currency mangles.
class RegisterZReportPdfService {
  const RegisterZReportPdfService({
    this.fontLoader = const PointyPdfFontLoader(),
    this.brandLogoLoader = const PointyBrandLogoLoader(),
  });

  final PointyPdfFontLoader fontLoader;
  final PointyBrandLogoLoader brandLogoLoader;

  Future<Uint8List> buildBytes({
    required RegisterSessionSummary summary,
    ShopSettings? shopSettings,
    Uint8List? shopLogoBytes,
  }) async {
    final fonts = await fontLoader.load();
    final brandLogoBytes = await brandLogoLoader.load();
    final document = _buildDocument(
      summary: summary,
      shopSettings: shopSettings,
      shopLogoBytes: shopLogoBytes,
      brandLogoBytes: brandLogoBytes,
      fonts: fonts,
    );
    return document.save();
  }

  /// Prints on the device's documents printer when [printingRepository] is
  /// given and one is set; otherwise opens the system print dialog (any
  /// A4/office printer, or save-as-PDF).
  Future<bool> printZReport({
    required RegisterSessionSummary summary,
    ShopSettings? shopSettings,
    Uint8List? shopLogoBytes,
    PrintingRepository? printingRepository,
  }) async {
    final bytes = await buildBytes(
      summary: summary,
      shopSettings: shopSettings,
      shopLogoBytes: shopLogoBytes,
    );
    if (printingRepository != null) {
      return printingRepository.printDocumentPdf(
        jobName: _fileName(summary),
        usePrinterSettings: true,
        onLayout: (_) async => bytes,
      );
    }
    return Printing.layoutPdf(
      name: _fileName(summary),
      format: PdfPageFormat.a4,
      usePrinterSettings: true,
      onLayout: (_) async => bytes,
    );
  }

  /// Hands the PDF to the OS share sheet (email/save/AirDrop, download on web).
  Future<bool> shareZReport({
    required RegisterSessionSummary summary,
    ShopSettings? shopSettings,
    Uint8List? shopLogoBytes,
  }) async {
    final bytes = await buildBytes(
      summary: summary,
      shopSettings: shopSettings,
      shopLogoBytes: shopLogoBytes,
    );
    return Printing.sharePdf(bytes: bytes, filename: _fileName(summary));
  }

  String _fileName(RegisterSessionSummary summary) =>
      'z-report-${summary.sessionNumber}.pdf';

  pw.Document _buildDocument({
    required RegisterSessionSummary summary,
    required ShopSettings? shopSettings,
    required Uint8List? shopLogoBytes,
    required Uint8List? brandLogoBytes,
    required PointyPdfFonts fonts,
  }) {
    final shopName = (shopSettings?.shopName.trim().isNotEmpty ?? false)
        ? shopSettings!.shopName.trim()
        : 'نقطة البيع';
    final shopFooter = shopSettings?.receiptFooter.trim();

    final pdf = pw.Document();
    pdf.addPage(
      buildPointyPdfMultiPage(
        fonts: fonts,
        header: (context) =>
            _header(shopName: shopName, logoBytes: shopLogoBytes),
        footer: (context) => PointyPdfFooter(
          pageLabel: 'صفحة ${context.pageNumber} / ${context.pagesCount}',
          shopFooter: shopFooter,
          brandLogo: pdfLogoProvider(brandLogoBytes),
        ),
        build: (context) => _body(summary),
      ),
    );
    return pdf;
  }

  pw.Widget _header({required String shopName, required Uint8List? logoBytes}) {
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
            PointyPdfBadge('تقرير إغلاق الوردية (Z)'),
          ],
        ),
        trailing: PointyPdfLogo(logoBytes: logoBytes),
      ),
    );
  }

  List<pw.Widget> _body(RegisterSessionSummary summary) {
    return [
      _sessionMeta(summary),
      pw.SizedBox(height: 16),
      _salesSection(summary),
      pw.SizedBox(height: 16),
      _paymentMethodsSection(summary),
      if (summary.integrations.hasActivity) ...[
        pw.SizedBox(height: 16),
        ..._integrationsSection(summary.integrations),
      ],
      pw.SizedBox(height: 16),
      _categoriesSection(summary),
      pw.SizedBox(height: 16),
      _cashSection(summary),
    ];
  }

  pw.Widget _sessionMeta(RegisterSessionSummary summary) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        PointyPdfFieldRow(label: 'الوردية', value: summary.sessionNumber),
        if (summary.ownerName.trim().isNotEmpty)
          PointyPdfFieldRow(label: 'الكاشير', value: summary.ownerName.trim()),
        if (summary.openedAt != null)
          PointyPdfFieldRow(
            label: 'فُتحت',
            value: formatPdfDateTime(summary.openedAt!),
          ),
        if (summary.closedAt != null)
          PointyPdfFieldRow(
            label: 'أُغلقت',
            value: formatPdfDateTime(summary.closedAt!),
          ),
        PointyPdfFieldRow(
          label: 'الحالة',
          value: summary.status == 'closed' ? 'مغلقة' : 'مفتوحة',
        ),
      ],
    );
  }

  pw.Widget _salesSection(RegisterSessionSummary summary) {
    final sales = summary.sales;
    final refunds = summary.refunds;
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        PointyPdfSectionTitle('ملخص المبيعات'),
        pw.SizedBox(height: 8),
        PointyPdfFieldRow(
          label: 'إجمالي المبيعات',
          value: formatMoney(sales.grossSales),
        ),
        if (sales.discountTotal > 0)
          PointyPdfFieldRow(
            label: 'الخصومات',
            value: formatMoney(sales.discountTotal),
          ),
        if (refunds.refundTotal > 0)
          PointyPdfFieldRow(
            label: 'المرتجعات',
            value: formatMoney(refunds.refundTotal),
          ),
        PointyPdfFieldRow(
          label: 'صافي المبيعات',
          value: formatMoney(sales.netSales),
          strong: true,
        ),
        PointyPdfFieldRow(label: 'عدد الفواتير', value: '${sales.orderCount}'),
        PointyPdfFieldRow(label: 'القطع المباعة', value: sales.itemsSold),
        if (sales.voidCount > 0)
          PointyPdfFieldRow(label: 'فواتير ملغاة', value: '${sales.voidCount}'),
        if (summary.expenses.count > 0)
          PointyPdfFieldRow(
            label: 'مصروفات الوردية',
            value: formatMoney(summary.expenses.total),
          ),
        if (summary.drawerPurchases.count > 0)
          PointyPdfFieldRow(
            label: 'مشتريات من الدرج',
            value: formatMoney(summary.drawerPurchases.total),
          ),
      ],
    );
  }

  pw.Widget _paymentMethodsSection(RegisterSessionSummary summary) {
    final rows = <List<String>>[
      for (final method in summary.paymentMethods)
        [
          _methodLabel(method.method),
          '${method.count}',
          formatMoney(method.gross),
          formatMoney(method.commission),
          formatMoney(method.refund),
          formatMoney(method.net),
        ],
      [
        'الإجمالي',
        '${summary.paymentTotals.count}',
        formatMoney(summary.paymentTotals.gross),
        formatMoney(summary.paymentTotals.commission),
        formatMoney(summary.paymentTotals.refund),
        formatMoney(summary.paymentTotals.net),
      ],
    ];
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        PointyPdfSectionTitle('حسب طريقة الدفع'),
        pw.SizedBox(height: 8),
        PointyPdfTable.invoice(
          columns: const [
            'طريقة الدفع',
            'العدد',
            'المقبوض',
            'العمولة',
            'المرتجع',
            'الصافي',
          ],
          columnFlex: const [1.6, 0.7, 1.1, 1.0, 1.0, 1.1],
          rows: rows,
        ).build(),
      ],
    );
  }

  /// Where the provider money went: each provider's takings split into its
  /// share and the shop's, every way that money went astray, then every
  /// transaction — the archive copy is where a disputed top-up is looked up
  /// months later. Returned as separate widgets so the transaction table can
  /// break across pages.
  List<pw.Widget> _integrationsSection(SessionIntegrations integrations) {
    const labels = ZReportIntegrationLabels.arabic();
    List<String> moneyRow(String name, SessionIntegrationFigures figures) => [
      name,
      '${figures.transactionCount}',
      formatMoney(figures.sold),
      formatMoney(figures.cost),
      formatMoney(figures.margin),
    ];

    // A table rather than "HD Box — لم يُنفّذ بعد (1)" lines: the pdf shaper
    // scrambles a Latin brand and parentheses inside an Arabic label, so each
    // part gets a cell of its own.
    final problems = <List<String>>[
      for (final figures in integrations.providers) ...[
        for (final bucket in const [
          SessionIntegrationBucket.unknown,
          SessionIntegrationBucket.awaiting,
          SessionIntegrationBucket.refunded,
        ])
          if (figures.bucket(bucket).count > 0)
            [
              labels.providerName(figures.provider),
              labels.bucket(bucket),
              '${figures.bucket(bucket).count}',
              formatMoney(figures.bucket(bucket).amount),
            ],
        if (figures.refundedAfterDelivery.count > 0)
          [
            labels.providerName(figures.provider),
            labels.floatLost,
            '${figures.refundedAfterDelivery.count}',
            formatMoney(figures.refundedAfterDelivery.cost),
          ],
      ],
    ];

    return [
      PointyPdfSectionTitle(labels.title),
      pw.SizedBox(height: 8),
      PointyPdfTable.invoice(
        columns: [
          labels.provider,
          labels.transactionCount,
          labels.sold,
          labels.cost,
          labels.margin,
        ],
        columnFlex: const [1.6, 0.9, 1.2, 1.2, 1.1],
        rows: [
          for (final figures in integrations.providers)
            moneyRow(labels.providerName(figures.provider), figures),
          if (integrations.providers.length > 1)
            moneyRow(labels.allProviders, integrations.totals),
        ],
      ).build(),
      if (problems.isNotEmpty) ...[
        pw.SizedBox(height: 8),
        PointyPdfTable.invoice(
          columns: [
            labels.provider,
            labels.status,
            labels.transactionCount,
            labels.amount,
          ],
          columnFlex: const [1.2, 2.6, 0.9, 1.2],
          rows: problems,
        ).build(),
      ],
      pw.SizedBox(height: 8),
      // Each cell holds one direction: the sale's time goes under its receipt
      // number and the provider under the service, on lines of their own.
      PointyPdfTable.invoice(
        dense: true,
        columns: [
          labels.receipt,
          labels.service,
          labels.subscriber,
          labels.price,
          labels.transactionCost,
          labels.status,
        ],
        columnFlex: const [1.2, 1.9, 1.7, 1.45, 1.45, 1.5],
        rows: [
          for (final transaction in integrations.transactions)
            [
              [
                transaction.receiptNumber,
                if (transaction.soldAt != null) formatTime(transaction.soldAt!),
              ].join('\n'),
              [
                if (transaction.optionLabel.isNotEmpty) transaction.optionLabel,
                labels.providerName(transaction.provider),
              ].join('\n'),
              transaction.subscriberRef,
              formatMoney(transaction.price),
              formatMoney(transaction.cost),
              labels.transactionStatus(transaction),
            ],
        ],
      ).build(),
    ];
  }

  pw.Widget _categoriesSection(RegisterSessionSummary summary) {
    final rows = <List<String>>[
      for (final category in summary.categories)
        [
          category.category ?? 'غير مصنف',
          category.quantity,
          formatMoney(category.net),
        ],
    ];
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        PointyPdfSectionTitle('المبيعات حسب الفئة'),
        pw.SizedBox(height: 8),
        PointyPdfTable.invoice(
          columns: const ['الفئة', 'الكمية', 'الصافي'],
          columnFlex: const [2.4, 0.8, 1.1],
          rows: rows,
          emptyValue: 'لا توجد مبيعات',
        ).build(),
      ],
    );
  }

  pw.Widget _cashSection(RegisterSessionSummary summary) {
    final cash = summary.cash;
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        PointyPdfSectionTitle('تسوية النقد'),
        pw.SizedBox(height: 8),
        PointyPdfFieldRow(
          label: 'النقد الافتتاحي',
          value: formatMoney(cash.openingCash),
        ),
        PointyPdfFieldRow(
          label: 'مبيعات نقدية',
          value: formatMoney(cash.cashSalesTotal),
        ),
        if (cash.payInTotal > 0)
          PointyPdfFieldRow(
            label: 'إيداع نقدي',
            value: formatMoney(cash.payInTotal),
          ),
        if (cash.payOutTotal > 0)
          PointyPdfFieldRow(
            label: 'سحب نقدي',
            value: formatMoney(cash.payOutTotal),
          ),
        if (cash.cashRefundTotal > 0)
          PointyPdfFieldRow(
            label: 'مرتجعات نقدية',
            value: formatMoney(cash.cashRefundTotal),
          ),
        PointyPdfFieldRow(
          label: 'النقد المتوقع',
          value: formatMoney(cash.expectedCash),
          strong: true,
        ),
        if (cash.closingCash != null)
          PointyPdfFieldRow(
            label: 'النقد الفعلي',
            value: formatMoney(cash.closingCash!),
          ),
        if (cash.cashVariance != null)
          PointyPdfFieldRow(
            label: 'الفرق',
            value: formatMoney(cash.cashVariance!),
            strong: true,
            highlighted: cash.hasCashVariance,
          ),
      ],
    );
  }

  String _methodLabel(String method) {
    return switch (method) {
      'cash' => 'نقدًا',
      'card' => 'بطاقة',
      'transfer' => 'تحويل',
      'salary_deduction' => 'خصم من الراتب',
      _ => method,
    };
  }
}
