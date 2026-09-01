import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/data/models/sale_order.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/order/sale_order_details_content.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    locale: const Locale('ar'),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    theme: PointyTheme.light(),
    home: Scaffold(body: child),
  );
}

SaleOrder _creditInvoice({
  int? customer,
  String? customerName,
  bool canAssignCustomer = true,
}) {
  return SaleOrder(
    id: 7,
    receiptNumber: 'R20260701000007',
    status: 'open',
    customer: customer,
    customerName: customerName,
    lines: const [],
    payments: const [],
    subtotal: 7,
    total: 7,
    saleType: SaleType.credit,
    balanceDue: 7,
    paymentStatus: 'unpaid',
    canAssignCustomer: canAssignCustomer,
  );
}

SaleOrder _standardInvoice({
  required String status,
  required double returnedQuantity,
}) {
  return SaleOrder(
    id: 9,
    receiptNumber: 'R20260701000009',
    status: status,
    lines: [
      SaleOrderLine(
        id: 1,
        productId: 4,
        variantId: 4,
        productName: 'شاي',
        quantity: 2,
        returnedQuantity: returnedQuantity,
        returnableQuantity: 2 - returnedQuantity,
        unitPrice: 5,
        total: 10,
      ),
    ],
    payments: const [],
    subtotal: 10,
    total: 10,
    paymentStatus: 'paid',
  );
}

const _assignButton = ValueKey('assign_invoice_customer_button');
const _voidedCallout = ValueKey('voided_invoice_callout');

