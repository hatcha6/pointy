import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/printing_repository.dart';
import 'package:pointy_frontend/src/data/repositories/sale_repository.dart';
import 'package:pointy_frontend/src/data/repositories/shop_settings_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/returns_exchange/views/returns_exchange_lookup_screen.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

import '../../shared/fake_app_navigation.dart';

/// The returns desk's one search box. A customer brings the receipt, the
/// goods, or neither: a scanned product lists the sales it was on inside the
/// shop's return window, the cashier picks theirs, and the invoice opens with
/// that line already chosen in the return dialog.
void main() {
  testWidgets(
    'a scanned product lists its sales and opens the picked one ready to return',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final searches = <String>[];
      Map<String, Object?>? returnBody;
      final service = _service((request) async {
        final path = request.url.path;
        if (path.endsWith('/orders/return-search/')) {
          searches.add(request.url.queryParameters['q'] ?? '');
          return _json(
            _searchResult(
              lines: [
                _soldLine(id: 1000, order: 100, receipt: 'R20261009000100'),
                _soldLine(
                  id: 2000,
                  order: 200,
                  receipt: 'R20261008000090',
                  matchedBy: 'serial',
                  matchedCode: '356938035643809',
                ),
              ],
            ),
          );
        }
        if (path.endsWith('/orders/100/return-items/')) {
          returnBody = jsonDecode(request.body) as Map<String, Object?>;
          return _json(_invoice(id: 100, returned: 1));
        }
        if (path.endsWith('/orders/100/')) {
          return _json(_invoice(id: 100));
        }
        return http.Response('{}', 404);
      });

      await _pumpDesk(tester, service);
      await tester.enterText(find.byType(TextField).first, '6241000123456');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();

      expect(searches, ['6241000123456']);
      expect(find.text('منتجات مباعة'), findsOneWidget);
      expect(
        find.text('المنتجات المباعة خلال آخر 3 يوم — مدة الإرجاع المسموحة'),
        findsOneWidget,
      );
      expect(find.text('أرز النجمة'), findsNWidgets(2));
      // The handset found by its IMEI says so.
      expect(find.text('الرقم التسلسلي 356938035643809'), findsOneWidget);

      await tester.tap(find.textContaining('R20261009000100'));
      await tester.pumpAndSettle();

      // The row is not the document: the invoice was fetched and its other
      // line is there too.
      expect(find.text('سكر'), findsOneWidget);
      expect(find.text('رجوع إلى نتائج البحث'), findsOneWidget);

      await tester.tap(find.text('إرجاع منتجات').first);
      await tester.pumpAndSettle();
      // Confirming straight away returns the line the cashier picked — one of
      // it — and nothing else.
      await tester.tap(find.text('تأكيد'));
      await tester.pumpAndSettle(const Duration(seconds: 1));

      expect(returnBody?['lines'], [
        {'line': 1000, 'quantity': '1'},
      ]);

      // Going back searches again, so a quantity just returned is not offered
      // twice.
      await tester.tap(find.text('رجوع إلى نتائج البحث'));
      await tester.pumpAndSettle();
      expect(searches, ['6241000123456', '6241000123456']);
      expect(find.text('منتجات مباعة'), findsOneWidget);
    },
  );

  testWidgets('the end of a receipt number lists the invoices it can mean', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final service = _service((request) async {
      return _json(
        _searchResult(
          invoices: [
            _invoiceRow(id: 100, receipt: 'R20261009000123'),
            _invoiceRow(
              id: 101,
              receipt: 'R202610091000123',
              hasReturnableItems: false,
            ),
          ],
        ),
      );
    });

    await _pumpDesk(tester, service);
    await tester.enterText(find.byType(TextField).first, '123');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(find.text('فواتير'), findsOneWidget);
    expect(find.text('R20261009000123'), findsOneWidget);
    expect(find.text('R202610091000123'), findsOneWidget);
    // An invoice with nothing left to return is still shown, and says so.
    expect(find.text('لا شيء متبقٍ للإرجاع'), findsOneWidget);
  });

  testWidgets('a closed return window explains why goods find nothing', (
    tester,
  ) async {
    final service = _service((request) async {
      return _json(_searchResult(windowHours: 0));
    });

    await _pumpDesk(tester, service);
    await tester.enterText(find.byType(TextField).first, 'حليب');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(find.text('لم يُعثر على فاتورة أو منتج مباع.'), findsOneWidget);
    expect(
      find.text(
        'مدة الإرجاع في الإعدادات صفر، فلا يمكن البحث بالمنتج أو بهاتف '
        'العميل. ابحث برقم الفاتورة.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('an invoice that fails to open leaves the list in place', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final service = _service((request) async {
      if (request.url.path.endsWith('/orders/return-search/')) {
        return _json(
          _searchResult(
            lines: [_soldLine(id: 1000, order: 100, receipt: 'R1')],
          ),
        );
      }
      return http.Response('{"detail":"boom"}', 500);
    });

    await _pumpDesk(tester, service);
    await tester.enterText(find.byType(TextField).first, 'ارز');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('R1 •'));
    await tester.pumpAndSettle();

    expect(
      find.text('تعذّر فتح الفاتورة. تحقّق من الاتصال ثم أعد المحاولة.'),
      findsOneWidget,
    );
    expect(find.text('منتجات مباعة'), findsOneWidget);
  });
}

