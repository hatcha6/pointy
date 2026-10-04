import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/purchase_submission.dart';
import 'package:pointy_frontend/src/data/repositories/printing_repository.dart';
import 'package:pointy_frontend/src/data/repositories/purchase_repository.dart';
import 'package:pointy_frontend/src/data/repositories/shop_settings_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/purchasing/views/purchase_order_details_screen.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

import '../../../shared/role_fixtures.dart';

/// A supplier exchange of goods bought by the carton.
///
/// A replacement line carries no unit — the server counts its quantity and
/// cost in single items (`_like_for_like_replacement`). The dialog defaulted
/// every replacement to 1 at the line's carton price, so exchanging a carton of
/// 24 took 24 bottles out and put 1 back, valued at a carton, while the money
/// said the swap was even. The replacement now mirrors what goes out.
void main() {
  testWidgets('one carton out brings 24 bottles back at the bottle cost', (
    tester,
  ) async {
    final repository = await _pumpOrder(tester);

    await _openExchange(tester);
    // What goes out is counted and priced by the carton, never "per piece".
    expect(find.textContaining('الكمية 3 كرتون'), findsOneWidget);
    expect(find.textContaining('48.00 د.ل لكل كرتون'), findsOneWidget);
    expect(find.textContaining('للقطعة'), findsNothing);
    // Bought by the carton, so the section says how a replacement is counted.
    expect(
      find.text(
        'تُدخَل كمية البديل وتكلفته بالوحدة الأساسية للصنف، لا بوحدة الشراء كالكرتون.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('إضافة عنصر').first);
    await tester.pumpAndSettle();

    expect(_text(tester, 'الكمية'), '24');
    expect(_text(tester, 'التكلفة'), '2.00');
    await tester.tap(find.text('تأكيد'));
    await tester.pumpAndSettle();

    final sent = repository.exchanged!.toJson();
    expect(sent['lines'], [
      {'line': 1, 'quantity': '1.000'},
    ]);
    expect(sent['replacement_lines'], [
      {'variant': 11, 'quantity': '24.000', 'unit_cost': '2.00'},
    ]);
  });

  testWidgets('the replacement is valued after the line discount', (
    tester,
  ) async {
    await _pumpOrder(tester, netUnitCost: '36.00');

    await _openExchange(tester);
    await tester.tap(find.byTooltip('إضافة عنصر').first);
    await tester.pumpAndSettle();

    // 36.00 a carton after discount ÷ 24.
    expect(_text(tester, 'التكلفة'), '1.50');
  });

  testWidgets('the mirror follows what goes out until the buyer edits it', (
    tester,
  ) async {
    final repository = await _pumpOrder(tester);

    await _openExchange(tester);
    await tester.tap(find.byTooltip('إضافة عنصر').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('إضافة عنصر').first);
    await tester.pumpAndSettle();
    expect(_text(tester, 'الكمية'), '48');

    await tester.enterText(find.widgetWithText(TextField, 'الكمية'), '30');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('إضافة عنصر').first);
    await tester.pumpAndSettle();

    // Edited, so it is the buyer's now: three cartons out, still 30 back.
    expect(_text(tester, 'الكمية'), '30');
    await tester.tap(find.text('تأكيد'));
    await tester.pumpAndSettle();
    expect(repository.exchanged!.toJson()['replacement_lines'], [
      {'variant': 11, 'quantity': '30.000', 'unit_cost': '2.00'},
    ]);
  });

  testWidgets('taking the carton back off takes its mirror with it', (
    tester,
  ) async {
    await _pumpOrder(tester);

    await _openExchange(tester);
    await tester.tap(find.byTooltip('إضافة عنصر').first);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'الكمية'), findsOneWidget);

    await tester.tap(find.byTooltip('إنقاص عنصر').first);
    await tester.pumpAndSettle();

    expect(find.widgetWithText(TextField, 'الكمية'), findsNothing);
    expect(
      find.text(
        'يظهر هنا بديل مطابق لكل عنصر صادر، ويمكنك تعديله أو إضافة غيره.',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}

String _text(WidgetTester tester, String label) {
  return tester
      .widget<TextField>(find.widgetWithText(TextField, label))
      .controller!
      .text;
}

Future<void> _openExchange(WidgetTester tester) async {
  await tester.tap(find.text('إجراءات أخرى'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('استبدال'));
  await tester.pumpAndSettle();
}

Future<_FakePurchaseRepository> _pumpOrder(
  WidgetTester tester, {
  String netUnitCost = '48.00',
}) async {
  await tester.binding.setSurfaceSize(const Size(1100, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final order = _receivedCartonOrder(netUnitCost: netUnitCost);
  final repository = _FakePurchaseRepository(order);
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('ar'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: PointyTheme.light(),
      home: PurchaseOrderDetailsScreen(
        purchaseRepository: repository,
        printingRepository: PrintingRepository(PosApiService()),
        shopSettingsRepository: ShopSettingsRepository(PosApiService()),
        initialOrder: order,
        capabilities: AuthorizationCapabilities.forUser(managerUser),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return repository;
}

class _FakePurchaseRepository extends PurchaseRepository {
  _FakePurchaseRepository(this.order) : super(PosApiService());

  final PurchaseOrder order;
  PurchaseAdjustmentDraft? exchanged;

  @override
  Future<Result<PurchaseOrder>> loadPurchaseOrder(int purchaseOrderId) async {
    return Ok(order);
  }

  @override
  Future<Result<PurchaseOrder>> exchangeItems({
    required int purchaseOrderId,
    required PurchaseAdjustmentDraft draft,
    String? idempotencyKey,
  }) async {
    exchanged = draft;
    return Ok(order);
  }
}

/// Three cartons of 24 at 48.00 a carton, received.
PurchaseOrder _receivedCartonOrder({required String netUnitCost}) {
  return PurchaseOrder.fromJson({
    'id': 400,
    'order_number': 'P20261004000400',
    'supplier': 14,
    'supplier_name': 'مورد المشروبات',
    'warehouse': 7,
    'status': 'received',
    'lines': [
      {
        'id': 1,
        'product': 10,
        'variant': 11,
        'product_name': 'مشروب غازي',
        'quantity': 3,
        'unit': 'carton',
        'unit_label': 'كرتون',
        'unit_factor': '24',
        'received_quantity': 3,
        'open_quantity': 0,
        'adjustable_quantity': 3,
        'unit_cost': '48.00',
        'net_unit_cost': netUnitCost,
        'line_total': '144.00',
      },
    ],
    'subtotal': '144.00',
    'total': '144.00',
    'paid_total': '144.00',
    'balance_due': '0.00',
    'payment_status': 'paid',
    'can_return': true,
    'can_refund': true,
    'can_exchange': true,
    'submitted_at': '2026-10-01T10:00:00Z',
    'received_at': '2026-10-02T10:00:00Z',
    'created_at': '2026-10-01T09:00:00Z',
  });
}