void main() {
  group('SaleOrder.fromJson', () {
    test('parses can_assign_customer and defaults it to false', () {
      final base = <String, Object?>{
        'id': 3,
        'status': 'open',
        'sale_type': 'credit',
        'lines': const <Object?>[],
        'payments': const <Object?>[],
        'subtotal': '7.00',
        'total': '7.00',
      };
      expect(
        SaleOrder.fromJson({
          ...base,
          'can_assign_customer': true,
        }).canAssignCustomer,
        isTrue,
      );
      expect(
        SaleOrder.fromJson({
          ...base,
          'can_assign_customer': false,
        }).canAssignCustomer,
        isFalse,
      );
      // An older backend without the flag must not surface the action.
      expect(SaleOrder.fromJson(base).canAssignCustomer, isFalse);
    });
  });

  group('SaleOrderDetailsContent assign-customer action', () {
    testWidgets('shows "change customer" and invokes the callback', (
      tester,
    ) async {
      SaleOrder? assigned;
      await tester.pumpWidget(
        _wrap(
          SaleOrderDetailsContent(
            order: _creditInvoice(customer: 12, customerName: 'مدين أصلي'),
            onAssignCustomer: (order) async {
              assigned = order;
              return true;
            },
          ),
        ),
      );

      expect(find.byKey(_assignButton), findsOneWidget);
      expect(find.text('تغيير العميل'), findsOneWidget);

      await tester.tap(find.byKey(_assignButton));
      await tester.pumpAndSettle();
      expect(assigned?.id, 7);
    });

    testWidgets('shows "assign customer" when the invoice has none', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          SaleOrderDetailsContent(
            order: _creditInvoice(),
            onAssignCustomer: (_) async => true,
          ),
        ),
      );

      expect(find.byKey(_assignButton), findsOneWidget);
      expect(find.text('تعيين عميل'), findsOneWidget);
    });

    testWidgets('hides the action once the server forbids it', (tester) async {
      await tester.pumpWidget(
        _wrap(
          SaleOrderDetailsContent(
            order: _creditInvoice(customer: 12, canAssignCustomer: false),
            onAssignCustomer: (_) async => true,
          ),
        ),
      );

      expect(find.byKey(_assignButton), findsNothing);
    });

    testWidgets('hides the action without a callback (no permission)', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(SaleOrderDetailsContent(order: _creditInvoice(customer: 12))),
      );

      expect(find.byKey(_assignButton), findsNothing);
    });
  });

  group('SaleOrderDetailsContent voided callout', () {
    testWidgets('explains why a voided invoice offers no return', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          SaleOrderDetailsContent(
            order: _standardInvoice(status: 'void', returnedQuantity: 2),
            onReturn: (_, _, _) async => true,
            onVoid: (_, _) async => true,
          ),
        ),
      );

      // The three adjustment actions drop out of the bar on a voided invoice…
      expect(find.text('إرجاع منتجات'), findsNothing);
      expect(find.text('إلغاء الفاتورة'), findsNothing);
      // …so the callout has to say why, instead of leaving a blank action bar.
      expect(find.byKey(_voidedCallout), findsOneWidget);
      expect(find.text('لا يمكن الإرجاع من هذه الفاتورة'), findsOneWidget);
    });

    testWidgets(
      'stays out of the way of an invoice that can still be returned',
      (tester) async {
        await tester.pumpWidget(
          _wrap(
            SaleOrderDetailsContent(
              order: _standardInvoice(status: 'paid', returnedQuantity: 0),
              onReturn: (_, _, _) async => true,
              onVoid: (_, _) async => true,
            ),
          ),
        );

        expect(find.byKey(_voidedCallout), findsNothing);
        expect(find.text('إرجاع منتجات'), findsOneWidget);
      },
    );
  });

  /// The void dialog asks *why* before it cancels an invoice, so it carries a
  /// text controller. That controller used to be created in the calling method
  /// and never disposed at all — the mirror image of disposing it too early,
  /// and one edit away from the crash: `showDialog` completes when the route is
  /// popped, while the exit animation still has the field mounted, so any
  /// caller that "fixed" the leak with a `dispose()` after the await would
  /// rebuild a `TextField` against a dead controller and take the screen down.
  /// The dialog owns it now; these open and close it the way a cashier does.
  group('SaleOrderDetailsContent void dialog', () {
    testWidgets('cancelling it leaves the screen standing', (tester) async {
      String? voidedWith;
      await tester.pumpWidget(
        _wrap(
          SaleOrderDetailsContent(
            order: _standardInvoice(status: 'paid', returnedQuantity: 0),
            onVoid: (_, reason) async {
              voidedWith = reason;
              return true;
            },
            popOnSuccessfulAdjustment: false,
          ),
        ),
      );

      await _openVoidDialog(tester);
      expect(find.byType(AlertDialog), findsOneWidget);

      await tester.tap(find.text('إلغاء'));
      await tester.pumpAndSettle();

      // Backing out voids nothing, and the field leaves with the route.
      expect(voidedWith, isNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('cancelling after typing a reason is clean', (tester) async {
      await tester.pumpWidget(
        _wrap(
          SaleOrderDetailsContent(
            order: _standardInvoice(status: 'paid', returnedQuantity: 0),
            onVoid: (_, _) async => true,
            popOnSuccessfulAdjustment: false,
          ),
        ),
      );

      await _openVoidDialog(tester);
      await tester.enterText(_voidReasonField, 'الزبون تراجع');
      await tester.pumpAndSettle();

      await tester.tap(find.text('إلغاء'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });

    testWidgets('confirming carries the trimmed reason through', (
      tester,
    ) async {
      String? voidedWith;
      await tester.pumpWidget(
        _wrap(
          SaleOrderDetailsContent(
            order: _standardInvoice(status: 'paid', returnedQuantity: 0),
            onVoid: (_, reason) async {
              voidedWith = reason;
              return true;
            },
            popOnSuccessfulAdjustment: false,
          ),
        ),
      );

      await _openVoidDialog(tester);
      await tester.enterText(_voidReasonField, '  الزبون تراجع  ');
      await tester.tap(find.text('تأكيد'));
      await tester.pumpAndSettle();

      expect(voidedWith, 'الزبون تراجع');
      expect(tester.takeException(), isNull);
    });

    testWidgets('opening and cancelling it twice is clean', (tester) async {
      await tester.pumpWidget(
        _wrap(
          SaleOrderDetailsContent(
            order: _standardInvoice(status: 'paid', returnedQuantity: 0),
            onVoid: (_, _) async => true,
            popOnSuccessfulAdjustment: false,
          ),
        ),
      );

      for (var i = 0; i < 2; i += 1) {
        await _openVoidDialog(tester);
        await tester.tap(find.text('إلغاء'));
        await tester.pumpAndSettle();
      }

      expect(tester.takeException(), isNull);
    });
  });
}

/// The reason box inside the void dialog.
final Finder _voidReasonField = find.descendant(
  of: find.byType(AlertDialog),
  matching: find.byType(TextField),
);

Future<void> _openVoidDialog(WidgetTester tester) async {
  final trigger = find.text('إلغاء الفاتورة');
  await tester.ensureVisible(trigger);
  await tester.pumpAndSettle();
  await tester.tap(trigger);
  await tester.pumpAndSettle();
}
