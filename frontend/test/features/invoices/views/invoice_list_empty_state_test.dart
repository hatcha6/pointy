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
import 'package:pointy_frontend/src/shared/components/components.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

import '../../../shared/fake_app_navigation.dart';

/// A customer comes back holding a receipt. The cashier searches, forgets that
/// last week's status filter is still on, and the list goes blank — saying only
/// "there are no invoices", which reads as "your shop has never sold anything".
/// And when the LAN drops mid-lookup, the same screen used to state the failure
/// with nothing to press. Both dead ends are what this locks out.
void main() {
  testWidgets('a filtered-to-nothing invoice list clears in one tap', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final requestedUrls = <Uri>[];
    final service = _service((request) async {
      requestedUrls.add(request.url);
      return http.Response(
        jsonEncode({'results': <Object?>[], 'next': null}),
        200,
        headers: const {'content-type': 'application/json'},
      );
    });
    final viewModel = _viewModel(service);
    addTearDown(viewModel.dispose);
    await viewModel.applyQuery(
      const SaleOrderQuery(
        search: '1042',
        status: SaleOrderStatusFilter.voided,
        customerId: 7,
        customerName: 'زبون',
      ),
    );

    await _pumpScreen(tester, service, viewModel);

    // Scoped to the empty state: the search field carries the term too.
    expect(
      find.descendant(
        of: find.byType(PointyEmptyState),
        matching: find.textContaining('1042'),
      ),
      findsOneWidget,
    );
    expect(find.text('لا توجد فواتير بعد.'), findsNothing);

    await tester.tap(find.text('مسح البحث والفلاتر'));
    await tester.pumpAndSettle();

    expect(viewModel.query.search, isEmpty);
    expect(viewModel.query.status, SaleOrderStatusFilter.all);
    expect(viewModel.query.customerId, isNull);
    final lastRequest = requestedUrls.last.queryParameters;
    expect(lastRequest.containsKey('status'), isFalse);
    expect(lastRequest.containsKey('customer'), isFalse);
    // With nothing left to clear, the screen falls back to the plain message.
    expect(find.text('لا توجد فواتير بعد.'), findsOneWidget);
    expect(find.text('مسح البحث والفلاتر'), findsNothing);
  });

  testWidgets('a failed invoice load offers a retry, not just a verdict', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    var attempts = 0;
    var isReachable = false;
    final service = _service((request) async {
      attempts++;
      if (!isReachable) {
        return http.Response('', 500);
      }
      return http.Response(
        jsonEncode({'results': <Object?>[], 'next': null}),
        200,
        headers: const {'content-type': 'application/json'},
      );
    });
    final viewModel = _viewModel(service);
    addTearDown(viewModel.dispose);
    await tester.runAsync(() => viewModel.loadInvoices());

    await _pumpScreen(tester, service, viewModel);

    expect(find.text('تعذر تحميل الفواتير.'), findsOneWidget);
    final attemptsBeforeRetry = attempts;

    isReachable = true;
    await tester.tap(find.text('إعادة المحاولة'));
    await tester.pumpAndSettle();

    expect(attempts, greaterThan(attemptsBeforeRetry));
    expect(viewModel.hasLoadError, isFalse);
    expect(find.text('تعذر تحميل الفواتير.'), findsNothing);
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
  InvoiceListViewModel viewModel,
) async {
  final user = PosUser.fromJson(const {
    'id': 1,
    'username': 'manager',
    'display_name': 'مدير النظام',
    'email': '',
    'role': 'manager',
    'permissions': <String>[],
    'is_active': true,
  });

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
