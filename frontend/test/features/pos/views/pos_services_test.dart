import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/dev/services_fixtures.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/integration_card.dart';
import 'package:pointy_frontend/src/data/models/sale_order.dart';
import 'package:pointy_frontend/src/data/models/service_kinds.dart';
import 'package:pointy_frontend/src/data/models/service_quote.dart';
import 'package:pointy_frontend/src/data/models/voucher_menu.dart';
import 'package:pointy_frontend/src/features/pos/view_models/pos_service_shelves.dart';
import 'package:pointy_frontend/src/features/pos/view_models/pos_view_model.dart';
import 'package:pointy_frontend/src/features/pos/views/direct_services/airtime_launcher.dart';
import 'package:pointy_frontend/src/features/pos/views/direct_services/bill_flow_sheet.dart';
import 'package:pointy_frontend/src/features/pos/views/direct_services/bill_types_grid.dart';
import 'package:pointy_frontend/src/features/pos/views/direct_services/services_strip.dart';
import 'package:pointy_frontend/src/features/pos/views/pos_voucher_menu.dart';

import '../../../support/key_value_store_testing.dart';
import '../../../support/pos_services_screen_testing.dart';
import '../../../support/services_testing.dart';
import '../../../support/test_fonts.dart';

/// «كروت دفتر» sells two more things than cards: airtime sent to a phone
/// abroad and bills paid abroad. They are cards in a strip above the brands,
/// two tabs after «الكل», and — once priced by the server — ordinary lines in
/// the open invoice.
void main() {
  setUpAll(loadAppFonts);

  Finder key(String name) => find.byKey(ValueKey(name));

  Future<void> settle(WidgetTester tester) =>
      tester.pumpAndSettle(const Duration(milliseconds: 100));

  Future<void> pumpTime(WidgetTester tester, [int milliseconds = 120]) async {
    await tester.pump(Duration(milliseconds: milliseconds));
    await tester.pump(const Duration(milliseconds: 50));
  }

  Future<void> tapKey(WidgetTester tester, String name) async {
    await tester.ensureVisible(key(name));
    await tester.tap(key(name));
    await settle(tester);
  }

  /// A till with the company shop open, and the invoice it fills.
  Future<PosViewModel> openShop(
    WidgetTester tester, {
    bool withServices = true,
    bool testMode = false,
    Size size = const Size(1440, 1000),
  }) async {
    final integrations = ServicesTillIntegrations(
      withServices: withServices,
      testMode: testMode,
    );
    final viewModel = await openTill(integrations);
    disposeWithTest(viewModel.dispose);
    await pumpPosScreen(tester, viewModel, integrations, size: size);
    await tester.tap(find.text('كروت دفتر'));
    await settle(tester);
    return viewModel;
  }

  group('the menu', () {
    testServices('shows the services as cards above the brands', (
      tester,
    ) async {
      await openShop(tester);

      expect(find.byType(ServicesStrip), findsOneWidget);
      expect(key('service_card_airtime'), findsOneWidget);
      expect(key('service_card_electricity'), findsOneWidget);
      expect(key('service_card_water'), findsOneWidget);
      expect(key('service_card_tv'), findsOneWidget);
      expect(key('service_card_internet'), findsOneWidget);
      // Every card says what it does, in a line, and that it is new.
      expect(find.text('الشحن المباشر'), findsWidgets);
      expect(
        find.text(
          'أرسل رصيداً إلى أي رقم هاتف في العالم خلال ثوانٍ، بدون بطاقة',
        ),
        findsOneWidget,
      );
      expect(find.text('جديد'), findsWidgets);
      // …and the brands are still there under them.
      expect(find.text('آيتونز'), findsOneWidget);
    });

    testServices('adds two tabs right after «الكل»', (tester) async {
      await openShop(tester);

      final all = tester.getCenter(key('voucher_category_all'));
      final airtime = tester.getCenter(key('voucher_service_tab_airtime'));
      final bills = tester.getCenter(key('voucher_service_tab_bills'));
      final games = tester.getCenter(key('voucher_category_games'));
      // Arabic reads from the right: all, airtime, bills, then the categories.
      expect(all.dx, greaterThan(airtime.dx));
      expect(airtime.dx, greaterThan(bills.dx));
      expect(bills.dx, greaterThan(games.dx));
      expect(find.text('الشحن المباشر'), findsWidgets);
      expect(find.text('دفع الفواتير'), findsWidgets);
    });

    testServices('is just the cards when the server lists no services', (
      tester,
    ) async {
      await openShop(tester, withServices: false);

      expect(find.byType(ServicesStrip), findsNothing);
      expect(key('voucher_service_tab_airtime'), findsNothing);
      expect(key('voucher_service_tab_bills'), findsNothing);
      expect(find.text('آيتونز'), findsOneWidget);
    });

    testServices('leaves the services off a till built without integrations', (
      tester,
    ) async {
      final menu = servicesMenu();
      await tester.pumpWidget(
        servicesApp(
          PosVoucherMenuView(
            menu: menu,
            animateSkeleton: false,
            shelves: null,
            onBrandSelected: (_) {},
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(ServicesStrip), findsNothing);
      expect(key('voucher_service_tab_airtime'), findsNothing);
      expect(find.text('آيتونز'), findsOneWidget);
    });
  });

  group('test mode', () {
    const banner = 'وضع تجريبي — لا يُرسل رصيد حقيقي ولا يُدفع شيء';

    testServices('is said over the services strip', (tester) async {
      await openShop(tester, testMode: true);

      expect(find.byType(ServicesStrip), findsOneWidget);
      expect(key('service_test_mode_banner'), findsOneWidget);
      expect(find.text(banner), findsOneWidget);
      final shown = tester.getRect(key('service_test_mode_banner'));
      expect(
        shown.top,
        lessThan(tester.getRect(key('service_card_airtime')).top),
        reason: 'above the cards it warns about',
      );
    });

    testServices('is not said on the live supplier', (tester) async {
      await openShop(tester);

      expect(key('service_test_mode_banner'), findsNothing);
    });

    testServices('is said over the airtime tab, and the bills tab', (
      tester,
    ) async {
      await openShop(tester, testMode: true);

      await tester.tap(key('voucher_service_tab_airtime'));
      await settle(tester);
      expect(find.byType(AirtimeLauncher), findsOneWidget);
      expect(key('service_test_mode_banner'), findsOneWidget);

      await tester.tap(key('voucher_service_tab_bills'));
      await settle(tester);
      expect(find.byType(BillTypesGrid), findsOneWidget);
      expect(key('service_test_mode_banner'), findsOneWidget);
    });

    testServices('is said at the top of a bill flow', (tester) async {
      await openShop(tester, testMode: true);

      await tapKey(tester, 'service_card_electricity');

      // The strip's own banner is still behind the dialog; the dialog has one.
      expect(
        find.descendant(
          of: find.byType(BillFlowSheet),
          matching: key('service_test_mode_banner'),
        ),
        findsOneWidget,
      );
    });

    testServices('one service saying so is enough to say it on the strip', (
      tester,
    ) async {
      final menu = servicesMenu();
      final entryOnly = VoucherMenu.fromJson({
        'available': true,
        'provider': 'pointy',
        'services': [
          for (final service in servicesPreviewMenuServicesJson())
            if (service['key'] == 'airtime')
              {...service, 'test_mode': true}
            else
              service,
        ],
      });
      expect(menu.isTestMode, isFalse);
      expect(entryOnly.isTestMode, isTrue);
      final integrations = ServicesTillIntegrations()..menu = entryOnly;
      final viewModel = await openTill(integrations);
      disposeWithTest(viewModel.dispose);
      await pumpPosScreen(
        tester,
        viewModel,
        integrations,
        size: const Size(1440, 1000),
      );
      await tester.tap(find.text('كروت دفتر'));
      await settle(tester);

      expect(key('service_test_mode_banner'), findsOneWidget);
    });

    testServices('marks the line in the cart, and the sale can still be made', (
      tester,
    ) async {
      final viewModel = await openShop(tester, testMode: true);

      await tester.tap(key('voucher_service_tab_airtime'));
      await settle(tester);
      await tapKey(tester, 'airtime_start');
      await tapKey(tester, 'service_country_popular_ML');
      await tester.enterText(key('service_phone_field'), '70123456');
      await pumpTime(tester, 900);
      await tapKey(tester, 'airtime_next');
      await tapKey(tester, 'service_amount_5000');
      await tapKey(tester, 'airtime_next');
      await pumpTime(tester);
      await tapKey(tester, 'service_add_to_cart');
      await pumpTime(tester);

      expect(viewModel.cart, hasLength(1));
      expect(viewModel.cart.single.integration!.testMode, isTrue);
      expect(find.text('عملية تجريبية'), findsOneWidget);
      expect(key('service_test_mode_mark'), findsOneWidget);
    });

    testServices('marks a bill in the cart too', (tester) async {
      final viewModel = await openShop(tester, testMode: true);

      await tapKey(tester, 'service_card_electricity');
      await tapKey(tester, 'service_country_NG');
      await tapKey(tester, 'bill_provider_5');
      await tester.enterText(key('bill_account_field'), '45012345678');
      await pumpTime(tester);
      await tapKey(tester, 'bill_next');
      await tapKey(tester, 'bill_amount_5000');
      await pumpTime(tester);
      await tapKey(tester, 'service_add_to_cart');
      await pumpTime(tester, 400);

      expect(viewModel.cart.single.integration!.testMode, isTrue);
      expect(key('service_test_mode_mark'), findsOneWidget);
    });

    testServices('leaves a real line unmarked', (tester) async {
      final viewModel = await openShop(tester);

      await tester.tap(key('voucher_service_tab_airtime'));
      await settle(tester);
      await tapKey(tester, 'airtime_start');
      await tapKey(tester, 'service_country_popular_ML');
      await tester.enterText(key('service_phone_field'), '70123456');
      await pumpTime(tester, 900);
      await tapKey(tester, 'airtime_next');
      await tapKey(tester, 'service_amount_5000');
      await tapKey(tester, 'airtime_next');
      await pumpTime(tester);
      await tapKey(tester, 'service_add_to_cart');
      await pumpTime(tester);

      expect(viewModel.cart.single.integration!.testMode, isFalse);
      expect(key('service_test_mode_mark'), findsNothing);
    });
  });

  group('the «جديد» badge', () {
    testServices('is on a service the till has only just shown, and the day '
        'is kept', (tester) async {
      final store = installMemoryKeyValueStore();

      await openShop(tester);

      expect(find.text('جديد'), findsWidgets);
      final stored =
          jsonDecode((await store.getString('pos_services_first_seen'))!)
              as Map<String, Object?>;
      expect(
        stored.keys,
        containsAll(['airtime', 'electricity', 'water', 'tv', 'internet']),
      );
    });

    testServices('is gone from a service first shown more than a month ago', (
      tester,
    ) async {
      final longAgo = DateTime.now()
          .subtract(const Duration(days: 31))
          .toIso8601String();
      installMemoryKeyValueStore({
        'pos_services_first_seen': jsonEncode({
          for (final kind in [
            'airtime',
            'electricity',
            'water',
            'tv',
            'internet',
          ])
            kind: longAgo,
        }),
      });

      await openShop(tester);

      expect(key('service_card_airtime'), findsOneWidget);
      expect(find.text('جديد'), findsNothing);
    });

    testServices('stays on the services not yet a month old', (tester) async {
      final lastWeek = DateTime.now()
          .subtract(const Duration(days: 7))
          .toIso8601String();
      installMemoryKeyValueStore({
        'pos_services_first_seen': jsonEncode({'airtime': lastWeek}),
      });

      await openShop(tester);

      expect(find.text('جديد'), findsWidgets);
    });
  });

  group('the bills tab', () {
    testServices('greets a shop that has never paid a bill, until dismissed '
        'for good', (tester) async {
      await openShop(tester);
      await tester.tap(key('voucher_service_tab_bills'));
      await settle(tester);

      expect(key('bills_explainer'), findsOneWidget);
      expect(
        find.textContaining('سدّد فواتير الكهرباء والمياه والتلفزيون'),
        findsOneWidget,
      );
      expect(key('bills_help'), findsNothing, reason: 'the banner has it');

      await tester.tap(key('service_explainer_dismiss'));
      await settle(tester);
      expect(key('bills_explainer'), findsNothing);
      expect(key('bills_help'), findsOneWidget, reason: 'a link is left');
    });

    testServices('«كيف يعمل؟» opens the three steps and what is not possible', (
      tester,
    ) async {
      await openShop(tester);
      await tester.tap(key('voucher_service_tab_bills'));
      await settle(tester);

      await tester.tap(key('service_explainer_how'));
      await settle(tester);

      expect(find.text('كيف يعمل دفع الفواتير؟'), findsOneWidget);
      expect(find.textContaining('اختر الدولة والجهة'), findsOneWidget);
      expect(
        find.textContaining('لا يمكن استرجاع الدفع بعد إرساله'),
        findsOneWidget,
      );
      await tester.tap(key('service_how_done'));
      await settle(tester);
      expect(find.text('كيف يعمل دفع الفواتير؟'), findsNothing);
    });

    testServices('stays dismissed on the till, and the help link reopens the '
        'sheet', (tester) async {
      await openShop(tester);
      await tester.tap(key('voucher_service_tab_bills'));
      await settle(tester);
      await tester.tap(key('service_explainer_dismiss'));
      await settle(tester);

      await tester.tap(key('voucher_service_tab_airtime'));
      await settle(tester);
      await tester.tap(key('voucher_service_tab_bills'));
      await settle(tester);
      expect(key('bills_explainer'), findsNothing);

      await tester.tap(key('bills_help'));
      await settle(tester);
      expect(find.text('كيف يعمل دفع الفواتير؟'), findsOneWidget);
    });
  });

  group('airtime', () {
    testServices('its card opens the tab, and the form is on one screen', (
      tester,
    ) async {
      await openShop(tester);

      await tapKey(tester, 'service_card_airtime');

      expect(find.byType(AirtimeLauncher), findsOneWidget);
      expect(key('airtime_start'), findsOneWidget);
      await tapKey(tester, 'airtime_start');
      expect(key('service_country_search'), findsOneWidget);
      expect(find.byType(ServicesStrip), findsNothing);
    });

    testServices('from the number to a line in the invoice', (tester) async {
      final viewModel = await openShop(tester);

      await tester.tap(key('voucher_service_tab_airtime'));
      await settle(tester);
      await tapKey(tester, 'airtime_start');
      await tapKey(tester, 'service_country_popular_ML');
      await tester.enterText(key('service_phone_field'), '70123456');
      await pumpTime(tester, 900);
      await tapKey(tester, 'airtime_next');
      await tapKey(tester, 'service_amount_5000');
      await tapKey(tester, 'airtime_next');
      await pumpTime(tester);
      await tapKey(tester, 'service_add_to_cart');
      await pumpTime(tester);

      expect(viewModel.cart, hasLength(1));
      final line = viewModel.cart.single;
      expect(line.isDirectService, isTrue);
      expect(line.integration!.optionCode, 'air:289:5000:XOF');
      expect(line.integration!.subscriberRef, '+22370123456');
      expect(line.unitPrice, 96.5);
      expect(line.variant.id, 9301, reason: 'the menu\'s airtime product');
      expect(viewModel.subtotal, 96.5);
      // The cart says where it goes, in Arabic.
      expect(find.text('شحن مباشر'), findsOneWidget);
      expect(find.textContaining('إلى'), findsWidgets);
      expect(find.text('أُضيف الشحن المباشر إلى السلة'), findsOneWidget);
    });

    testServices('a number half typed survives a visit to another tab', (
      tester,
    ) async {
      await openShop(tester);
      await tester.tap(key('voucher_service_tab_airtime'));
      await settle(tester);
      await tapKey(tester, 'airtime_start');
      await tapKey(tester, 'service_country_popular_ML');
      await tester.enterText(key('service_phone_field'), '70123');
      await pumpTime(tester, 900);
      await tapKey(tester, 'airtime_close');

      await tester.tap(key('voucher_category_all'));
      await settle(tester);
      expect(find.byType(AirtimeLauncher), findsNothing);
      await tester.tap(key('voucher_service_tab_airtime'));
      await settle(tester);
      await tapKey(tester, 'airtime_start');

      final field = tester.widget<TextField>(key('service_phone_field'));
      expect(field.controller!.text, '70 12 3');
      expect(key('airtime_selected_country'), findsOneWidget);
    });

    testServices('a till that cannot sell fills the form but cannot add it', (
      tester,
    ) async {
      final integrations = ServicesTillIntegrations();
      final shelves = PosServiceShelves(repository: integrations);
      disposeWithTest(shelves.dispose);
      shelves.requestTab(ServiceKind.airtime);
      await tester.pumpWidget(
        servicesApp(
          PosVoucherMenuView(
            menu: servicesMenu(),
            animateSkeleton: false,
            shelves: shelves,
            onServiceAdd: null,
          ),
        ),
      );
      await settle(tester);
      await tapKey(tester, 'airtime_start');
      await tapKey(tester, 'service_country_popular_ML');
      await tester.enterText(key('service_phone_field'), '70123456');
      await pumpTime(tester, 900);
      await tapKey(tester, 'airtime_next');
      await tapKey(tester, 'service_amount_5000');
      await tapKey(tester, 'airtime_next');
      await pumpTime(tester);

      expect(shelves.airtime!.canAdd, isTrue);
      expect(
        tester.widget<FilledButton>(key('service_add_to_cart')).onPressed,
        isNull,
      );
    });
  });

  group('bills', () {
    testServices('their tab lists one card per type of bill', (tester) async {
      await openShop(tester);

      await tester.tap(key('voucher_service_tab_bills'));
      await settle(tester);

      expect(find.byType(BillTypesGrid), findsOneWidget);
      for (final type in ['electricity', 'water', 'tv', 'internet']) {
        expect(key('bill_card_$type'), findsOneWidget);
      }
      expect(find.text('فواتير المياه'), findsWidgets);
      expect(find.byType(AirtimeLauncher), findsNothing);
    });

    testServices('a card opens its dialog; finishing it adds a line', (
      tester,
    ) async {
      final viewModel = await openShop(tester);

      await tapKey(tester, 'service_card_electricity');
      expect(find.text('اختر الدولة'), findsOneWidget);

      await tapKey(tester, 'service_country_NG');
      await tapKey(tester, 'bill_provider_5');
      await tester.enterText(key('bill_account_field'), '45012345678');
      await pumpTime(tester);
      await tapKey(tester, 'bill_next');
      await tapKey(tester, 'bill_amount_5000');
      await pumpTime(tester);
      await tapKey(tester, 'service_add_to_cart');
      await pumpTime(tester, 400);

      // The dialog is gone and the invoice has the bill.
      expect(key('bill_summary'), findsNothing);
      expect(viewModel.cart, hasLength(1));
      final line = viewModel.cart.single;
      expect(line.isDirectService, isTrue);
      expect(line.integration!.optionCode, 'bill:5:5000:NGN');
      expect(line.integration!.subscriberRef, '45012345678');
      expect(line.variant.id, 9302);
      expect(find.text('دفع فاتورة'), findsOneWidget);
      expect(find.textContaining('رقم'), findsWidgets);
      expect(find.text('أُضيفت الفاتورة إلى السلة'), findsOneWidget);
    });

    testServices('closing the dialog adds nothing', (tester) async {
      final viewModel = await openShop(tester);

      await tapKey(tester, 'service_card_water');
      expect(find.text('أدخل رقم الحساب ورقم الفاتورة'), findsOneWidget);
      await tapKey(tester, 'bill_close');

      expect(key('bill_account_field'), findsNothing);
      expect(viewModel.cart, isEmpty);
    });

    testServices('water, sold in Senegal only, skips straight to the invoice', (
      tester,
    ) async {
      await openShop(tester);

      await tapKey(tester, 'service_card_water');

      expect(key('service_country_SN'), findsNothing);
      expect(key('bill_account_field'), findsOneWidget);
      expect(key('bill_invoice_field'), findsOneWidget);
    });
  });

  group('while a provider performs what the sale sold', () {
    const airtime = ServiceQuote(
      kind: ServiceKind.airtime,
      optionCode: 'air:289:5000:XOF',
      optionLabel: 'أورنج مالي · 5,000 فرنك أفريقي',
      subscriberRef: '+22370123456',
      price: 96.5,
      receiveAmount: '5000',
      receiveCurrency: 'XOF',
      quote: 'sealed.air:289:5000:XOF.96.50',
      serviceVariantId: 9301,
    );
    IntegrationChargeResult charged() => const IntegrationChargeResult(
      fulfillment: 1,
      orderLine: 7,
      provider: 'pointy',
      kind: 'airtime',
      subscriberRef: '+22370123456',
      outcome: 'charged',
      status: 'confirmed',
    );

    testServices(
      'the till is covered, and counts the seconds, until it answers',
      (tester) async {
        final integrations = ServicesTillIntegrations();
        final gate = Completer<void>();
        integrations
          ..chargeGate = gate.future
          ..chargeAnswers = [
            Ok([charged()]),
          ];
        final viewModel = await openTill(integrations);
        disposeWithTest(viewModel.dispose);
        await pumpPosScreen(tester, viewModel, integrations);
        viewModel.addServiceLine(quote: airtime, variantId: 9301, title: 'شحن');
        await tester.pump();
        expect(key('provider_charge_overlay'), findsNothing);

        final checkout = viewModel.checkoutCurrentSale(
          payments: const [
            SaleCheckoutPaymentDraft(method: PaymentMethod.cash, amount: 96.5),
          ],
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(key('provider_charge_overlay'), findsOneWidget);
        expect(find.text('جارٍ تنفيذ الشحن… لا تُغلق الشاشة'), findsOneWidget);
        expect(find.text('لم تمضِ ثانية'), findsOneWidget);
        await tester.pump(const Duration(seconds: 3));
        expect(find.text('مضت 3 ثوانٍ'), findsOneWidget);
        // Nothing under it can be touched, and a tap on it closes nothing.
        final barrier = tester.widget<ModalBarrier>(
          find.descendant(
            of: key('provider_charge_overlay'),
            matching: find.byType(ModalBarrier),
          ),
        );
        expect(barrier.dismissible, isFalse);

        gate.complete();
        final outcome = await checkout;
        await tester.pump();

        expect(outcome.recharges.single.isCharged, isTrue);
        expect(key('provider_charge_overlay'), findsNothing);
      },
    );

    testServices(
      'is not drawn for a sale that sold nothing a provider performs',
      (tester) async {
        final integrations = ServicesTillIntegrations();
        final viewModel = await openTill(integrations);
        disposeWithTest(viewModel.dispose);
        await pumpPosScreen(tester, viewModel, integrations);

        expect(viewModel.isChargingProviders, isFalse);
        expect(key('provider_charge_overlay'), findsNothing);
      },
    );
  });

  group('a service line priced a while ago', () {
    final airtime = ServiceQuote(
      kind: ServiceKind.airtime,
      optionCode: 'air:289:5000:XOF',
      optionLabel: 'أورنج مالي · 5,000 فرنك أفريقي',
      subscriberRef: '+22370123456',
      price: 96.5,
      receiveAmount: '5000',
      receiveCurrency: 'XOF',
      quote: 'sealed.air:289:5000:XOF.96.50',
      serviceVariantId: 9301,
      request: const ServiceQuoteRequest.airtime(
        country: 'ML',
        operatorId: 289,
        phone: '70123456',
        amount: '5000',
        amountCurrency: 'XOF',
      ),
    );

    testServices(
      'is priced again when pay is pressed, and the cashier decides a moved price',
      (tester) async {
        final integrations = ServicesTillIntegrations();
        final viewModel = await openTill(
          integrations,
          serviceQuoteFreshFor: Duration.zero,
        );
        disposeWithTest(viewModel.dispose);
        await pumpPosScreen(tester, viewModel, integrations);
        viewModel.addServiceLine(quote: airtime, variantId: 9301, title: 'شحن');
        await tester.pump(const Duration(milliseconds: 50));
        integrations.quotePrice = 99;

        await tester.tap(find.textContaining('ادفع').first);
        await tester.pump(const Duration(milliseconds: 200));
        await tester.pump(const Duration(milliseconds: 200));

        expect(find.text('تغيّر سعر الخدمة'), findsOneWidget);
        expect(
          find.textContaining('كان 96.50 د.ل ← أصبح 99.00 د.ل'),
          findsOneWidget,
        );
        expect(key('payment_sheet'), findsNothing, reason: 'stops here');
        expect(
          viewModel.cart.single.unitPrice,
          96.5,
          reason: 'not changed yet',
        );

        await tester.tap(key('service_requote_accept'));
        await tester.pump(const Duration(milliseconds: 200));
        await tester.pump(const Duration(milliseconds: 200));

        expect(find.text('تغيّر سعر الخدمة'), findsNothing);
        expect(viewModel.cart.single.unitPrice, 99);
        expect(
          key('payment_sheet'),
          findsNothing,
          reason: 'the new total is seen first',
        );
      },
    );

    testServices('cancelling leaves the line as it was', (tester) async {
      final integrations = ServicesTillIntegrations();
      final viewModel = await openTill(
        integrations,
        serviceQuoteFreshFor: Duration.zero,
      );
      disposeWithTest(viewModel.dispose);
      await pumpPosScreen(tester, viewModel, integrations);
      viewModel.addServiceLine(quote: airtime, variantId: 9301, title: 'شحن');
      await tester.pump(const Duration(milliseconds: 50));
      integrations.quotePrice = 99;

      await tester.tap(find.textContaining('ادفع').first);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(key('service_requote_cancel'));
      await tester.pump(const Duration(milliseconds: 200));

      expect(viewModel.cart.single.unitPrice, 96.5);
      expect(viewModel.cart, hasLength(1));
    });

    testServices(
      'a held invoice that is switched back to asks about a moved price at once',
      (tester) async {
        final integrations = ServicesTillIntegrations();
        final viewModel = await openTill(
          integrations,
          serviceQuoteFreshFor: Duration.zero,
        );
        disposeWithTest(viewModel.dispose);
        await pumpPosScreen(tester, viewModel, integrations);
        viewModel.addServiceLine(quote: airtime, variantId: 9301, title: 'شحن');
        final heldId = viewModel.saleSessions.first.id;
        viewModel.startNewSaleSession();
        await tester.pump(const Duration(milliseconds: 50));
        integrations.quotePrice = 99;

        viewModel.switchSaleSession(heldId);
        await tester.pump(const Duration(milliseconds: 200));
        await tester.pump(const Duration(milliseconds: 200));

        expect(find.text('تغيّر سعر الخدمة'), findsOneWidget);
      },
    );
  });

  group('a tab asked for from elsewhere', () {
    testServices('opens when the menu does', (tester) async {
      final integrations = ServicesTillIntegrations();
      final shelves = PosServiceShelves(repository: integrations);
      disposeWithTest(shelves.dispose);
      shelves.requestTab(ServiceKind.bill);
      await tester.pumpWidget(
        servicesApp(
          PosVoucherMenuView(
            menu: servicesMenu(),
            animateSkeleton: false,
            shelves: shelves,
          ),
        ),
      );
      await settle(tester);

      expect(find.byType(BillTypesGrid), findsOneWidget);
      expect(shelves.takeRequestedTab(), isNull, reason: 'asked once');
    });
  });

  group('room', () {
    for (final (name, size) in const [
      ('a 1366 till', Size(1366, 768)),
      ('a 1024 till', Size(1024, 768)),
    ]) {
      testServices('$name draws the strip and both tabs without overflow', (
        tester,
      ) async {
        await openShop(tester, size: size);
        expect(tester.takeException(), isNull, reason: 'strip');

        await tester.tap(key('voucher_service_tab_airtime'));
        await settle(tester);
        await tapKey(tester, 'airtime_start');
        await tapKey(tester, 'service_country_popular_ML');
        await tester.enterText(key('service_phone_field'), '70123456');
        await pumpTime(tester, 900);
        await tapKey(tester, 'airtime_next');
        await tapKey(tester, 'service_amount_5000');
        await tapKey(tester, 'airtime_next');
        await pumpTime(tester);
        expect(tester.takeException(), isNull, reason: 'airtime');

        await tester.tap(key('voucher_service_tab_bills'));
        await settle(tester);
        expect(tester.takeException(), isNull, reason: 'bills');
      });
    }
  });

  test('the fixture lists a card for every type the pane draws', () {
    final cards = servicesMenu().sellableServices.map((s) => s.key).toList();
    expect(cards, [
      'airtime',
      'bill:electricity',
      'bill:water',
      'bill:tv',
      'bill:internet',
    ]);
  });
}
