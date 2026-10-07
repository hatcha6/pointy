import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/data/models/tracking_mode.dart';
import 'package:pointy_frontend/src/data/models/unit_attribute.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/product_tile.dart';
import 'package:pointy_frontend/src/shared/tracking/identifier_check.dart';
import 'package:pointy_frontend/src/shared/tracking/unit_attribute_summary.dart';

void main() {
  group('an IMEI is questioned where it is scanned', () {
    test('a real IMEI passes its check digit', () {
      expect(luhnValid('490154203237518'), isTrue);
      expect(checkIdentifier('490154203237518', kind: 'imei'), isNull);
      // Spaces and dashes are how labels print it; they are not digits.
      expect(checkIdentifier('49-015420-323751-8', kind: 'imei'), isNull);
    });

    test('one mistyped digit fails it', () {
      expect(
        checkIdentifier('490154203237519', kind: 'imei'),
        IdentifierProblem.imeiChecksum,
      );
    });

    test('the other two shapes an IMEI may take are not checked', () {
      // 14 digits: no check digit yet. 16: an IMEISV, whose last two digits
      // are a software version — checking them would fail every handset.
      expect(checkIdentifier('49015420323751', kind: 'imei'), isNull);
      expect(checkIdentifier('4901542032375101', kind: 'imei'), isNull);
    });

    test('a wrong length or a letter is questioned', () {
      expect(
        checkIdentifier('4901542', kind: 'imei'),
        IdentifierProblem.imeiLength,
      );
      expect(
        checkIdentifier('49015420323751X', kind: 'imei'),
        IdentifierProblem.imeiNotNumeric,
      );
    });

    test('a serial number is never held to an IMEI rule', () {
      expect(checkIdentifier('C02XK1ZZJGH5', kind: 'serial'), isNull);
      expect(checkIdentifier('490154203237519', kind: ''), isNull);
    });
  });

  test('an article reads as its values, not label-value pairs', () {
    final summary = UnitAttributeSummary.describe(const [
      UnitAttributeValue(
        key: 'battery_health',
        label: 'صحة البطارية',
        display: '91%',
        dataType: UnitAttributeType.percent,
      ),
      UnitAttributeValue(
        key: 'condition_grade',
        label: 'درجة الحالة',
        display: 'ممتاز +',
        dataType: UnitAttributeType.choice,
      ),
      UnitAttributeValue(
        key: 'charger_included',
        label: 'الشاحن مرفق',
        display: 'نعم',
        value: true,
        dataType: UnitAttributeType.boolean,
      ),
      UnitAttributeValue(
        key: 'box',
        label: 'العلبة الأصلية',
        display: 'لا',
        value: false,
        dataType: UnitAttributeType.boolean,
      ),
      UnitAttributeValue(
        key: 'bought_on',
        label: 'تاريخ الشراء',
        display: '2026/03/01',
        dataType: UnitAttributeType.date,
      ),
    ]);

    // A date alone says nothing, so it keeps its label; an unticked yes/no
    // fact says nothing at all.
    expect(summary, '91% · ممتاز + · الشاحن مرفق · تاريخ الشراء 2026/03/01');
  });

  group('the purchase catalog says how each product is identified', () {
    Future<void> pumpTile(WidgetTester tester, ProductVariant variant) {
      return tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ar'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: PointyTheme.light(),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 220,
                height: 300,
                child: ProductTile.variant(variant: variant, onTap: () {}),
              ),
            ),
          ),
        ),
      );
    }

    ProductVariant variant(TrackingMode mode, {bool expiryRequired = false}) {
      return ProductVariant(
        id: 1,
        productId: 1,
        sku: 'SKU-1',
        unitPrice: 10,
        productName: 'صنف',
        trackingMode: mode,
        tracksExpiry: mode.tracksLots,
        expiryRequired: expiryRequired,
      );
    }

    testWidgets('a handset is flagged as scanned one by one', (tester) async {
      await pumpTile(tester, variant(TrackingMode.serial));
      expect(find.text('رقم تسلسلي'), findsOneWidget);
    });

    testWidgets('lots that expire and lots that never do read differently', (
      tester,
    ) async {
      await pumpTile(tester, variant(TrackingMode.batch, expiryRequired: true));
      expect(find.text('دفعات وصلاحية'), findsOneWidget);

      await pumpTile(tester, variant(TrackingMode.batch));
      expect(find.text('دفعات'), findsOneWidget);
    });

    testWidgets('a counted product carries no flag', (tester) async {
      await pumpTile(tester, variant(TrackingMode.quantity));
      expect(find.text('رقم تسلسلي'), findsNothing);
      expect(find.text('دفعات'), findsNothing);
    });
  });
}
