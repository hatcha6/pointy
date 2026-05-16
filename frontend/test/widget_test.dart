import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';

import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/models/product.dart';
import 'package:pointy_frontend/src/app.dart';
import 'package:pointy_frontend/src/data/repositories/user_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/catalog/views/product_details_screen.dart';
import 'package:pointy_frontend/src/features/pos/views/register_session_close_sheet.dart';
import 'package:pointy_frontend/src/features/users/view_models/user_management_view_model.dart';
import 'package:pointy_frontend/src/features/users/views/user_management_screen.dart';
import 'package:pointy_frontend/src/shared/infinite_scroll_grid.dart';
import 'package:pointy_frontend/src/shared/product_tile.dart';

void main() {
  testWidgets('checkout posts cart lines and clears cart on success', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    Map<String, Object?>? checkoutBody;

    await tester.pumpWidget(
      PointyApp(
        apiService: _mockApiService(
          onCheckout: (request) {
            checkoutBody = jsonDecode(request.body) as Map<String, Object?>;
          },
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await tester.tap(find.text('بدء الجلسة'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await tester.tap(find.byType(ProductTile).first);
    await tester.pump();
    await tester.tap(find.byType(ProductTile).first);
    await tester.pump();

    await tester.tap(find.text('ادفع د.ل 7.00'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(checkoutBody, isNotNull);
    expect(checkoutBody?['payment_method'], 'cash');
    expect(checkoutBody?['amount_received'], '7.00');
    expect(checkoutBody?['lines'], [
      {'product': 1, 'quantity': 2},
    ]);
    expect(find.text('لا توجد عناصر في السلة'), findsOneWidget);
    expect(find.text('تم تسجيل البيع. رقم الإيصال: R-100'), findsOneWidget);
  });

  testWidgets('checkout keeps cart and shows error on failure', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      PointyApp(apiService: _mockApiService(checkoutStatusCode: 400)),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await tester.tap(find.text('بدء الجلسة'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await tester.tap(find.byType(ProductTile).first);
    await tester.pump();

    await tester.tap(find.text('ادفع د.ل 3.50'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('ادفع د.ل 3.50'), findsOneWidget);
    expect(
      find.text('تعذر تسجيل البيع. تحقق من جلسة الدرج وحاول مرة أخرى.'),
      findsOneWidget,
    );
    expect(find.text('لا توجد عناصر في السلة'), findsNothing);
  });

  testWidgets('register gate starts a session before showing POS', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(PointyApp(apiService: _mockApiService()));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('نقطة البيع'), findsOneWidget);
    expect(find.text('جلسة الدرج'), findsOneWidget);
    expect(find.text('نقدية الافتتاح'), findsOneWidget);

    await tester.tap(find.text('بدء الجلسة'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('البيع الحالي'), findsOneWidget);
    expect(find.text('جلسة RS-1'), findsOneWidget);

    expect(find.byType(ProductTile), findsWidgets);

    await tester.tap(find.byType(ProductTile).first);
    await tester.pump();

    expect(find.text('ادفع د.ل 3.50'), findsOneWidget);
    expect(find.byIcon(Icons.delete_outline), findsOneWidget);
  });

  testWidgets('catalog screen exposes the product creation form', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(PointyApp(apiService: _mockApiService()));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tester.tap(find.text('المنتجات').last);
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('إدارة المنتجات'), findsOneWidget);
    expect(find.text('إضافة منتج'), findsOneWidget);
    expect(find.text('منتج جديد'), findsNothing);

    await tester.tap(find.text('إضافة منتج'));
    await tester.pumpAndSettle();

    expect(find.text('منتج جديد'), findsOneWidget);
    expect(find.text('اسم المنتج'), findsOneWidget);
    expect(find.text('رمز المنتج'), findsOneWidget);
    expect(find.text('إنشاء المنتج'), findsOneWidget);
  });

  testWidgets('POS screen exposes reusable search and ordering controls', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(PointyApp(apiService: _mockApiService()));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await tester.tap(find.text('بدء الجلسة'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('ابحث باسم المنتج أو الرمز'), findsOneWidget);
    expect(find.byTooltip('الفلاتر والترتيب'), findsOneWidget);

    await tester.tap(find.byTooltip('الفلاتر والترتيب'));
    await tester.pumpAndSettle();

    expect(find.text('الفلاتر والترتيب'), findsOneWidget);
    expect(find.text('ترتيب النتائج'), findsOneWidget);
    expect(find.text('حالة المنتج'), findsNothing);
  });

  testWidgets(
    'catalog screen exposes reusable search, filtering, and ordering controls',
    (WidgetTester tester) async {
      await tester.pumpWidget(PointyApp(apiService: _mockApiService()));
      await tester.pumpAndSettle(const Duration(seconds: 1));

      await tester.tap(find.byIcon(Icons.menu));
      await tester.pumpAndSettle();
      await tester.tap(find.text('المنتجات').last);
      await tester.pumpAndSettle(const Duration(seconds: 1));

      expect(find.text('ابحث باسم المنتج أو الرمز'), findsOneWidget);
      expect(find.byTooltip('الفلاتر والترتيب'), findsOneWidget);

      await tester.tap(find.byTooltip('الفلاتر والترتيب'));
      await tester.pumpAndSettle();

      expect(find.text('الفلاتر والترتيب'), findsOneWidget);
      expect(find.text('حالة المنتج'), findsOneWidget);
      expect(find.text('ترتيب النتائج'), findsOneWidget);
      expect(find.text('السعر: من الأعلى إلى الأقل'), findsOneWidget);
    },
  );

  testWidgets('navigation drawer exposes primary destinations', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(PointyApp(apiService: _mockApiService()));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();

    expect(find.text('مدير النظام'), findsOneWidget);
    expect(find.text('شاشة البيع'), findsOneWidget);
    expect(find.text('المنتجات'), findsWidgets);
    expect(find.text('جلسات الدرج'), findsOneWidget);
    expect(find.text('المستخدمون'), findsOneWidget);
    expect(find.text('تسجيل الخروج'), findsOneWidget);
  });

  testWidgets('login screen authenticates before showing POS', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      PointyApp(apiService: _mockApiService(isAuthenticated: false)),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('تسجيل الدخول'), findsOneWidget);

    await tester.enterText(find.byType(TextFormField).at(0), 'manager');
    await tester.enterText(find.byType(TextFormField).at(1), 'secret');
    await tester.tap(find.text('دخول'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('جلسة الدرج'), findsOneWidget);
    expect(find.text('نقدية الافتتاح'), findsOneWidget);
  });

  testWidgets('manager can open user management', (WidgetTester tester) async {
    await tester.pumpWidget(PointyApp(apiService: _mockApiService()));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tester.tap(find.text('المستخدمون'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('إدارة المستخدمين'), findsOneWidget);
    expect(find.text('كاشير الوردية'), findsOneWidget);
    expect(find.text('إضافة مستخدم'), findsOneWidget);
  });

  testWidgets('cashier navigation hides management destinations', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      PointyApp(
        apiService: _mockApiService(
          currentUserRole: 'cashier',
          currentUserDisplayName: 'كاشير الوردية',
          currentUserPermissions: const [
            'catalog.view_product',
            'sales.add_order',
            'sales.view_order',
            'sales.add_registersession',
            'sales.change_registersession',
            'sales.view_registersession',
          ],
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();

    expect(find.text('كاشير الوردية'), findsOneWidget);
    expect(find.text('شاشة البيع'), findsOneWidget);
    expect(find.text('جلسات الدرج'), findsOneWidget);
    expect(find.text('المنتجات'), findsNothing);
    expect(find.text('المستخدمون'), findsNothing);
  });

  testWidgets(
    'user management shows forbidden state for direct cashier entry',
    (WidgetTester tester) async {
      final cashier = PosUser.fromJson(
        _userJson(
          username: 'cashier',
          displayName: 'كاشير الوردية',
          role: 'cashier',
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ar'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: UserManagementScreen(
            viewModel: UserManagementViewModel(
              UserRepository(_mockApiService(currentUserRole: 'cashier')),
            ),
            currentUser: cashier,
            capabilities: AuthorizationCapabilities.forUser(cashier),
            onOpenPos: () {},
            onOpenCatalog: () {},
            onOpenRegisterSessions: () {},
            onLogout: () {},
          ),
        ),
      );
      await tester.pumpAndSettle(const Duration(seconds: 1));

      expect(find.text('غير مصرح'), findsOneWidget);
      expect(
        find.text('لا يملك هذا المستخدم صلاحية الوصول إلى هذه الشاشة.'),
        findsOneWidget,
      );
      expect(find.text('إضافة مستخدم'), findsNothing);
    },
  );

  testWidgets('register session history shows sessions and linked sales', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(PointyApp(apiService: _mockApiService()));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tester.tap(find.text('جلسات الدرج'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('سجل جلسات الدرج'), findsOneWidget);
    expect(find.text('جلسة RS-1'), findsOneWidget);
    expect(find.text('جلسة RS-2'), findsOneWidget);
    expect(find.text('اختر جلسة درج لعرض مبيعاتها.'), findsOneWidget);

    await tester.tap(find.text('جلسة RS-1'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('مبيعات جلسة RS-1'), findsOneWidget);
    expect(find.text('إيصال R-100'), findsOneWidget);
    expect(find.text('د.ل 7.00'), findsWidgets);
  });

  testWidgets('session orders load more when the list underfills', (
    WidgetTester tester,
  ) async {
    final requestedOrderPages = <int>[];

    await tester.pumpWidget(
      PointyApp(
        apiService: _mockApiService(onOrderPage: requestedOrderPages.add),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tester.tap(find.text('جلسات الدرج'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await tester.tap(find.text('جلسة RS-1'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(requestedOrderPages, containsAllInOrder([1, 2]));
    expect(find.text('إيصال R-100'), findsOneWidget);
    expect(find.text('إيصال R-101'), findsOneWidget);
  });

  testWidgets('register gate resumes an existing open session', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      PointyApp(apiService: _mockApiService(hasOpenSession: true)),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('جلسة RS-1'), findsOneWidget);
    expect(find.text('نقدية الافتتاح: د.ل 12.00'), findsOneWidget);

    await tester.tap(find.text('متابعة البيع'));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('البيع الحالي'), findsOneWidget);
    expect(find.byTooltip('إغلاق جلسة الدرج'), findsOneWidget);
  });

  testWidgets('close register sheet submits cash and denomination counts', (
    WidgetTester tester,
  ) async {
    RegisterSessionCloseInput? submittedInput;

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: Scaffold(
          body: RegisterSessionCloseSheet(
            onClose: (input) async {
              submittedInput = input;
              return true;
            },
          ),
        ),
      ),
    );

    await tester.enterText(find.byType(TextFormField).at(0), '25.50');
    await tester.enterText(find.byType(TextFormField).at(1), '1');
    await tester.enterText(find.byType(TextFormField).at(2), '2');
    await tester.enterText(find.byType(TextFormField).at(3), '3');
    await tester.enterText(find.byType(TextFormField).at(4), '4');

    await tester.tap(find.text('إغلاق الجلسة'));
    await tester.pump();

    expect(submittedInput?.closingCash, 25.50);
    expect(submittedInput?.count025, 1);
    expect(submittedInput?.count050, 2);
    expect(submittedInput?.count075, 3);
    expect(submittedInput?.count100, 4);
  });

  testWidgets('product details screen presents product information', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        locale: Locale('ar'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: ProductDetailsScreen(
          product: Product(
            id: 42,
            sku: 'COF-100',
            name: 'قهوة عربية',
            unitPrice: 5.50,
            barcode: '123456',
            description: 'حبوب مطحونة بعناية',
          ),
        ),
      ),
    );

    expect(find.text('تفاصيل المنتج'), findsOneWidget);
    expect(find.text('قهوة عربية'), findsOneWidget);
    expect(find.text('د.ل 5.50'), findsOneWidget);
    expect(find.text('123456'), findsOneWidget);
    expect(find.text('حبوب مطحونة بعناية'), findsOneWidget);
  });

  testWidgets('infinite grid requests more data when content underfills', (
    WidgetTester tester,
  ) async {
    var loadMoreCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          height: 320,
          width: 320,
          child: InfiniteScrollGrid<int>(
            items: const [1],
            hasMore: true,
            isLoadingInitial: false,
            isLoadingMore: false,
            onLoadMore: () async {
              loadMoreCalls += 1;
            },
            emptyBuilder: (_) => const Text('empty'),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisExtent: 120,
            ),
            itemBuilder: (_, item) => Text('$item'),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(loadMoreCalls, 1);
  });

  testWidgets('infinite list requests more data when content underfills', (
    WidgetTester tester,
  ) async {
    var loadMoreCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          height: 320,
          width: 320,
          child: InfiniteScrollList<int>(
            items: const [1],
            hasMore: true,
            isLoadingInitial: false,
            isLoadingMore: false,
            onLoadMore: () async {
              loadMoreCalls += 1;
            },
            emptyBuilder: (_) => const Text('empty'),
            itemBuilder: (_, item) =>
                SizedBox(height: 56, child: Text('$item')),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(loadMoreCalls, 1);
  });
}

PosApiService _mockApiService({
  bool isAuthenticated = true,
  bool hasOpenSession = false,
  int checkoutStatusCode = 200,
  String currentUserRole = 'manager',
  String currentUserDisplayName = 'مدير النظام',
  List<String> currentUserPermissions = const [],
  void Function(http.Request request)? onCheckout,
  void Function(int page)? onOrderPage,
}) {
  var authenticated = isAuthenticated;
  var currentSessionIsOpen = hasOpenSession;

  return PosApiService(
    client: MockClient((request) async {
      final path = request.url.path;

      if (path.endsWith('/auth/me/')) {
        if (!authenticated) {
          return http.Response('', 401);
        }
        return _jsonResponse(
          _userJson(
            displayName: currentUserDisplayName,
            role: currentUserRole,
            permissions: currentUserPermissions,
          ),
        );
      }

      if (path.endsWith('/auth/login/')) {
        authenticated = true;
        return _jsonResponse(
          _userJson(
            displayName: currentUserDisplayName,
            role: currentUserRole,
            permissions: currentUserPermissions,
          ),
        );
      }

      if (path.endsWith('/auth/logout/')) {
        authenticated = false;
        return http.Response('', 204);
      }

      if (path.endsWith('/users/')) {
        if (request.method == 'POST') {
          final body = jsonDecode(request.body) as Map<String, Object?>;
          return _jsonResponse({
            'id': 3,
            ...body,
            'is_active': body['is_active'] ?? true,
          });
        }
        return _jsonResponseList([
          _userJson(),
          _userJson(
            id: 2,
            username: 'cashier',
            displayName: 'كاشير الوردية',
            role: 'cashier',
          ),
        ]);
      }

      if (path.endsWith('/users/2/')) {
        final body = jsonDecode(request.body) as Map<String, Object?>;
        return _jsonResponse({
          ..._userJson(
            id: 2,
            username: 'cashier',
            displayName: 'كاشير الوردية',
            role: 'cashier',
          ),
          ...body,
        });
      }

      if (path.endsWith('/register-sessions/current/')) {
        if (!currentSessionIsOpen) {
          return http.Response('', 204);
        }
        return _jsonResponse(_sessionJson(openingCash: '12.00'));
      }

      if (path.endsWith('/register-sessions/start/')) {
        currentSessionIsOpen = true;
        return _jsonResponse(_sessionJson());
      }

      if (path.endsWith('/register-sessions/1/close/')) {
        currentSessionIsOpen = false;
        return _jsonResponse({
          ..._sessionJson(),
          'status': 'closed',
          'closing_cash': '25.50',
        });
      }

      if (path.endsWith('/register-sessions/1/orders/')) {
        final page =
            int.tryParse(request.url.queryParameters['page'] ?? '1') ?? 1;
        onOrderPage?.call(page);
        if (page == 2) {
          return _jsonResponse({
            'count': 2,
            'next': null,
            'previous':
                'http://localhost/api/register-sessions/1/orders/?page=1',
            'results': [
              _orderJson(
                id: 101,
                receiptNumber: 'R-101',
                total: '3.50',
                quantity: 1,
                createdAt: '2026-05-15T09:15:00Z',
              ),
            ],
          });
        }
        return _jsonResponse({
          'count': 2,
          'next': 'http://localhost/api/register-sessions/1/orders/?page=2',
          'previous': null,
          'results': [_orderJson()],
        });
      }

      if (path.endsWith('/register-sessions/')) {
        final page = int.tryParse(request.url.queryParameters['page'] ?? '1');
        if (page == 2) {
          return _jsonResponse({
            'count': 2,
            'next': null,
            'previous': 'http://localhost/api/register-sessions/?page=1',
            'results': [
              _sessionJson(id: 2, sessionNumber: 'RS-2', openingCash: '8.00'),
            ],
          });
        }

        return _jsonResponse({
          'count': 2,
          'next': 'http://localhost/api/register-sessions/?page=2',
          'previous': null,
          'results': [_sessionJson(openingCash: '12.00')],
        });
      }

      if (path.endsWith('/products/')) {
        return _jsonResponse(_productPageJson());
      }

      if (path.endsWith('/orders/checkout/')) {
        onCheckout?.call(request);
        if (checkoutStatusCode < 200 || checkoutStatusCode >= 300) {
          return http.Response('bad request', checkoutStatusCode);
        }
        return _jsonResponse(_orderJson());
      }

      return http.Response('not found', 404);
    }),
  );
}

http.Response _jsonResponse(Map<String, Object?> body) {
  return http.Response.bytes(
    utf8.encode(jsonEncode(body)),
    200,
    headers: const {'Content-Type': 'application/json; charset=utf-8'},
  );
}

http.Response _jsonResponseList(List<Object?> body) {
  return http.Response.bytes(
    utf8.encode(jsonEncode(body)),
    200,
    headers: const {'Content-Type': 'application/json; charset=utf-8'},
  );
}

Map<String, Object?> _userJson({
  int id = 1,
  String username = 'manager',
  String displayName = 'مدير النظام',
  String role = 'manager',
  List<String> permissions = const [],
}) {
  return {
    'id': id,
    'username': username,
    'display_name': displayName,
    'email': '',
    'role': role,
    'permissions': permissions,
    'is_active': true,
  };
}

Map<String, Object?> _sessionJson({
  int id = 1,
  String sessionNumber = 'RS-1',
  String openingCash = '0.00',
}) {
  return {
    'id': id,
    'session_number': sessionNumber,
    'status': 'open',
    'opening_cash': openingCash,
    'closing_cash': null,
    'count_025': 0,
    'count_050': 0,
    'count_075': 0,
    'count_100': 0,
    'opened_at': '2026-05-15T09:00:00Z',
    'closed_at': null,
    'created_at': '2026-05-15T09:00:00Z',
    'updated_at': '2026-05-15T09:00:00Z',
  };
}

Map<String, Object?> _productPageJson() {
  return {
    'next': null,
    'results': [
      {
        'id': 1,
        'sku': 'COF-001',
        'name': 'قهوة البيت',
        'unit_price': '3.50',
        'barcode': '',
        'description': '',
        'is_active': true,
      },
    ],
  };
}

Map<String, Object?> _orderJson({
  int id = 100,
  String receiptNumber = 'R-100',
  String total = '7.00',
  int quantity = 2,
  String createdAt = '2026-05-15T09:10:00Z',
}) {
  return {
    'id': id,
    'receipt_number': receiptNumber,
    'status': 'paid',
    'register_session': 1,
    'register_session_number': 'RS-1',
    'lines': [
      {
        'product': 1,
        'product_name': 'قهوة البيت',
        'quantity': quantity,
        'unit_price': '3.50',
        'line_total': total,
      },
    ],
    'subtotal': total,
    'total': total,
    'created_at': createdAt,
    'updated_at': createdAt,
  };
}
