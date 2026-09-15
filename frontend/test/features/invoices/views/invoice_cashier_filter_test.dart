import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/models/sale_order.dart';
import 'package:pointy_frontend/src/data/repositories/contact_repository.dart';
import 'package:pointy_frontend/src/data/repositories/printing_repository.dart';
import 'package:pointy_frontend/src/data/repositories/sale_repository.dart';
import 'package:pointy_frontend/src/data/repositories/shop_settings_repository.dart';
import 'package:pointy_frontend/src/data/repositories/user_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/invoices/view_models/invoice_list_view_model.dart';
import 'package:pointy_frontend/src/features/invoices/views/invoice_list_screen.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

import '../../../shared/fake_app_navigation.dart';

/// An owner wants one cashier's history: "show me Bahr's invoices", without
/// opening the drawer history and picking his shifts one at a time.
///
/// The filter is offered only to someone who sees shop-wide sales. For everyone
/// else the backend already scopes the invoices list to their own register
/// sessions, so a cashier filter could only narrow it to themselves or to
/// nothing — an control that cannot do anything is worse than no control.
void main() {
  testWidgets('an owner can narrow the invoices list to one cashier', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final requests = <Uri>[];
    final service = _service((request) async {
      requests.add(request.url);
      if (request.url.path.endsWith('/users/')) {
        return _json({
          'results': [
            _userJson(id: 4, username: 'bahr', name: 'بحر'),
            _userJson(id: 5, username: 'mkhalid', name: 'محمد خالد'),
          ],
          'next': null,
        });
      }
      return _json(const {'results': <Object?>[], 'next': null});
    });
    final viewModel = _viewModel(service);
    addTearDown(viewModel.dispose);

    await _pumpScreen(tester, service, viewModel, user: _manager());

    await tester.tap(find.text('الفلاتر'));
    await tester.pumpAndSettle();

    // The cashier section sits in the sheet, unset.
    expect(find.text('الكاشير'), findsOneWidget);
    expect(find.text('كل الكاشيرين'), findsOneWidget);

    await tester.tap(find.text('كل الكاشيرين'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('بحر'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('تأكيد'));
    await tester.pumpAndSettle();

    // Back in the filter sheet, now naming him.
    expect(find.text('بحر'), findsOneWidget);

    // The sheet's apply button is the last child of its ListView, so it is
    // built only once scrolled to — as a user on a phone would.
    await tester.dragUntilVisible(
      find.text('تطبيق'),
      find.byType(ListView).last,
      const Offset(0, -120),
    );
    await tester.tap(find.text('تطبيق'));
    await tester.pumpAndSettle();

    expect(viewModel.query.cashierId, 4);
    expect(viewModel.query.cashierName, 'بحر');
    final listRequest = requests.lastWhere(
      (uri) => uri.path.endsWith('/orders/'),
    );
    expect(listRequest.queryParameters['cashier'], '4');
  });

  testWidgets('a cashier is not offered a filter the backend would ignore', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final service = _service(
      (request) async => _json(const {'results': <Object?>[], 'next': null}),
    );
    final viewModel = _viewModel(service);
    addTearDown(viewModel.dispose);

    await _pumpScreen(tester, service, viewModel, user: _cashier());

    await tester.tap(find.text('الفلاتر'));
    await tester.pumpAndSettle();

    // The sheet opened — it just has no cashier section in it.
    expect(find.text('الفلاتر والترتيب'), findsOneWidget);
    expect(find.text('الكاشير'), findsNothing);
    expect(find.text('كل الكاشيرين'), findsNothing);
  });

  testWidgets('clearing the filters drops the cashier too', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final requests = <Uri>[];
    final service = _service((request) async {
      requests.add(request.url);
      return _json(const {'results': <Object?>[], 'next': null});
    });
    final viewModel = _viewModel(service);
    addTearDown(viewModel.dispose);
    await viewModel.applyQuery(
      const SaleOrderQuery(cashierId: 4, cashierName: 'بحر'),
    );

    await _pumpScreen(tester, service, viewModel, user: _manager());

    // The empty state offers the way out of a filter that emptied the list —
    // it has to count the cashier filter, or it would not appear at all.
    await tester.tap(find.text('مسح الفلاتر'));
    await tester.pumpAndSettle();

    expect(viewModel.query.cashierId, isNull);
    expect(
      requests.last.queryParameters.containsKey('cashier'),
      isFalse,
      reason: 'the cleared list must not still ask for one cashier',
    );
  });
}

http.Response _json(Object body) {
  return http.Response(
    jsonEncode(body),
    200,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );
}

Map<String, Object?> _userJson({
  required int id,
  required String username,
  required String name,
}) {
  return {
    'id': id,
    'username': username,
    'display_name': name,
    'first_name': name,
    'last_name': '',
    'email': '',
    'role': 'cashier',
    'permissions': <String>[],
    'is_active': true,
  };
}

PosUser _manager() {
  return PosUser.fromJson(const {
    'id': 1,
    'username': 'sufian',
    'display_name': 'سفيان',
    'email': '',
    'role': 'manager',
    'permissions': <String>[],
    'is_active': true,
  });
}

PosUser _cashier() {
  return PosUser.fromJson(const {
    'id': 2,
    'username': 'bahr',
    'display_name': 'بحر',
    'email': '',
    'role': 'cashier',
    'permissions': ['view_order'],
    'is_active': true,
  });
}

PosApiService _service(MockClientHandler handler) {
  return PosApiService(
    baseUrl: 'http://pointy.test/api',
    client: MockClient(handler),
  );
}

InvoiceListViewModel _viewModel(PosApiService service) {
  return InvoiceListViewModel(
    SaleRepository(service),
    PrintingRepository(service),
    ShopSettingsRepository(service),
  );
}

Future<void> _pumpScreen(
  WidgetTester tester,
  PosApiService service,
  InvoiceListViewModel viewModel, {
  required PosUser user,
}) async {
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
          capabilities: AuthorizationCapabilities.forUser(user),
          onOpenInvoice: (_) {},
          navigation: FakeAppNavigation(currentUser: user),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
