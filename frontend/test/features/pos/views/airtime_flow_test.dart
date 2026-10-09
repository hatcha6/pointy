import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/features/pos/views/direct_services/airtime_flow_sheet.dart';

import '../../../support/services_testing.dart';
import '../../../support/test_fonts.dart';

/// The stepped direct top-up: country, number and network, amount, summary.
void main() {
  setUpAll(loadAppFonts);

  Finder key(String name) => find.byKey(ValueKey(name));

  Future<void> pumpTime(WidgetTester tester, [int milliseconds = 900]) async {
    await tester.pump(Duration(milliseconds: milliseconds));
    await tester.pump(const Duration(milliseconds: 50));
  }

  Future<void> settle(WidgetTester tester) =>
      tester.pumpAndSettle(const Duration(milliseconds: 100));

  Future<void> toNumber(WidgetTester tester) async {
    await tester.tap(key('service_country_popular_ML'));
    await settle(tester);
  }

  Future<void> toAmount(WidgetTester tester) async {
    await toNumber(tester);
    await tester.enterText(key('service_phone_field'), '70123456');
    await pumpTime(tester);
    await tester.tap(key('airtime_next'));
    await settle(tester);
  }

  testServices('opens on the country, with nothing to go back to', (
    tester,
  ) async {
    await pumpAirtimeFlow(tester);

    expect(key('airtime_picker'), findsOneWidget);
    expect(key('airtime_back'), findsNothing);
    expect(key('airtime_next'), findsNothing);
  });

  testServices('a country moves on to the number, and back returns', (
    tester,
  ) async {
    final harness = await pumpAirtimeFlow(tester);
    await toNumber(tester);

    expect(harness.viewModel.country!.code, 'ML');
    expect(key('airtime_selected_country'), findsOneWidget);
    expect(key('service_phone_field'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(key('airtime_next')).onPressed,
      isNull,
      reason: 'no network yet',
    );

    await tester.tap(key('airtime_back'));
    await settle(tester);
    expect(key('airtime_picker'), findsOneWidget);
  });

  testServices('a detected network lets the number step go on to the amount', (
    tester,
  ) async {
    final harness = await pumpAirtimeFlow(tester);
    await toAmount(tester);

    expect(harness.viewModel.operator, isNotNull);
    expect(key('service_amount_other'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(key('airtime_next')).onPressed,
      isNull,
      reason: 'no amount yet',
    );
  });

  testServices(
    'an amount leads to the summary, whose button adds to the cart',
    (tester) async {
      final harness = await pumpAirtimeFlow(tester);
      await toAmount(tester);

      final tile = find.byWidgetPredicate(
        (w) =>
            w.key is ValueKey &&
            (w.key! as ValueKey).value.toString().startsWith(
              'service_amount_',
            ) &&
            (w.key! as ValueKey).value != 'service_amount_other',
      );
      await tester.tap(tile.first);
      await pumpTime(tester);
      await tester.tap(key('airtime_next'));
      await pumpTime(tester);

      expect(key('airtime_summary'), findsOneWidget);
      // The number, country and network are read back in large digits.
      expect(key('service_readback_number'), findsOneWidget);
      await tester.tap(key('service_add_to_cart'));
      await pumpTime(tester);
      expect(harness.added, hasLength(1));
    },
  );

  testServices('a cart that refuses keeps the summary and says so', (
    tester,
  ) async {
    final harness = await pumpAirtimeFlow(tester);
    harness.cartAccepts = false;
    await toAmount(tester);
    await tester.tap(
      find
          .byWidgetPredicate(
            (w) =>
                w.key is ValueKey &&
                (w.key! as ValueKey).value.toString().startsWith(
                  'service_amount_',
                ) &&
                (w.key! as ValueKey).value != 'service_amount_other',
          )
          .first,
    );
    await pumpTime(tester);
    await tester.tap(key('airtime_next'));
    await pumpTime(tester);
    await tester.tap(key('service_add_to_cart'));
    await pumpTime(tester);

    expect(key('service_add_refused'), findsOneWidget);
    expect(key('airtime_summary'), findsOneWidget);
  });

  testServices('opens where the form already stands', (tester) async {
    final harness = await pumpAirtimeFlow(tester);
    await toNumber(tester);
    await tester.pumpWidget(const SizedBox.shrink());

    expect(airtimeStartStep(harness.viewModel), AirtimeFlowStep.number);
  });
}