Future<void> _pumpDesk(WidgetTester tester, PosApiService service) async {
  final user = PosUser.fromJson(const {
    'id': 3,
    'username': 'desk',
    'display_name': 'مكتب المرتجعات',
    'email': '',
    'role': 'cashier',
    'permissions': <String>['sales.add_order', 'sales.process_return_lookup'],
    'is_active': true,
  });
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('ar'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: PointyTheme.light(),
      home: ReturnsExchangeLookupScreen(
        saleRepository: SaleRepository(service),
        printingRepository: PrintingRepository(service),
        shopSettingsRepository: ShopSettingsRepository(service),
        catalogRepository: CatalogRepository(service),
        capabilities: AuthorizationCapabilities.forUser(user),
        navigation: FakeAppNavigation(currentUser: user),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

PosApiService _service(MockClientHandler handler) {
  return PosApiService(
    baseUrl: 'http://pointy.test/api',
    client: MockClient(handler),
  );
}

http.Response _json(Object? body) {
  return http.Response(
    jsonEncode(body),
    200,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );
}

Map<String, Object?> _searchResult({
  List<Map<String, Object?>> invoices = const [],
  List<Map<String, Object?>> lines = const [],
  int windowHours = 72,
}) {
  return {
    'order': null,
    'invoices': invoices,
    'lines': lines,
    'lines_truncated': false,
    'window_hours': windowHours,
    'window_starts_at': '2026-10-07T09:00:00Z',
  };
}

Map<String, Object?> _soldLine({
  required int id,
  required int order,
  required String receipt,
  String matchedBy = 'barcode',
  String matchedCode = '',
}) {
  return {
    'id': id,
    'order': order,
    'receipt_number': receipt,
    'sold_at': '2026-10-09T09:10:00Z',
    'sale_type': 'standard',
    'customer_name': '',
    'cashier_name': 'سالم',
    'product': 1,
    'product_name': 'أرز النجمة',
    'variant_name': 'أرز النجمة',
    'unit_label': '',
    'quantity': 3,
    'returned_quantity': 0,
    'returnable_quantity': 3,
    'unit_price': '12.50',
    'discount_total': '0.00',
    'line_total': '37.50',
    'matched_by': matchedBy,
    'matched_code': matchedCode,
  };
}

Map<String, Object?> _invoiceRow({
  required int id,
  required String receipt,
  bool hasReturnableItems = true,
}) {
  return {
    'id': id,
    'receipt_number': receipt,
    'status': 'paid',
    'sale_type': 'standard',
    'register_session': 7,
    'cashier_name': 'سالم',
    'line_count': 1,
    'has_returnable_items': hasReturnableItems,
    'payments': const <Object?>[],
    'subtotal': '12.50',
    'total': '12.50',
    'created_at': '2026-10-09T09:10:00Z',
  };
}

Map<String, Object?> _invoice({required int id, int returned = 0}) {
  Map<String, Object?> line(int lineId, String name, int quantity) => {
    'id': lineId,
    'product': lineId,
    'product_name': name,
    'quantity': quantity,
    'returned_quantity': lineId == 1000 ? returned : 0,
    'returnable_quantity': quantity - (lineId == 1000 ? returned : 0),
    'unit_price': '12.50',
    'line_total': '37.50',
  };
  return {
    'id': id,
    'receipt_number': 'R20261009000100',
    'status': 'paid',
    'register_session': 7,
    'register_session_number': 'RS-7',
    'lines': [line(1000, 'أرز النجمة', 3), line(1001, 'سكر', 2)],
    'payments': [
      {
        'id': 900,
        'method': 'cash',
        'amount': '62.50',
        'commission_percent': '0.00',
        'commission_amount': '0.00',
        'external_reference': '',
        'created_at': '2026-10-09T09:10:00Z',
      },
    ],
    'subtotal': '62.50',
    'total': '62.50',
    'can_void': true,
    'can_return': true,
    'created_at': '2026-10-09T09:10:00Z',
    'updated_at': '2026-10-09T09:10:00Z',
  };
}
