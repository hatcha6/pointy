import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/product_tracking.dart';
import 'package:pointy_frontend/src/data/models/product_update_draft.dart';
import 'package:pointy_frontend/src/data/models/tracking_mode.dart';
import 'package:pointy_frontend/src/data/services/api_session.dart';
import 'package:pointy_frontend/src/features/catalog/view_models/tracking_mode_refusal.dart';

/// The two answers the server gives a tracking-mode change it will not save
/// as sent: a question the user can answer (stock already on the shelf), and
/// a refusal nothing but fixing the stock can answer.
void main() {
  PosApiException refusal(Map<String, Object?> body, {int status = 400}) =>
      PosApiException(
        message: 'Product update failed with status $status',
        statusCode: status,
        responseBody: jsonEncode(body),
      );

  // Exactly what DRF sends for a ``validate()`` error: every leaf a list.
  final question = refusal({
    'tracking_mode': ['في المخزون 30 قطعة من هذا المنتج بلا أرقام.'],
    'code': [trackingIdentifyLaterCode],
    'on_hand': ['30'],
    'current_mode': ['quantity'],
    'requested_mode': ['serial'],
  });

  test('the identify-later refusal is read as a question', () {
    final request = trackingIdentificationFrom(question);

    expect(request, isNotNull);
    expect(request!.onHand, '30');
    expect(request.requestedMode, TrackingMode.serial);
  });

  test('a refusal without the code is not a question', () {
    final fractional = refusal({
      'tracking_mode': ['الرصيد (2.5) ليس عددًا صحيحًا من القطع.'],
    });

    expect(trackingIdentificationFrom(fractional), isNull);
    expect(
      trackingModeErrorFrom(fractional),
      'الرصيد (2.5) ليس عددًا صحيحًا من القطع.',
    );
  });

  test('only a 400 is a refusal at all', () {
    expect(trackingIdentificationFrom(refusal({}, status: 500)), isNull);
    expect(trackingIdentificationFrom(Exception('offline')), isNull);
  });

  group('ProductUpdateDraft', () {
    const draft = ProductUpdateDraft(
      name: 'هاتف',
      description: '',
      isActive: true,
      tracksExpiry: false,
      tracking: ProductTracking(mode: TrackingMode.serial),
      pricingCurrency: 'USD',
      defaultSaleUnit: 'box',
      defaultPurchaseUnit: 'carton',
      categoryIds: [3],
    );

    test('an ordinary save never carries the answer', () {
      expect(
        draft.toJson().containsKey('tracking_mode_identify_later'),
        isFalse,
      );
    });

    test('the answered edit is the same edit, plus the answer', () {
      final answered = draft.identifyingStockLater().toJson();

      expect(answered['tracking_mode_identify_later'], isTrue);
      expect(
        answered..remove('tracking_mode_identify_later'),
        equals(draft.toJson()),
      );
    });
  });
}
