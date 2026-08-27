import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/purchase_cost_warning.dart';
import 'package:pointy_frontend/src/data/services/api_session.dart';

/// The client half of the cost guard.
///
/// Two behaviours matter and both are easy to get subtly wrong: the app must
/// only offer "confirm anyway" when confirming actually works, and it must not
/// mistake an ordinary validation error for a cost warning.
void main() {
  PosApiException exception(Object? body, {int status = 400}) {
    // decodedBody is derived from the raw body, exactly as it is in the field.
    return PosApiException(
      message: 'Purchase order create failed with status',
      statusCode: status,
      responseBody: jsonEncode(body),
    );
  }

  Map<String, Object?> warning({required String blocking}) {
    return <String, Object?>{
      'blocking': blocking,
      'index': 0,
      'kind': 'above_sale_price',
      'product_name': 'خبز',
      'variant_id': 12,
      'base_unit_cost': '130.00',
      'reference': '1.00',
      'ratio': '130.00',
      'message': 'خبز: التكلفة 130.00 أعلى من سعر البيع 1.00.',
    };
  }

  test('a refused purchase carries the numbers that explain it', () {
    final warnings = purchaseCostWarningsFromException(
      exception(<String, Object?>{
        'cost_warnings': [warning(blocking: 'false')],
      }),
    );

    expect(warnings, hasLength(1));
    expect(warnings.single.kind, PurchaseCostWarningKind.aboveSalePrice);
    expect(warnings.single.baseUnitCost, '130.00');
    expect(warnings.single.reference, '1.00');
    expect(warnings.single.index, 0);
    expect(warnings.single.blocking, isFalse);
  });

  test('a POS refusal is marked blocking so no confirm is offered', () {
    // The flag travels as a string because DRF stringifies every leaf of an
    // error detail on its way out; a bool would arrive wrapped in a list.
    final warnings = purchaseCostWarningsFromException(
      exception(<String, Object?>{
        'cost_warnings': [warning(blocking: 'true')],
      }),
    );

    expect(warnings.single.blocking, isTrue);
    expect(purchaseCostWarningsAreBlocking(warnings), isTrue);
  });

  test('an ordinary validation error is not a cost warning', () {
    final warnings = purchaseCostWarningsFromException(
      exception(<String, Object?>{
        'supplier': ['This field is required.'],
      }),
    );

    expect(warnings, isEmpty);
    expect(purchaseCostWarningsAreBlocking(warnings), isFalse);
  });

  test('a non-400 failure is never read as a cost warning', () {
    final warnings = purchaseCostWarningsFromException(
      exception(<String, Object?>{'detail': 'Server error'}, status: 500),
    );

    expect(warnings, isEmpty);
  });
}
