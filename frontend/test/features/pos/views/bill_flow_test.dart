import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/dev/services_fake_repository.dart';
import 'package:pointy_frontend/src/data/models/service_kinds.dart';
import 'package:pointy_frontend/src/data/models/service_quote.dart';
import 'package:pointy_frontend/src/data/models/services_directory.dart';
import 'package:pointy_frontend/src/features/pos/view_models/bill_flow_view_model.dart';
import 'package:pointy_frontend/src/features/pos/view_models/services_catalog.dart';
import 'package:pointy_frontend/src/features/pos/views/direct_services/bill_flow_sheet.dart';
import 'package:pointy_frontend/src/shared/barcode/barcode_scan_listener.dart';

import '../../../support/scan_burst.dart';
import '../../../support/services_testing.dart';
import '../../../support/test_fonts.dart';

/// Paying a bill abroad as the cashier meets it: a card for the type opens a
/// dialog that asks, one thing at a time, for the country, the company, the
/// number on the bill and the amount — then reads everything back.
void main() {
  setUpAll(loadAppFonts);

  Finder key(String name) => find.byKey(ValueKey(name));

  Future<void> pumpTime(WidgetTester tester, [int milliseconds = 120]) async {
    await tester.pump(Duration(milliseconds: milliseconds));
    await tester.pump(const Duration(milliseconds: 50));
  }

  Future<void> settle(WidgetTester tester) =>
      tester.pumpAndSettle(const Duration(milliseconds: 100));

  Future<void> tapKey(WidgetTester tester, String name) async {
    await tester.ensureVisible(key(name));
    await tester.tap(key(name));
    await settle(tester);
  }

  Future<void> typeInto(WidgetTester tester, String name, String text) async {
    await tester.enterText(key(name), text);
    await pumpTime(tester);
  }

  bool nextEnabled(WidgetTester tester) =>
      tester.widget<FilledButton>(key('bill_next')).onPressed != null;

  bool addEnabled(WidgetTester tester) =>
      tester.widget<FilledButton>(key('service_add_to_cart')).onPressed != null;

  group('electricity, through the five steps', () {
    testServices(
      'the country, the company, the meter, the amount, the summary',
      (tester) async {
        final harness = await pumpBillFlow(tester, BillType.electricity);

        // ① the country: only countries that have electricity, nothing else.
        expect(find.text('فواتير الكهرباء'), findsWidgets);
        expect(find.text('اختر الدولة'), findsOneWidget);
        expect(find.textContaining('تحتاج: رقم العدّاد'), findsOneWidget);
        expect(key('bill_back'), findsNothing, reason: 'nothing to go back to');
        for (final code in ['NG', 'SN', 'ML', 'ZA']) {
          expect(key('service_country_$code'), findsOneWidget);
        }
        expect(key('service_country_EG'), findsNothing);
        await tapKey(tester, 'service_country_NG');

        // ② the company, told apart by how it is paid.
        expect(find.text('اختر الجهة'), findsOneWidget);
        expect(find.textContaining('عدّاد مسبق الدفع'), findsOneWidget);
        expect(find.textContaining('فاتورة لاحقة الدفع'), findsOneWidget);
        expect(find.text('كهرباء إيكيجا (مسبقة الدفع)'), findsOneWidget);
        expect(key('bill_provider_search'), findsOneWidget);
        await tapKey(tester, 'bill_provider_5');

        // ③ the number on the bill, with its name and an example.
        expect(find.text('أدخل رقم العدّاد'), findsOneWidget);
        expect(find.text('مثال: 04223568280'), findsOneWidget);
        expect(
          find.text('ستظهر على الإيصال شيفرة الشحن لإدخالها في العدّاد.'),
          findsOneWidget,
        );
        expect(nextEnabled(tester), isFalse);
        await typeInto(tester, 'bill_account_field', '4501 2345 678');
        expect(
          harness.viewModel.account,
          '45012345678',
          reason: 'spaces are not part of a number',
        );
        expect(nextEnabled(tester), isTrue);
        await tapKey(tester, 'bill_next');

        // ④ the amount: round suggestions priced, and an amount of one's own.
        expect(find.text('اختر المبلغ'), findsWidgets);
        expect(key('bill_amount_5000'), findsOneWidget);
        expect(key('bill_amount_other'), findsOneWidget);
        await tapKey(tester, 'bill_amount_5000');
        await pumpTime(tester);

        // ⑤ the summary: read back to the customer, priced by the server.
        expect(find.text('راجع الطلب ثم أضفه إلى السلة'), findsOneWidget);
        expect(key('bill_summary'), findsOneWidget);
        expect(find.text('نيجيريا'), findsWidgets);
        expect(find.text('كهرباء إيكيجا (مسبقة الدفع)'), findsWidgets);
        expect(find.text('يدفع الزبون'), findsOneWidget);
        expect(
          find.textContaining('لا يمكن استرجاع الدفع بعد إرساله'),
          findsWidgets,
        );
        expect(addEnabled(tester), isTrue);

        await tester.tap(key('service_add_to_cart'));
        await tester.pump();

        expect(harness.added, hasLength(1));
        expect(harness.added.single.optionCode, 'bill:5:5000:NGN');
        expect(harness.added.single.kind, ServiceKind.bill);
        expect(harness.added.single.subscriberRef, harness.viewModel.account);
        final request = harness.repository.quotes.last;
        expect(request.kind, ServiceKind.bill);
        expect(request.country, 'NG');
        expect(request.billerId, 5);
        expect(request.amount, '5000');
        expect(request.amountCurrency, 'NGN');
        expect(request.amountId, isNull, reason: 'only a plan has an id');
        expect(request.invoiceId, isNull);
      },
    );

    testServices(
      'back steps back, one step at a time, keeping what was chosen',
      (tester) async {
        final harness = await pumpBillFlow(tester, BillType.electricity);
        await tapKey(tester, 'service_country_NG');
        await tapKey(tester, 'bill_provider_5');
        await typeInto(tester, 'bill_account_field', '45012345678');
        await tapKey(tester, 'bill_next');
        await tapKey(tester, 'bill_amount_5000');
        await pumpTime(tester);
        expect(harness.viewModel.step, BillFlowStep.summary);

        await tapKey(tester, 'bill_back');
        expect(harness.viewModel.step, BillFlowStep.amount);
        await tapKey(tester, 'bill_back');
        expect(harness.viewModel.step, BillFlowStep.account);
        final field = tester.widget<TextField>(key('bill_account_field'));
        expect(
          field.controller!.text,
          '45012345678',
          reason: 'what was typed stays',
        );
        await tapKey(tester, 'bill_back');
        expect(harness.viewModel.step, BillFlowStep.provider);
        await tapKey(tester, 'bill_back');
        expect(harness.viewModel.step, BillFlowStep.country);
        expect(key('bill_back'), findsNothing);
        expect(harness.added, isEmpty);
      },
    );

    testServices(
      'the breadcrumb names the country and the company, and goes back to them',
      (tester) async {
        final harness = await pumpBillFlow(tester, BillType.electricity);
        await tapKey(tester, 'service_country_NG');
        await tapKey(tester, 'bill_provider_5');
        await typeInto(tester, 'bill_account_field', '45012345678');

        expect(key('bill_crumb_country'), findsOneWidget);
        expect(key('bill_crumb_provider'), findsOneWidget);

        await tester.tap(key('bill_crumb_provider'));
        await settle(tester);
        expect(harness.viewModel.step, BillFlowStep.provider);

        await tester.tap(key('bill_crumb_country'));
        await settle(tester);
        expect(harness.viewModel.step, BillFlowStep.country);
      },
    );

    testServices(
      'an amount of one\'s own is priced as it is typed, within limits',
      (tester) async {
        final harness = await pumpBillFlow(tester, BillType.electricity);
        await tapKey(tester, 'service_country_NG');
        await tapKey(tester, 'bill_provider_5');
        await typeInto(tester, 'bill_account_field', '45012345678');
        await tapKey(tester, 'bill_next');

        await tapKey(tester, 'bill_amount_other');
        expect(find.text('من 1,000 إلى 300,000'), findsWidgets);
        await typeInto(tester, 'service_custom_amount', '500');
        expect(find.text('أقل مبلغ مسموح 1,000'), findsOneWidget);
        expect(nextEnabled(tester), isFalse);

        await typeInto(tester, 'service_custom_amount', '7500');
        await pumpTime(tester, 500);
        expect(nextEnabled(tester), isTrue);
        await tester.tap(key('bill_next'));
        await settle(tester);
        await pumpTime(tester);

        expect(harness.viewModel.step, BillFlowStep.summary);
        expect(addEnabled(tester), isTrue);
        await tester.tap(key('service_add_to_cart'));
        await tester.pump();
        expect(harness.added.single.optionCode, 'bill:5:7500:NGN');
      },
    );

    testServices(
      'a till that cannot sell can read the summary but not add it',
      (tester) async {
        final harness = await pumpBillFlow(
          tester,
          BillType.electricity,
          canSell: false,
        );
        await tapKey(tester, 'service_country_NG');
        await tapKey(tester, 'bill_provider_5');
        await typeInto(tester, 'bill_account_field', '45012345678');
        await tapKey(tester, 'bill_next');
        await tapKey(tester, 'bill_amount_5000');
        await pumpTime(tester);

        expect(harness.viewModel.canAdd, isTrue);
        expect(addEnabled(tester), isFalse);
      },
    );

    testServices(
      'a number the company refuses is said in Arabic at the summary',
      (tester) async {
        final repository = PreviewServicesRepository();
        final harness = await pumpBillFlow(
          tester,
          BillType.electricity,
          repository: repository,
        );
        await tapKey(tester, 'service_country_NG');
        await tapKey(tester, 'bill_provider_5');
        await typeInto(tester, 'bill_account_field', '45012345678');
        await tapKey(tester, 'bill_next');
        repository.refuseQuote = ServiceRefusalCode.invalidAccount;
        await tapKey(tester, 'bill_amount_5000');
        await pumpTime(tester);

        expect(
          find.text('الرقم غير صالح لدى هذه الجهة، تأكد منه'),
          findsOneWidget,
        );
        expect(addEnabled(tester), isFalse);
        expect(harness.added, isEmpty);
      },
    );

    testServices('an invoice number the company refuses says what it takes', (
      tester,
    ) async {
      final repository = PreviewServicesRepository();
      final harness = await pumpBillFlow(
        tester,
        BillType.electricity,
        repository: repository,
      );
      await tapKey(tester, 'service_country_NG');
      await tapKey(tester, 'bill_provider_5');
      await typeInto(tester, 'bill_account_field', '45012345678');
      await tapKey(tester, 'bill_next');
      repository.refuseQuote = ServiceRefusalCode.invalidInvoice;
      await tapKey(tester, 'bill_amount_5000');
      await pumpTime(tester);

      expect(
        find.text(
          'رقم الفاتورة غير صالح — 24 خانة كحد أقصى من الأحرف الإنجليزية والأرقام و - _ /',
        ),
        findsOneWidget,
      );
      expect(addEnabled(tester), isFalse);
      expect(
        key('service_retry'),
        findsNothing,
        reason: 'asking again is no help',
      );
      expect(harness.added, isEmpty);
    });

    testServices(
      'a company the list no longer holds reads the list again, then prices',
      (tester) async {
        final repository = PreviewServicesRepository();
        final harness = await pumpBillFlow(
          tester,
          BillType.electricity,
          repository: repository,
        );
        await tapKey(tester, 'service_country_NG');
        await tapKey(tester, 'bill_provider_5');
        await typeInto(tester, 'bill_account_field', '45012345678');
        await tapKey(tester, 'bill_next');
        repository.refuseQuote = ServiceRefusalCode.unknownBiller;
        await tapKey(tester, 'bill_amount_5000');
        await pumpTime(tester);

        expect(
          find.descendant(
            of: key('service_retry'),
            matching: find.text('تحديث القائمة'),
          ),
          findsOneWidget,
        );
        final directoryReads = repository.directoryReads;
        final asked = repository.quotes.length;

        repository.refuseQuote = null;
        await tester.tap(key('service_retry'));
        await pumpTime(tester, 200);

        expect(repository.directoryReads, directoryReads + 1);
        expect(repository.quotes.length, greaterThan(asked));
        expect(harness.viewModel.canAdd, isTrue);
        expect(addEnabled(tester), isTrue);
      },
    );
  });

  group('test mode', () {
    const banner = 'وضع تجريبي — لا يُرسل رصيد حقيقي ولا يُدفع شيء';

    testServices('is said at the top of the flow, from the first step to the '
        'last', (tester) async {
      final repository = PreviewServicesRepository()..testMode = true;
      await pumpBillFlow(tester, BillType.electricity, repository: repository);

      expect(key('service_test_mode_banner'), findsOneWidget);
      expect(find.text(banner), findsOneWidget);

      await tapKey(tester, 'service_country_NG');
      await tapKey(tester, 'bill_provider_5');
      await typeInto(tester, 'bill_account_field', '45012345678');
      await tapKey(tester, 'bill_next');
      await tapKey(tester, 'bill_amount_5000');
      await pumpTime(tester);

      expect(find.text('راجع الطلب ثم أضفه إلى السلة'), findsOneWidget);
      expect(key('service_test_mode_banner'), findsOneWidget);
      expect(addEnabled(tester), isTrue, reason: 'marked, not stopped');
    });

    testServices('is not said on the live supplier', (tester) async {
      await pumpBillFlow(tester, BillType.electricity);

      expect(key('service_test_mode_banner'), findsNothing);
    });

    testServices('is said when the menu says so', (tester) async {
      await pumpBillFlow(tester, BillType.electricity, testMode: true);

      expect(key('service_test_mode_banner'), findsOneWidget);
    });

    for (final (name, size, scale) in const [
      ('a phone', Size(390, 844), 1.0),
      ('a small phone with text a third bigger', Size(360, 640), 1.3),
    ]) {
      testServices('$name draws it without overflow', (tester) async {
        final repository = PreviewServicesRepository()..testMode = true;
        await pumpBillFlow(
          tester,
          BillType.electricity,
          repository: repository,
          size: size,
          textScale: scale,
        );
        await tapKey(tester, 'service_country_NG');

        expect(key('service_test_mode_banner'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('television with fixed plans', () {
    testServices('Canal+ Mali sells plans: listed in Arabic with their price', (
      tester,
    ) async {
      final harness = await pumpBillFlow(tester, BillType.tv);
      expect(find.text('اشتراكات التلفزيون'), findsWidgets);
      await tapKey(tester, 'service_country_ML');

      // Mali has one company, so the cashier is not asked to choose it.
      expect(harness.viewModel.isProviderFixed, isTrue);
      expect(harness.viewModel.step, BillFlowStep.account);
      expect(find.text('أدخل رقم بطاقة الاشتراك'), findsOneWidget);
      await typeInto(tester, 'bill_account_field', '0123456789');
      await tapKey(tester, 'bill_next');

      expect(find.text('اختر الباقة'), findsOneWidget);
      for (final plan in [241, 242, 243, 244, 245, 246]) {
        expect(key('bill_plan_$plan'), findsOneWidget);
      }
      expect(find.text('كانال بلس أكسيس – شهر'), findsOneWidget);
      expect(find.text('كانال بلس أكسيس – 3 أشهر'), findsOneWidget);
      expect(key('bill_amount_other'), findsNothing, reason: 'plans only');
      expect(key('service_custom_amount'), findsNothing);

      await tapKey(tester, 'bill_plan_242');
      await pumpTime(tester);

      expect(harness.viewModel.step, BillFlowStep.summary);
      expect(find.text('كانال بلس أكسيس – شهر'), findsWidgets);
      expect(addEnabled(tester), isTrue);
      final request = harness.repository.quotes.last;
      expect(request.amountId, 242);
      expect(request.amount, '5000');
      await tester.tap(key('service_add_to_cart'));
      await tester.pump();
      expect(harness.added.single.optionCode, startsWith('bill:24:5000:XOF'));
    });
  });

  group('water, an invoice paid in Senegal only', () {
    testServices('the country and the company are chosen for the cashier', (
      tester,
    ) async {
      final harness = await pumpBillFlow(tester, BillType.water);

      expect(find.text('فواتير المياه'), findsWidgets);
      expect(harness.viewModel.isCountryFixed, isTrue);
      expect(harness.viewModel.country!.code, 'SN');
      expect(harness.viewModel.biller!.id, 52);
      expect(harness.viewModel.step, BillFlowStep.account);
      expect(key('bill_back'), findsNothing);
      expect(key('service_country_SN'), findsNothing, reason: 'never asked');
    });

    testServices(
      'account and invoice number are both asked for, then the invoice total',
      (tester) async {
        final harness = await pumpBillFlow(tester, BillType.water);

        expect(find.text('أدخل رقم الحساب ورقم الفاتورة'), findsOneWidget);
        expect(key('bill_account_field'), findsOneWidget);
        expect(key('bill_invoice_field'), findsOneWidget);
        expect(find.text('رقم الحساب / العقد'), findsOneWidget);
        expect(find.text('رقم الفاتورة'), findsOneWidget);
        expect(nextEnabled(tester), isFalse);

        await typeInto(tester, 'bill_account_field', '12345678');
        expect(nextEnabled(tester), isFalse, reason: 'the invoice is missing');
        await typeInto(tester, 'bill_invoice_field', '2024-118833');
        expect(nextEnabled(tester), isTrue);
        await tapKey(tester, 'bill_next');

        // No suggestions: the amount is whatever the invoice says.
        expect(key('bill_amount_other'), findsNothing);
        expect(
          find.text('أدخل قيمة الفاتورة كما هي مكتوبة عليها.'),
          findsOneWidget,
        );
        await typeInto(tester, 'service_custom_amount', '15000');
        await pumpTime(tester, 500);
        expect(nextEnabled(tester), isTrue);
        await tester.tap(key('bill_next'));
        await settle(tester);
        await pumpTime(tester);

        expect(harness.viewModel.step, BillFlowStep.summary);
        expect(find.text('رقم الفاتورة'), findsWidgets);
        expect(find.text('2024-118833'), findsOneWidget);
        expect(addEnabled(tester), isTrue);

        await tester.tap(key('service_add_to_cart'));
        await tester.pump();

        final request = harness.repository.quotes.last;
        expect(request.billerId, 52);
        expect(request.account, '12345678');
        expect(request.invoiceId, '2024-118833');
        expect(request.amount, '15000');
        expect(harness.added.single.optionCode, contains('2024-118833'));
      },
    );

    testServices('Enter in the account field moves to the invoice field', (
      tester,
    ) async {
      await pumpBillFlow(tester, BillType.water);
      await tester.showKeyboard(key('bill_account_field'));
      await tester.enterText(key('bill_account_field'), '12345678');
      await tester.testTextInput.receiveAction(TextInputAction.next);
      await tester.pump();

      final invoice = tester.widget<TextField>(key('bill_invoice_field'));
      expect(invoice.focusNode!.hasFocus, isTrue);
    });
  });

  group('when something goes wrong', () {
    testServices('a directory that cannot be read has a retry', (tester) async {
      final repository = PreviewServicesRepository()..failDirectory = true;
      final harness = await pumpBillFlow(
        tester,
        BillType.electricity,
        repository: repository,
      );
      expect(find.text('تعذّر تحميل الدول والشبكات.'), findsOneWidget);

      repository.failDirectory = false;
      await tester.tap(find.text('إعادة المحاولة'));
      await settle(tester);

      expect(find.text('تعذّر تحميل الدول والشبكات.'), findsNothing);
      expect(key('service_country_NG'), findsOneWidget);
      expect(harness.catalog.directory, isNotNull);
    });

    testServices('a country that cannot be read has a retry at the companies', (
      tester,
    ) async {
      final repository = PreviewServicesRepository()..failCountries.add('NG');
      final harness = await pumpBillFlow(
        tester,
        BillType.electricity,
        repository: repository,
      );
      await tapKey(tester, 'service_country_NG');

      expect(find.text('تعذّر تحميل شبكات الدولة.'), findsOneWidget);
      repository.failCountries.clear();
      await tester.tap(find.text('إعادة المحاولة'));
      await settle(tester);

      expect(find.text('تعذّر تحميل شبكات الدولة.'), findsNothing);
      expect(key('bill_provider_5'), findsOneWidget);
      expect(harness.viewModel.country!.code, 'NG');
    });

    testServices(
      'services switched off for every shop say so, not a blank list',
      (tester) async {
        final repository = PreviewServicesRepository()
          ..directory = ServicesDirectory.fromJson(const {
            'available': false,
            'error_code': 'switched_off',
            'countries': <Object?>[],
          });
        await pumpBillFlow(
          tester,
          BillType.electricity,
          repository: repository,
        );

        expect(find.text('الخدمة غير متاحة الآن'), findsOneWidget);
        expect(
          find.text('أوقفت دفتر هذه الخدمة مؤقتاً لجميع المحلات.'),
          findsOneWidget,
        );
        expect(key('service_country_NG'), findsNothing);
      },
    );

    testServices('a type with no country listed says so, not a blank list', (
      tester,
    ) async {
      final repository = PreviewServicesRepository()
        ..directory = ServicesDirectory.fromJson(const {
          'available': true,
          'countries': <Object?>[
            {
              'code': 'ML',
              'name': 'مالي',
              'dial': ['223'],
              'airtime': 3,
            },
          ],
          'bill_types': <Object?>[],
        });
      await pumpBillFlow(tester, BillType.water, repository: repository);

      expect(find.text('الخدمة غير متاحة الآن'), findsOneWidget);
      expect(find.text('لا توجد دول متاحة الآن، حاول لاحقاً.'), findsOneWidget);
    });

    testServices('the close button closes and adds nothing', (tester) async {
      final harness = await pumpBillFlow(tester, BillType.electricity);
      await tester.tap(key('bill_close'));
      await tester.pump();

      expect(harness.closed, 1);
      expect(harness.added, isEmpty);
    });

    testServices(
      '«كيف يعمل؟» says what to do and that a payment cannot be taken back',
      (tester) async {
        await pumpBillFlow(tester, BillType.electricity);
        await tester.tap(key('bill_help'));
        await settle(tester);

        expect(find.textContaining('اختر الدولة والجهة'), findsOneWidget);
        expect(find.textContaining('اكتب الرقم واختر المبلغ'), findsOneWidget);
        expect(
          find.textContaining('أضف إلى السلة وأصدر الفاتورة'),
          findsOneWidget,
        );
        expect(
          find.textContaining('للعدّاد المسبق الدفع: ستجد على الإيصال شيفرة'),
          findsOneWidget,
        );
      },
    );
  });

  group('the dialog', () {
    // The cashier meets the flow through its card: showBillFlow opens it as a
    // dialog (a sheet on a phone) and resolves to the priced bill when it is
    // added — or to nothing when it is closed.
    Future<ServiceQuote?> openAndRun(
      WidgetTester tester, {
      required BillType type,
      required Future<void> Function() inside,
      Size size = const Size(1366, 768),
    }) async {
      useWindow(tester, size);
      final repository = PreviewServicesRepository();
      final catalog = ServicesCatalog(repository: repository);
      disposeWithTest(catalog.dispose);
      ServiceQuote? result;
      var finished = false;
      await tester.pumpWidget(
        servicesApp(
          Builder(
            builder: (context) => Center(
              child: FilledButton(
                key: const ValueKey('open_bill'),
                onPressed: () async {
                  result = await showBillFlow(
                    context,
                    // The dialog owns its flow; the catalog is the till's.
                    create: () => BillFlowViewModel(
                      type: type,
                      catalog: catalog,
                      repository: repository,
                      quoteDebounce: const Duration(milliseconds: 20),
                    ),
                  );
                  finished = true;
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(key('open_bill'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      await settle(tester);
      await inside();
      await pumpTime(tester, 400);
      expect(finished, isTrue, reason: 'the dialog is gone');
      return result;
    }

    testServices('adding resolves to the priced bill and closes it', (
      tester,
    ) async {
      final quote = await openAndRun(
        tester,
        type: BillType.electricity,
        inside: () async {
          await tapKey(tester, 'service_country_NG');
          await tapKey(tester, 'bill_provider_5');
          await typeInto(tester, 'bill_account_field', '45012345678');
          await tapKey(tester, 'bill_next');
          await tapKey(tester, 'bill_amount_5000');
          await pumpTime(tester);
          await tester.tap(key('service_add_to_cart'));
          await settle(tester);
        },
      );

      expect(quote, isNotNull);
      expect(quote!.optionCode, 'bill:5:5000:NGN');
      expect(find.byType(BillFlowSheet), findsNothing);
    });

    testServices(
      'Esc steps back through the flow and closes it only at the first step',
      (tester) async {
        final quote = await openAndRun(
          tester,
          type: BillType.electricity,
          inside: () async {
            await tapKey(tester, 'service_country_NG');
            await tapKey(tester, 'bill_provider_5');
            expect(key('bill_account_field'), findsOneWidget);

            await tester.sendKeyEvent(LogicalKeyboardKey.escape);
            await settle(tester);
            expect(
              key('bill_provider_5'),
              findsOneWidget,
              reason: 'one step back',
            );
            expect(key('bill_account_field'), findsNothing);

            await tester.sendKeyEvent(LogicalKeyboardKey.escape);
            await settle(tester);
            expect(
              key('service_country_NG'),
              findsOneWidget,
              reason: 'two back',
            );
            expect(key('bill_provider_5'), findsNothing);

            // At the first step there is nowhere to go back to: it closes.
            await tester.sendKeyEvent(LogicalKeyboardKey.escape);
            await settle(tester);
            expect(find.byType(BillFlowSheet), findsNothing);
          },
        );

        expect(quote, isNull);
      },
    );

    testServices('closing resolves to nothing', (tester) async {
      final quote = await openAndRun(
        tester,
        type: BillType.electricity,
        inside: () async {
          await tester.tap(key('bill_close'));
          await settle(tester);
        },
      );

      expect(quote, isNull);
    });

    testServices('on a phone it is a sheet over the whole width', (
      tester,
    ) async {
      final quote = await openAndRun(
        tester,
        type: BillType.water,
        size: const Size(390, 844),
        inside: () async {
          expect(find.byType(BillFlowSheet), findsOneWidget);
          final box = tester.getRect(find.byType(BillFlowSheet));
          expect(box.width, greaterThan(360));
          await tester.tap(key('bill_close'));
          await settle(tester);
        },
      );

      expect(quote, isNull);
      expect(tester.takeException(), isNull);
    });
  });

  group('room', () {
    Future<void> walkThrough(WidgetTester tester, BillHarness harness) async {
      await tapKey(tester, 'service_country_NG');
      expect(tester.takeException(), isNull, reason: 'providers');
      await tapKey(tester, 'bill_provider_5');
      expect(tester.takeException(), isNull, reason: 'account');
      await typeInto(tester, 'bill_account_field', '45012345678');
      await tapKey(tester, 'bill_next');
      expect(tester.takeException(), isNull, reason: 'amount');
      await tapKey(tester, 'bill_amount_other');
      await typeInto(tester, 'service_custom_amount', '7500');
      await pumpTime(tester, 500);
      expect(tester.takeException(), isNull, reason: 'custom amount');
      await tapKey(tester, 'bill_next');
      await pumpTime(tester);
      expect(harness.viewModel.step, BillFlowStep.summary);
      expect(tester.takeException(), isNull, reason: 'summary');
    }

    for (final (name, size, scale) in const [
      ('a 1366 till', Size(1366, 768), 1.0),
      ('a 1024 till', Size(1024, 768), 1.0),
      ('a phone', Size(390, 844), 1.0),
      ('a small phone', Size(360, 640), 1.0),
      ('a 1366 till with text a third bigger', Size(1366, 768), 1.3),
      ('a phone with text a third bigger', Size(390, 844), 1.3),
    ]) {
      testServices('$name draws every step without overflowing', (
        tester,
      ) async {
        final harness = await pumpBillFlow(
          tester,
          BillType.electricity,
          size: size,
          textScale: scale,
        );
        await walkThrough(tester, harness);
      });
    }

    testServices('dark draws every step', (tester) async {
      final harness = await pumpBillFlow(
        tester,
        BillType.electricity,
        dark: true,
      );
      await walkThrough(tester, harness);
    });

    testServices('water at a third more text, both fields and the note', (
      tester,
    ) async {
      final harness = await pumpBillFlow(
        tester,
        BillType.water,
        size: const Size(390, 844),
        textScale: 1.3,
      );
      await typeInto(tester, 'bill_account_field', '12345678');
      await typeInto(tester, 'bill_invoice_field', '2024-118833');
      await tapKey(tester, 'bill_next');
      await typeInto(tester, 'service_custom_amount', '15000');
      await pumpTime(tester, 500);
      await tapKey(tester, 'bill_next');
      await pumpTime(tester);

      expect(harness.viewModel.step, BillFlowStep.summary);
      expect(tester.takeException(), isNull);
    });

    testServices('television plans at a third more text', (tester) async {
      await pumpBillFlow(
        tester,
        BillType.tv,
        size: const Size(390, 844),
        textScale: 1.3,
      );
      await tapKey(tester, 'service_country_ML');
      await typeInto(tester, 'bill_account_field', '0123456789');
      await tapKey(tester, 'bill_next');

      expect(key('bill_plan_246'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('the till\'s barcode listener', () {
    // The fields of a bill are deliberate wedge targets: a meter number can be
    // scanned off the bill itself, and must arrive whole.
    testServices(
      'a number scanned into the meter field is never a product scan',
      (tester) async {
        final burst = ScanBurst();
        final scanned = <String>[];
        useWindow(tester, const Size(1366, 768));
        final harness = BillHarness(
          type: BillType.electricity,
          repository: PreviewServicesRepository(),
        );
        await tester.pumpWidget(
          servicesApp(
            BarcodeScanListener(
              onBarcodeScanned: scanned.add,
              clock: burst.clock,
              child: Center(
                child: SizedBox(
                  width: 560,
                  child: BillFlowSheet(
                    viewModel: harness.viewModel,
                    onAdd: harness.accept,
                    onClose: () {},
                  ),
                ),
              ),
            ),
          ),
        );
        await harness.catalog.ensureLoaded();
        await settle(tester);
        await tapKey(tester, 'service_country_NG');
        await tapKey(tester, 'bill_provider_5');
        await tester.showKeyboard(key('bill_account_field'));

        final swallowed = await burst.typeAndEnter(tester, '45012345678');

        expect(scanned, isEmpty);
        expect(swallowed, isFalse);
        expect(harness.viewModel.account, '45012345678');
      },
    );
  });
}
