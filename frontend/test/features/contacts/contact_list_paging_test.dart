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
import 'package:pointy_frontend/src/data/repositories/purchase_repository.dart';
import 'package:pointy_frontend/src/data/repositories/shop_settings_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/contacts/view_models/contact_management_view_model.dart';
import 'package:pointy_frontend/src/features/contacts/views/contact_management_screen.dart';
import 'package:pointy_frontend/src/shared/components/components.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

import '../../shared/fake_app_navigation.dart';

/// A shop with more contacts than fit on one page scrolls to the bottom of the
/// list and waits for the next page.
///
/// The failure that prompted these: a load-more request that failed cleared
/// `hasMore`, which ends pagination for the life of the view model — and that
/// view model lives as long as the app. One dropped request on a shop LAN and
/// the contacts list was frozen at its first 50 rows, scrolling forever with
/// nothing arriving and no way to ask again short of re-login.
void main() {
  for (final size in const [Size(520, 900), Size(1400, 900)]) {
    testWidgets('customers page in as the list is scrolled @${size.width}', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final requested = <Uri>[];
      final service = _service((request) async => _respond(request, requested));
      final viewModel = ContactManagementViewModel(ContactRepository(service));
      addTearDown(viewModel.dispose);
      await _pumpScreen(tester, service, viewModel);

      expect(viewModel.customers, hasLength(_pageSize));
      expect(viewModel.hasMoreCustomers, isTrue);

      await _scrollToBottom(tester);

      expect(
        _pagesRequested(requested, 'customers'),
        containsAll(<String>['1', '2']),
        reason: 'the second page was never requested',
      );
      expect(viewModel.customers.length, greaterThan(_pageSize));
    });

    testWidgets('suppliers page in as the list is scrolled @${size.width}', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final requested = <Uri>[];
      final service = _service((request) async => _respond(request, requested));
      final viewModel = ContactManagementViewModel(ContactRepository(service));
      addTearDown(viewModel.dispose);
      await _pumpScreen(tester, service, viewModel);

      await tester.tap(find.text('الموردون'));
      await tester.pumpAndSettle();
      await _scrollToBottom(tester);

      expect(
        _pagesRequested(requested, 'suppliers'),
        containsAll(<String>['1', '2']),
        reason: 'the second page was never requested',
      );
      expect(viewModel.suppliers.length, greaterThan(_pageSize));
    });
  }

  testWidgets('a page that fails is offered again, not abandoned', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final requested = <Uri>[];
    var reachable = false;
    final service = _service((request) async {
      final page =
          int.tryParse(request.url.queryParameters['page'] ?? '1') ?? 1;
      if (request.url.path.endsWith('/customers/') && page > 1 && !reachable) {
        requested.add(request.url);
        return http.Response('', 503);
      }
      return _respond(request, requested);
    });
    final viewModel = ContactManagementViewModel(ContactRepository(service));
    addTearDown(viewModel.dispose);
    await _pumpScreen(tester, service, viewModel);

    await _scrollToBottom(tester);

    // The rows already fetched stay put, and the shop is not told it has no
    // more customers — it was the request that failed, not the shop's books.
    expect(viewModel.customers, hasLength(_pageSize));
    expect(viewModel.hasMoreCustomers, isTrue);
    expect(viewModel.customerLoadMoreFailed, isTrue);

    // Whatever dropped the request is over. The list offers a retry at its end
    // rather than silently refusing to grow.
    reachable = true;
    final requestsBeforeRetry = requested.length;
    await tester.tap(find.text('إعادة المحاولة'));
    await tester.pumpAndSettle();

    expect(requested.length, greaterThan(requestsBeforeRetry));
    expect(viewModel.customerLoadMoreFailed, isFalse);
    expect(viewModel.customers.length, greaterThan(_pageSize));

    // And the automatic trigger is live again: scrolling on pages in as before.
    await _scrollToBottom(tester);
    expect(viewModel.customers.length, _pageSize * _totalPages);
    expect(viewModel.hasMoreCustomers, isFalse);
  });
}

const _pageSize = 50;
const _totalPages = 4;

List<String?> _pagesRequested(List<Uri> requested, String kind) {
  return requested
      .where((uri) => uri.path.endsWith('/$kind/'))
      .map((uri) => uri.queryParameters['page'])
      .toList();
}

/// Rides the list to its end the way a reader does — each arriving page moves
/// the bottom further away, so this keeps going until it stops moving.
Future<void> _scrollToBottom(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    final scrollable = find
        .ancestor(
          of: find.byType(PointyDataRow).first,
          matching: find.byType(Scrollable),
        )
        .first;
    final position = tester.state<ScrollableState>(scrollable).position;
    if (position.pixels == position.maxScrollExtent && i > 0) {
      break;
    }
    position.jumpTo(position.maxScrollExtent);
    await tester.pump();
    await tester.pumpAndSettle();
  }
}

http.Response _respond(http.Request request, List<Uri> requested) {
  requested.add(request.url);
  final page = int.tryParse(request.url.queryParameters['page'] ?? '1') ?? 1;
  final isSuppliers = request.url.path.endsWith('/suppliers/');
  final results = [
    for (var index = 0; index < _pageSize; index++)
      isSuppliers
          ? _supplierJson((page - 1) * _pageSize + index)
          : _customerJson((page - 1) * _pageSize + index),
  ];
  return http.Response(
    jsonEncode({
      'count': _pageSize * _totalPages,
      'next': page < _totalPages ? 'http://pointy.test/api/x?page=$page' : null,
      'results': results,
    }),
    200,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );
}

Map<String, Object?> _customerJson(int index) {
  return {
    'id': index + 1,
    'customer_number': 'C-${(index + 1).toString().padLeft(4, '0')}',
    'full_name': 'زبون رقم ${index + 1}',
    'phone': '09${(index + 1).toString().padLeft(8, '0')}',
    'email': '',
    'gender': '',
    'marketing_consent': false,
    'notes': '',
    'is_active': true,
  };
}

Map<String, Object?> _supplierJson(int index) {
  return {
    'id': index + 1,
    'name': 'مورد رقم ${index + 1}',
    'contact_name': '',
    'phone': '09${(index + 1).toString().padLeft(8, '0')}',
    'email': '',
    'address': '',
    'notes': '',
    'is_active': true,
  };
}

PosApiService _service(MockClientHandler handler) {
  return PosApiService(
    baseUrl: 'http://pointy.test/api',
    client: MockClient(handler),
  );
}

Future<void> _pumpScreen(
  WidgetTester tester,
  PosApiService service,
  ContactManagementViewModel viewModel,
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
        child: ContactManagementScreen(
          viewModel: viewModel,
          purchaseRepository: PurchaseRepository(service),
          printingRepository: PrintingRepository(service),
          shopSettingsRepository: ShopSettingsRepository(service),
          navigation: FakeAppNavigation(currentUser: user),
          capabilities: AuthorizationCapabilities.forUser(user),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
