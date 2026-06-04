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

  test('frontend interaction event name serializes for ingest', () {
    final event = AnalyticsEventDraft.usage(
      AnalyticsEventName.frontendInteraction,
      severity: AnalyticsEventSeverity.debug,
      attributes: const {'action': 'pointer_up', 'target': 'pointer'},
    );

    final json = event.toJson();
    final restored = AnalyticsEventDraft.fromJson(json);

    expect(json['name'], 'frontend.interaction');
    expect(json['severity'], 'debug');
    expect(restored.name, 'frontend.interaction');
  });

  test('analytics event query serializes robust activity filters', () {
    final query = AnalyticsEventQuery(
      search: 'void',
      type: AnalyticsEventTypeFilter.fraudSignal,
      severity: AnalyticsEventSeverityFilter.warning,
      source: AnalyticsEventSourceFilter.backend,
      action: AnalyticsEventActionFilter.orderVoided,
      occurredAfter: DateTime.utc(2026, 5, 20),
      occurredBefore: DateTime.utc(2026, 5, 21),
      userId: 7,
      registerSessionId: 'register:3',
      entityType: 'sale_order',
      entityId: '42',
      minRiskScore: 70,
      ordering: AnalyticsEventOrdering.highestRisk,
    );

    final params = query.toQueryParameters(page: 2);

    expect(params['search'], 'void');
    expect(params['event_type'], 'fraud_signal');
    expect(params['severity'], 'warning');
    expect(params['source'], 'backend');
    expect(params['activity_scope'], 'reviewable');
    expect(params['action'], 'order_voided');
    expect(params['occurred_at_after'], '2026-05-20T00:00:00.000Z');
    expect(params['occurred_at_before'], '2026-05-21T00:00:00.000Z');
    expect(params['received_by'], '7');
    expect(params['session_id'], 'register:3');
    expect(params['entity_type'], 'sale_order');
    expect(params['entity_id'], '42');
    expect(params['risk_score_min'], '70');
    expect(params['ordering'], '-risk_score');
    expect(params['page'], '2');
  });

  test('analytics event query serializes multi-user activity filters', () {
    final query = AnalyticsEventQuery(
      dateRange: AnalyticsEventDateRange.all,
      userIds: const [7, 9, 7],
      userLabels: const ['مدير', 'كاشير'],
    );

    final params = query.toQueryParameters(page: 1);

    expect(params['received_by'], '7,9');
    expect(query.activeFilterCount, 1);
    expect(
      query,
      const AnalyticsEventQuery(
        dateRange: AnalyticsEventDateRange.all,
        userId: 7,
        userLabel: 'مدير',
      ).copyWith(userIds: const [7, 9], userLabels: const ['مدير', 'كاشير']),
    );
  });

  test('analytics event query serializes cart and draft action filters', () {
    final expectedActions = {
      AnalyticsEventActionFilter.posCartCleared: 'pos_cart_cleared',
      AnalyticsEventActionFilter.posLineQuantityChanged:
          'pos_line_quantity_changed',
      AnalyticsEventActionFilter.purchaseDraftSubmitted:
          'purchase_draft_submitted',
      AnalyticsEventActionFilter.purchaseLineQuantityChanged:
          'purchase_line_quantity_changed',
      AnalyticsEventActionFilter.registerSessionStarted:
          'register_session_started',
      AnalyticsEventActionFilter.registerSessionClosed:
          'register_session_closed',
      AnalyticsEventActionFilter.receiptReprinted: 'receipt_reprinted',
      AnalyticsEventActionFilter.productChanged: 'product_changed',
      AnalyticsEventActionFilter.stockMovementCreated: 'stock_movement_created',
      AnalyticsEventActionFilter.barcodeLabelsPrinted: 'barcode_labels_printed',
      AnalyticsEventActionFilter.userChanged: 'user_changed',
      AnalyticsEventActionFilter.settingsChanged: 'settings_changed',
      AnalyticsEventActionFilter.discountChanged: 'discount_changed',
      AnalyticsEventActionFilter.reportActivity: 'report_activity',
      AnalyticsEventActionFilter.printerActivity: 'printer_activity',
      AnalyticsEventActionFilter.analyticsExport: 'analytics_export',
    };

    for (final entry in expectedActions.entries) {
      expect(
        AnalyticsEventQuery(
          action: entry.key,
        ).toQueryParameters(page: 1)['action'],
        entry.value,
      );
    }
  });

  test('analytics event record derives register session references', () {
    final event = AnalyticsEventRecord.fromJson({
      'id': 1,
      'client_event_id': 'event-1',
      'event_type': 'audit',
      'name': 'sales.checkout.completed',
      'severity': 'info',
      'source': 'backend',
      'occurred_at': '2026-05-20T09:30:00Z',
      'received_by': 4,
      'received_by_username': 'cashier',
      'entity_type': 'sale_order',
      'entity_id': '42',
      'attributes': {'register_session_id': 12},
      'metrics': {'total': 17.5},
    });

    expect(event.eventType, AnalyticsEventType.audit);
    expect(event.registerSessionReference, 'register:12');
    expect(event.metrics['total'], 17.5);
  });
}
