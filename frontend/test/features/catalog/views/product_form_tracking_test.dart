import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/catalog/view_models/catalog_view_model.dart';
import 'package:pointy_frontend/src/features/catalog/views/product_form.dart';
import 'package:pointy_frontend/src/shared/tracking/tracking_features.dart';

/// The new-product form's tracking choice.
///
/// Two promises: a shop that never switched serials or lots on sees exactly
/// the form it always had — the one «يتابع تاريخ الانتهاء» switch and nothing
/// else — and a shop that did can make a product serial, say what kind of
/// device it is and for how long it is guaranteed, and have that reach the
/// server.
void main() {
  late List<Map<String, Object?>> posted;

  CatalogViewModel buildViewModel() {
    http.Response json(Object body, [int status = 200]) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );
    final service = PosApiService(
      baseUrl: 'http://pointy.test/api',
      client: MockClient((request) async {
        final path = request.url.path;
        if (path.endsWith('/next-sku/')) {
          return json({'sku': '1042'});
        }
        if (path.endsWith('/identity-check/')) {
          return json(const {'sku': null, 'barcode': null});
        }
        if (path.endsWith('/asset-types/')) {
          return json(const {
            'results': [
              {
                'id': 4,
                'name': 'هاتف',
                'slug': 'phone',
                'is_active': true,
                'tracks_imei': true,
              },
            ],
            'next': null,
          });
        }
        if (request.method == 'POST' && path.endsWith('/products/')) {
          final body = jsonDecode(request.body) as Map<String, Object?>;
          posted.add(body);
          return json({
            'id': 100,
            'name': body['name'],
            'tracking_mode': body['tracking_mode'],
            'variants': [
              {
                'id': 1000,
                'product': 100,
                'sku': '1042',
                'unit_price': '1500.00',
                'is_default': true,
              },
            ],
          }, 201);
        }
        return json(const {'results': <Object?>[], 'next': null});
      }),
    );
    final viewModel = CatalogViewModel(CatalogRepository(service));
    addTearDown(viewModel.dispose);
    return viewModel;
  }

  Future<AppLocalizations> pumpForm(
    WidgetTester tester, {
    TrackingFeatures features = TrackingFeatures.none,
  }) async {
    posted = [];
    await tester.binding.setSurfaceSize(const Size(900, 2000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        // Where the app installs it: above the Navigator, so the form reads
        // the shop's switches whichever sheet it opens in.
        builder: (context, child) =>
            TrackingFeaturesScope(features: features, child: child!),
        home: Scaffold(body: ProductForm(viewModel: buildViewModel())),
      ),
    );
    await tester.pumpAndSettle();
    return AppLocalizations.delegate.load(const Locale('ar'));
  }

  Future<void> type(WidgetTester tester, String label, String text) async {
    await tester.enterText(find.widgetWithText(TextFormField, label), text);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
  }

  testWidgets('a shop that tracks nothing sees only the expiry switch', (
    tester,
  ) async {
    final l10n = await pumpForm(tester);

    expect(find.text(l10n.productTracksExpiryLabel), findsOne);
    expect(find.text(l10n.productTrackingSectionTitle), findsNothing);
    expect(find.text(l10n.trackingModeSerial), findsNothing);
  });

  testWidgets(
    'a serial shop makes a product serial, with its kind and its warranty',
    (tester) async {
      final l10n = await pumpForm(
        tester,
        features: const TrackingFeatures(serial: true),
      );

      // The section replaces the switch rather than sitting beside it.
      expect(find.text(l10n.productTrackingSectionTitle), findsOne);
      expect(find.text(l10n.productTracksExpiryLabel), findsNothing);
      // Lots are not this shop's trade, so they are not on offer.
      expect(find.text(l10n.trackingModeBatch), findsNothing);

      await tester.tap(find.text(l10n.trackingModeSerial));
      await tester.pumpAndSettle();
      expect(find.text(l10n.productTrackingVariantOrUnitHint), findsOne);

      await tester.tap(
        find.byKey(const ValueKey('product_tracking_asset_type_null_1')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('هاتف').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('product_tracking_warranty')),
        '365',
      );
      await tester.pumpAndSettle();

      await type(tester, l10n.productNameLabel, 'آيفون 13');
      await type(tester, l10n.unitPriceLabel, '1500');
      await tester.tap(find.text(l10n.createProductButton));
      await tester.pumpAndSettle();

      final body = posted.single;
      expect(body['tracking_mode'], 'serial');
      expect(body['asset_type'], 4);
      expect(body['warranty_days'], 365);
      expect(body['tracks_expiry'], isFalse);
    },
  );

  testWidgets('a service is never tracked, whatever was chosen before', (
    tester,
  ) async {
    final l10n = await pumpForm(
      tester,
      features: const TrackingFeatures(serial: true, batch: true),
    );

    await tester.tap(find.text(l10n.trackingModeBatch));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.productMoreDetailsTitle));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.productIsServiceTitle));
    await tester.pumpAndSettle();
    expect(find.text(l10n.productTrackingNoStock), findsOne);

    await type(tester, l10n.productNameLabel, 'صيانة شاشة');
    await type(tester, l10n.unitPriceLabel, '50');
    await tester.tap(find.text(l10n.createProductButton));
    await tester.pumpAndSettle();

    expect(posted.single['tracking_mode'], 'quantity');
    expect(posted.single['is_service'], isTrue);
  });
}
