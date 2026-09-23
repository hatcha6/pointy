import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/data/models/product.dart';
import 'package:pointy_frontend/src/data/models/product_query.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/data/models/shop_settings.dart';
import 'package:pointy_frontend/src/data/models/voucher_availability.dart';
import 'package:pointy_frontend/src/features/pos/views/pos_voucher_picker_sheet.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

/// Qareeb's cards are products in the till's catalog: a brand is a product,
/// each denomination a variant. The picker opens on what the catalog holds
/// and folds in the provider's live answer, so a card that sold out since the
/// last sweep is never sold.
void main() {
  const libyana = Product(
    id: 30,
    name: 'ليبيانا',
    quantityOnHand: 0,
    isService: true,
    isSystem: true,
    systemKind: ProductSystemKind.voucher,
  );
  ProductVariant card(int id, String label, double price) => ProductVariant(
    id: id,
    productId: 30,
    productName: 'ليبيانا',
    displayName: label,
    fullName: 'ليبيانا - $label',
    sku: 'QRB-$id',
    unitPrice: price,
    isService: true,
  ).copyWith(productDetail: libyana);

  final ten = card(1, '10 دينار', 10);
  final five = card(2, '5 دينار', 5);
  final hundred = card(3, '100 دينار', 100);

  Future<ProductVariant?> pump(
    WidgetTester tester,
    Future<VoucherAvailability?> Function() check,
  ) async {
    ProductVariant? picked;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        theme: PointyTheme.light(),
        home: Scaffold(
          body: PosVoucherPicker(
            product: libyana,
            variants: [ten, five, hundred],
            checkAvailability: check,
            onPicked: (variant) => picked = variant,
          ),
        ),
      ),
    );
    return picked;
  }

  testWidgets(
    'opens at once, cheapest card first, before the provider answers',
    (tester) async {
      final answer = Completer<VoucherAvailability?>();
      await pump(tester, () => answer.future);
      await tester.pump();

      final labels = tester
          .widgetList<Text>(find.byType(Text))
          .map((text) => text.data)
          .whereType<String>()
          .where((text) => text.contains('دينار'))
          .toList();
      expect(labels, ['5 دينار', '10 دينار', '100 دينار']);

      answer.complete(null);
      await tester.pumpAndSettle();
    },
  );

  testWidgets('a card the provider no longer has disappears', (tester) async {
    await pump(
      tester,
      () async => const VoucherAvailability(
        ok: true,
        balance: 674.9,
        cards: [
          VoucherCard(
            variantId: 1,
            label: '10 دينار',
            price: 10,
            isAvailable: true,
            cost: 9.7,
          ),
          VoucherCard(
            variantId: 2,
            label: '5 دينار',
            price: 5,
            isAvailable: true,
            cost: 4.85,
          ),
          VoucherCard(
            variantId: 3,
            label: '100 دينار',
            price: 100,
            isAvailable: false,
            cost: 97,
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('100 دينار'), findsNothing);
    expect(find.text('5 دينار'), findsOneWidget);
    // And the cashier is told why a denomination they expected is gone.
    expect(find.textContaining('نفدت'), findsOneWidget);
  });

  testWidgets('a card dearer than the float is flagged, not refused', (
    tester,
  ) async {
    ProductVariant? picked;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        theme: PointyTheme.light(),
        home: Scaffold(
          body: PosVoucherPicker(
            product: libyana,
            variants: [ten, hundred],
            checkAvailability: () async => const VoucherAvailability(
              ok: true,
              balance: 50,
              cards: [
                VoucherCard(
                  variantId: 1,
                  label: '10 دينار',
                  price: 10,
                  isAvailable: true,
                  cost: 9.7,
                ),
                VoucherCard(
                  variantId: 3,
                  label: '100 دينار',
                  price: 100,
                  isAvailable: true,
                  cost: 97,
                ),
              ],
            ),
            onPicked: (variant) => picked = variant,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('يتجاوز رصيد الوكالة'), findsOneWidget);
    await tester.tap(find.text('100 دينار'));
    expect(picked?.id, 3);
  });

  test('the till asks for the cards it sells, and only those', () {
    const query = ProductQuery(system: ProductSystemFilter.sellable);
    expect(query.toQueryParameters(page: 1)['system'], 'sellable');
  });

  test('a provider whose cards are in the catalog gets no top-up button', () {
    final settings = ShopSettings.fromJson({
      'connected_integrations': ['hdbox', 'qareeb'],
      'lookup_integrations': ['hdbox'],
    });
    expect(settings.connectedIntegrations, ['hdbox', 'qareeb']);
    expect(settings.tillRechargeIntegrations, ['hdbox']);

    // A backend from before the field only ever listed lookup providers.
    final older = ShopSettings.fromJson({
      'connected_integrations': ['hdbox'],
    });
    expect(older.tillRechargeIntegrations, ['hdbox']);
  });

  test('a card keeps being a card when opened on its own', () {
    final alone = Product.fromVariant(five);
    expect(alone.isSystem, isTrue);
    expect(alone.isVoucher, isTrue);
  });
}
