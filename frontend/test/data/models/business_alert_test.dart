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

  test('a low provider float parses into a typed alert, not "unknown"', () {
    // Every provider code reached the client as BusinessAlertType.unknown
    // until these cases existed, so the bell said "a new alert" about a float
    // that was about to stop the till selling.
    final alert = BusinessAlert.fromJson({
      'id': 31,
      'code': 'integrations.low_float',
      'category': 'sales',
      'severity': 'warning',
      'is_hidden': false,
      'payload': {
        'provider': 'hdbox',
        'account_label': 'Alnassim',
        'amount': '180.00',
        'threshold': '250.00',
        'currency': 'LYD',
        'balance_at': '2026-09-21T08:50:00Z',
        'count': 1,
      },
    });

    expect(alert.type, BusinessAlertType.lowProviderFloat);
    expect(alert.category, BusinessAlertCategory.sales);
    expect(alert.primaryLabel, 'hdbox');
    expect(alert.amount, 180);
    expect(alert.detailLabel, 'Alnassim');
    expect(alert.occurredAt, isNotNull, reason: 'how old the reading is');
  });

  test('an exhausted float sorts above the ordinary money alerts', () {
    final empty = BusinessAlert.fromJson({
      'id': 32,
      'code': 'integrations.low_float',
      'category': 'sales',
      'severity': 'critical',
      'is_hidden': false,
      'payload': {'provider': 'lnet', 'amount': '0.00', 'count': 1},
    });
    final drift = BusinessAlert.fromJson({
      'id': 33,
      'code': 'integrations.float_drift',
      'category': 'sales',
      'severity': 'warning',
      'is_hidden': false,
      'payload': {'provider': 'lnet', 'amount': '12.00', 'direction': 'short'},
    });

    expect(empty.severity, BusinessAlertSeverity.critical);
    expect(empty.sortScore, lessThan(drift.sortScore));
    expect(drift.type, BusinessAlertType.providerFloatDrift);
    expect(drift.secondaryLabel, 'short');
  });

  test('a recharge that was sent and never answered outranks everything', () {
    final unresolved = BusinessAlert.fromJson({
      'id': 34,
      'code': 'integrations.unresolved_recharge',
      'category': 'sales',
      'severity': 'critical',
      'is_hidden': false,
      'payload': {
        'provider': 'hdbox',
        'card_no': '210906803499',
        'amount': '220.00',
        'sent_at': '2026-09-20T18:02:00Z',
      },
    });
    final outOfStock = BusinessAlert.fromJson({
      'id': 35,
      'code': 'inventory.out_of_stock',
      'category': 'inventory',
      'severity': 'critical',
      'is_hidden': false,
      'payload': {'product_name': 'قهوة', 'count': 1},
    });

    expect(unresolved.type, BusinessAlertType.unresolvedRecharge);
    expect(unresolved.secondaryLabel, '210906803499');
    expect(
      unresolved.sortScore,
      lessThan(outOfStock.sortScore),
      reason: 'nobody yet knows whether that money moved',
    );
  });
}
