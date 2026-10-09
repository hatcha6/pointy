import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/integration_card.dart';
import 'package:pointy_frontend/src/features/pos/views/direct_services/service_charge_issue_dialog.dart';

import '../../../support/services_testing.dart';
import '../../../support/test_fonts.dart';

/// What the cashier is told when a provider did not do what a sale sold — in
/// words about airtime and bills, never about «البطاقة» or the agency's
/// account — and what to do with the customer's money.
void main() {
  setUpAll(loadAppFonts);

  Finder key(String name) => find.byKey(ValueKey(name));

  IntegrationChargeResult row({
    String kind = 'airtime',
    String outcome = 'refused',
    String errorCode = '',
    String errorDetail = '',
    String reference = '',
    String subscriber = '+22370123456',
    String label = 'أورنج مالي · 5,000 فرنك أفريقي',
    bool needsAttention = false,
  }) => IntegrationChargeResult(
    fulfillment: 1,
    orderLine: 7,
    provider: 'pointy',
    kind: kind,
    subscriberRef: subscriber,
    optionLabel: label,
    outcome: outcome,
    status: outcome == 'unknown' ? 'submitted' : 'pending',
    needsAttention: needsAttention,
    errorCode: errorCode,
    errorDetail: errorDetail,
    providerReference: reference,
  );

  IntegrationChargeResult fixture(String name) {
    final text = File('test/fixtures/services/$name.json').readAsStringSync();
    final results = (jsonDecode(text) as Map)['results']! as List;
    return IntegrationChargeResult.fromJson(
      (results.first as Map).cast<String, Object?>(),
    );
  }

  Future<void> open(
    WidgetTester tester,
    List<IntegrationChargeResult> rows, {
    String receiptNumber = 'R-100',
    double textScale = 1,
    Size size = const Size(1366, 768),
  }) async {
    useWindow(tester, size);
    await tester.pumpWidget(
      servicesApp(
        Builder(
          builder: (context) => Center(
            child: FilledButton(
              key: const ValueKey('open'),
              onPressed: () => showServiceChargeIssueDialog(
                context,
                rows,
                receiptNumber: receiptNumber,
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

  const cardWords = [
    'البطاقة',
    'اسم المستخدم',
    'كلمة المرور',
    'رصيد الوكالة',
    'الوكالة',
  ];

  void expectNoCardWords(WidgetTester tester) {
    final texts = tester
        .widgetList<Text>(find.byType(Text))
        .map((text) => text.data ?? text.textSpan?.toPlainText() ?? '')
        .join('\n');
    for (final word in cardWords) {
      expect(texts, isNot(contains(word)), reason: word);
    }
  }

  group('a refused top-up', () {
    testServices('says nothing was sent and the money goes back', (
      tester,
    ) async {
      await open(tester, [row(errorCode: 'insufficient_float')]);

      expect(find.text('لم يُنفَّذ الشحن'), findsOneWidget);
      expect(
        find.text('لم يُرسَل أي رصيد — أعد المبلغ للزبون.'),
        findsOneWidget,
      );
      expect(
        find.text('رصيد الكروت لا يكفي — حوّل من المحفظة ثم أعد البيع.'),
        findsOneWidget,
      );
      expect(find.textContaining('22370123456'), findsOneWidget);
      expectNoCardWords(tester);
    });

    testServices('says why, in plain words, by what the provider answered', (
      tester,
    ) async {
      const reasons = {
        'price_changed':
            'تغيّر السعر لدى المزوّد قبل التنفيذ — أعد البيع بالسعر الجديد.',
        'unreachable': 'الخدمة أو المزوّد غير متاح الآن — حاول بعد قليل.',
        'unavailable': 'الخدمة أو المزوّد غير متاح الآن — حاول بعد قليل.',
        'switched_off': 'الخدمة أو المزوّد غير متاح الآن — حاول بعد قليل.',
        'provider_error': 'رفض المزوّد الطلب — لم يُخصم شيء.',
      };
      for (final entry in reasons.entries) {
        await open(tester, [row(errorCode: entry.key)]);

        expect(find.text(entry.value), findsOneWidget, reason: entry.key);
        expectNoCardWords(tester);
        await tester.tap(key('service_issue_close'));
        await tester.pumpAndSettle(const Duration(milliseconds: 100));
      }
    });

    testServices('knows a price that moved even when only the detail says so', (
      tester,
    ) async {
      // What the shop backend really answered: a generic code, and the reason
      // in the detail.
      await open(tester, [fixture('charge_price_changed')]);

      expect(
        find.text(
          'تغيّر السعر لدى المزوّد قبل التنفيذ — أعد البيع بالسعر الجديد.',
        ),
        findsOneWidget,
      );
    });

    testServices('and a number the provider did not accept', (tester) async {
      await open(tester, [
        row(
          errorCode: 'provider_error',
          errorDetail: 'invalid_phone: not a number',
        ),
      ]);

      expect(
        find.text('الرقم غير صالح لدى المزوّد — تأكد منه ثم أعد البيع.'),
        findsOneWidget,
      );
    });

    testServices('a refused bill is a bill', (tester) async {
      await open(tester, [
        row(
          kind: 'bill',
          subscriber: '04223568280',
          label: 'كهرباء إيكيجا (مسبقة الدفع) · 5,000 نيرة نيجيرية',
          errorCode: 'unreachable',
        ),
      ]);

      expect(find.text('لم تُسدَّد الفاتورة'), findsOneWidget);
      expect(
        find.text('لم يُسدَّد أي مبلغ للجهة — أعد المبلغ للزبون.'),
        findsOneWidget,
      );
      expect(find.text('لم يُنفَّذ الشحن'), findsNothing);
    });

    testServices('an airtime and a bill refused together are «الخدمة»', (
      tester,
    ) async {
      await open(tester, [
        row(errorCode: 'unreachable'),
        row(kind: 'bill', subscriber: '04223568280', errorCode: 'unreachable'),
      ]);

      expect(find.text('لم تُنفَّذ الخدمة'), findsOneWidget);
    });

    testServices('can be dismissed with a tap outside', (tester) async {
      await open(tester, [row(errorCode: 'unreachable')]);

      await tester.tapAt(const Offset(8, 8));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));

      expect(key('service_issue_dialog'), findsNothing);
    });
  });

  group('a result nobody knows', () {
    final unknown = row(
      outcome: 'unknown',
      errorCode: 'indeterminate',
      needsAttention: true,
    );

    testServices('says do not send it again and do not refund it', (
      tester,
    ) async {
      await open(tester, [unknown]);

      expect(find.text('نتيجة الشحن غير معروفة'), findsOneWidget);
      expect(
        find.text(
          'النتيجة غير معروفة — لا تُعد الشحن ولا تُرجع المبلغ حتى تتأكد.',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('افتح الفاتورة من سجل الفواتير'),
        findsOneWidget,
      );
      // The number is held left to right inside the Arabic line.
      expect(find.textContaining('رقم الفاتورة:'), findsOneWidget);
      expect(find.textContaining('R-100'), findsOneWidget);
      expectNoCardWords(tester);
    });

    testServices('names a bill\'s payment as a payment', (tester) async {
      await open(tester, [
        row(
          kind: 'bill',
          outcome: 'unknown',
          errorCode: 'indeterminate',
          needsAttention: true,
        ),
      ]);

      expect(find.text('نتيجة السداد غير معروفة'), findsOneWidget);
      expect(
        find.text(
          'النتيجة غير معروفة — لا تُعد السداد ولا تُرجع المبلغ حتى تتأكد.',
        ),
        findsOneWidget,
      );
    });

    testServices('gives the provider\'s reference when it has one', (
      tester,
    ) async {
      await open(tester, [
        row(
          outcome: 'unknown',
          needsAttention: true,
          reference: '0856bb97-05eb-4129-8b14',
        ),
      ]);

      expect(find.textContaining('0856bb97-05eb-4129-8b14'), findsOneWidget);
    });

    testServices('is not dismissed by a stray tap', (tester) async {
      await open(tester, [unknown]);

      await tester.tapAt(const Offset(8, 8));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));

      expect(key('service_issue_dialog'), findsOneWidget);

      await tester.tap(key('service_issue_close'));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(key('service_issue_dialog'), findsNothing);
    });

    testServices('lists every line it does not know about', (tester) async {
      await open(tester, [
        unknown,
        row(
          outcome: 'unknown',
          needsAttention: true,
          subscriber: '+2349031234567',
        ),
      ]);

      expect(find.textContaining('22370123456'), findsOneWidget);
      expect(find.textContaining('2349031234567'), findsOneWidget);
    });
  });

  for (final (name, size, scale) in const [
    ('a till', Size(1366, 768), 1.0),
    ('a small phone with text a third bigger', Size(360, 640), 1.3),
  ]) {
    testServices('$name draws it without overflow', (tester) async {
      await open(
        tester,
        [
          row(outcome: 'unknown', needsAttention: true, reference: 'x' * 20),
          row(errorCode: 'insufficient_float'),
          row(kind: 'bill', errorCode: 'price_changed'),
        ],
        size: size,
        textScale: scale,
      );

      expect(tester.takeException(), isNull);
    });
  }
}
