import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/models/purchase_submission.dart';
import 'package:pointy_frontend/src/data/repositories/printing_repository.dart';
import 'package:pointy_frontend/src/data/repositories/purchase_repository.dart';
import 'package:pointy_frontend/src/data/repositories/shop_settings_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/purchasing/views/purchase_order_details_screen.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

import '../../../shared/role_fixtures.dart';

/// A delivered order the shop still owes on. Paying against it is
/// `purchasing.add_supplierpayment` on the server — which the buyer who ran
/// the order does not hold — so the footer offered them a button that could
/// only answer 403. Owing the supplier is no longer enough to be offered it.
void main() {
  testWidgets('a buyer is told what is owed but offered no payment', (
    tester,
  ) async {
    await _pumpOrder(
      tester,
      capabilitiesFor(UserRole.purchasingAgent, purchasingAgentPermissions),
    );

    // Hiding the button is not hiding the debt.
    expect(find.text('المتبقي للمورد'), findsWidgets);
    expect(find.text('تسجيل دفعة'), findsNothing);

    // Nor is it tucked in among the actions the buyer does hold.
    await tester.tap(find.text('إجراءات أخرى'));
    await tester.pumpAndSettle();
    expect(find.text('إرجاع'), findsOneWidget);
    expect(find.text('تسجيل دفعة'), findsNothing);
  });

  testWidgets('granting the payment permission offers the payment', (
    tester,
  ) async {
    await _pumpOrder(
      tester,
      capabilitiesFor(UserRole.purchasingAgent, {
        ...purchasingAgentPermissions,
        'purchasing.add_supplierpayment',
      }),
    );

    expect(find.text('تسجيل دفعة'), findsOneWidget);
  });

  testWidgets('a manager is offered it as the next step', (tester) async {
    await _pumpOrder(tester, AuthorizationCapabilities.forUser(managerUser));

    expect(find.text('تسجيل دفعة'), findsOneWidget);
  });
}

Future<void> _pumpOrder(
  WidgetTester tester,
  AuthorizationCapabilities capabilities,
) async {
  await tester.binding.setSurfaceSize(const Size(1100, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final order = _deliveredUnpaidOrder();
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('ar'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: PointyTheme.light(),
      home: PurchaseOrderDetailsScreen(
        purchaseRepository: _FakePurchaseRepository(order),
        printingRepository: PrintingRepository(PosApiService()),
        shopSettingsRepository: ShopSettingsRepository(PosApiService()),
        initialOrder: order,
        capabilities: capabilities,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _FakePurchaseRepository extends PurchaseRepository {
  _FakePurchaseRepository(this.order) : super(PosApiService());

  final PurchaseOrder order;

  @override
  Future<Result<PurchaseOrder>> loadPurchaseOrder(int purchaseOrderId) async {
    return Ok(order);
  }
}

/// Received in full, nothing paid: the state a supplier payment is for.
PurchaseOrder _deliveredUnpaidOrder() {
  return PurchaseOrder.fromJson(const {
    'id': 200,
    'order_number': 'P20260925000200',
    'supplier': 14,
    'supplier_name': 'مورد المدينة',
    'status': 'received',
    'lines': [
      {
        'id': 1,
        'product': 1,
        'product_name': 'قهوة البيت',
        'variant_sku': 'COF-001',
        'quantity': 2,
        'received_quantity': 2,
        'open_quantity': 0,
        'adjustable_quantity': 2,
        'unit_cost': '3.75',
        'line_total': '7.50',
      },
    ],
    'subtotal': '7.50',
    'total': '7.50',
    'paid_total': '0.00',
    'balance_due': '7.50',
    'payment_status': 'unpaid',
    'can_return': true,
    'can_refund': true,
    'can_exchange': true,
    'submitted_at': '2026-09-20T10:00:00Z',
    'received_at': '2026-09-21T10:00:00Z',
    'created_at': '2026-09-20T09:00:00Z',
  });
}
