import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/card_settlement.dart';
import 'package:pointy_frontend/src/data/models/money_position.dart';

/// The settlement screen adds held days up and subtracts the deposit from
/// them while the owner ticks boxes. These pin the arithmetic to whole cents,
/// read straight from the server's strings, so the difference it shows is the
/// one the server stores.
void main() {
  group('moneyCents', () {
    test('reads the server strings exactly', () {
      expect(moneyCents('1823.40'), 182340);
      expect(moneyCents('0.10'), 10);
      expect(moneyCents('-9.30'), -930);
      expect(moneyCents('12'), 1200);
      expect(moneyCents('12.5'), 1250);
      expect(moneyCents(null), 0);
      expect(moneyCents('not money'), 0);
    });

    test('a third decimal rounds half up, as the server quantizes', () {
      expect(moneyCents('0.125'), 13);
      expect(moneyCents('0.124'), 12);
    });

    test('numbers do not drift', () {
      expect(moneyCents(0.1 + 0.2), 30);
      expect(moneyCents(5199.3), 519930);
    });

    test('cents go back to the wire unchanged', () {
      expect(centsToApi(519930), '5199.30');
      expect(centsToApi(-930), '-9.30');
      expect(centsToApi(5), '0.05');
    });
  });

  test('held takings parse days, totals and the proposed match', () {
    final takings = HeldTakings.fromJson({
      'account': {
        'id': 9,
        'name': 'معاملات',
        'kind': 'clearing',
        'settles_into': 2,
        'settles_into_name': 'حساب المحل',
      },
      'today': '2026-10-04',
      'settled_on': '2026-10-04',
      'days': [
        {
          'day': '2026-10-01',
          'expected_on': '2026-10-04',
          'overdue': false,
          'gross': '1000.00',
          'commission': '10.00',
          'net': '990.00',
          'count': 3,
        },
      ],
      'totals': {'net': '990.00', 'overdue_net': '0.00', 'count': 3},
      'suggestion': {
        'days': ['2026-10-01'],
        'match': 'exact',
        'expected': '990.00',
        'difference': '0.00',
      },
    });

    expect(takings.account.isClearing, isTrue);
    expect(takings.account.settlesIntoName, 'حساب المحل');
    expect(takings.days.single.key, '2026-10-01');
    expect(takings.days.single.netCents, 99000);
    expect(takings.suggestion.match, SettlementMatch.exact);
    expect(takings.suggestion.days, ['2026-10-01']);
    expect(takings.suggestion.differenceCents, 0);
  });

  test('a draft sends days, exclusions and the figure the owner saw', () {
    final draft = CardSettlementDraft(
      clearingAccountId: 9,
      settledOn: DateTime(2026, 10, 4),
      amountReceivedCents: 98500,
      days: const ['2026-10-01'],
      excludePaymentIds: const [501],
      expectedCents: 99000,
      reference: 'SMS 4471',
    );

    expect(draft.toJson(), {
      'clearing_account': 9,
      'settled_on': '2026-10-04',
      'amount_received': '985.00',
      'days': ['2026-10-01'],
      'exclude_payment_ids': [501],
      'expected_amount': '990.00',
      'reference': 'SMS 4471',
      'note': '',
    });
  });

  group('a clearing money account', () {
    test('round-trips its schedule and leaves other kinds untouched', () {
      final account = MoneyAccount.fromJson({
        'id': 9,
        'name': 'معاملات',
        'kind': 'clearing',
        'settles_into': 2,
        'settles_into_name': 'حساب المحل',
        'holds_untagged_card': true,
        'settlement_cutoff': '00:00:00',
        'settlement_weekdays': '6,0,1,2,3',
        'settlement_lag_days': 1,
        'closed_on': null,
      });

      expect(account.kind, MoneyAccountKind.clearing);
      expect(account.isClearing, isTrue);
      expect(account.holdsUntaggedCard, isTrue);
      final json = account.toJson();
      expect(json['settles_into'], 2);
      expect(json['settlement_weekdays'], '6,0,1,2,3');
      expect(json['settlement_lag_days'], 1);

      // A bank's save is the payload it always was.
      const bank = MoneyAccount(
        id: 2,
        name: 'المصرف',
        kind: MoneyAccountKind.bank,
      );
      expect(bank.toJson().containsKey('settles_into'), isFalse);
    });

    test(
      'an unknown kind still falls back to cash, a clearing one does not',
      () {
        expect(
          MoneyAccountKind.fromApiValue('clearing'),
          MoneyAccountKind.clearing,
        );
        expect(MoneyAccountKind.fromApiValue('mystery'), MoneyAccountKind.cash);
      },
    );

    test('the position carries the held summary and the in-transit total', () {
      final position = MoneyPosition.fromJson({
        'accounts': [
          {
            'account': {'id': 9, 'name': 'معاملات', 'kind': 'clearing'},
            'expected_balance': '148.50',
            'components': [],
            'last_count': null,
            'held': {
              'days': 2,
              'payments': 2,
              'oldest_day': '2026-09-25',
              'next_expected_on': '2026-09-28',
              'overdue_days': 1,
              'overdue_amount': '99.00',
            },
          },
        ],
        'totals': {
          'cash': '0',
          'bank': '0',
          'in_transit': '148.50',
          'total': '148.50',
        },
      });

      expect(position.clearingAccounts, hasLength(1));
      expect(position.bankAccounts, isEmpty);
      expect(position.totals.inTransit, 148.50);
      final held = position.clearingAccounts.single.held!;
      expect(held.hasOverdue, isTrue);
      expect(held.overdueAmount, 99.00);
    });
  });
}
