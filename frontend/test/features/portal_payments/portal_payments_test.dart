import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/integration_card.dart';
import 'package:pointy_frontend/src/data/models/portal_payment.dart';
import 'package:pointy_frontend/src/data/repositories/integrations_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/pos/views/integration_recharge_parts.dart';
import 'package:pointy_frontend/src/features/portal_payments/view_models/portal_payments_view_model.dart';
import 'package:pointy_frontend/src/features/portal_payments/views/portal_payment_session_picker.dart';
import 'package:pointy_frontend/src/features/portal_payments/views/portal_payments_screen.dart';
import 'package:pointy_frontend/src/features/portal_payments/views/record_portal_payment_sheet.dart';
import 'package:pointy_frontend/src/shared/formatters.dart';

/// Recording a top-up done on LNET's website as the sale it was. The rules
/// that decide whether one may be recorded are the server's; these pin that
/// the screen asks for exactly what the checkout will, and says why it won't.
void main() {
  group('the day as the server describes it', () {
    test('every field a payment and a drawer carry is read', () {
      final day = PortalPaymentsDay.fromJson(_dayJson());

      expect(day.provider, 'lnet');
      expect(day.complete, isTrue);
      expect(day.unrecordedCount, 1);
      expect(day.unrecordedAmount, 45);
      expect(day.paymentMethods, ['cash', 'card', 'transfer']);
      expect(day.requireCardReceipt, isFalse);

      final unrecorded = day.payments.first;
      expect(unrecorded.state, PortalPaymentState.unrecorded);
      expect(unrecorded.recordable, isTrue);
      expect(unrecorded.price, 45);
      expect(unrecorded.cost, 42.75);

      final recorded = day.payments[1];
      expect(recorded.state, PortalPaymentState.recorded);
      expect(recorded.order!.receiptNumber, 'R20260925000031');
      expect(recorded.order!.cashierName, 'بحر');

      final closed = day.sessions.last;
      expect(closed.isOpen, isFalse);
      expect(closed.cashVariance, 45);
    });

    test('a state this build does not know is never recordable', () {
      expect(
        PortalPaymentState.fromApiValue('something_new'),
        PortalPaymentState.unknown,
      );
      expect(PortalPaymentState.unknown.needsRecording, isFalse);
    });

    test('a refusal keeps the reason the manager is shown', () {
      final refusal = PortalPaymentRefusal.fromBody({
        'code': 'pending_sale',
        'detail': 'pending_sale',
        'order_ids': [7, 9],
      })!;
      expect(refusal.code, 'pending_sale');
      expect(refusal.orderIds, [7, 9]);
      expect(PortalPaymentRefusal.fromBody({'detail': 'x'}), isNull);
    });

    test('a paid invoice and an آجل one are asked for differently', () {
      expect(
        const PortalPaymentRecordDraft(
          registerSessionId: 3,
          paymentMethod: 'card',
          cardReceiptUrl: 'https://slip',
          expectedTotal: 45,
        ).toJson(),
        {
          'register_session': 3,
          'sale_type': 'standard',
          'payment_method': 'card',
          'card_receipt_url': 'https://slip',
          'expected_total': '45.00',
        },
      );
      expect(
        const PortalPaymentRecordDraft(
          registerSessionId: 3,
          isCredit: true,
          paymentMethod: '',
          amountPaid: 0,
          customerId: 12,
          allowPendingSale: true,
        ).toJson(),
        {
          'register_session': 3,
          'sale_type': 'credit',
          'payment_method': '',
          'amount_paid': '0.00',
          'customer': 12,
          'allow_pending_sale': true,
        },
      );
    });
  });

  group('the drawer a payment belongs to', () {
    final day = PortalPaymentsDay.fromJson(_dayJson());

    test('the one drawer open when the payment was made is suggested', () {
      // 13:45 — RS-11 (open since 08:00) held it; RS-12 only opened at 14:00.
      expect(
        PortalPaymentSessionPicker.suggestedFor(day.sessions, _paidAt),
        11,
      );
    });

    test('a drawer counted before the payment existed is never suggested', () {
      // RS-12 closed at 16:00; a payment at 17:30 cannot be in its count.
      final late = DateTime(2026, 9, 25, 17, 30);
      expect(day.sessions.last.closedBefore(late), isTrue);
      expect(PortalPaymentSessionPicker.suggestedFor(day.sessions, late), 11);
    });
  });

  group('view model', () {
    test('only what still needs an invoice is listed until asked', () async {
      final repo = _Repo();
      final viewModel = PortalPaymentsViewModel(repo, providerKey: 'lnet');
      await viewModel.load();

      expect(viewModel.visiblePayments.map((p) => p.reference), ['4307300']);
      viewModel.setShowAll(true);
      expect(viewModel.visiblePayments, hasLength(3));
      expect(repo.refreshes, [true]);
    });

    test('a write reloads the day without reading LNET again', () async {
      final repo = _Repo();
      final viewModel = PortalPaymentsViewModel(repo, providerKey: 'lnet');
      await viewModel.load();
      final payment = viewModel.visiblePayments.single;

      final result = await viewModel.record(
        payment,
        const PortalPaymentRecordDraft(registerSessionId: 11),
      );

      expect(result, isA<Ok<PortalPaymentOrder>>());
      expect(repo.recorded.single.$1, '4307300');
      // The provider was just read to verify it; Pointy's side is all that moved.
      expect(repo.refreshes, [true, false]);
    });

    test('a second tap while the first is in flight is never sent', () async {
      final repo = _Repo(slow: true);
      final viewModel = PortalPaymentsViewModel(repo, providerKey: 'lnet');
      await viewModel.load();
      final payment = viewModel.visiblePayments.single;
      const draft = PortalPaymentRecordDraft(registerSessionId: 11);

      final first = viewModel.record(payment, draft);
      final second = await viewModel.record(payment, draft);
      await first;

      expect(second, isA<Error<PortalPaymentOrder>>());
      expect(repo.recorded, hasLength(1));
    });
  });

  group('screen', () {
    testWidgets('a payment LNET has not finished explains why, and opens '
        'nothing', (tester) async {
      final repo = _Repo();
      final viewModel = PortalPaymentsViewModel(repo, providerKey: 'lnet');
      await viewModel.load();
      viewModel.setShowAll(true);
      await tester.pumpWidget(
        _app(PortalPaymentsScreen(viewModel: viewModel, providerName: 'LNET')),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey('portal_payment_row_4307302')),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('ملغاة'), findsWidgets);
      expect(find.byType(RecordPortalPaymentSheet), findsNothing);
    });

    testWidgets('an unrecorded payment opens the sheet on its own drawer', (
      tester,
    ) async {
      final repo = _Repo();
      final viewModel = PortalPaymentsViewModel(repo, providerKey: 'lnet');
      await viewModel.load();
      await tester.pumpWidget(
        _app(PortalPaymentsScreen(viewModel: viewModel, providerName: 'LNET')),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey('portal_payment_row_4307300')),
      );
      await tester.pumpAndSettle();

      expect(find.byType(RecordPortalPaymentSheet), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('portal_payment_record_button')),
      );
      await tester.pumpAndSettle();

      final draft = repo.recorded.single.$2;
      expect(draft.registerSessionId, 11);
      expect(draft.paymentMethod, 'cash');
      expect(draft.expectedTotal, 45);
      expect(find.textContaining('R20260925000040'), findsOneWidget);
    });
  });

  group('record sheet', () {
    late List<PortalPaymentRecordDraft> drafts;
    late List<PortalPaymentCandidate> links;

    Widget sheet(PortalPayment payment, PortalPaymentsDay day) {
      drafts = [];
      links = [];
      return _app(
        Scaffold(
          body: RecordPortalPaymentSheet(
            payment: payment,
            day: day,
            providerName: 'LNET',
            onRecord: (draft) async {
              drafts.add(draft);
              return Ok(_order);
            },
            onLink: (candidate) async {
              links.add(candidate);
              return Ok(_order);
            },
            pickCustomer: (_) async => null,
          ),
        ),
      );
    }

    Future<void> record(WidgetTester tester) async {
      final button = find.byKey(const ValueKey('portal_payment_record_button'));
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
    }

    testWidgets('a closed drawer is offered, and says what recording moves', (
      tester,
    ) async {
      final day = PortalPaymentsDay.fromJson(_dayJson());
      await tester.pumpWidget(sheet(day.payments.first, day));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('portal_payment_session_12')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('portal_payment_closed_session_warning')),
        findsOneWidget,
      );
      // And that it opened after the payment: the cash had to be carried in.
      expect(
        find.byKey(const ValueKey('portal_payment_opened_after_warning')),
        findsOneWidget,
      );
      await record(tester);
      expect(drafts.single.registerSessionId, 12);
    });

    testWidgets('آجل cannot be recorded without a customer where the shop '
        'says so', (tester) async {
      final day = PortalPaymentsDay.fromJson(_dayJson());
      await tester.pumpWidget(sheet(day.payments.first, day));
      await tester.pumpAndSettle();

      await tester.tap(find.text('آجل'));
      await tester.pumpAndSettle();
      await record(tester);

      expect(drafts, isEmpty);
      expect(find.text('الفاتورة الآجلة تتطلب اختيار عميل.'), findsWidgets);
    });

    testWidgets('a sale waiting for this top-up must be linked, or the manager '
        'must say it is a different one', (tester) async {
      final day = PortalPaymentsDay.fromJson(
        _dayJson(firstState: 'pending_sale', withCandidate: true),
      );
      final payment = day.payments.first;
      await tester.pumpWidget(sheet(payment, day));
      await tester.pumpAndSettle();

      await record(tester);
      expect(drafts, isEmpty);

      await tester.tap(
        find.byKey(const ValueKey('portal_payment_different_top_up')),
      );
      await tester.pumpAndSettle();
      await record(tester);
      expect(drafts.single.allowPendingSale, isTrue);
    });

    testWidgets('linking settles the waiting sale instead', (tester) async {
      final day = PortalPaymentsDay.fromJson(
        _dayJson(firstState: 'pending_sale', withCandidate: true),
      );
      await tester.pumpWidget(sheet(day.payments.first, day));
      await tester.pumpAndSettle();

      await tester.tap(find.text('هي نفسها — اربطها'));
      await tester.pumpAndSettle();

      expect(links.single.fulfillmentId, 88);
      expect(drafts, isEmpty);
    });
  });

  group('till history for an LNET line', () {
    testWidgets('a top-up is named, priced at what the customer paid, and a '
        'cancelled one says so', (tester) async {
      await tester.pumpWidget(
        _app(
          Scaffold(
            body: RechargeHistoryList(
              page: IntegrationHistoryPage(
                ok: true,
                kind: IntegrationHistoryKind.purchases,
                total: 2,
                purchases: [
                  IntegrationPurchaseEntry(
                    reference: '4300578',
                    cost: 42.75,
                    amount: 45,
                    at: DateTime(2026, 9, 20, 16, 38),
                    operatorName: 'lnet_r67',
                    isOurs: true,
                    status: 'verified',
                  ),
                  IntegrationPurchaseEntry(
                    reference: '4300494',
                    cost: 23.75,
                    amount: 25,
                    at: DateTime(2026, 9, 19, 12),
                    operatorName: 'lnet_r67',
                    isOurs: true,
                    status: 'cancelled',
                  ),
                ],
              ),
              isLoading: false,
              onPrevious: () {},
              onNext: () {},
            ),
          ),
        ),
      );

      expect(find.text('شحن رصيد'), findsNWidgets(2));
      expect(find.text(formatMoney(45)), findsOneWidget);
      // Never the float's share in its place.
      expect(find.text(formatMoney(42.75)), findsNothing);
      expect(find.textContaining('ملغاة'), findsOneWidget);
    });
  });
}

