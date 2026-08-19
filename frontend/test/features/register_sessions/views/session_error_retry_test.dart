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
import 'package:pointy_frontend/src/features/register_sessions/views/register_session_list.dart';
import 'package:pointy_frontend/src/features/register_sessions/views/session_orders.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

/// End of shift: the manager opens the drawer history to reconcile, and the LAN
/// hiccups. Every panel here used to state the failure and stop — no control at
/// all, on a screen whose only other way to re-ask is to leave and come back.
/// The summary tab beside them has always offered a retry; these three now
/// match it.
void main() {
  testWidgets('a failed session history offers a retry, not just a verdict', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    var isReachable = false;
    var historyRequests = 0;
    final service = _service((request) async {
      if (request.url.path.endsWith('/register-sessions/')) {
        historyRequests++;
        return isReachable
            ? _json({
                'results': [_sessionJson()],
                'next': null,
              })
            : http.Response('', 500);
      }
      return _json(const {'results': <Object?>[], 'next': null});
    });
    final viewModel = _viewModel(service);
    addTearDown(viewModel.dispose);
    await tester.runAsync(viewModel.loadSessions);

    await _pump(
      tester,
      viewModel,
      () => RegisterSessionList(
        viewModel: viewModel,
        capabilities: _capabilities(),
      ),
    );

    expect(find.text('تعذر تحميل سجل الجلسات.'), findsOneWidget);
    final before = historyRequests;

    isReachable = true;
    await tester.tap(find.text('إعادة المحاولة'));
    await tester.pumpAndSettle();

    expect(historyRequests, greaterThan(before));
    expect(viewModel.hasSessionLoadError, isFalse);
    expect(find.text('تعذر تحميل سجل الجلسات.'), findsNothing);
    expect(find.text('جلسة 12'), findsOneWidget);
  });

  testWidgets('a failed session sales load offers a retry', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    var isReachable = false;
    var orderRequests = 0;
    final service = _service((request) async {
      if (request.url.path.endsWith('/orders/')) {
        orderRequests++;
        return isReachable
            ? _json(const {'results': <Object?>[], 'next': null})
            : http.Response('', 500);
      }
      return _json({
        'results': [_sessionJson()],
        'next': null,
      });
    });
    final viewModel = await _selectSession(tester, service);
    addTearDown(viewModel.dispose);

    await _pump(
      tester,
      viewModel,
      () => SessionOrders(
        viewModel: viewModel,
        contactRepository: ContactRepository(service),
        capabilities: _capabilities(),
      ),
    );

    expect(find.text('تعذر تحميل مبيعات هذه الجلسة.'), findsOneWidget);
    final before = orderRequests;

    isReachable = true;
    await tester.tap(find.text('إعادة المحاولة'));
    await tester.pumpAndSettle();

    expect(orderRequests, greaterThan(before));
    expect(viewModel.hasOrderLoadError, isFalse);
    expect(find.text('تعذر تحميل مبيعات هذه الجلسة.'), findsNothing);
    // The retry landed on an empty shift, not on the failure state.
    expect(find.text('لا توجد مبيعات مسجلة في هذه الجلسة.'), findsOneWidget);
  });

  testWidgets('a failed cash movements load offers a retry', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    var isReachable = false;
    var movementRequests = 0;
    final service = _service((request) async {
      if (request.url.path.endsWith('/cash-movements/')) {
        movementRequests++;
        return isReachable
            ? _json(const {'results': <Object?>[], 'next': null})
            : http.Response('', 500);
      }
      if (request.url.path.endsWith('/register-sessions/')) {
        return _json({
          'results': [_sessionJson()],
          'next': null,
        });
      }
      return _json(const {'results': <Object?>[], 'next': null});
    });
    final viewModel = await _selectSession(tester, service);
    addTearDown(viewModel.dispose);

    await _pump(
      tester,
      viewModel,
      () => SessionOrders(
        viewModel: viewModel,
        contactRepository: ContactRepository(service),
        capabilities: _capabilities(),
      ),
    );

    await tester.tap(find.text('حركات النقد'));
    await tester.pumpAndSettle();

    expect(find.text('تعذر تحميل حركات النقد لهذه الجلسة.'), findsOneWidget);
    final before = movementRequests;

    isReachable = true;
    await tester.tap(find.text('إعادة المحاولة'));
    await tester.pumpAndSettle();

    expect(movementRequests, greaterThan(before));
    expect(viewModel.hasCashMovementLoadError, isFalse);
    expect(find.text('تعذر تحميل حركات النقد لهذه الجلسة.'), findsNothing);
    expect(find.text('لا توجد حركات نقد مسجلة في هذه الجلسة.'), findsOneWidget);
  });
}

/// Builds the view model and selects the one session in the history, so the
/// detail pane under test has a shift to render.
Future<RegisterSessionHistoryViewModel> _selectSession(
  WidgetTester tester,
  PosApiService service,
) async {
  final viewModel = _viewModel(service);
  await tester.runAsync(() async {
    await viewModel.loadSessions();
    await viewModel.selectSession(viewModel.sessions.single);
  });
  return viewModel;
}

http.Response _json(Object body) {
  return http.Response(
    jsonEncode(body),
    200,
    headers: const {'content-type': 'application/json'},
  );
}

Map<String, Object?> _sessionJson() {
  return const {
    'id': 12,
    'session_number': 12,
    'status': 'closed',
    'owner_name': '',
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

/// A cashier who may read a shift's orders but not shop settings, so the detail
/// pane shows the sales and cash-movement tabs without the manager summary.
AuthorizationCapabilities _capabilities() {
  return AuthorizationCapabilities.forUser(_user());
}

PosUser _user() {
  return PosUser.fromJson(const {
    'id': 2,
    'username': 'cashier',
    'display_name': 'أمين الصندوق',
    'email': '',
    'role': 'cashier',
    'permissions': ['view_order'],
    'is_active': true,
  });
}

/// Mirrors `RegisterSessionHistoryScreen`, which drives both panes through a
/// `ListenableBuilder` — without it a retry would refetch and never repaint.
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
