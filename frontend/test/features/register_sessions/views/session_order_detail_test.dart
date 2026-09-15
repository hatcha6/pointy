import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/repositories/contact_repository.dart';
import 'package:pointy_frontend/src/data/repositories/printing_repository.dart';
import 'package:pointy_frontend/src/data/repositories/register_session_repository.dart';
import 'package:pointy_frontend/src/data/repositories/sale_repository.dart';
import 'package:pointy_frontend/src/data/repositories/shop_settings_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/register_sessions/view_models/register_session_history_view_model.dart';
import 'package:pointy_frontend/src/features/register_sessions/views/session_orders.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

/// Two ways into a shift, both of which used to land somewhere wrong.
///
/// A manager tapping a sale in the shift's strip got the summary row rendered
/// as if it were the document — "no products in this invoice" on a sale that
/// plainly had some, and no return action, because returning is offered only
/// when a line still has something returnable on it.
///
/// A manager arriving from an invoice's drawer-session link wants that shift,
/// which is usually older than the first page of history — and the history
/// reload that runs alongside must not drop it.
void main() {
  testWidgets('opening a sale from the shift fetches the whole document', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final detailRequests = <String>[];
    final service = _service((request) async {
      final path = request.url.path;
      if (path.endsWith('/register-sessions/')) {
        return _json({
          'results': [_sessionJson(id: 12)],
          'next': null,
        });
      }
      if (path.contains('/orders')) {
        if (path.endsWith('/orders/')) {
          // The shift's strip: summary rows, no line items.
          return _json({
            'results': [_orderRow()],
            'next': null,
          });
        }
        detailRequests.add(path);
        return _json(_orderDetail());
      }
      return _json(const {'results': <Object?>[], 'next': null});
    });

    final viewModel = _viewModel(service);
    addTearDown(viewModel.dispose);
    await tester.runAsync(() async {
      await viewModel.loadSessions();
      await viewModel.selectSession(viewModel.sessions.single);
    });

    await _pump(
      tester,
      viewModel,
      () => SessionOrders(
        viewModel: viewModel,
        contactRepository: ContactRepository(service),
        capabilities: _capabilities(),
      ),
    );

    await tester.tap(find.text('إيصال 1011'));
    await tester.pumpAndSettle();

    expect(detailRequests, hasLength(1));
    expect(find.text('صنف المبيعة'), findsOneWidget);
    expect(find.text('لا توجد منتجات في هذه الفاتورة.'), findsNothing);
  });

  testWidgets('a deep-linked shift survives the history loading around it', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final service = _service((request) async {
      final path = request.url.path;
      // Page one of the history holds only recent shifts; 12 is months old.
      if (path.endsWith('/register-sessions/')) {
        return _json({
          'results': [_sessionJson(id: 99)],
          'next': null,
        });
      }
      if (path.endsWith('/register-sessions/12/')) {
        return _json(_sessionJson(id: 12));
      }
      return _json(const {'results': <Object?>[], 'next': null});
    });

    final viewModel = _viewModel(service);
    addTearDown(viewModel.dispose);

    await tester.runAsync(() async {
      expect(await viewModel.focusSession(12), isTrue);
    });

    expect(viewModel.selectedSession?.id, 12);
    expect(viewModel.sessions.map((session) => session.id), contains(12));

    // Refreshing the list re-reads a first page that still does not contain
    // this shift; the reviewer must not be thrown back to nothing selected.
    await tester.runAsync(viewModel.loadSessions);

    expect(viewModel.selectedSession?.id, 12);
    expect(viewModel.sessions.map((session) => session.id), contains(12));
  });

  // Plain `test`, not `testWidgets`: these two drive the view model only, and
  // the widget binding would additionally surface the bluetooth-printer
  // plugin's MissingPluginException as a test failure.
  test('arriving by deep link fetches the shift once, not twice', () async {
    // The screen's view model loads the history in its constructor while
    // initState focuses the linked shift; on a slow link the history lands
    // second, and its trailing "refresh what is selected" step used to re-read
    // orders, cash movements AND the summary that focusSession had just
    // fetched — three redundant requests, the heaviest of them the summary.
    final requests = <String>[];
    final service = _service((request) async {
      final path = request.url.path;
      requests.add(path);
      if (path.endsWith('/register-sessions/')) {
        await Future<void>.delayed(const Duration(milliseconds: 40));
        return _json({
          'results': [_sessionJson(id: 99)],
          'next': null,
        });
      }
      if (path.endsWith('/register-sessions/12/')) {
        return _json(_sessionJson(id: 12));
      }
      return _json(const {'results': <Object?>[], 'next': null});
    });

    final viewModel = _viewModel(service);
    addTearDown(viewModel.dispose);

    await viewModel.focusSession(12);
    // Long enough for the slow history page to land and run its tail.
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(
      requests.where((path) => path.endsWith('/summary/')).length,
      1,
      reason: 'the deep-linked shift must be summarised once: $requests',
    );
    expect(requests.where((path) => path.endsWith('/orders/')).length, 1);
    expect(
      requests.where((path) => path.endsWith('/cash-movements/')).length,
      1,
    );
  });

  test('refreshing still re-reads the shift on screen', () async {
    // The other side of the same coin: an open drawer keeps selling while it is
    // being reviewed, so the refresh button must still re-read the selection.
    final requests = <String>[];
    final service = _service((request) async {
      final path = request.url.path;
      requests.add(path);
      if (path.endsWith('/register-sessions/')) {
        return _json({
          'results': [_sessionJson(id: 12)],
          'next': null,
        });
      }
      if (path.endsWith('/register-sessions/12/')) {
        return _json(_sessionJson(id: 12));
      }
      return _json(const {'results': <Object?>[], 'next': null});
    });

    final viewModel = _viewModel(service);
    addTearDown(viewModel.dispose);

    await viewModel.focusSession(12);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    requests.clear();
    await viewModel.loadSessions();
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(
      requests.where((path) => path.endsWith('/summary/')).length,
      1,
      reason: 'refresh means refresh — the selection is re-read: $requests',
    );
  });

  testWidgets('a shift that cannot be loaded reports failure, not a blank', (
    tester,
  ) async {
    final service = _service((request) async {
      if (request.url.path.endsWith('/register-sessions/')) {
        return _json(const {'results': <Object?>[], 'next': null});
      }
      return http.Response('', 404);
    });
    final viewModel = _viewModel(service);
    addTearDown(viewModel.dispose);

    await tester.runAsync(() async {
      expect(await viewModel.focusSession(404), isFalse);
    });
    expect(viewModel.selectedSession, isNull);
  });
}

