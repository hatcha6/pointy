import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/features/pos/view_models/pos_service_shelves.dart';
import 'package:pointy_frontend/src/features/pos/views/pos_voucher_brand_card.dart';
import 'package:pointy_frontend/src/features/pos/views/pos_voucher_menu.dart';

import '../../../support/pos_services_screen_testing.dart';
import '../../../support/services_testing.dart';
import '../../../support/test_fonts.dart';
import '../../../support/voucher_search_testing.dart';

/// Typing with the «كروت دفتر» chip selected filters the menu in place.
void main() {
  setUpAll(loadAppFonts);

  Finder key(String name) => find.byKey(ValueKey(name));

  Future<void> pumpMenu(
    WidgetTester tester,
    ValueNotifier<String> search, {
    VoidCallback? onClear,
  }) async {
    useWindow(tester, const Size(1200, 900));
    final shelves = PosServiceShelves(repository: ServicesTillIntegrations());
    disposeWithTest(shelves.dispose);
    await tester.pumpWidget(
      servicesApp(
        ValueListenableBuilder<String>(
          valueListenable: search,
          builder: (context, text, _) => PosVoucherMenuView(
            menu: searchMenu(),
            animateSkeleton: false,
            shelves: shelves,
            onBrandSelected: (_) {},
            search: text,
            onClearSearch: onClear,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
  }

  testServices('visa lands on Mastercard', (tester) async {
    final search = ValueNotifier('');
    await pumpMenu(tester, search);
    expect(find.byType(PosVoucherBrandCard), findsNWidgets(4));

    search.value = 'visa';
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.byType(PosVoucherBrandCard), findsOneWidget);
    expect(key('voucher_brand_mastercard'), findsOneWidget);
  });

  testServices('apple lands on آيتونز', (tester) async {
    final search = ValueNotifier('');
    await pumpMenu(tester, search);
    search.value = 'apple';
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(key('voucher_brand_itunes'), findsOneWidget);
    expect(find.byType(PosVoucherBrandCard), findsOneWidget);
  });

  testServices('electricity shows the electricity bill card', (tester) async {
    final search = ValueNotifier('');
    await pumpMenu(tester, search);
    search.value = 'electricity';
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(key('service_card_electricity'), findsOneWidget);
    expect(key('service_card_water'), findsNothing);
    expect(find.byType(PosVoucherBrandCard), findsNothing);

    search.value = 'شحن رصيد';
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(key('service_card_airtime'), findsOneWidget);
  });

  testServices('no match says so and offers to clear the search', (
    tester,
  ) async {
    final search = ValueNotifier('');
    await pumpMenu(tester, search, onClear: () => search.value = '');
    search.value = 'قهوة';
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(key('voucher_search_empty'), findsOneWidget);
    expect(find.textContaining('قهوة'), findsWidgets);

    await tester.tap(key('voucher_search_clear'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(key('voucher_search_empty'), findsNothing);
    expect(find.byType(PosVoucherBrandCard), findsNWidgets(4));
  });
}
