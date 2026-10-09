import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/contact.dart';
import 'package:pointy_frontend/src/data/models/customer_activity.dart';
import 'package:pointy_frontend/src/data/models/messaging_gateway.dart';
import 'package:pointy_frontend/src/data/models/payment_card.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/models/sale_order_page.dart';
import 'package:pointy_frontend/src/data/models/shop_settings.dart';
import 'package:pointy_frontend/src/data/repositories/contact_repository.dart';
import 'package:pointy_frontend/src/data/repositories/printing_repository.dart';
import 'package:pointy_frontend/src/data/repositories/shop_settings_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/contacts/view_models/customer_details_view_model.dart';
import 'package:pointy_frontend/src/features/contacts/views/customer_details_screen.dart';
import 'package:pointy_frontend/src/shared/components/components.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

/// A customer who owes the shop can be texted what their account stands at,
/// from the callout that already says it — when the shop sends SMS and there
/// is a phone to text.
PosUser _manager({bool sms = true}) => PosUser(
  id: 1,
  username: 'manager',
  displayName: 'مدير',
  role: UserRole.manager,
  isActive: true,
  smsAvailable: sms,
);

Customer _customer({String phone = '0912345678'}) => Customer(
  id: 7,
  customerNumber: 'C-0007',
  fullName: 'سالم علي',
  phone: phone,
  email: '',
  gender: CustomerGender.unspecified,
  marketingConsent: false,
  notes: '',
  isActive: true,
);

void main() {
  final l10n = lookupAppLocalizations(const Locale('ar'));
  const button = ValueKey('send_customer_balance_sms_button');

  Future<_Contacts> pump(
    WidgetTester tester, {
    Customer? customer,
    PosUser? user,
    Result<MessagingSendResult>? answer,
  }) async {
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final contacts = _Contacts(customer ?? _customer(), answer: answer);
    final viewModel = CustomerDetailsViewModel(
      contactRepository: contacts,
      initialCustomer: contacts.customer,
      shopSettingsRepository: _Settings(),
      printingRepository: PrintingRepository(PosApiService()),
    );
    addTearDown(viewModel.dispose);
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
          body: CustomerDetailsView(
            viewModel: viewModel,
            capabilities: AuthorizationCapabilities.forUser(user ?? _manager()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return contacts;
  }

  testWidgets('the balance goes out from the callout and says so', (
    tester,
  ) async {
    final contacts = await pump(tester);
    expect(find.byKey(button), findsOneWidget);
    await tester.tap(find.byKey(button));
    await tester.pumpAndSettle();
    expect(contacts.texted, [7]);
    expect(find.text(l10n.customerSendBalanceSmsSent), findsOneWidget);
  });

  testWidgets('a text that cannot go out says why', (tester) async {
    await pump(
      tester,
      answer: const Ok(
        MessagingSendResult(
          status: 'failed',
          errorCode: 'insufficient_balance',
        ),
      ),
    );
    await tester.tap(find.byKey(button));
    await tester.pumpAndSettle();
    expect(find.text(l10n.messagingErrorInsufficientBalance), findsOneWidget);
    expect(find.text(l10n.customerSendBalanceSmsSent), findsNothing);
  });

  testWidgets('no phone, or no SMS for this shop: no button', (tester) async {
    await pump(tester, customer: _customer(phone: ' '));
    expect(find.byKey(button), findsNothing);
    // The callout itself is still there: it is about the money, not the text.
    expect(find.byType(PointyDetailCallout), findsWidgets);

    await pump(tester, user: _manager(sms: false));
    expect(find.byKey(button), findsNothing);
  });
}

class _Contacts extends ContactRepository {
  _Contacts(this.customer, {this.answer}) : super(PosApiService());

  final Customer customer;
  final Result<MessagingSendResult>? answer;
  final List<int> texted = [];

  @override
  Future<Result<Customer>> loadCustomer(int customerId) async => Ok(customer);

  @override
  Future<Result<CustomerSalesSummary>> loadCustomerSalesSummary(
    int customerId,
  ) async => Ok(
    CustomerSalesSummary(
      customerId: customerId,
      invoiceCount: 2,
      paidInvoiceCount: 0,
      voidInvoiceCount: 0,
      returnCount: 0,
      voidCount: 0,
      refundCount: 0,
      exchangeCount: 0,
      totalInvoiced: 200,
      returnTotal: 0,
      voidTotal: 0,
      refundTotal: 0,
      exchangeTotal: 0,
      netSales: 200,
      outstandingBalance: 160,
      netBalance: 160,
      openDebtsTotal: 160,
    ),
  );

  @override
  Future<Result<SaleOrderPage>> loadCustomerOrderHistory({
    required int customerId,
    int page = 1,
  }) async => const Ok(SaleOrderPage(orders: [], hasMore: false));

  @override
  Future<Result<CustomerAdjustmentHistoryPage>> loadCustomerAdjustmentHistory({
    required int customerId,
    int page = 1,
  }) async =>
      const Ok(CustomerAdjustmentHistoryPage(entries: [], hasMore: false));

  @override
  Future<Result<PaymentCardPage>> loadCustomerCards({
    required int customerId,
    int page = 1,
  }) async => const Ok(PaymentCardPage(cards: [], hasMore: false));

  @override
  Future<Result<MessagingSendResult>> sendCustomerBalanceSms(
    int customerId,
  ) async {
    texted.add(customerId);
    return answer ?? const Ok(MessagingSendResult(status: 'queued'));
  }
}

class _Settings extends ShopSettingsRepository {
  _Settings() : super(PosApiService());

  // The credit section stays hidden; nothing here is about it.
  @override
  Future<Result<ShopSettings>> loadSettings() async =>
      Error(Exception('not used'));
}
