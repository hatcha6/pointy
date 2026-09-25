// Dev-only preview harness for "payments made on the provider's website" —
// LNET top-ups a cashier did on billing.lnet.ly while the till could not sell
// them, recorded afterwards as the invoices they were. Opened from the
// register sessions screen.
//
// Renders against an in-memory fake repository (no backend, no auth). Run with:
//
//   flutter run -d web-server --web-port 8080 -t lib/dev/portal_payments_preview.dart
//
// Pick a scenario with `?screen=`:
//
//   list      the day: unrecorded, one that may be a waiting sale, one
//             recorded, one cancelled at LNET, one recorded-then-voided
//   sheet     the record sheet on an unrecorded payment, a closed shift in
//             the list with the overage the website cash left in its count
//   pending   the record sheet when a Pointy sale is still waiting for this
//             very top-up — link it, or say it is a different one
//   history   the till's history for an LNET line: the amount paid, not the
//             float's share, and a cancelled top-up struck through
//
// The figures are LNET's real ones: a 5% agency commission, serials from the
// captured report. See AGENTS.md ("UI preview harness"). Not part of the
// shipping app. Safe to delete.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/integration_card.dart';
import 'package:pointy_frontend/src/data/models/portal_payment.dart';
import 'package:pointy_frontend/src/data/repositories/integrations_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/pos/views/integration_recharge_parts.dart';
import 'package:pointy_frontend/src/features/portal_payments/view_models/portal_payments_view_model.dart';
import 'package:pointy_frontend/src/features/portal_payments/views/portal_payments_screen.dart';
import 'package:pointy_frontend/src/features/portal_payments/views/record_portal_payment_sheet.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/shell/shell.dart';

void main() => runApp(const _PreviewApp());

String _screen() {
  final uri = Uri.base;
  final direct = uri.queryParameters['screen'];
  if (direct != null) return direct;
  final fragment = uri.fragment;
  final parsed = Uri.tryParse(
    fragment.startsWith('/') ? fragment.substring(1) : fragment,
  );
  return parsed?.queryParameters['screen'] ?? 'list';
}

class _PreviewApp extends StatelessWidget {
  const _PreviewApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: PointyTheme.light(),
      builder: (context, child) => PointyNavigationRailScope(
        isActive: false,
        controller: PointyNavigationRailController(),
        child: child ?? const SizedBox.shrink(),
      ),
      home: switch (_screen()) {
        'sheet' => _SheetPreview(day: _day()),
        'pending' => _SheetPreview(day: _day(pending: true)),
        'history' => const _HistoryPreview(),
        _ => PortalPaymentsScreen(
          viewModel: PortalPaymentsViewModel(_Repo(), providerKey: 'lnet'),
          providerName: 'LNET',
        ),
      },
    );
  }
}

/// The record sheet, open on the first payment of the day.
class _SheetPreview extends StatelessWidget {
  const _SheetPreview({required this.day});

  final PortalPaymentsDay day;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Material(
            elevation: 2,
            child: RecordPortalPaymentSheet(
              payment: day.payments.first,
              day: day,
              providerName: 'LNET',
              onRecord: (_) async => const Ok(_recordedOrder),
              onLink: (_) async => const Ok(_recordedOrder),
              pickCustomer: (_) async => null,
            ),
          ),
        ),
      ),
    );
  }
}

class _HistoryPreview extends StatelessWidget {
  const _HistoryPreview();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SizedBox(
          width: 480,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: RechargeHistoryList(
              page: IntegrationHistoryPage(
                ok: true,
                kind: IntegrationHistoryKind.purchases,
                total: 3,
                purchases: [
                  IntegrationPurchaseEntry(
                    reference: '4307300',
                    cost: 42.75,
                    amount: 45,
                    at: DateTime(2026, 9, 25, 13, 45),
                    operatorName: 'lnet_r67',
                    isOurs: true,
                    status: 'verified',
                  ),
                  IntegrationPurchaseEntry(
                    reference: '4299905',
                    cost: 23.75,
                    amount: 25,
                    at: DateTime(2026, 8, 24, 21, 25),
                    operatorName: 'lnet_r67',
                    isOurs: true,
                    status: 'cancelled',
                  ),
                  IntegrationPurchaseEntry(
                    reference: '4288114',
                    cost: 42.75,
                    amount: 45,
                    at: DateTime(2026, 7, 25, 19, 4),
                    operatorName: 'lnet_r67',
                    isOurs: true,
                    status: 'verified',
                  ),
                ],
              ),
              isLoading: false,
              onPrevious: () {},
              onNext: () {},
            ),
          ),
        ),
      ),
    );
  }
}

class _Repo extends IntegrationsRepository {
  _Repo() : super(PosApiService());

  @override
  Future<Result<PortalPaymentsDay>> loadPortalPayments(
    String providerKey, {
    DateTime? date,
    bool refresh = true,
  }) async => Ok(_day());

  @override
  Future<Result<PortalPaymentOrder>> recordPortalPayment(
    String providerKey,
    String reference,
    PortalPaymentRecordDraft draft,
  ) async => const Ok(_recordedOrder);

