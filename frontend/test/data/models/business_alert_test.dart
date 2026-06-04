import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/analytics_event.dart';
import 'package:pointy_frontend/src/data/models/business_alert.dart';

void main() {
  test('suspected activity alert builds an investigation activity query', () {
    final alert = BusinessAlert.fromJson({
      'id': 12,
      'code': 'fraud.suspected_cashier_activity',
      'category': 'fraud',
      'severity': 'warning',
      'is_hidden': false,
      'payload': {
        'user_id': 7,
        'user_label': 'أمين الصندوق',
        'risk_score': 82,
        'headline': 'مرتجعات نقدية متكررة',
        'rule_title': 'تركيز مرتجعات نقدية',
        'investigation_query': {
          'activity_scope': 'reviewable',
          'received_by': '7',
          'occurred_at_after': '2026-05-01T00:00:00Z',
          'occurred_at_before': '2026-06-01T00:00:00Z',
          'ordering': '-occurred_at',
        },
      },
    });

    final query = alert.investigationActivityQuery();
    final params = query!.toQueryParameters(page: 1);

    expect(alert.type, BusinessAlertType.suspectedCashierActivity);
    expect(alert.category, BusinessAlertCategory.fraud);
    expect(alert.primaryLabel, 'أمين الصندوق');
    expect(alert.investigationReason, 'مرتجعات نقدية متكررة');
    expect(query.dateRange, AnalyticsEventDateRange.custom);
    expect(query.selectedUserIds, [7]);
    expect(query.selectedUserLabels, ['أمين الصندوق']);
    expect(params['activity_scope'], 'reviewable');
    expect(params['received_by'], '7');
    expect(params['occurred_at_after'], '2026-05-01T00:00:00.000Z');
    expect(params['occurred_at_before'], '2026-06-01T00:00:00.000Z');
    expect(params['ordering'], '-occurred_at');
  });
}
