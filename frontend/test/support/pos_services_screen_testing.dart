import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/dev/services_fake_repository.dart';
import 'package:pointy_frontend/dev/services_fixtures.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/models/product.dart';
import 'package:pointy_frontend/src/data/models/product_category.dart';
import 'package:pointy_frontend/src/data/models/product_page.dart';
import 'package:pointy_frontend/src/data/models/product_query.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/data/models/register_session.dart';
import 'package:pointy_frontend/src/data/models/sale_order.dart';
import 'package:pointy_frontend/src/data/models/voucher_menu.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/contact_repository.dart';
import 'package:pointy_frontend/src/data/repositories/integrations_repository.dart';
import 'package:pointy_frontend/src/data/repositories/printing_repository.dart';
import 'package:pointy_frontend/src/data/repositories/purchase_repository.dart';
import 'package:pointy_frontend/src/data/repositories/register_session_repository.dart';
import 'package:pointy_frontend/src/data/repositories/sale_repository.dart';
import 'package:pointy_frontend/src/data/repositories/shop_settings_repository.dart';
import 'package:pointy_frontend/src/data/services/local_scoped_json_storage.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/pos/view_models/pos_view_model.dart';
import 'package:pointy_frontend/src/features/pos/views/pos_screen.dart';
import 'package:pointy_frontend/src/shared/app_navigation_drawer.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/shell/shell.dart';

import 'voucher_menu_testing.dart';

/// The till around «كروت دفتر»' direct services: a POS screen on fake
/// repositories whose company menu lists the services, and the fake relay
/// that answers them.

/// The company menu as the server serves it with the services on: the cards
/// of [voucherMenuJson] plus airtime and every type of bill.
///
/// [testMode] is the relay on its sandbox supplier: the menu says
/// `test_mode: true` at the top and on each service.
VoucherMenu servicesMenu({bool withServices = true, bool testMode = false}) {
  final json = voucherMenuJson(withCost: false);
  if (withServices) {
    json['services'] = servicesPreviewMenuServicesJson(testMode: testMode);
  }
  if (testMode) {
    json['test_mode'] = true;
  }
  return VoucherMenu.fromJson(json);
}

/// A fake relay whose company menu is [servicesMenu]. With [testMode] the
/// directory and every country say so too, as the backend does.
class ServicesTillIntegrations extends PreviewServicesRepository {
  ServicesTillIntegrations({bool withServices = true, bool testMode = false}) {
    menu = servicesMenu(withServices: withServices, testMode: testMode);
    this.testMode = testMode;
  }
}

final PosUser managerUser = PosUser.fromJson(const {
  'id': 1,
  'username': 'manager',
  'role': 'manager',
  'permissions': <String>[],
});

final AuthorizationCapabilities managerCapabilities =
    AuthorizationCapabilities.forUser(managerUser);

const vouchersChip = ProductCategory(
  id: 99,
  name: 'كروت دفتر',
  isQuickAccess: true,
  isSystem: true,
  systemKey: ProductCategorySystemKey.pointyVouchers,
);

const _coffee = Product(
  id: 42,
  name: 'قهوة عربية',
  quantityOnHand: 30,
  defaultVariant: ProductVariant(
    id: 420,
    productId: 42,
    sku: 'COF-100',
    unitPrice: 5.50,
    quantityOnHand: 30,
  ),
);

class _Catalog extends CatalogRepository {
  _Catalog() : super(PosApiService());

  @override
  Future<Result<ProductPage>> loadProducts({
    required ProductQuery query,
    int page = 1,
    bool bypassCache = false,
  }) async => Ok(
    ProductPage(
      products: page == 1 ? const [_coffee] : const [],
      hasMore: false,
    ),
  );

  @override
  Future<Result<List<ProductCategory>>> loadQuickAccessCategories() async =>
      const Ok([vouchersChip]);
}

class _Register extends RegisterSessionRepository {
  _Register() : super(PosApiService());

