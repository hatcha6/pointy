import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/models/stock_unit.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/inventory_repository.dart';
import 'package:pointy_frontend/src/data/repositories/printing_repository.dart';
import 'package:pointy_frontend/src/data/repositories/purchase_repository.dart';
import 'package:pointy_frontend/src/data/repositories/sale_repository.dart';
import 'package:pointy_frontend/src/data/repositories/shop_settings_repository.dart';
import 'package:pointy_frontend/src/data/repositories/tracked_stock_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/catalog/view_models/catalog_view_model.dart';
import 'package:pointy_frontend/src/features/catalog/view_models/unit_search_lookup.dart';
import 'package:pointy_frontend/src/features/catalog/views/catalog_screen.dart';
import 'package:pointy_frontend/src/shared/catalog/catalog_empty_state.dart';
import 'package:pointy_frontend/src/shared/app_navigation_drawer.dart';
import 'package:pointy_frontend/src/shared/barcode/barcode_scan_listener.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

import '../unit_search_fixtures.dart';

final _manager = PosUser.fromJson(const {
  'id': 1,
  'username': 'manager',
  'display_name': 'مدير',
  'email': '',
  'role': 'manager',
  'permissions': <String>[],
  'is_active': true,
  'serialized_inventory_enabled': true,
});

class _Navigation implements AppNavigation {
  @override
  PosUser get currentUser => _manager;

  @override
  AuthorizationCapabilities get capabilities =>
      AuthorizationCapabilities.forUser(_manager);

  @override
  void navigateTo(
    BuildContext context,
    AppNavigationDestination destination, {
    AppNavigationDestination? from,
  }) {}

  @override
  void openAiChat(
    BuildContext context, {
    String? seedPrompt,
    bool autoSend = false,
    AppNavigationDestination? from,
  }) {}

  @override
  void logout(BuildContext context) {}
}

/// "Take us directly to that unit": an IMEI typed into the products search
/// and confirmed with Enter — or scanned — opens the article itself.
void main() {
  late List<Uri> requested;
  late Map<String, Object?> lookupAnswer;
  late List<int> openedUnits;

  PosApiService service() => PosApiService(
    baseUrl: 'http://pointy.test/api',
    client: MockClient((request) async {
      requested.add(request.url);
      final body = request.url.path.endsWith('stock-units/lookup/')
          ? lookupAnswer
          : {'results': <Object?>[], 'next': null};
      return http.Response(
        jsonEncode(body),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }),
  );

  setUp(() {
    requested = [];
    openedUnits = [];
    lookupAnswer = {'unit': liveUnitJson(), 'history': <Object?>[]};
  });

  bool askedForUnits() =>
      requested.any((url) => url.path.endsWith('stock-units/lookup/'));

  Future<void> settle(WidgetTester tester) async {
    for (var index = 0; index < 6; index++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  Future<void> pumpCatalog(
    WidgetTester tester, {
    bool tracksUnits = true,
  }) async {
    await tester.binding.setSurfaceSize(const Size(800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = service();
    final viewModel = CatalogViewModel(
      CatalogRepository(api),
      unitSearch: tracksUnits
          ? UnitSearchLookup(TrackedStockRepository(api).lookupUnit)
          : null,
    );
    addTearDown(viewModel.dispose);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: PointyTheme.light(),
        home: CatalogScreen(
          viewModel: viewModel,
          inventoryRepository: InventoryRepository(api),
          printingRepository: PrintingRepository(api),
          purchaseRepository: PurchaseRepository(api),
          saleRepository: SaleRepository(api),
          shopSettingsRepository: ShopSettingsRepository(api),
          navigation: _Navigation(),
          capabilities: AuthorizationCapabilities.forUser(_manager),
          onOpenStockUnit: (_, StockUnit unit) => openedUnits.add(unit.id),
          onOpenRecord: (_, _, _) async => true,
        ),
      ),
    );
    await settle(tester);
  }

  Future<void> typeAndEnter(WidgetTester tester, String text) async {
    await tester.enterText(
      find.byKey(const ValueKey('catalog_product_lookup_field')),
      text,
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await settle(tester);
  }

  testWidgets('Enter on an IMEI with one article opens it', (tester) async {
    await pumpCatalog(tester);
    await typeAndEnter(tester, imei);

    expect(openedUnits, [41]);
    expect(
      requested.where((url) => url.path.endsWith('stock-units/lookup/')),
      hasLength(1),
    );
  });

  testWidgets('a scanned IMEI opens it too', (tester) async {
    lookupAnswer = {
      'unit': null,
      'history': [soldUnitJson()],
    };
    await pumpCatalog(tester);

    tester
        .widget<BarcodeScanListener>(find.byType(BarcodeScanListener).first)
        .onBarcodeScanned(imei);
    await settle(tester);

    expect(openedUnits, [40]);
  });

  testWidgets('several articles: the card lists them and nothing opens', (
    tester,
  ) async {
    lookupAnswer = {
      'unit': liveUnitJson(),
      'history': [soldUnitJson()],
    };
    await pumpCatalog(tester);
    await typeAndEnter(tester, imei);
    await tester.pump(const Duration(milliseconds: 400));
    await settle(tester);

    expect(openedUnits, isEmpty);
    expect(
      find.byKey(const ValueKey('unit_search_match_card')),
      findsOneWidget,
    );
    expect(find.text('سجلان لهذا الرقم'), findsOneWidget);
  });

  testWidgets('typing an IMEI shows the card above the products', (
    tester,
  ) async {
    await pumpCatalog(tester);
    await tester.enterText(
      find.byKey(const ValueKey('catalog_product_lookup_field')),
      imei,
    );
    await tester.pump(const Duration(milliseconds: 400));
    await settle(tester);

    expect(
      find.byKey(const ValueKey('unit_search_match_card')),
      findsOneWidget,
    );
    expect(openedUnits, isEmpty);
  });

  testWidgets('a found article is not followed by «no results»', (
    tester,
  ) async {
    await pumpCatalog(tester);
    await tester.enterText(
      find.byKey(const ValueKey('catalog_product_lookup_field')),
      imei,
    );
    await tester.pump(const Duration(milliseconds: 400));
    await settle(tester);

    expect(
      find.byKey(const ValueKey('unit_search_match_card')),
      findsOneWidget,
    );
    expect(find.byType(CatalogEmptyState), findsNothing);
  });

  testWidgets('a shop that tracks no articles asks nothing', (tester) async {
    await pumpCatalog(tester, tracksUnits: false);
    await typeAndEnter(tester, imei);
    await tester.enterText(
      find.byKey(const ValueKey('catalog_product_lookup_field')),
      imei,
    );
    await tester.pump(const Duration(milliseconds: 400));
    await settle(tester);

    expect(askedForUnits(), isFalse);
    expect(openedUnits, isEmpty);
    expect(find.byKey(const ValueKey('unit_search_match_card')), findsNothing);
  });
}