http.Response _json(Object body) {
  return http.Response(
    jsonEncode(body),
    200,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );
}

Map<String, Object?> _sessionJson({required int id}) {
  return {
    'id': id,
    'session_number': 'RS-$id',
    'status': 'closed',
    'owner_name': 'سالم',
    'opening_cash': '0',
    'closing_cash': null,
    'cash_sales_total': '0',
    'pay_in_total': '0',
    'pay_out_total': '0',
    'cash_refund_total': '0',
    'expected_cash': '0',
    'denomination_total': '0',
    'cash_variance': null,
    'has_cash_variance': false,
  };
}

Map<String, Object?> _orderRow() {
  return const {
    'id': 11,
    'receipt_number': '1011',
    'status': 'paid',
    'sale_type': 'standard',
    'payment_status': 'paid',
    'line_count': 1,
    'has_returnable_items': true,
    'payments': <Object?>[],
    'subtotal': '10.00',
    'discount_total': '0.00',
    'total': '10.00',
    'created_at': '2026-09-15T09:00:00Z',
  };
}

Map<String, Object?> _orderDetail() {
  return {
    ..._orderRow(),
    'lines': const [
      {
        'id': 1100,
        'product_name': 'صنف المبيعة',
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

RegisterSessionHistoryViewModel _viewModel(PosApiService service) {
  return RegisterSessionHistoryViewModel(
    RegisterSessionRepository(service),
    SaleRepository(service),
    printingRepository: PrintingRepository(service),
    shopSettingsRepository: ShopSettingsRepository(service),
  );
}

AuthorizationCapabilities _capabilities() {
  return AuthorizationCapabilities.forUser(
    PosUser.fromJson(const {
      'id': 2,
      'username': 'cashier',
      'display_name': 'أمين الصندوق',
      'email': '',
      'role': 'cashier',
      'permissions': ['view_order'],
      'is_active': true,
    }),
  );
}

Future<void> _pump(
  WidgetTester tester,
  RegisterSessionHistoryViewModel viewModel,
  Widget Function() builder,
) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('ar'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: PointyTheme.light(),
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          body: ListenableBuilder(
            listenable: viewModel,
            builder: (context, _) => builder(),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
