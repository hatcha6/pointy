// Dev-only preview harness for the dialog a sale ends in.
//
// Renders the checkout result's states with hand-built outcomes — no backend,
// no auth. Pick one with `?screen=`, add `&theme=dark` for dark mode:
//
//   make frontend-checkout-result-preview
//
// Screens: board | working | working-slow | success | success-change
//          | success-link | success-card | success-attention | success-credit
//          | failure-credit | failure-stock | failure-network
//
// `?screen=board` lays every state out at once (size the viewport large —
// e.g. 1700x3200 — so Flutter paints all of it). Not part of the shipping
// app. Safe to delete.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/data/models/integration_card.dart';
import 'package:pointy_frontend/src/data/models/sale_order.dart';
import 'package:pointy_frontend/src/data/repositories/sale_repository.dart';
import 'package:pointy_frontend/src/data/services/order_document_service.dart';
import 'package:pointy_frontend/src/features/pos/view_models/pos_view_model.dart';
import 'package:pointy_frontend/src/features/pos/views/checkout_result/checkout_failure_view.dart';
import 'package:pointy_frontend/src/features/pos/views/checkout_result/checkout_progress_view.dart';
import 'package:pointy_frontend/src/features/pos/views/checkout_result/checkout_receipt_actions.dart';
import 'package:pointy_frontend/src/features/pos/views/checkout_result/checkout_success_view.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

void main() => runApp(const _PreviewApp());

bool get _dark => Uri.base.queryParameters['theme'] == 'dark';

String get _screen => Uri.base.queryParameters['screen'] ?? 'board';

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
      theme: _dark ? PointyTheme.dark() : PointyTheme.light(),
      home: Scaffold(
        backgroundColor: const Color(0xFF5B6168),
        body: _screen == 'board'
            ? const _Board()
            : Center(child: _Frame(child: _surface(_screen))),
      ),
    );
  }
}

class _Board extends StatelessWidget {
  const _Board();

