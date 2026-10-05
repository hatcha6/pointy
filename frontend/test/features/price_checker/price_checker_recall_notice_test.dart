import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/price_lookup_result.dart';
import 'package:pointy_frontend/src/features/price_checker/views/price_checker_kiosk_view.dart';
import 'package:pointy_frontend/src/features/price_checker/views/price_checker_test_scan_sheet.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

Widget _wrap(Widget child, {bool dark = false}) {
  return MaterialApp(
    locale: const Locale('ar'),
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    theme: dark ? PointyTheme.dark() : PointyTheme.light(),
    home: child,
  );
}

/// What the server sends for a stopped pack: no price key at all.
const Map<String, Object?> _recalledJson = {
  'found': true,
  'barcode': 'CARTON-L99',
  'in_stock': false,
  'currency': 'د.ل',
  'display_lines': ['موقوف عن البيع'],
  'product_name': 'أموكسيسيلين ٥٠٠ ملغ',
  'variant_name': 'علبة ٢٠',
  'sku': 'AMOX',
  'unit': 'PCS',
  'image_url': '',
  'availability': 'recalled',
  'lot': {'code': 'L-99', 'expiry_date': '2027-03-31'},
};

void main() {
  group('PriceLookupResult', () {
    test('reads availability and the printed lot', () {
      final result = PriceLookupResult.fromJson(_recalledJson);
      expect(result.availability, PriceLookupAvailability.recalled);
      expect(result.isStopped, isTrue);
      expect(result.lotCode, 'L-99');
      expect(result.lotExpiry, DateTime(2027, 3, 31));
      expect(result.finalPriceDisplay, isEmpty);
      expect(result.lotDetail, isNull);
    });

    test('an ordinary or older payload is ok, never stopped', () {
      final result = PriceLookupResult.fromJson(const {
        'found': true,
        'barcode': '1',
        'final_price_display': '5.00 د.ل',
      });
      expect(result.availability, PriceLookupAvailability.ok);
      expect(result.isStopped, isFalse);
    });

    test('reads the staff-only lot detail when present', () {
      final result = PriceLookupResult.fromJson({
        ..._recalledJson,
        'lot_detail': {
          'batch_id': 7,
          'status': 'quarantined',
          'is_locked': true,
          'quarantined_at': '2026-10-04T09:41:00Z',
          'quarantine_reason': 'سحب من المصنّع',
          'expiry_date': '2027-03-31',
        },
      });
      expect(result.lotDetail?.batchId, 7);
      expect(result.lotDetail?.quarantineReason, 'سحب من المصنّع');
      expect(result.lotDetail?.quarantinedAt, isNotNull);
    });
  });

  group('kiosk recall notice', () {
    const sizes = <Size>[
      Size(480, 320),
      Size(390, 844),
      Size(800, 1280),
      Size(1280, 800),
      Size(1920, 1080),
    ];

    for (final availability in const [
      PriceLookupAvailability.recalled,
      PriceLookupAvailability.expired,
    ]) {
      testWidgets('$availability shows the notice and no price at any size', (
        tester,
      ) async {
        final json = {..._recalledJson, 'availability': availability.name};
        for (final size in sizes) {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await tester.pumpWidget(
            _wrap(
              PriceCheckerKioskView(
                status: PriceCheckerKioskStatus.found,
                result: PriceLookupResult.fromJson(json),
                shopName: 'صيدلية الأمل',
              ),
            ),
          );
          await tester.pump(const Duration(milliseconds: 400));

          final title = availability == PriceLookupAvailability.expired
              ? 'انتهت صلاحية هذه العبوة'
              : 'هذا المنتج موقوف عن البيع';
          expect(find.text(title), findsOneWidget, reason: '$size');
          expect(find.text('يرجى مراجعة الكاشير'), findsOneWidget);
          expect(find.text('أموكسيسيلين ٥٠٠ ملغ'), findsOneWidget);
          expect(find.textContaining('L-99'), findsOneWidget);
          // Never a price, never the in-stock pill.
          expect(find.textContaining('د.ل'), findsNothing);
          expect(find.text('متوفّر'), findsNothing);
          expect(tester.takeException(), isNull, reason: '$size');
        }
      });
    }
  });

  group('staff test scan', () {
    testWidgets('shows the lot state staff may see, and the kiosk preview', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(900, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var asked = '';
      final staffResult = PriceLookupResult.fromJson({
        ..._recalledJson,
        'lot_detail': {
          'batch_id': 7,
          'status': 'quarantined',
          'quarantined_at': '2026-10-04T09:41:00Z',
          'quarantine_reason': 'سحب من المصنّع',
          'expiry_date': '2027-03-31',
        },
      });
      await tester.pumpWidget(
        _wrap(
          Scaffold(
            body: PriceCheckerTestScanPanel(
              lookup: (code) async {
                asked = code;
                return Ok(staffResult);
              },
            ),
          ),
        ),
      );
      expect(
        find.text('امسح عبوة لترى ما سيعرضه كاشف الأسعار للزبون.'),
        findsOneWidget,
      );

      await tester.enterText(find.byType(TextField), 'CARTON-L99');
      await tester.tap(find.text('فحص'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(asked, 'CARTON-L99');
      expect(find.text('حالة الدفعة'), findsOneWidget);
      expect(find.text('سحب من المصنّع'), findsOneWidget);
      expect(find.text('ما يراه الزبون'), findsOneWidget);
      expect(find.text('هذا المنتج موقوف عن البيع'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
