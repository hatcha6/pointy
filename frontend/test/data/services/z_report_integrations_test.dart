import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/register_session_summary.dart';
import 'package:pointy_frontend/src/data/services/z_report_integrations.dart';
import 'package:pointy_frontend/src/features/register_sessions/pdf/z_report_pdf.dart';
import 'package:pointy_frontend/src/shared/formatters.dart';

const _hdbox = SessionIntegrationFigures(
  provider: 'hdbox',
  count: 2,
  sold: 110,
  cost: 90,
  margin: 20,
  delivered: SessionIntegrationBucketTotals(count: 1, amount: 30, cost: 25),
  awaiting: SessionIntegrationBucketTotals(count: 1, amount: 80, cost: 65),
  unknown: SessionIntegrationBucketTotals.empty,
  refunded: SessionIntegrationBucketTotals(count: 1, amount: 30, cost: 25),
  refundedAfterDelivery: SessionIntegrationBucketTotals(
    count: 1,
    amount: 0,
    cost: 25,
  ),
);

final _integrations = SessionIntegrations(
  providers: const [_hdbox],
  totals: _hdbox,
  transactions: [
    SessionIntegrationTransaction(
      id: 1,
      provider: 'hdbox',
      orderId: 41,
      receiptNumber: 'R-41',
      soldAt: DateTime.utc(2026, 6, 24, 9, 12),
      subscriberRef: '210906803499',
      optionLabel: 'تجديد شهر',
      price: 30,
      cost: 25,
      status: 'confirmed',
      bucket: SessionIntegrationBucket.delivered,
    ),
    const SessionIntegrationTransaction(
      id: 2,
      provider: 'hdbox',
      orderId: 42,
      price: 80,
      cost: 65,
      status: 'pending',
      bucket: SessionIntegrationBucket.awaiting,
      errorCode: 'insufficient_float',
    ),
    const SessionIntegrationTransaction(
      id: 3,
      provider: 'hdbox',
      orderId: 43,
      price: 30,
      cost: 25,
      refundedAmount: 30,
      status: 'confirmed',
      bucket: SessionIntegrationBucket.refunded,
    ),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('thermal drawer copy', () {
    test('names what each provider took and every way it went astray', () {
      final section = zReportIntegrationThermalSection(_integrations);
      final rows = (section['rows']! as List).cast<Map<String, Object?>>();

      expect(section['title'], 'خدمات الشحن');
      expect(rows.map((row) => row['label']), [
        'HD Box (3)',
        'HD Box — لم يُنفّذ بعد (1)',
        'HD Box — مُرتجع (1)',
        'HD Box — مُرتجع بعد التنفيذ (1)',
      ]);
      expect(rows[0]['value'], formatMoney(110));
      expect(rows[1]['value'], formatMoney(80));
      expect(rows[2]['value'], formatMoney(30));
      // Said, and bold — but its cost is not printed at the counter.
      expect(rows[3]['value'], '');
      expect(rows[3]['emphasize'], isTrue);
      expect((section['total']! as Map)['value'], formatMoney(110));
    });

    test('keeps what the shop pays the provider off the slip', () {
      final section = zReportIntegrationThermalSection(_integrations);
      final values = [
        for (final row in (section['rows']! as List).cast<Map>()) row['value'],
      ];

      expect(values, isNot(contains(formatMoney(90)))); // the provider's share
      expect(values, isNot(contains(formatMoney(20)))); // the shop's margin
      expect(values, isNot(contains(formatMoney(65))));
    });
  });

  test('the A4 copy renders a shift with provider transactions', () async {
    final summary = RegisterSessionSummary.fromJson(const {
      'session': {'id': 7, 'session_number': 'RS-7', 'status': 'closed'},
    });
    final withIntegrations = RegisterSessionSummary(
      sessionId: summary.sessionId,
      sessionNumber: summary.sessionNumber,
      status: summary.status,
      ownerName: summary.ownerName,
      sales: summary.sales,
      refunds: summary.refunds,
      paymentMethods: summary.paymentMethods,
      paymentTotals: summary.paymentTotals,
      categories: summary.categories,
      cash: summary.cash,
      expenses: summary.expenses,
      drawerPurchases: summary.drawerPurchases,
      integrations: _integrations,
    );

    final bytes = await const RegisterZReportPdfService().buildBytes(
      summary: withIntegrations,
    );

    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
  });
}