  static const _states = [
    'working',
    'working-slow',
    'success',
    'success-change',
    'success-link',
    'success-card',
    'success-attention',
    'success-credit',
    'failure-credit',
    'failure-stock',
    'failure-network',
  ];

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Wrap(
        spacing: 24,
        runSpacing: 24,
        children: [
          for (final state in _states)
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  state,
                  textDirection: TextDirection.ltr,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
                const SizedBox(height: 6),
                SizedBox(
                  height: 760,
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: _Frame(child: _surface(state)),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// The dialog's own frame, without the route: the same width cap and shape.
class _Frame extends StatelessWidget {
  const _Frame({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 520, maxHeight: 760),
      child: Material(
        color: context.pointyColors.surface,
        clipBehavior: Clip.antiAlias,
        borderRadius: BorderRadius.circular(PointyRadii.dialog),
        child: child,
      ),
    );
  }
}

const _order = SaleOrder(
  id: 42,
  status: 'paid',
  receiptNumber: 'R20261017000042',
  lines: [],
  payments: [],
  subtotal: 125,
  total: 125,
  customerPhone: '0912345678',
);

final _handlers = CheckoutReceiptHandlers(
  print: () async {
    await Future<void>.delayed(const Duration(milliseconds: 900));
    return InvoicePrintStatus.printed;
  },
  share: () async => OrderDocumentActionStatus.completed,
  sendSms: (_) async {
    await Future<void>.delayed(const Duration(milliseconds: 700));
    return null;
  },
);

IntegrationChargeResult _card({String outcome = 'charged'}) =>
    IntegrationChargeResult.fromJson({
      'fulfillment': 1,
      'order_line': 7,
      'provider': 'qareeb',
      'kind': 'voucher',
      'option_label': 'ليبيانا 20 دينار',
      'outcome': outcome,
      'status': outcome == 'charged' ? 'confirmed' : 'submitted',
      'needs_attention': outcome == 'unknown',
      'error_code': outcome == 'unknown' ? 'indeterminate' : '',
      'receipt': {
        if (outcome == 'charged') 'code': '4821 7730 1956 2244',
        if (outcome == 'charged') 'serial': '009912001455',
        if (outcome == 'charged') 'instructions': 'اطلب *121*الرقم السري#',
      },
    });

Widget _success({
  InvoicePrintStatus printStatus = InvoicePrintStatus.printed,
  List<IntegrationChargeResult> recharges = const [],
  double changeDue = 0,
  SaleOrder order = _order,
  SaleType saleType = SaleType.standard,
  bool linksOn = false,
  bool owner = true,
}) => CheckoutSuccessView(
  order: order,
  saleType: saleType,
  printStatus: printStatus,
  recharges: recharges,
  changeDue: changeDue,
  onlineInvoicesEnabled: linksOn,
  onOpenSettings: owner ? () {} : null,
  scanToContinue: !CheckoutSuccessView.holdsOpen(recharges),
  onDone: () {},
  handlers: _handlers,
);

Widget _failure(SaleCheckoutOutcome outcome) => CheckoutFailureView(
  outcome: outcome,
  showLossAmounts: false,
  onRetry: () {},
  onEditPayment: () {},
  onReviewCart: () {},
);

Widget _surface(String state) => switch (state) {
  'working' => const CheckoutProgressView(
    saleType: SaleType.standard,
    total: 125,
    progress: PosCheckoutProgress(
      step: PosCheckoutStep.charge,
      prints: true,
      chargeLabels: ['ليبيانا 20 دينار'],
    ),
  ),
  'working-slow' => CheckoutProgressView(
    saleType: SaleType.standard,
    total: 125,
    progress: PosCheckoutProgress(
      step: PosCheckoutStep.charge,
      prints: true,
      chargeLabels: const ['ليبيانا 20 دينار'],
      chargeStartedAt: DateTime.now().subtract(const Duration(seconds: 23)),
    ),
  ),
  'success' => _success(owner: false),
  'success-change' => _success(changeDue: 5, owner: true),
  'success-link' => _success(
    changeDue: 15,
    linksOn: true,
    order: const SaleOrder(
      id: 42,
      status: 'paid',
      receiptNumber: 'R20261017000042',
      lines: [],
      payments: [],
      subtotal: 125,
      total: 125,
      publicInvoiceUrl: 'https://shop.dftr.ly/i/7Hq2xK',
    ),
  ),
  'success-card' => _success(recharges: [_card()]),
  'success-attention' => _success(
    recharges: [_card(outcome: 'unknown')],
    printStatus: InvoicePrintStatus.noPrinter,
  ),
  'success-credit' => _success(
    saleType: SaleType.credit,
    printStatus: InvoicePrintStatus.failed,
    order: const SaleOrder(
      id: 43,
      status: 'paid',
      receiptNumber: 'R20261017000043',
      lines: [],
      payments: [],
      subtotal: 340,
      total: 340,
      balanceDue: 240,
      saleType: SaleType.credit,
    ),
  ),
  'failure-credit' => _failure(
    const SaleCheckoutOutcome.creditLimitRejected(
      SaleCheckoutCreditLimitException(
        limit: 500,
        outstanding: 450,
        available: 50,
        newDebt: 240,
        projected: 690,
      ),
    ),
  ),
  'failure-stock' => _failure(
    const SaleCheckoutOutcome.stockRejected([
      SaleStockShortage(productName: 'قهوة البيت', requested: 3, available: 1),
      SaleStockShortage(productName: 'شاي أخضر', requested: 2, available: 0),
    ]),
  ),
  'failure-network' => _failure(
    const SaleCheckoutOutcome.failure(unanswered: true, reference: 'A41F09C2'),
  ),
  _ => Text('unknown screen: $state', textDirection: TextDirection.ltr),
};
