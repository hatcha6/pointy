import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/camera.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/models/sale_order.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/contact_repository.dart';
import 'package:pointy_frontend/src/data/repositories/printing_repository.dart';
import 'package:pointy_frontend/src/data/repositories/sale_repository.dart';
import 'package:pointy_frontend/src/data/repositories/shop_settings_repository.dart';
import 'package:pointy_frontend/src/data/repositories/surveillance_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/invoices/views/invoice_details_screen.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

/// Converting a quotation replaces its screen with the new sale's. That screen
/// is the sale's own invoice, so it plays the sale's own footage — it used to
/// be built without the camera repository, and simply had none.
void main() {
  final l10n = lookupAppLocalizations(const Locale('ar'));

  testWidgets('the converted sale opens with its own camera footage', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final service = PosApiService();
    final surveillance = _FakeSurveillanceRepository();
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: PointyTheme.light(),
        home: InvoiceDetailsScreen(
          saleRepository: _FakeSaleRepository(),
          printingRepository: PrintingRepository(service),
          shopSettingsRepository: ShopSettingsRepository(service),
          surveillanceRepository: surveillance,
          catalogRepository: CatalogRepository(service),
          contactRepository: ContactRepository(service),
          initialOrder: _quotation,
          capabilities: AuthorizationCapabilities.forUser(
            const PosUser(
              id: 2,
              username: 'counter',
              role: UserRole.cashier,
              isActive: true,
              permissions: {'sales.view_order', 'sales.add_order'},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(surveillance.requestedOrders, [_quotation.id]);

    await tester.tap(find.text(l10n.convertQuotationButton));
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithText(FilledButton, l10n.convertQuotationConfirm),
    );
    await tester.pumpAndSettle();

    expect(
      find.text(l10n.invoiceDetailsTitle(_sale.receiptNumber!)),
      findsOneWidget,
    );
    expect(surveillance.requestedOrders, [_quotation.id, _sale.id]);
  });
}

final _quotation = SaleOrder(
  id: 21,
  receiptNumber: 'Q1021',
  status: 'open',
  saleType: SaleType.quotation,
  lines: const [],
  payments: const [],
  subtotal: 50,
  total: 50,
  paymentStatus: 'unpaid',
);

final _sale = SaleOrder(
  id: 22,
  receiptNumber: '1022',
  status: 'paid',
  lines: const [],
  payments: const [],
  subtotal: 50,
  total: 50,
  paymentStatus: 'paid',
);

class _FakeSaleRepository extends SaleRepository {
  _FakeSaleRepository() : super(PosApiService());

  @override
  Future<Result<SaleOrder>> loadOrder(int saleOrderId) async =>
      Ok(saleOrderId == _sale.id ? _sale : _quotation);

  @override
  Future<Result<SaleOrder>> convertQuotation(
    int orderId, {
    required SaleType saleType,
    double? amountReceived,
    String? idempotencyKey,
  }) async => Ok(_sale);
}

/// Answers every footage request with "no cameras" — the section then shows
/// nothing — and keeps the order ids it was asked about.
class _FakeSurveillanceRepository extends SurveillanceRepository {
  _FakeSurveillanceRepository() : super(PosApiService());

  final requestedOrders = <int>[];

  @override
  Future<Result<InvoiceFootage>> loadInvoiceFootage(int orderId) async {
    requestedOrders.add(orderId);
    return Error(Exception('no cameras'));
  }
}
