import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/integration_card.dart';
import 'package:pointy_frontend/src/features/pos/views/direct_services/service_delivered_dialog.dart';

import '../../../support/services_testing.dart';
import '../../../support/test_fonts.dart';

/// What the cashier is told once the sale is paid and the provider has
/// answered: what was sent where, the reference — and, for a prepaid meter, the
/// token the customer must be handed.
void main() {
  setUpAll(loadAppFonts);

  Finder key(String name) => find.byKey(ValueKey(name));

  final airtime = IntegrationChargeResult.fromJson(const {
    'fulfillment': 17,
    'provider': 'pointy',
    'kind': 'airtime',
    'subscriber_ref': '+22370123456',
    'option_label': 'أورنج مالي · 5,000 فرنك أفريقي',
    'outcome': 'charged',
    'status': 'confirmed',
    'provider_reference': '4602843',
    'receipt': {
      'title': 'شحن مباشر',
      'rows': [
        ['الشبكة', 'أورنج مالي'],
        ['الرقم', '+22370123456'],
        ['المبلغ المرسل', '5,000 فرنك أفريقي'],
        ['رقم العملية', '4602843'],
      ],
      'pin': '',
      'pin_label': 'رمز الشحن',
      'notice': 'تم إرسال الرصيد إلى الرقم المذكور، ولا يمكن استرداده.',
    },
  });
  final electricity = IntegrationChargeResult.fromJson(const {
    'fulfillment': 18,
    'provider': 'pointy',
    'kind': 'bill',
    'subscriber_ref': '04223568280',
    'option_label': 'كهرباء إيكيجا (مسبقة الدفع)',
    'outcome': 'charged',
    'status': 'confirmed',
    'receipt': {
      'title': 'دفع فاتورة كهرباء',
      'rows': [
        ['الجهة', 'كهرباء إيكيجا (مسبقة الدفع)'],
        ['رقم العدّاد', '04223568280'],
        ['المبلغ', '5,000 نيرة نيجيرية'],
        ['الوحدات', '10.7 ك.و.س'],
      ],
      'pin': '2737-6032-5315-7183-0856',
      'pin_label': 'رمز الشحن',
      'notice': 'أدخل رمز الشحن في العدّاد.',
    },
  });

  /// The dialog, opened from a button the way the cart opens it.
  Future<void> open(
    WidgetTester tester,
    List<IntegrationChargeResult> results, {
    double textScale = 1,
    Size size = const Size(1366, 768),
    bool testMode = false,
  }) async {
    useWindow(tester, size);
    await tester.pumpWidget(
      servicesApp(
        Builder(
          builder: (context) => Center(
            child: FilledButton(
              key: const ValueKey('open'),
              onPressed: () => showServiceDeliveredDialog(
                context,
                results,
                testMode: testMode,
              ),
              child: const Text('open'),
            ),
          ),
        ),
        textScale: textScale,
      ),
    );
    await tester.tap(key('open'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
  }

  testServices('airtime: what was sent where, in the server\'s own words', (
    tester,
  ) async {
    await open(tester, [airtime]);

    expect(find.text('تم إرسال الرصيد'), findsOneWidget);
    expect(find.text('الشبكة'), findsOneWidget);
    expect(find.text('أورنج مالي'), findsOneWidget);
    expect(find.text('المبلغ المرسل'), findsOneWidget);
    expect(find.text('5,000 فرنك أفريقي'), findsOneWidget);
    expect(find.text('رقم العملية'), findsOneWidget);
    expect(
      find.text('تم إرسال الرصيد إلى الرقم المذكور، ولا يمكن استرداده.'),
      findsOneWidget,
    );
    expect(key('service_delivered_token'), findsNothing);
    expect(key('service_delivered_copy'), findsNothing);
  });

  group('a sale made in test mode', () {
    testServices('says «عملية تجريبية» when the till knows it was one', (
      tester,
    ) async {
      await open(tester, [airtime], testMode: true);

      expect(key('service_test_mode_mark'), findsOneWidget);
      expect(find.text('عملية تجريبية'), findsOneWidget);
    });

    testServices('says it when the answer itself says so', (tester) async {
      final flagged = IntegrationChargeResult.fromJson(const {
        'kind': 'airtime',
        'subscriber_ref': '+22370123456',
        'outcome': 'charged',
        'test_mode': true,
        'receipt': {'title': 'شحن مباشر'},
      });
      await open(tester, [flagged]);

      expect(key('service_test_mode_mark'), findsOneWidget);
    });

    testServices('says nothing of it on a real sale', (tester) async {
      await open(tester, [airtime, electricity]);

      expect(key('service_test_mode_mark'), findsNothing);
      expect(find.text('عملية تجريبية'), findsNothing);
    });

    testServices('still shows the token, and the mark does not push it off', (
      tester,
    ) async {
      await open(
        tester,
        [electricity],
        testMode: true,
        size: const Size(360, 640),
        textScale: 1.3,
      );

      expect(key('service_test_mode_mark'), findsOneWidget);
      expect(key('service_delivered_token'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  testServices('«تم» closes it', (tester) async {
    await open(tester, [airtime]);

    await tester.tap(key('service_delivered_done'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));

    expect(key('service_delivered_dialog'), findsNothing);
  });

  testServices('airtime can be dismissed by a tap outside', (tester) async {
    await open(tester, [airtime]);

    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));

    expect(key('service_delivered_dialog'), findsNothing);
  });

  group('a prepaid meter\'s token', () {
    testServices('is large, left to right, and says what to do with it', (
      tester,
    ) async {
      await open(tester, [electricity]);

      expect(find.text('تم سداد الفاتورة'), findsOneWidget);
      final token = tester.widget<SelectableText>(
        key('service_delivered_token'),
      );
      expect(token.data, '2737-6032-5315-7183-0856');
      expect(token.textDirection, TextDirection.ltr);
      expect(find.text('رمز الشحن'), findsOneWidget);
      // One line of advice, the server's own: not that and ours, which said
      // the same thing twice.
      expect(find.text('أدخل رمز الشحن في العدّاد.'), findsOneWidget);
      expect(
        find.text('سلّم الزبون هذا الرمز ليُدخله في العدّاد.'),
        findsNothing,
      );
    });

    testServices('is told to be handed over when the slip gave no advice', (
      tester,
    ) async {
      final bare = IntegrationChargeResult.fromJson(const {
        'kind': 'bill',
        'subscriber_ref': '04223568280',
        'option_label': 'كهرباء إيكيجا (مسبقة الدفع)',
        'outcome': 'charged',
        'receipt': {
          'rows': [
            ['رقم العدّاد', '04223568280'],
          ],
          'pin': '2737-6032-5315-7183-0856',
          'pin_label': 'رمز الشحن',
        },
      });
      await open(tester, [bare]);

      expect(
        find.text('سلّم الزبون هذا الرمز ليُدخله في العدّاد.'),
        findsOneWidget,
      );
    });

    testServices('keeps the server\'s test-mode notice beside the token', (
      tester,
    ) async {
      final test = IntegrationChargeResult.fromJson(const {
        'kind': 'bill',
        'subscriber_ref': '04223568280',
        'outcome': 'charged',
        'receipt': {
          'rows': [
            ['رقم العدّاد', '04223568280'],
          ],
          'pin': 'TEST-3399-5027-4599-5760',
          'pin_label': 'رمز الشحن',
          'notice': 'عملية تجريبية: لم يتم تسديد أي مبلغ فعلي.',
        },
      });
      await open(tester, [test], testMode: true);

      expect(
        find.text('عملية تجريبية: لم يتم تسديد أي مبلغ فعلي.'),
        findsOneWidget,
      );
      expect(key('service_test_mode_mark'), findsOneWidget);
    });

    for (final (name, size, scale) in const [
      ('a till', Size(1366, 768), 1.0),
      ('a phone', Size(390, 844), 1.0),
      ('a small phone with text a third bigger', Size(360, 640), 1.3),
    ]) {
      testServices('$name keeps it whole on one line, inside its box', (
        tester,
      ) async {
        await open(tester, [electricity], size: size, textScale: scale);

        final text = tester.state<EditableTextState>(
          find.descendant(
            of: key('service_delivered_token'),
            matching: find.byType(EditableText),
          ),
        );
        final render = text.renderEditable;
        expect(
          render.size.height,
          lessThan(render.preferredLineHeight * 1.5),
          reason: 'a token split over two lines is read wrongly into a meter',
        );
        // As painted — scaled down when the dialog is narrow — it is inside
        // the box that holds it.
        final box = tester.getRect(key('service_delivered_token_box'));
        final painted = tester.getRect(key('service_delivered_token'));
        expect(painted.left, greaterThanOrEqualTo(box.left));
        expect(painted.right, lessThanOrEqualTo(box.right));
        expect(
          tester.widget<SelectableText>(key('service_delivered_token')).data,
          '2737-6032-5315-7183-0856',
          reason: 'copied whole, whatever is shown',
        );
        expect(tester.takeException(), isNull);
      });
    }

    testServices('is never lost to a stray tap outside', (tester) async {
      await open(tester, [electricity]);

      await tester.tapAt(const Offset(8, 8));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));

      expect(key('service_delivered_dialog'), findsOneWidget);
      expect(key('service_delivered_token'), findsOneWidget);
    });

    testServices('is copied with one tap, and the copy is said', (
      tester,
    ) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await open(tester, [electricity]);

      await tester.tap(key('service_delivered_copy'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(copied, '2737-6032-5315-7183-0856');
      expect(find.text('تم نسخ الرمز'), findsOneWidget);
    });
  });

  testServices('airtime and a bill together are «الخدمات»', (tester) async {
    await open(tester, [airtime, electricity]);

    expect(find.text('تم تنفيذ الخدمات'), findsOneWidget);
    expect(find.text('أورنج مالي'), findsOneWidget);
    // A number is held left to right inside the Arabic line.
    expect(find.textContaining('04223568280'), findsOneWidget);
    expect(key('service_delivered_token'), findsOneWidget);
  });

  testServices('a server that sent no rows is still read back', (tester) async {
    final bare = IntegrationChargeResult.fromJson(const {
      'kind': 'airtime',
      'subscriber_ref': '+22370123456',
      'option_label': 'أورنج مالي · 5,000 فرنك أفريقي',
      'outcome': 'charged',
      'provider_reference': '4602843',
      'receipt': <String, Object?>{},
    });
    await open(tester, [bare]);

    expect(find.text('الرقم'), findsOneWidget);
    expect(find.text('العملية'), findsOneWidget);
    expect(find.text('أورنج مالي · 5,000 فرنك أفريقي'), findsOneWidget);
    expect(find.text('رقم العملية'), findsOneWidget);
  });

  for (final (name, size, scale) in const [
    ('a till', Size(1366, 768), 1.0),
    ('a phone', Size(390, 844), 1.0),
    ('a small phone with text a third bigger', Size(360, 640), 1.3),
  ]) {
    testServices('$name draws the token without overflow', (tester) async {
      await open(tester, [airtime, electricity], size: size, textScale: scale);

      expect(tester.takeException(), isNull);
      expect(key('service_delivered_done'), findsOneWidget);
    });
  }
}
