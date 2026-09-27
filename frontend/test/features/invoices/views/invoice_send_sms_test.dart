import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/models/sale_order.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/repositories/contact_repository.dart';
import 'package:pointy_frontend/src/data/repositories/printing_repository.dart';
import 'package:pointy_frontend/src/data/repositories/sale_repository.dart';
import 'package:pointy_frontend/src/data/repositories/shop_settings_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/invoices/views/invoice_details_screen.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

/// "Send as message" on an invoice: SMS is a paid add-on the shop can also
/// switch off, so the action exists only while the shop can send — and when
/// the server refuses, the cashier reads why, in Arabic.
void main() {
  final l10n = lookupAppLocalizations(const Locale('ar'));

  testWidgets('no SMS in the subscription, no send action', (tester) async {
    await _pump(tester, smsAvailable: false);

    expect(find.byTooltip(l10n.invoiceSendSmsTooltip), findsNothing);
  });

  testWidgets('with SMS, a refusal is named in Arabic', (tester) async {
    await _pump(
      tester,
      smsAvailable: true,
      sendResponse: http.Response(
        jsonEncode({
          'detail': 'monthly SMS limit reached',
          'code': 'monthly_limit',
        }),
        400,
        headers: const {'content-type': 'application/json; charset=utf-8'},
      ),
    );

    await tester.tap(find.byTooltip(l10n.invoiceSendSmsTooltip));
    await tester.pumpAndSettle();

    expect(find.text(l10n.messagingErrorMonthlyLimit), findsOneWidget);
  });

  testWidgets('with SMS, a queued message reads as sent', (tester) async {
    await _pump(tester, smsAvailable: true);

    await tester.tap(find.byTooltip(l10n.invoiceSendSmsTooltip));
    await tester.pumpAndSettle();

    expect(find.text(l10n.invoiceSendSmsSuccess), findsOneWidget);
  });
}

Map<String, Object?> _order() {
  return {
    'id': 11,
    'receipt_number': '1011',
    'status': 'paid',
    'sale_type': 'standard',
    'payment_status': 'paid',
    'customer': 3,
    'customer_name': 'علي',
    'customer_phone': '0912345678',
    'payments': <Object?>[],
    'subtotal': '10.00',
    'discount_total': '0.00',
    'total': '10.00',
    'amount_paid': '10.00',
    'balance_due': '0.00',
    'created_at': '2026-09-15T09:00:00Z',
    'lines': <Object?>[],
  };
}

Future<void> _pump(
  WidgetTester tester, {
  required bool smsAvailable,
  http.Response? sendResponse,
}) async {
  await tester.binding.setSurfaceSize(const Size(1200, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  http.Response json(Object? body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );

  final service = PosApiService(
    baseUrl: 'http://pointy.test/api',
    client: MockClient((request) async {
      if (request.url.path.endsWith('/send-invoice-sms/')) {
        return sendResponse ??
            json({
              'id': 1,
              'status': 'queued',
              'error_code': '',
              'error_detail': '',
              'body': 'شكرًا لتسوقك من محل النور.',
            }, 201);
      }
      return json(_order());
    }),
  );
  final user = PosUser(
    id: 2,
    username: 'counter',
    role: UserRole.cashier,
    isActive: true,
    permissions: const {'sales.view_order'},
    smsAvailable: smsAvailable,
  );

  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('ar'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: PointyTheme.light(),
      home: InvoiceDetailsScreen(
        saleRepository: SaleRepository(service),
        printingRepository: PrintingRepository(service),
        shopSettingsRepository: ShopSettingsRepository(service),
        catalogRepository: CatalogRepository(service),
        contactRepository: ContactRepository(service),
        initialOrder: SaleOrder.fromJson(_order()),
        capabilities: AuthorizationCapabilities.forUser(user),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