final _paidAt = DateTime(2026, 9, 25, 13, 45);

const _order = PortalPaymentOrder(
  id: 501,
  receiptNumber: 'R20260925000040',
  status: 'paid',
  saleType: 'standard',
  total: 45,
  registerSessionId: 11,
  sessionNumber: 'RS-11',
  cashierName: 'بحر',
);

Map<String, Object?> _dayJson({
  String firstState = 'unrecorded',
  bool withCandidate = false,
}) {
  return {
    'provider': 'lnet',
    'date': '2026-09-25',
    'currency': 'LYD',
    'read_ok': true,
    'read_error_code': '',
    'read_at': '2026-09-25T15:30:00Z',
    'complete': true,
    'payments': [
      {
        'reference': '4307300',
        'paid_at': _paidAt.toUtc().toIso8601String(),
        'amount': '45.00',
        'cost': '42.75',
        'subscriber_ref': 'salem.q',
        'subscriber_name': '',
        'customer_id': null,
        'operator_name': 'lnet_r67',
        'provider_status': 'verified',
        'provider_status_label': 'verified',
        'state': firstState,
        'recordable': true,
        'price': '45.00',
        'order': null,
        'candidates': [
          if (withCandidate)
            {
              'fulfillment_id': 88,
              'status': 'pending',
              'sold_at': '2026-09-25T10:00:00Z',
              'order': {
                'id': 70,
                'receipt_number': 'R20260925000007',
                'status': 'paid',
                'sale_type': 'standard',
                'total': '45.00',
                'register_session_id': 11,
                'session_number': 'RS-11',
                'cashier_name': 'بحر',
              },
            },
        ],
        'released_order_ids': <int>[],
      },
      {
        'reference': '4307301',
        'paid_at': '2026-09-25T09:10:00Z',
        'amount': '20.00',
        'cost': '19.00',
        'subscriber_ref': 'osama.ageil',
        'subscriber_name': 'أسامة',
        'customer_id': 4,
        'operator_name': 'lnet_r67',
        'provider_status': 'verified',
        'provider_status_label': 'verified',
        'state': 'recorded',
        'recordable': false,
        'price': null,
        'order': {
          'id': 31,
          'receipt_number': 'R20260925000031',
          'status': 'paid',
          'sale_type': 'standard',
          'total': '20.00',
          'register_session_id': 11,
          'session_number': 'RS-11',
          'cashier_name': 'بحر',
        },
        'candidates': <Object?>[],
        'released_order_ids': <int>[],
      },
      {
        'reference': '4307302',
        'paid_at': '2026-09-25T08:40:00Z',
        'amount': '45.00',
        'cost': '42.75',
        'subscriber_ref': 'cancelled.one',
        'subscriber_name': '',
        'customer_id': null,
        'operator_name': 'lnet_r67',
        'provider_status': 'cancelled',
        'provider_status_label': 'cancelled',
        'state': 'not_verified',
        'recordable': false,
        'price': '45.00',
        'order': null,
        'candidates': <Object?>[],
        'released_order_ids': <int>[],
      },
    ],
    'summary': {
      'counts': {'unrecorded': 1, 'recorded': 1, 'not_verified': 1},
      'unrecorded_count': 1,
      'unrecorded_amount': '45.00',
      'pending_sale_count': 0,
    },
    'sessions': [
      {
        'id': 11,
        'session_number': 'RS-11',
        'cashier_name': 'بحر',
        'owner_id': 2,
        'status': 'open',
        'opened_at': DateTime(2026, 9, 25, 8).toUtc().toIso8601String(),
        'closed_at': null,
        'cash_variance': null,
      },
      {
        'id': 12,
        'session_number': 'RS-12',
        'cashier_name': 'سفيان',
        'owner_id': 3,
        'status': 'closed',
        'opened_at': DateTime(2026, 9, 25, 14).toUtc().toIso8601String(),
        'closed_at': DateTime(2026, 9, 25, 16).toUtc().toIso8601String(),
        'cash_variance': '45.00',
      },
    ],
    'payment_methods': ['cash', 'card', 'transfer'],
    'require_customer_for_credit': true,
    'require_card_receipt': false,
  };
}

class _Repo extends IntegrationsRepository {
  _Repo({this.slow = false}) : super(PosApiService());

  final bool slow;
  final List<bool> refreshes = [];
  final List<(String, PortalPaymentRecordDraft)> recorded = [];

  @override
  Future<Result<PortalPaymentsDay>> loadPortalPayments(
    String providerKey, {
    DateTime? date,
    bool refresh = true,
  }) async {
    refreshes.add(refresh);
    return Ok(PortalPaymentsDay.fromJson(_dayJson()));
  }

  @override
  Future<Result<PortalPaymentOrder>> recordPortalPayment(
    String providerKey,
    String reference,
    PortalPaymentRecordDraft draft,
  ) async {
    recorded.add((reference, draft));
    if (slow) await Future<void>.delayed(const Duration(milliseconds: 20));
    return Ok(_order);
  }

  @override
  Future<Result<PortalPaymentOrder>> linkPortalPayment(
    String providerKey,
    String reference, {
    required int fulfillmentId,
  }) async => Ok(_order);
}

Widget _app(Widget home) {
  return MaterialApp(
    locale: const Locale('ar'),
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    home: home,
  );
}
