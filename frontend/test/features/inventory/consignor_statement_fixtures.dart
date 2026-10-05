import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/consignment.dart';
import 'package:pointy_frontend/src/data/models/consignor_statement.dart';
import 'package:pointy_frontend/src/data/repositories/consignment_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';

/// A consignor statement as the server sends it, for tests and captures.
Map<String, Object?> statementJson({
  bool withCommission = true,
  double receivable = 0,
  List<Map<String, Object?>>? lines,
  bool hasNext = false,
  bool remindersOn = true,
}) {
  final now = DateTime.now();
  String ago(int days) =>
      now.subtract(Duration(days: days)).toUtc().toIso8601String();
  final rows =
      lines ??
      [
        {
          'id': 11,
          'code': 'RLX-7781-A',
          'product_name': 'ساعة رولكس ديت جست 36',
          'agreement': 3,
          'agreement_number': 'A2026081500012',
          'state': 'awaiting',
          'activity_at': ago(47),
          'sold_at': ago(47),
          'sold_price': '12500.00',
          'payout_due': '9800.00',
          'payout_is_estimate': false,
          'advance': '0.00',
          'net_due': '9800.00',
          'invoice_number': 'R20260819000231',
          'sold_on_credit': false,
          'days_waiting': 47,
          'last_reminder': {
            'sent_at': ago(17),
            'round': 1,
            'status': 'delivered',
          },
        },
        {
          'id': 12,
          'code': 'LV-NF-0932',
          'product_name': 'حقيبة لويس فيتون نيفرفول',
          'agreement': 4,
          'agreement_number': 'A2026091000020',
          'state': 'awaiting',
          'activity_at': ago(12),
          'sold_at': ago(12),
          'sold_price': '4300.00',
          'payout_due': '3650.00',
          'payout_is_estimate': false,
          'advance': '0.00',
          'net_due': '3650.00',
          'invoice_number': 'R20260923000118',
          'sold_on_credit': true,
          'days_waiting': 12,
          'last_reminder': null,
        },
        {
          'id': 13,
          'code': 'SONY-4471209',
          'product_name': 'كاميرا سوني A7 IV مع عدسة 28-70',
          'agreement': 4,
          'agreement_number': 'A2026091000020',
          'state': 'held',
          'activity_at': ago(25),
          'acquired_at': ago(25),
          'declared_value': '7000.00',
          'list_price': '7400.00',
          'payout_due': '6300.00',
          'payout_is_estimate': true,
          'advance': '0.00',
          'net_due': '0.00',
        },
        {
          'id': 14,
          'code': '356789104512347',
          'product_name': 'آيفون 15 برو ماكس 256 جيجا',
          'agreement': 4,
          'agreement_number': 'A2026091000020',
          'state': 'held',
          'activity_at': ago(25),
          'acquired_at': ago(25),
          'declared_value': '4200.00',
          'payout_due': '3900.00',
          'payout_is_estimate': true,
          'advance': '0.00',
          'net_due': '0.00',
        },
        {
          'id': 15,
          'code': 'OMG-SM-3310',
          'product_name': 'ساعة أوميغا سيماستر',
          'agreement': 3,
          'agreement_number': 'A2026081500012',
          'state': 'paid',
          'activity_at': ago(33),
          'sold_at': ago(40),
          'paid_at': ago(33),
          'payout_due': '8200.00',
          'payout_is_estimate': false,
          'advance': '0.00',
          'net_due': '0.00',
          'consignor_payout': 7,
          'payout_number': 'CP2026090200004',
          'invoice_number': 'R20260826000077',
        },
        {
          'id': 16,
          'code': 'CHN-CF-118',
          'product_name': 'حقيبة شانيل كلاسيك',
          'agreement': 3,
          'agreement_number': 'A2026081500012',
          'state': 'returned',
          'activity_at': ago(20),
          'declared_value': '12000.00',
          'payout_due': '10000.00',
          'payout_is_estimate': true,
          'advance': '0.00',
          'net_due': '0.00',
        },
      ];
  return {
    'consignor': {
      'id': 42,
      'full_name': 'سالم الورفلي',
      'phone': '0912345678',
      'do_not_contact': false,
    },
    'period': {'start': null, 'end': null},
    'figures': {
      'payable': '13450.00',
      'receivable': '$receivable',
      'claims_open': '0.00',
      'claims_unassessed': 0,
      'total_count': 6,
      'held_count': 2,
      'held_declared_value': '11200.00',
      'awaiting_count': 2,
      'oldest_awaiting_at': ago(47),
      'paid_count': 1,
      'returned_count': 1,
      'lost_count': 0,
      'period_sold_count': 3,
      'period_sold_value': '25000.00',
      'period_paid_total': '8200.00',
      'period_payout_count': 1,
      'agreement_count': 2,
      'shop_commission': ?(withCommission ? '3350.00' : null),
    },
    'reminders': {
      'enabled': remindersOn,
      'every_days': 30,
      'max_rounds': 3,
      'last_at': ago(17),
      'last_status': 'delivered',
    },
    'count': rows.length,
    'next': hasNext ? 'http://x/?page=2' : null,
    'previous': null,
    'results': rows,
  };
}

/// Answers the statement endpoint from [pages] (page number → body).
class FakeStatementRepository extends ConsignmentRepository {
  FakeStatementRepository(this.pages) : super(PosApiService());

  final Map<int, Map<String, Object?>> pages;
  final List<({int page, List<String> states, DateTime? start})> calls = [];
  bool failNext = false;
  List<int> disbursed = const [];

  @override
  Future<Result<ConsignorStatementPage>> loadStatement(
    int consignorId, {
    DateTime? start,
    DateTime? end,
    List<String> states = const [],
    int page = 1,
    bool summaryOnly = false,
  }) async {
    calls.add((page: page, states: states, start: start));
    if (failNext) {
      failNext = false;
      return Error(Exception('offline'));
    }
    final body = pages[page] ?? pages[1]!;
    return Ok(ConsignorStatementPage.fromJson(body));
  }

  @override
  Future<Result<ConsignorPayout>> disburse({
    required int unitId,
    List<int> alsoUnitIds = const [],
    String method = 'cash',
    String reference = '',
  }) async {
    disbursed = [unitId, ...alsoUnitIds];
    return Ok(
      const ConsignorPayout(id: 9, number: 'CP2026100500009', amount: 13450),
    );
  }

  @override
  Future<Result<bool>> resendSaleSms(int unitId) async => const Ok(true);
}
