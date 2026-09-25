// The till's "on my account" button: a member of staff charging their own
// shopping to payroll picks their staff account without searching for it.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/contact.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/models/product_category.dart';
import 'package:pointy_frontend/src/data/models/product_page.dart';
import 'package:pointy_frontend/src/data/models/product_query.dart';
import 'package:pointy_frontend/src/data/models/product_variant_page.dart';
import 'package:pointy_frontend/src/data/models/register_session.dart';
import 'package:pointy_frontend/src/data/repositories/integrations_repository.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/contact_repository.dart';
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

final PosUser _managerUser = PosUser.fromJson(const {
  'id': 1,
  'username': 'manager',
  'role': 'manager',
  'permissions': <String>[],
});

final AuthorizationCapabilities _managerCaps =
    AuthorizationCapabilities.forUser(_managerUser);

class _FakeCatalogRepository extends CatalogRepository {
  _FakeCatalogRepository() : super(PosApiService());

  @override
  Future<Result<ProductPage>> loadProducts({
    required ProductQuery query,
    int page = 1,
    bool bypassCache = false,
  }) async => const Ok(ProductPage(products: [], hasMore: false));

  @override
  Future<Result<ProductVariantPage>> loadProductVariants({
    required ProductQuery query,
    int page = 1,
  }) async => const Ok(ProductVariantPage(variants: [], hasMore: false));

  @override
  Future<Result<List<ProductCategory>>> loadQuickAccessCategories() async =>
      const Ok([]);
}

class _FakeRegisterSessionRepository extends RegisterSessionRepository {
  _FakeRegisterSessionRepository() : super(PosApiService());

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

class _FakeSaleRepository extends SaleRepository {
  _FakeSaleRepository() : super(PosApiService());
}

class _FakeShopSettingsRepository extends ShopSettingsRepository {
  _FakeShopSettingsRepository() : super(PosApiService());
}

class _FakeContactRepository extends ContactRepository {
  _FakeContactRepository({this.fails = false}) : super(PosApiService());

  final bool fails;
  var staffAccountCalls = 0;

  @override
  Future<Result<Customer>> loadStaffAccount() async {
    staffAccountCalls += 1;
    if (fails) {
      return Error(Exception('offline'));
    }
    return const Ok(
      Customer(
        id: 90,
        customerNumber: 'C20260923000090',
        fullName: 'سلمى',
        phone: '',
        email: '',
        gender: CustomerGender.unspecified,
        marketingConsent: false,
        notes: '',
        isActive: true,
        staffEmployeeId: 4,
      ),
    );
  }
}

class _FakePurchaseRepository extends PurchaseRepository {
  _FakePurchaseRepository() : super(PosApiService());
}

class _FakeNavigation implements AppNavigation {
  @override
  PosUser get currentUser => _managerUser;

  @override
  AuthorizationCapabilities get capabilities => _managerCaps;

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

Future<PosViewModel> _activeSessionViewModel() async {
  final viewModel = PosViewModel(
    _FakeCatalogRepository(),
    _FakeRegisterSessionRepository(),
    _FakeSaleRepository(),
    _FakeShopSettingsRepository(),
    PrintingRepository(PosApiService()),
    sessionStorage: MemoryScopedJsonStorage(),
  );
  await viewModel.loadCurrentRegisterSession();
  await viewModel.resumeRegisterSession();
  return viewModel;
}

Future<void> _pumpPos(
  WidgetTester tester,
  PosViewModel viewModel, {
  required ContactRepository contacts,
}) async {
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
        contactRepository: contacts,
        printingRepository: PrintingRepository(PosApiService()),
        shopSettingsRepository: _FakeShopSettingsRepository(),
        catalogRepository: _FakeCatalogRepository(),
        purchaseRepository: _FakePurchaseRepository(),
        integrationsRepository: IntegrationsRepository(PosApiService()),
        capabilities: _managerCaps,
        navigation: _FakeNavigation(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  Future<PosViewModel> openSaleSettings(
    WidgetTester tester,
    _FakeContactRepository contacts,
  ) async {
    tester.view.physicalSize = const Size(1280, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final viewModel = await _activeSessionViewModel();
    addTearDown(viewModel.dispose);
    await _pumpPos(tester, viewModel, contacts: contacts);
    await tester.tap(find.byKey(const ValueKey('sale_draft_settings_button')));
    await tester.pumpAndSettle();
    return viewModel;
  }

  testWidgets('a cashier puts the sale on their own staff account in one tap', (
    tester,
  ) async {
    final contacts = _FakeContactRepository();
    final viewModel = await openSaleSettings(tester, contacts);

    await tester.tap(
      find.byKey(const ValueKey('sale_settings_staff_account_button')),
    );
    await tester.pumpAndSettle();

    expect(contacts.staffAccountCalls, 1);
    expect(find.text('سلمى · حساب موظف'), findsOneWidget);

    await tester.tap(find.text('حفظ'));
    await tester.pumpAndSettle();

    expect(viewModel.selectedCustomer?.id, 90);
    expect(viewModel.selectedCustomer?.isStaffAccount, isTrue);
  });

  testWidgets('a failed look-up says so and leaves the sale as it was', (
    tester,
  ) async {
    final viewModel = await openSaleSettings(
      tester,
      _FakeContactRepository(fails: true),
    );

    await tester.tap(
      find.byKey(const ValueKey('sale_settings_staff_account_button')),
    );
    await tester.pumpAndSettle();

    expect(find.text('تعذّر فتح حسابك كموظف. حاول مرة أخرى.'), findsOneWidget);
    await tester.tap(find.text('حفظ'));
    await tester.pumpAndSettle();
    expect(viewModel.selectedCustomer, isNull);
  });
}
