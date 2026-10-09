import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations_ar.dart';
import 'package:pointy_frontend/src/data/models/cart_line.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/data/models/service_kinds.dart';
import 'package:pointy_frontend/src/data/models/service_quote.dart';
import 'package:pointy_frontend/src/features/pos/view_models/pos_view_model.dart';
import 'package:pointy_frontend/src/features/pos/views/direct_services/service_requote_dialog.dart';
import 'package:pointy_frontend/src/features/pos/views/direct_services/service_texts.dart';

import '../../../support/services_testing.dart';
import '../../../support/test_fonts.dart';

/// A service line priced earlier, priced again: the cashier sees what it was,
/// what it is, and decides — nothing is changed behind their back.
void main() {
  setUpAll(loadAppFonts);

  Finder key(String name) => find.byKey(ValueKey(name));

  CartLine line({double price = 96.5, String subscriber = '+22370123456'}) =>
      CartLine.create(
        variant: ProductVariant(
          id: 9301,
          productId: 0,
          sku: '',
          unitPrice: price,
          productName: 'شحن مباشر',
          isService: true,
        ),
        quantity: 1,
        integration: CartLineIntegration(
          provider: 'pointy',
          subscriberRef: subscriber,
          optionCode: 'air:289:5000:XOF',
          optionLabel: 'أورنج مالي · 5,000 فرنك أفريقي',
          quote: 'sealed',
        ),
      );

  ServiceQuote quote(double price) => ServiceQuote(
    kind: ServiceKind.airtime,
    optionCode: 'air:289:5000:XOF',
    optionLabel: 'أورنج مالي · 5,000 فرنك أفريقي',
    subscriberRef: '+22370123456',
    price: price,
    receiveAmount: '5000',
    receiveCurrency: 'XOF',
    quote: 'sealed.new',
    serviceVariantId: 9301,
  );

  Future<ServiceRequoteDecision?> open(
    WidgetTester tester,
    List<ServiceRequote> changes, {
    Size size = const Size(1366, 768),
    double textScale = 1,
  }) async {
    useWindow(tester, size);
    ServiceRequoteDecision? decision;
    await tester.pumpWidget(
      servicesApp(
        Builder(
          builder: (context) => Center(
            child: FilledButton(
              key: const ValueKey('open'),
              onPressed: () async =>
                  decision = await showServiceRequoteDialog(context, changes),
              child: const Text('open'),
            ),
          ),
        ),
        textScale: textScale,
      ),
    );
    await tester.tap(key('open'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    return decision;
  }

  testServices(
    'shows the old price and the new one, and nothing else changes',
    (tester) async {
      await open(tester, [ServiceRequote(line: line(), quote: quote(99))]);

      expect(find.text('تغيّر سعر الخدمة'), findsOneWidget);
      expect(find.textContaining('22370123456'), findsOneWidget);
      expect(
        find.textContaining('كان 96.50 د.ل ← أصبح 99.00 د.ل'),
        findsOneWidget,
      );
      expect(key('service_requote_accept'), findsOneWidget);
      expect(find.text('اعتمد السعر الجديد'), findsOneWidget);
      expect(find.text('إلغاء'), findsOneWidget);
    },
  );

  testServices('accepting says accept', (tester) async {
    ServiceRequoteDecision? decision;
    useWindow(tester, const Size(1366, 768));
    await tester.pumpWidget(
      servicesApp(
        Builder(
          builder: (context) => Center(
            child: FilledButton(
              key: const ValueKey('open'),
              onPressed: () async => decision = await showServiceRequoteDialog(
                context,
                [ServiceRequote(line: line(), quote: quote(99))],
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(key('open'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));

    await tester.tap(key('service_requote_accept'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));

    expect(decision, ServiceRequoteDecision.accept);
  });

  testServices('cancelling, or tapping away, leaves everything as it was', (
    tester,
  ) async {
    ServiceRequoteDecision? decision;
    useWindow(tester, const Size(1366, 768));
    await tester.pumpWidget(
      servicesApp(
        Builder(
          builder: (context) => Center(
            child: FilledButton(
              key: const ValueKey('open'),
              onPressed: () async => decision = await showServiceRequoteDialog(
                context,
                [ServiceRequote(line: line(), quote: quote(99))],
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(key('open'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));

    await tester.tap(key('service_requote_cancel'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));

    expect(decision, ServiceRequoteDecision.cancel);
  });

  testServices('an offer that is gone says the line will be removed', (
    tester,
  ) async {
    await open(tester, [
      ServiceRequote(
        line: line(),
        refusal: const ServiceQuoteRefusal(
          errorCode: ServiceRefusalCode.amountNotOffered,
        ),
      ),
    ]);

    expect(
      find.text(
        'لم تعد هذه الخدمة متاحة بهذه المواصفات — سيُزال السطر من الفاتورة.',
      ),
      findsOneWidget,
    );
    expect(find.text('هذا المبلغ غير متاح، اختر مبلغاً آخر'), findsOneWidget);
    expect(find.text('اعتمد التغييرات'), findsOneWidget);
  });

  testServices('a price that moved and an offer that is gone, together', (
    tester,
  ) async {
    await open(tester, [
      ServiceRequote(line: line(), quote: quote(99)),
      ServiceRequote(
        line: line(subscriber: '+2349031234567'),
        refusal: const ServiceQuoteRefusal(
          errorCode: ServiceRefusalCode.unknownOperator,
        ),
      ),
    ]);

    expect(
      find.textContaining('كان 96.50 د.ل ← أصبح 99.00 د.ل'),
      findsOneWidget,
    );
    expect(find.textContaining('سيُزال السطر'), findsOneWidget);
    expect(find.text('اعتمد التغييرات'), findsOneWidget);
  });

  for (final (name, size, scale) in const [
    ('a till', Size(1366, 768), 1.0),
    ('a small phone with text a third bigger', Size(360, 640), 1.3),
  ]) {
    testServices('$name draws it without overflow', (tester) async {
      await open(
        tester,
        [
          ServiceRequote(line: line(), quote: quote(99)),
          ServiceRequote(
            line: line(subscriber: '+2349031234567'),
            refusal: const ServiceQuoteRefusal(
              errorCode: ServiceRefusalCode.amountNotOffered,
            ),
          ),
        ],
        size: size,
        textScale: scale,
      );

      expect(tester.takeException(), isNull);
    });
  }

  group('how long ago a line was priced', () {
    final l10n = AppLocalizationsAr();
    final now = DateTime(2026, 10, 8, 12);

    test('is not said for a line priced a moment ago', () {
      expect(serviceQuoteAgeText(l10n, null, now: now), isNull);
      expect(
        serviceQuoteAgeText(
          l10n,
          now.subtract(const Duration(seconds: 40)),
          now: now,
        ),
        isNull,
      );
    });

    test('is said in minutes, hours and days, in Arabic', () {
      String? age(Duration ago) =>
          serviceQuoteAgeText(l10n, now.subtract(ago), now: now);

      expect(age(const Duration(minutes: 1)), 'سُعّرت قبل دقيقة');
      expect(age(const Duration(minutes: 2)), 'سُعّرت قبل دقيقتين');
      expect(age(const Duration(minutes: 7)), 'سُعّرت قبل 7 دقائق');
      expect(age(const Duration(minutes: 45)), 'سُعّرت قبل 45 دقيقة');
      expect(age(const Duration(hours: 1, minutes: 10)), 'سُعّرت قبل ساعة');
      expect(age(const Duration(hours: 3)), 'سُعّرت قبل 3 ساعات');
      expect(age(const Duration(hours: 20)), 'سُعّرت قبل 20 ساعة');
      expect(age(const Duration(days: 1, hours: 2)), 'سُعّرت قبل يوم');
      expect(age(const Duration(days: 4)), 'سُعّرت قبل 4 أيام');
    });
  });
}
