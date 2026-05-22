import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/analytics_event.dart';

void main() {
  test('analytics event draft serializes typed values for ingest', () {
    final event = AnalyticsEventDraft.fraudSignal(
      name: 'sale.void.risk',
      riskScore: 150,
      entityType: 'sale_order',
      entityId: '42',
      attributes: const {'reason': 'late_void'},
      metrics: const {'amount': 19.5},
    );

    final json = event.toJson();
    final restored = AnalyticsEventDraft.fromJson(json);

    expect(json['event_type'], 'fraud_signal');
    expect(json['severity'], 'warning');
    expect(json['source'], 'frontend');
    expect(json['risk_score'], 100);
    expect(json['entity_type'], 'sale_order');
    expect(restored.eventType, AnalyticsEventType.fraudSignal);
    expect(restored.metrics['amount'], 19.5);
  });

  test('generated analytics event ids are UUID v4 shaped', () {
    final id = generateAnalyticsEventId();

    expect(
      id,
      matches(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ),
      ),
    );
  });
}
