import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/balance_entry.dart';
import 'package:pointy_frontend/src/data/models/contact.dart';
import 'package:pointy_frontend/src/data/models/customer_activity.dart';
import 'package:pointy_frontend/src/data/models/purchase_submission.dart';
import 'package:pointy_frontend/src/data/services/api_session.dart';
import 'package:pointy_frontend/src/features/payments/models/payment_record.dart';
import 'package:pointy_frontend/src/shared/balance_labels.dart';

PosApiException _refusal(int status, Map<String, Object?> body) {
  return PosApiException(
    message: 'refused',
    statusCode: status,
    responseBody: jsonEncode(body),
  );
}

void main() {
  group('BalanceEntry.fromJson', () {
    test('reads an entry the way the server writes it', () {
      final entry = BalanceEntry.fromJson(const {
        'id': 4,
        'number': 'B20260925000004',
        'kind': 'opening',
        'direction': 'we_owe_them',
        'amount': '150.00',
        'settled_amount': '40.00',
        'remaining_amount': '110.00',
        'effective_date': '2026-01-01',
        'note': 'من الدفتر القديم',
        'created_by_username': 'manager',
        'can_cancel': false,
        'doc_status': 'submitted',
      });

      expect(entry.id, 4);
      expect(entry.number, 'B20260925000004');
      expect(entry.isOpening, isTrue);
      expect(entry.isRefund, isFalse);
      expect(entry.direction, BalanceDirection.weOweThem);
      expect(entry.amount, 150);
      expect(entry.settledAmount, 40);
      expect(entry.remainingAmount, 110);
      expect(entry.effectiveDate, DateTime(2026, 1, 1));
      expect(entry.note, 'من الدفتر القديم');
      expect(entry.canCancel, isFalse);
      expect(entry.isCancelled, isFalse);
    });

    test('knows a refund and a cancelled entry', () {
      final refund = BalanceEntry.fromJson(const {
        'id': 1,
        'kind': 'refund',
        'direction': 'they_owe_us',
        'amount': 20,
      });
      expect(refund.isRefund, isTrue);
      expect(refund.kind, BalanceEntryKind.refund);

      final cancelled = BalanceEntry.fromJson(const {
        'id': 2,
        'kind': 'adjustment',
        'direction': 'they_owe_us',
        'amount': '5.00',
        'doc_status': 'cancelled',
        'cancel_reason': 'سُجّل مرتين',
      });
      expect(cancelled.isCancelled, isTrue);
      expect(cancelled.cancelReason, 'سُجّل مرتين');
    });
  });

  test('BalanceEntryPage reads a paginated page and a bare list', () {
    final page = BalanceEntryPage.fromAny(const {
      'next': 'http://x/?page=2',
      'results': [
        {'id': 1, 'kind': 'opening', 'direction': 'they_owe_us'},
      ],
    });
    expect(page.entries.single.id, 1);
    expect(page.hasMore, isTrue);

    final bare = BalanceEntryPage.fromAny(const [
      {'id': 2, 'kind': 'adjustment', 'direction': 'we_owe_them'},
    ]);
    expect(bare.entries.single.id, 2);
    expect(bare.hasMore, isFalse);
  });

  test('a draft sends money to the cent, the day only, and no empty note', () {
    final draft = BalanceEntryDraft(
      kind: BalanceEntryKind.adjustment,
      direction: BalanceDirection.theyOweUs,
      amount: 12.5,
      note: '  دين قديم  ',
      effectiveDate: DateTime(2026, 3, 4, 15, 30),
    );
    expect(draft.toJson(), {
      'kind': 'adjustment',
      'direction': 'they_owe_us',
      'amount': '12.50',
      'note': 'دين قديم',
      'effective_date': '2026-03-04',
    });

    const bare = BalanceEntryDraft(
      kind: BalanceEntryKind.opening,
      direction: BalanceDirection.weOweThem,
      amount: 3,
      note: '   ',
    );
    expect(bare.toJson(), {
      'kind': 'opening',
      'direction': 'we_owe_them',
      'amount': '3.00',
    });
  });

  test('a create draft carries its opening balance only when it has one', () {
    const withBalance = CustomerDraft(
      fullName: 'سالم',
      phone: '',
      email: '',
      gender: CustomerGender.unspecified,
      birthday: null,
      marketingConsent: false,
      notes: '',
      isActive: true,
      openingBalance: OpeningBalanceDraft(
        direction: BalanceDirection.theyOweUs,
        amount: 250,
      ),
    );
    expect(withBalance.toJson()['opening_balance'], {
      'direction': 'they_owe_us',
      'amount': '250.00',
    });

    const supplier = SupplierDraft(
      name: 'شركة الحسن',
      contactName: '',
      phone: '',
      email: '',
      address: '',
      notes: '',
      isActive: true,
    );
    expect(supplier.toJson().containsKey('opening_balance'), isFalse);
  });

  test('the customer summary reads the account position', () {
    final summary = CustomerSalesSummary.fromJson(const {
      'customer': 3,
      'credit_balance': '30.00',
      'net_balance': '-30.00',
      'open_debts_total': '20.00',
      'unapplied_credit': '50.00',
      'has_opening_balance': true,
    });
    expect(summary.creditBalance, 30);
    expect(summary.netBalance, -30);
    expect(summary.openDebtsTotal, 20);
    expect(summary.unappliedCredit, 50);
    expect(summary.hasOpeningBalance, isTrue);
    // Credit and debts both stand, so spending one on the other is offered.
    expect(summary.canApplyCredit, isTrue);
  });

  test('a payment names the balance entry it settled', () {
    final collected = CustomerPaymentRecord.fromJson(const {
      'id': 1,
      'method': 'cash',
      'amount': '30.00',
      'order': 5,
      'order_receipt_number': 'B20260101000001',
      'order_sale_type': 'account_entry',
    });
    expect(collected.settlesAccountEntry, isTrue);

    final invoice = CustomerPaymentRecord.fromJson(const {
      'id': 2,
      'method': 'cash',
      'amount': '30.00',
      'order': 6,
      'order_sale_type': 'credit',
    });
    expect(invoice.settlesAccountEntry, isFalse);

    final paid = SupplierPayment.fromJson(const {
      'id': 3,
      'supplier': 4,
      'supplier_name': 'شركة الحسن',
      'amount': '500.00',
      'method': 'cash',
      'balance_entry': 8,
      'balance_entry_number': 'B20260101000008',
    });
    expect(paid.balanceEntryId, 8);
    expect(paid.balanceEntryNumber, 'B20260101000008');
    expect(paid.purchaseOrderId, isNull);
  });

  group('classifyBalanceFailure', () {
    test('names each refusal the server codes', () {
      expect(
        classifyBalanceFailure(
          _refusal(400, {'code': 'opening_balance_exists'}),
        ),
        BalanceFailure.openingExists,
      );
      expect(
        classifyBalanceFailure(_refusal(409, {'code': 'document_blocked'})),
        BalanceFailure.settled,
      );
      expect(
        classifyBalanceFailure(
          _refusal(400, {'code': 'register_session_required'}),
        ),
        BalanceFailure.sessionRequired,
      );
      expect(
        classifyBalanceFailure(
          _refusal(400, {'code': 'refund_exceeds_credit'}),
        ),
        BalanceFailure.exceedsCredit,
      );
      expect(
        classifyBalanceFailure(_refusal(409, {'code': 'refund_is_final'})),
        BalanceFailure.refundFinal,
      );
    });

    test('reads a future date, top-level or nested under a create', () {
      expect(
        classifyBalanceFailure(
          _refusal(400, {
            'effective_date': ['future'],
          }),
        ),
        BalanceFailure.futureDate,
      );
      expect(
        classifyBalanceFailure(
          _refusal(400, {
            'opening_balance': {
              'effective_date': ['future'],
            },
          }),
        ),
        BalanceFailure.futureDate,
      );
    });

    test('tells a closed period from a missing permission', () {
      expect(
        classifyBalanceFailure(
          _refusal(403, {'detail': 'The books are closed through 2026-06-30.'}),
        ),
        BalanceFailure.periodLocked,
      );
      expect(
        classifyBalanceFailure(_refusal(403, {'detail': 'Not allowed.'})),
        BalanceFailure.forbidden,
      );
      expect(
        classifyBalanceFailure(Exception('offline')),
        BalanceFailure.generic,
      );
    });
  });
}
