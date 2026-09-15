import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/contact_repository.dart';
import 'package:pointy_frontend/src/data/repositories/printing_repository.dart';
import 'package:pointy_frontend/src/data/repositories/sale_repository.dart';
import 'package:pointy_frontend/src/data/repositories/shop_settings_repository.dart';
import 'package:pointy_frontend/src/data/repositories/user_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/invoices/view_models/invoice_list_view_model.dart';
import 'package:pointy_frontend/src/features/invoices/views/invoice_details_screen.dart';
import 'package:pointy_frontend/src/features/invoices/views/invoice_list_screen.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

import '../../../shared/fake_app_navigation.dart';

/// Two things an owner does with the invoices list, both of which used to fail.
///
/// Clicking down the list: every row is a summary — the list payload carries a
/// line COUNT and no line items — and the detail pane rendered that summary as
/// if it were the document. The first invoice opened looking empty, and the
/// next one clicked did not appear at all until someone pressed refresh.
///
/// Asking who rang a sale up: the answer lived only in the Z-Report, so an
/// owner looking at a suspicious invoice had to go and reconcile shifts by
/// hand. The invoice now names the cashier and the drawer session, and both
/// are links to the record behind them.
void main() {
  testWidgets('clicking an invoice loads its lines without pressing refresh', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final detailRequests = <int>[];
    final service = _service((request) async {
      final path = request.url.path;
      if (path.endsWith('/orders/')) {
        return _json({
          'results': [
            _listRow(id: 11, number: '1011'),
            _listRow(id: 12, number: '1012'),
          ],
          'next': null,
        });
      }
      final detailId = int.parse(
        path.split('/').where((p) => p.isNotEmpty).last,
      );
      detailRequests.add(detailId);
      return _json(_detail(id: detailId, number: '10$detailId'));
    });
    final viewModel = _listViewModel(service);
    addTearDown(viewModel.dispose);

    await _pumpInvoices(tester, service, viewModel);

    await tester.tap(find.text('فاتورة 1011'));
    await tester.pumpAndSettle();

    // Opening the row fetched the real document, and its line items are on
    // screen — no refresh tap in between.
    expect(detailRequests, [11]);
    expect(find.text('صنف الفاتورة 11'), findsOneWidget);

    await tester.tap(find.text('فاتورة 1012'));
    await tester.pumpAndSettle();

    // The pane follows the selection instead of staying on the first invoice.
    expect(detailRequests, [11, 12]);
    expect(find.text('صنف الفاتورة 12'), findsOneWidget);
    expect(find.text('صنف الفاتورة 11'), findsNothing);
  });

  testWidgets('the invoice names its cashier and drawer session, as links', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final service = _service((request) async {
      if (request.url.path.endsWith('/orders/')) {
        return _json({
          'results': [_listRow(id: 11, number: '1011')],
          'next': null,
        });
      }
      return _json(_detail(id: 11, number: '1011'));
    });
    final viewModel = _listViewModel(service);
    addTearDown(viewModel.dispose);

    final openedCashiers = <int>[];
    final openedSessions = <int>[];
    await _pumpInvoices(
      tester,
      service,
      viewModel,
      onOpenCashier: openedCashiers.add,
      onOpenRegisterSession: openedSessions.add,
    );

    await tester.tap(find.text('فاتورة 1011'));
    await tester.pumpAndSettle();

    expect(find.text('الكاشير'), findsOneWidget);
    expect(find.text('سالم'), findsOneWidget);
    expect(find.text('RS-7'), findsOneWidget);

    await tester.tap(find.text('سالم'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('RS-7'));
    await tester.pumpAndSettle();

    expect(openedCashiers, [4]);
    expect(openedSessions, [7]);
  });

  testWidgets('with no link handlers the attribution is plain text', (
    tester,
  ) async {
    // This is how a user without the rights to open a profile or the drawer
    // history sees it: the shell hands the details view null handlers rather
    // than a link that would land on a denied screen.
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final service = _service((request) async {
      if (request.url.path.endsWith('/orders/')) {
        return _json({
          'results': [_listRow(id: 11, number: '1011')],
          'next': null,
        });
      }
      return _json(_detail(id: 11, number: '1011'));
    });
    final viewModel = _listViewModel(service);
    addTearDown(viewModel.dispose);

    await _pumpInvoices(tester, service, viewModel);

    await tester.tap(find.text('فاتورة 1011'));
    await tester.pumpAndSettle();

    // The attribution still reads; it just does not pretend to be navigable.
    expect(find.text('سالم'), findsOneWidget);
    expect(find.byIcon(Icons.open_in_new), findsNothing);
  });
}

http.Response _json(Object? body) {
  return http.Response(
    jsonEncode(body),
    200,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );
}

/// What the invoices list serves: totals and attribution, no line items.
Map<String, Object?> _listRow({required int id, required String number}) {
  return {
    'id': id,
    'receipt_number': number,
    'status': 'paid',
    'sale_type': 'standard',
    'payment_status': 'paid',
    'register_session': 7,
    'register_session_number': 'RS-7',
    'cashier': 4,
    'cashier_name': 'سالم',
    'line_count': 1,
    'payments': <Object?>[],
    'subtotal': '10.00',
    'discount_total': '0.00',
    'total': '10.00',
    'amount_paid': '10.00',
    'balance_due': '0.00',
    'created_at': '2026-09-15T09:00:00Z',
  };
}

/// What the detail endpoint serves: the same order, with its lines.
Map<String, Object?> _detail({required int id, required String number}) {
  return {
    ..._listRow(id: id, number: number),
    'lines': [
      {
        'id': id * 100,
        'product_name': 'صنف الفاتورة $id',
        'quantity': '1',
        'unit_price': '10.00',
        'line_total': '10.00',
      },
    ],
  };
}

PosApiService _service(MockClientHandler handler) {
  return PosApiService(
    baseUrl: 'http://pointy.test/api',
    client: MockClient(handler),
  );
}

InvoiceListViewModel _listViewModel(PosApiService service) {
  return InvoiceListViewModel(
    SaleRepository(service),
    PrintingRepository(service),
    ShopSettingsRepository(service),
  );
}

Future<void> _pumpInvoices(
  WidgetTester tester,
  PosApiService service,
  InvoiceListViewModel viewModel, {
  ValueChanged<int>? onOpenCashier,
  ValueChanged<int>? onOpenRegisterSession,
}) async {
  final user = PosUser.fromJson(const {
    'id': 1,
    'username': 'manager',
    'display_name': 'مدير النظام',
    'email': '',
    'role': 'manager',
    'permissions': <String>[],
    'is_active': true,
  });
  final capabilities = AuthorizationCapabilities.forUser(user);

  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('ar'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: PointyTheme.light(),
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: InvoiceListScreen(
          viewModel: viewModel,
          contactRepository: ContactRepository(service),
          userRepository: UserRepository(service),
          capabilities: capabilities,
          onOpenInvoice: (_) {},
          navigation: FakeAppNavigation(currentUser: user),
          detailPaneBuilder: (context, order) => InvoiceDetailsView(
            saleRepository: SaleRepository(service),
            printingRepository: PrintingRepository(service),
            shopSettingsRepository: ShopSettingsRepository(service),
            catalogRepository: CatalogRepository(service),
            contactRepository: ContactRepository(service),
            initialOrder: order,
            capabilities: capabilities,
            onOpenCashier: onOpenCashier,
            onOpenRegisterSession: onOpenRegisterSession,
            showHeader: true,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