  @override
  Future<Result<PortalPaymentOrder>> linkPortalPayment(
    String providerKey,
    String reference, {
    required int fulfillmentId,
  }) async => const Ok(_recordedOrder);
}

const _recordedOrder = PortalPaymentOrder(
  id: 501,
  receiptNumber: 'R20260925000040',
  status: 'paid',
  saleType: 'standard',
  total: 45,
  registerSessionId: 11,
  sessionNumber: 'RS-11',
  cashierName: 'بحر',
);

Map<String, Object?> _order(int id, String receipt, String total) => {
  'id': id,
  'receipt_number': receipt,
  'status': 'paid',
  'sale_type': 'standard',
  'total': total,
  'register_session_id': 11,
  'session_number': 'RS-11',
  'cashier_name': 'بحر الشريف',
};

Map<String, Object?> _payment(
  String reference,
  DateTime at,
  String amount,
  String line, {
  String state = 'unrecorded',
  String status = 'verified',
  String name = '',
  Map<String, Object?>? order,
  List<Map<String, Object?>> candidates = const [],
}) {
  final value = double.parse(amount);
  return {
    'reference': reference,
    'paid_at': at.toUtc().toIso8601String(),
    'amount': amount,
    'cost': (value * 0.95).toStringAsFixed(2),
    'subscriber_ref': line,
    'subscriber_name': name,
    'customer_id': null,
    'operator_name': 'lnet_r67',
    'provider_status': status,
    'provider_status_label': status,
    'state': state,
    'recordable': state == 'unrecorded' ||
        state == 'released' ||
        state == 'pending_sale',
    'price': amount,
    'order': order,
    'candidates': candidates,
    'released_order_ids': <int>[],
  };
}

PortalPaymentsDay _day({bool pending = false}) {
  DateTime at(int hour, int minute) => DateTime(2026, 9, 25, hour, minute);
  return PortalPaymentsDay.fromJson({
    'provider': 'lnet',
    'date': '2026-09-25',
    'currency': 'LYD',
    'read_ok': true,
    'read_error_code': '',
    'read_at': at(16, 32).toUtc().toIso8601String(),
    'complete': true,
    'payments': [
      _payment(
        '4307330',
        at(14, 18),
        '45.00',
        'salem.qarqoum',
        name: pending ? '' : 'سالم قرقوم',
        state: pending ? 'pending_sale' : 'unrecorded',
        candidates: [
          if (pending)
            {
              'fulfillment_id': 88,
              'status': 'pending',
              'sold_at': at(13, 52).toUtc().toIso8601String(),
              'order': _order(70, 'R20260925000033', '45.00'),
            },
        ],
      ),
      _payment('4307322', at(14, 2), '40.00', 'hamzah.alfaqeh'),
      _payment(
        '4307315',
        at(13, 51),
        '45.00',
        'waiting.line',
        state: 'pending_sale',
        candidates: [
          {
            'fulfillment_id': 91,
            'status': 'pending',
            'sold_at': at(13, 40).toUtc().toIso8601String(),
            'order': _order(69, 'R20260925000032', '45.00'),
          },
        ],
      ),
      _payment('4307301', at(13, 39), '25.00', 'moammar.j', state: 'released'),
      _payment(
        '4307290',
        at(11, 5),
        '45.00',
        'osama.ageil',
        name: 'أسامة عقيل',
        state: 'recorded',
        order: _order(31, 'R20260925000031', '45.00'),
      ),
      _payment(
        '4307288',
        at(10, 40),
        '45.00',
        'ahme.algerare',
        state: 'not_verified',
        status: 'cancelled',
      ),
    ],
    'summary': {
      'counts': {'unrecorded': 2},
      'unrecorded_count': 3,
      'unrecorded_amount': '110.00',
      'pending_sale_count': 1,
    },
    'sessions': [
      {
        'id': 11,
        'session_number': 'RS-11',
        'cashier_name': 'بحر الشريف',
        'owner_id': 2,
        'status': 'closed',
        'opened_at': at(7, 50).toUtc().toIso8601String(),
        'closed_at': at(15, 10).toUtc().toIso8601String(),
        'cash_variance': '110.00',
      },
      {
        'id': 12,
        'session_number': 'RS-12',
        'cashier_name': 'سفيان',
        'owner_id': 3,
        'status': 'open',
        'opened_at': at(15, 5).toUtc().toIso8601String(),
        'closed_at': null,
        'cash_variance': null,
      },
      {
        'id': 9,
        'session_number': 'RS-9',
        'cashier_name': 'فرج',
        'owner_id': 4,
        'status': 'closed',
        'opened_at': at(1, 0).toUtc().toIso8601String(),
        'closed_at': at(2, 5).toUtc().toIso8601String(),
        'cash_variance': '0.00',
      },
    ],
    'payment_methods': ['cash', 'card', 'transfer'],
    'require_customer_for_credit': true,
    'require_card_receipt': true,
  });
}
