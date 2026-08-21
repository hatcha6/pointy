import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/models/product.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/printing_repository.dart';
import 'package:pointy_frontend/src/data/repositories/purchase_repository.dart';
import 'package:pointy_frontend/src/data/repositories/sale_repository.dart';
import 'package:pointy_frontend/src/data/repositories/shop_settings_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/catalog/view_models/product_details_view_model.dart';
import 'package:pointy_frontend/src/features/catalog/views/product_document_history_section.dart';
import 'package:pointy_frontend/src/shared/components/components.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

/// A product's "recent invoices" and "recent purchase bills" lists used to
/// render a bare error title when the LAN blinked, and the product details
/// screen has no refresh anywhere on it — so the only way to re-ask was to
/// leave the product and open it again. Both lists now offer the retry the
/// rest of the app already does.
void main() {
  testWidgets('a failed document history re-asks in one tap', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    var failHistory = true;
    final historyRequests = <String>[];
    final service = PosApiService(
      baseUrl: 'http://pointy.test/api',
      client: MockClient((request) async {
        final path = request.url.path;
        final isHistory =
            path.endsWith('/orders/') || path.endsWith('/purchase-orders/');
        if (isHistory) {
          historyRequests.add(path);
          if (failHistory) {
            return http.Response('{"detail":"boom"}', 500);
          }
        }
        return http.Response(
          jsonEncode({'results': <Object?>[], 'next': null}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final viewModel = ProductDetailsViewModel(
      CatalogRepository(service),
      PurchaseRepository(service),
      SaleRepository(service),
      Product.fromJson(const {
        'id': 7,
        'name': 'شاي أخضر',
        'unit': 'piece',
        'quantity_on_hand': 3,
      }),
    );
    addTearDown(viewModel.dispose);

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: PointyTheme.light(),
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: Scaffold(
            body: SingleChildScrollView(
              child: ListenableBuilder(
                listenable: viewModel,
                builder: (context, _) => ProductDocumentHistorySection(
                  viewModel: viewModel,
                  purchaseRepository: PurchaseRepository(service),
                  printingRepository: PrintingRepository(service),
                  shopSettingsRepository: ShopSettingsRepository(service),
                  capabilities: AuthorizationCapabilities.forUser(
                    PosUser.fromJson(const {
                      'id': 1,
                      'username': 'manager',
                      'display_name': 'مدير النظام',
                      'email': '',
                      'role': 'manager',
                      'permissions': <String>[],
                      'is_active': true,
                    }),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));

    // Both halves failed, and each names its own failure.
    expect(find.text(l10n.productRecentInvoicesLoadError), findsOneWidget);
    expect(find.text(l10n.productRecentPurchaseBillsLoadError), findsOneWidget);
    expect(find.byType(PointyErrorState), findsNWidgets(2));

    // Each failure carries its own way out, rather than dead-ending.
    final retries = find.descendant(
      of: find.byType(PointyErrorState),
      matching: find.text(l10n.retryButton),
    );
    expect(retries, findsNWidgets(2));

    final salesRequestsBefore = historyRequests
        .where((path) => path.endsWith('/orders/'))
        .length;
    final purchaseRequestsBefore = historyRequests
        .where((path) => path.endsWith('/purchase-orders/'))
        .length;
    expect(salesRequestsBefore, greaterThan(0));
    expect(purchaseRequestsBefore, greaterThan(0));

    // Retrying the invoices half re-asks the server for invoices only — it
    // must not quietly refetch the purchase bills beside it.
    failHistory = false;
    await tester.tap(retries.first);
    await tester.pumpAndSettle();

    expect(
      historyRequests.where((path) => path.endsWith('/orders/')).length,
      salesRequestsBefore + 1,
    );
    expect(
      historyRequests
          .where((path) => path.endsWith('/purchase-orders/'))
          .length,
      purchaseRequestsBefore,
    );

    // The recovered half now shows its empty state; the untouched half keeps
    // its error and its retry.
    expect(find.text(l10n.productRecentInvoicesEmpty), findsOneWidget);
    expect(find.text(l10n.productRecentPurchaseBillsLoadError), findsOneWidget);
  });

  testWidgets('the purchase-bills retry re-asks for purchase bills', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    var failHistory = true;
    final historyRequests = <String>[];
    final service = PosApiService(
      baseUrl: 'http://pointy.test/api',
      client: MockClient((request) async {
        final path = request.url.path;
        if (path.endsWith('/orders/') || path.endsWith('/purchase-orders/')) {
          historyRequests.add(path);
          if (failHistory) {
            return http.Response('{"detail":"boom"}', 500);
          }
        }
        return http.Response(
          jsonEncode({'results': <Object?>[], 'next': null}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final viewModel = ProductDetailsViewModel(
      CatalogRepository(service),
      PurchaseRepository(service),
      SaleRepository(service),
      Product.fromJson(const {
        'id': 7,
        'name': 'شاي أخضر',
        'unit': 'piece',
        'quantity_on_hand': 3,
      }),
      // With the sales half never loading, the purchase failure is the only
      // error on screen — so the single retry cannot be the sales one.
      shouldLoadSaleHistory: false,
    );
    addTearDown(viewModel.dispose);

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: PointyTheme.light(),
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: Scaffold(
            body: SingleChildScrollView(
              child: ListenableBuilder(
                listenable: viewModel,
                builder: (context, _) => ProductDocumentHistorySection(
                  viewModel: viewModel,
                  purchaseRepository: PurchaseRepository(service),
                  printingRepository: PrintingRepository(service),
                  shopSettingsRepository: ShopSettingsRepository(service),
                  capabilities: AuthorizationCapabilities.forUser(
                    PosUser.fromJson(const {
                      'id': 1,
                      'username': 'manager',
                      'display_name': 'مدير النظام',
                      'email': '',
                      'role': 'manager',
                      'permissions': <String>[],
                      'is_active': true,
                    }),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    expect(find.text(l10n.productRecentPurchaseBillsLoadError), findsOneWidget);

    final before = historyRequests
        .where((path) => path.endsWith('/purchase-orders/'))
        .length;
    expect(before, greaterThan(0));

    failHistory = false;
    await tester.tap(
      find.descendant(
        of: find.byType(PointyErrorState),
        matching: find.text(l10n.retryButton),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      historyRequests
          .where((path) => path.endsWith('/purchase-orders/'))
          .length,
      before + 1,
    );
    expect(find.text(l10n.productRecentPurchaseBillsEmpty), findsOneWidget);
  });

  testWidgets('the taller error state fits its box without overflowing', (
    tester,
  ) async {
    // The history lists live in a fixed-height, non-scrolling SizedBox, so an
    // error state that grew a retry button is a render overflow if the box was
    // not grown with it. A phone width is the tightest case — the title wraps.
    await tester.binding.setSurfaceSize(const Size(390, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final service = PosApiService(
      baseUrl: 'http://pointy.test/api',
      client: MockClient((request) async {
        final path = request.url.path;
        if (path.endsWith('/orders/') || path.endsWith('/purchase-orders/')) {
          return http.Response('{"detail":"boom"}', 500);
        }
        return http.Response(
          jsonEncode({'results': <Object?>[], 'next': null}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final viewModel = ProductDetailsViewModel(
      CatalogRepository(service),
      PurchaseRepository(service),
      SaleRepository(service),
      Product.fromJson(const {
        'id': 7,
        'name': 'شاي أخضر',
        'unit': 'piece',
        'quantity_on_hand': 3,
      }),
    );
    addTearDown(viewModel.dispose);

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: PointyTheme.light(),
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: Scaffold(
            body: SingleChildScrollView(
              child: ListenableBuilder(
                listenable: viewModel,
                builder: (context, _) => ProductDocumentHistorySection(
                  viewModel: viewModel,
                  purchaseRepository: PurchaseRepository(service),
                  printingRepository: PrintingRepository(service),
                  shopSettingsRepository: ShopSettingsRepository(service),
                  capabilities: AuthorizationCapabilities.forUser(
                    PosUser.fromJson(const {
                      'id': 1,
                      'username': 'manager',
                      'display_name': 'مدير النظام',
                      'email': '',
                      'role': 'manager',
                      'permissions': <String>[],
                      'is_active': true,
                    }),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(PointyErrorState), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });
}
