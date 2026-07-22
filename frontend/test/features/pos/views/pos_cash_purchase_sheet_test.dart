import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/contact.dart';
import 'package:pointy_frontend/src/data/models/product.dart';
import 'package:pointy_frontend/src/data/models/product_page.dart';
import 'package:pointy_frontend/src/data/models/product_query.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/data/models/purchase_submission.dart';
import 'package:pointy_frontend/src/data/models/shop_settings.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/contact_repository.dart';
import 'package:pointy_frontend/src/data/repositories/purchase_repository.dart';
import 'package:pointy_frontend/src/data/repositories/shop_settings_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/pos/views/pos_cash_purchase_sheet.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

const ProductVariant _breadVariant = ProductVariant(
  id: 11,
  productId: 1,
  sku: 'BREAD',
  unitPrice: 0.5,
  isDefault: true,
);

const Product _bread = Product(
  id: 1,
  name: 'خبز صامولي',
  quantityOnHand: 4,
  defaultVariant: _breadVariant,
  variants: [_breadVariant],
);

SupplierContact _supplier(int id, String name) => SupplierContact(
  id: id,
  name: name,
  contactName: '',
  phone: '',
  email: '',
  address: '',
  notes: '',
  isActive: true,
);

class _FakeContactRepository extends ContactRepository {
  _FakeContactRepository() : super(PosApiService());

  @override
  Future<Result<SupplierPage>> loadSuppliers({
    required ContactQuery query,
    int page = 1,
  }) async => Ok(
    SupplierPage(
      suppliers: [_supplier(5, 'مخبز الصباح'), _supplier(6, 'ألبان الواحة')],
      hasMore: false,
    ),
  );
}

class _FakeCatalogRepository extends CatalogRepository {
  _FakeCatalogRepository() : super(PosApiService());

  @override
  Future<Result<ProductPage>> loadProducts({
    required ProductQuery query,
    int page = 1,
  }) async {
    return const Ok(ProductPage(products: [_bread], hasMore: false));
  }
}

class _FakePurchaseRepository extends PurchaseRepository {
  _FakePurchaseRepository() : super(PosApiService());

  List<PurchaseDraftLine>? submittedLines;
  int? submittedSupplierId;

  @override
  Future<Result<double?>> loadLastProductCost(
    int productId, {
    int? variantId,
  }) async => const Ok(0.35);

  @override
  Future<Result<PurchaseSubmission>> submitPosCashPurchase(
    List<PurchaseDraftLine> lines, {
    required int supplierId,
    String? idempotencyKey,
  }) async {
    submittedLines = lines;
    submittedSupplierId = supplierId;
    return const Ok(
      PurchaseSubmission(
        draftNumber: 'PO-9',
        lineCount: 1,
        total: 7,
        status: 'received',
      ),
    );
  }
}

class _FakeShopSettingsRepository extends ShopSettingsRepository {
  _FakeShopSettingsRepository({this.limit}) : super(PosApiService());

  final double? limit;

  @override
  Future<Result<ShopSettings>> loadSettings() async => Ok(
    ShopSettings(
      shopName: 'دكان',
      receiptHeader: '',
      receiptFooter: '',
      enableOnlineInvoices: false,
      requireOpeningCash: true,
      autoPrintReceipts: false,
      allowOverselling: false,
      preventSellingAtLoss: true,
      lowStockThreshold: 5,
      cashierReturnWindowHours: 42,
      enableCashPayments: true,
      enableCardPayments: true,
      enableTransferPayments: true,
      requireCardPaymentReceipt: false,
      trustedCardTerminalIds: const [],
      cardCommissionPercent: 1,
      transferCommissionPercent: 0,
      posCashPurchaseLimit: limit,
    ),
  );
}

Future<_FakePurchaseRepository> _pumpSheet(
  WidgetTester tester, {
  double? limit,
}) async {
  final purchases = _FakePurchaseRepository();
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
      home: Scaffold(
        body: PosCashPurchaseSheet(
          contactRepository: _FakeContactRepository(),
          catalogRepository: _FakeCatalogRepository(),
          purchaseRepository: purchases,
          shopSettingsRepository: _FakeShopSettingsRepository(limit: limit),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return purchases;
}

/// Picks the supplier, searches for bread, and adds it as a line.
Future<void> _buildOneLinePurchase(WidgetTester tester) async {
  await tester.tap(find.text('مخبز الصباح'));
  await tester.pumpAndSettle();

  await tester.enterText(find.byType(TextField).last, 'خبز');
  // The search is debounced by 250ms.
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
  await tester.tap(find.text('خبز صامولي').last);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'cashier picks supplier, adds a scanned product, and submits the drawer purchase',
    (tester) async {
      tester.view.physicalSize = const Size(900, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final purchases = await _pumpSheet(tester);

      await _buildOneLinePurchase(tester);

      // The line landed with the last cost prefilled (0.35 × base unit).
      expect(find.text('خبز صامولي'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, '0.35'), findsOneWidget);

      // Bump the quantity to 20 loaves.
      await tester.enterText(find.widgetWithText(TextFormField, '1'), '20');
      await tester.pumpAndSettle();

      await tester.tap(find.text('تسجيل الشراء والدفع نقداً'));
      await tester.pumpAndSettle();

      expect(purchases.submittedSupplierId, 5);
      final lines = purchases.submittedLines;
      expect(lines, isNotNull);
      expect(lines!.single.variant.id, 11);
      expect(lines.single.quantity, 20);
      expect(lines.single.unitCost, closeTo(0.35, 0.001));
    },
  );

  testWidgets('a shop cap blocks submitting an over-limit purchase', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final purchases = await _pumpSheet(tester, limit: 5);

    await _buildOneLinePurchase(tester);
    await tester.enterText(find.widgetWithText(TextFormField, '1'), '20');
    await tester.pumpAndSettle();

    // 20 × 0.35 = 7.00 > the 5.00 cap: the error shows and nothing submits.
    expect(find.textContaining('يتجاوز الحد الأقصى'), findsOneWidget);
    await tester.tap(find.text('تسجيل الشراء والدفع نقداً'));
    await tester.pumpAndSettle();
    expect(purchases.submittedLines, isNull);
  });
}
