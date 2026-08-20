import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/repositories/payments_repository.dart';
import 'package:pointy_frontend/src/data/repositories/printing_repository.dart';
import 'package:pointy_frontend/src/data/repositories/shop_settings_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/payments/view_models/payments_hub_view_model.dart';
import 'package:pointy_frontend/src/features/payments/views/payments_hub_screen.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

import '../../../shared/fake_app_navigation.dart';

/// The Payments hub (الخزينة) is the shop's money ledger. Both of its tabs used
/// to state a load failure and stop — no control at all — and to explain a
/// filtered-to-nothing list with "amounts collected from customers will appear
/// here", which reads as "this shop has never taken a payment" to an accountant
/// who has merely picked last week.
void main() {
  testWidgets('a failed customer ledger offers a retry, not just a verdict', (
    tester,
  ) async {
    var isReachable = false;
    var requests = 0;
    final service = _service((request) async {
      if (request.url.path.endsWith('/payments/')) {
        requests++;
        return isReachable
            ? _json({
                'results': [_customerPaymentJson()],
                'next': null,
              })
            : http.Response('', 500);
      }
      return _emptyPage();
    });

    final viewModel = await _pumpHub(tester, service);

    expect(find.text('تعذّر تحميل المدفوعات'), findsOneWidget);
    final before = requests;

    isReachable = true;
    await tester.tap(find.text('إعادة المحاولة'));
    await tester.pumpAndSettle();

    expect(requests, greaterThan(before));
    expect(viewModel.hasCustomerError, isFalse);
    expect(find.text('تعذّر تحميل المدفوعات'), findsNothing);
  });

  testWidgets('a failed supplier ledger offers a retry too', (tester) async {
    var isReachable = false;
    var requests = 0;
    final service = _service((request) async {
      if (request.url.path.endsWith('/supplier-payments/')) {
        requests++;
        return isReachable ? _emptyPage() : http.Response('', 500);
      }
      return _emptyPage();
    });

    final viewModel = await _pumpHub(tester, service);

    await tester.tap(find.text('مدفوعات الموردين (صادر)'));
    await tester.pumpAndSettle();

    expect(find.text('تعذّر تحميل المدفوعات'), findsOneWidget);
    final before = requests;

    isReachable = true;
    await tester.tap(find.text('إعادة المحاولة'));
    await tester.pumpAndSettle();

    expect(requests, greaterThan(before));
    expect(viewModel.hasSupplierError, isFalse);
    expect(find.text('تعذّر تحميل المدفوعات'), findsNothing);
  });

  testWidgets(
    'a date window that matches nothing blames the filters, and one tap clears '
    'them in a single refetch',
    (tester) async {
      final windows = <bool>[];
      final service = _service((request) async {
        if (request.url.path.endsWith('/payments/')) {
          windows.add(request.url.queryParameters.containsKey('paid_at__gte'));
        }
        return _emptyPage();
      });

      final viewModel = await _pumpHub(tester, service);

      // Nothing is narrowing the list yet, so the hub keeps its original
      // "payments will show up here" guidance.
      expect(find.text('لا توجد مدفوعات عملاء'), findsOneWidget);
      expect(
        find.text('ستظهر هنا المبالغ المحصّلة من العملاء.'),
        findsOneWidget,
      );

      final now = DateTime.now();
      viewModel.setCustomerRange(
        DateTimeRange(start: now.subtract(const Duration(days: 7)), end: now),
      );
      await tester.pumpAndSettle();

      // Same blank list, but now the user emptied it — say so, and say it
      // without naming a search box this screen does not have.
      expect(find.text('لا توجد نتائج مطابقة للفلاتر المحددة'), findsOneWidget);
      expect(find.text('امسح الفلاتر لعرض القائمة كاملة.'), findsOneWidget);
      expect(find.text('ستظهر هنا المبالغ المحصّلة من العملاء.'), findsNothing);
      // This screen has no search box, so the shared "clear search and
      // filters" copy would point at a control that is not there.
      expect(find.text('مسح البحث والفلاتر'), findsNothing);
      expect(
        find.text(
          'تحقق من الكتابة، أو امسح البحث والفلاتر لعرض القائمة كاملة.',
        ),
        findsNothing,
      );

      expect(windows.last, isTrue, reason: 'the window reached the backend');
      final before = windows.length;

      await tester.tap(find.text('مسح الفلاتر'));
      await tester.pumpAndSettle();

      // Exactly one refetch: nulling the range and the method through their
      // own setters would fire two overlapping requests for the same ledger.
      expect(windows.length, before + 1);
      expect(windows.last, isFalse);
      expect(viewModel.customerRange, isNull);
      expect(
        find.text('ستظهر هنا المبالغ المحصّلة من العملاء.'),
        findsOneWidget,
      );
    },
  );
}

/// Pumps the real screen: both ledgers are private widgets fed by the screen's
/// `ListenableBuilder`, so pumping them bare would refetch and never repaint.
Future<PaymentsHubViewModel> _pumpHub(
  WidgetTester tester,
  PosApiService service,
) async {
  await tester.binding.setSurfaceSize(const Size(1100, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  late final PaymentsHubViewModel viewModel;
  await tester.runAsync(() async {
    viewModel = PaymentsHubViewModel(PaymentsRepository(service));
    await viewModel.loadCustomerPayments();
  });
  addTearDown(viewModel.dispose);

  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('ar'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: PointyTheme.light(),
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: PaymentsHubScreen(
          viewModel: viewModel,
          printingRepository: PrintingRepository(service),
          shopSettingsRepository: ShopSettingsRepository(service),
          capabilities: FakeAppNavigation(
            currentUser: _accountant(),
          ).capabilities,
          navigation: FakeAppNavigation(currentUser: _accountant()),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return viewModel;
}

PosApiService _service(MockClientHandler handler) {
  return PosApiService(
    baseUrl: 'http://pointy.test/api',
    client: MockClient(handler),
  );
}

http.Response _emptyPage() {
  return _json(const {'results': <Object?>[], 'next': null});
}

http.Response _json(Object body) {
  return http.Response(
    jsonEncode(body),
    200,
    headers: const {'content-type': 'application/json'},
  );
}

Map<String, Object?> _customerPaymentJson() {
  return const {
    'id': 5,
    'amount': '25',
    'method': 'cash',
    'paid_at': '2026-08-01T10:00:00Z',
    'order': 1,
    'order_number': 'INV-1',
    'customer_name': 'زبون',
  };
}

/// An accountant may read the money ledger, which is what gates the hub.
PosUser _accountant() {
  return PosUser.fromJson(const {
    'id': 3,
    'username': 'accountant',
    'display_name': 'المحاسب',
    'email': '',
    'role': 'accountant',
    'permissions': ['view_payment', 'purchasing.view_supplierpayment'],
    'is_active': true,
  });
}
