import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations_ar.dart';
import 'package:pointy_frontend/src/data/models/report_run.dart';
import 'package:pointy_frontend/src/data/models/shop_settings.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/features/reports/pdf/report_document_builder.dart';

void main() {
  final l10n = AppLocalizationsAr();

  test('builds Arabic RTL report labels and localized values', () {
    final document = buildBusinessReportPdfDocument(
      run: _reportRun(
        ReportRunType.salesSummary,
        payload: {
          'period': {'start_date': '2026-05-01', 'end_date': '2026-05-21'},
          'summary': {
            'gross_sales': '120.5',
            'profit_margin_percent': '15',
            'paid_order_count': 3,
          },
          'sections': [
            {
              'key': 'recent_orders',
              'columns': ['receipt_number', 'status', 'total', 'created_at'],
              'rows': [
                {
                  'receipt_number': 'R-1',
                  'status': 'paid',
                  'total': '120.50',
                  'created_at': '2026-05-21T10:30:00Z',
                },
              ],
            },
          ],
        },
      ),
      l10n: l10n,
      currentUser: _manager,
      includeAuditTrail: true,
      includePreparedBy: true,
      shopSettings: _settings,
    );

    expect(document.businessName, 'متجر الربيع');
    expect(document.businessHeader, 'شارع السوق');
    expect(document.businessFooter, 'شكرا لزيارتكم');
    expect(document.metrics.first.label, 'إجمالي المبيعات');
    expect(document.metrics.first.value, '120.50 د.ل');
    expect(document.metrics[1].value, '15.00%');
    expect(document.sections.first.heading, 'آخر الطلبات');
    expect(document.sections.first.tables.single.columns, [
      'رقم الإيصال',
      'الحالة',
      'الإجمالي',
      'تاريخ الإنشاء',
    ]);
    expect(document.sections.first.tables.single.rows.single[1], 'مدفوعة');
    expect(document.sections.first.tables.single.rows.single[2], '120.50 د.ل');
  });

  test('adds useful shop settings to payment reports', () {
    final document = buildBusinessReportPdfDocument(
      run: _reportRun(
        ReportRunType.paymentMethods,
        payload: {
          'summary': {'payment_total': '50.00'},
          'sections': [
            {
              'key': 'payment_methods',
              'columns': ['method', 'total', 'commission', 'count'],
              'rows': [
                {
                  'method': 'card',
                  'total': '50.00',
                  'commission': '0.50',
                  'count': 1,
                },
              ],
            },
          ],
        },
      ),
      l10n: l10n,
      currentUser: _manager,
      includeAuditTrail: false,
      includePreparedBy: false,
      shopSettings: _settings,
    );

    expect(
      document.shopSettingFields.map((field) => field.label),
      containsAll([
        'طرق الدفع المفعلة',
        'إيصال البطاقة مطلوب',
        'عمولة البطاقة',
      ]),
    );
    expect(document.shopSettingFields.first.value, 'نقدًا، بطاقة، تحويل');
    expect(document.sections.first.tables.single.rows.single.first, 'بطاقة');
  });
}

ReportRun _reportRun(
  ReportRunType type, {
  required Map<String, Object?> payload,
}) {
  return ReportRun(
    id: 7,
    reportType: type,
    params: const {},
    outputFormat: ReportOutputFormat.pdf,
    status: ReportRunStatus.success,
    payload: payload,
    rowCount: 1,
    checksum: 'abcdef1234567890',
    createdAt: DateTime(2026, 5, 21, 10, 30),
    completedAt: DateTime(2026, 5, 21, 10, 31),
    requestedByUsername: 'manager',
  );
}

const _manager = PosUser(
  id: 1,
  username: 'manager',
  role: UserRole.manager,
  isActive: true,
);

const _settings = ShopSettings(
  shopName: 'متجر الربيع',
  receiptHeader: 'شارع السوق',
  receiptFooter: 'شكرا لزيارتكم',
  enableOnlineInvoices: false,
  requireOpeningCash: true,
  autoPrintReceipts: false,
  allowOverselling: false,
  preventSellingAtLoss: true,
  lowStockThreshold: 5,
  cashierReturnWindowHours: 48,
  enableCashPayments: true,
  enableCardPayments: true,
  enableTransferPayments: true,
  requireCardPaymentReceipt: true,
  trustedCardTerminalIds: ['T1'],
  cardCommissionPercent: 1,
  transferCommissionPercent: 0,
);