  @override
  Future<Result<RegisterSession?>> loadCurrentSession() async => const Ok(
    RegisterSession(
      id: 2,
      sessionNumber: 'RS-2',
      status: 'open',
      openingCash: 100,
    ),
  );
}

class _Sales extends SaleRepository {
  _Sales() : super(PosApiService());

  /// The cart's own total: a service line carries its price at the end of its
  /// sealed quote (`…96.50`), which is what the fake relay writes there.
  @override
  Future<Result<SaleDiscountPreview>> previewDiscounts(
    SaleDiscountPreviewDraft draft,
  ) async {
    var subtotal = 0.0;
    for (final line in draft.lines) {
      final price = RegExp(
        r'(\d+\.\d{2})$',
      ).firstMatch(line.integration?.quote ?? '')?.group(1);
      subtotal += (double.tryParse(price ?? '') ?? 0) * line.quantity;
    }
    return Ok(
      SaleDiscountPreview(
        subtotal: subtotal,
        discountTotal: 0,
        total: subtotal,
      ),
    );
  }

  /// A recorded sale of one airtime line, the way the server answers.
  @override
  Future<Result<SaleOrder>> checkout(
    SaleCheckoutDraft draft, {
    String? idempotencyKey,
  }) async => Ok(
    SaleOrder(
      id: 100,
      status: 'paid',
      lines: const [
        SaleOrderLine(
          id: 7,
          productId: 1,
          variantId: 9301,
          quantity: 1,
          returnedQuantity: 0,
          returnableQuantity: 1,
          unitPrice: 96.5,
          total: 96.5,
          integration: SaleLineIntegration(
            provider: 'pointy',
            kind: 'airtime',
            subscriberRef: '+22370123456',
            optionLabel: 'أورنج مالي · 5,000 فرنك أفريقي',
          ),
        ),
      ],
      payments: const [],
      subtotal: 96.5,
      total: 96.5,
      receiptNumber: 'R-100',
    ),
  );
}

class _Navigation implements AppNavigation {
  @override
  PosUser get currentUser => managerUser;

  @override
  AuthorizationCapabilities get capabilities => managerCapabilities;

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

/// A till with an open register session whose integrations are [integrations].
/// [serviceQuoteFreshFor] is how long a service line's quote is trusted.
Future<PosViewModel> openTill(
  IntegrationsRepository integrations, {
  Duration serviceQuoteFreshFor = const Duration(minutes: 2),
  MemoryScopedJsonStorage? storage,
}) async {
  final viewModel = PosViewModel(
    _Catalog(),
    _Register(),
    _Sales(),
    ShopSettingsRepository(PosApiService()),
    PrintingRepository(PosApiService()),
    integrationsRepository: integrations,
    sessionStorage: storage ?? MemoryScopedJsonStorage(),
    chargeRetryDelay: Duration.zero,
    serviceQuoteFreshFor: serviceQuoteFreshFor,
  );
  await viewModel.loadCurrentRegisterSession();
  await viewModel.resumeRegisterSession();
  return viewModel;
}

/// The POS screen, the way the till shows it.
Future<void> pumpPosScreen(
  WidgetTester tester,
  PosViewModel viewModel,
  IntegrationsRepository integrations, {
  Size size = const Size(1440, 1000),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
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
      theme: PointyTheme.light(),
      builder: (context, child) => PointyNavigationRailScope(
        isActive: false,
        controller: PointyNavigationRailController(),
        child: child ?? const SizedBox.shrink(),
      ),
      home: PosScreen(
        viewModel: viewModel,
        contactRepository: ContactRepository(PosApiService()),
        printingRepository: PrintingRepository(PosApiService()),
        shopSettingsRepository: ShopSettingsRepository(PosApiService()),
        catalogRepository: _Catalog(),
        purchaseRepository: PurchaseRepository(PosApiService()),
        integrationsRepository: integrations,
        capabilities: managerCapabilities,
        navigation: _Navigation(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
