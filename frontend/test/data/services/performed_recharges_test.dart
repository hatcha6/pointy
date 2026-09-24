import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/integration_card.dart';
import 'package:pointy_frontend/src/data/models/sale_order.dart';
import 'package:pointy_frontend/src/data/services/performed_recharges.dart';

SaleOrder _order(List<SaleOrderLine> lines) => SaleOrder(
  id: 1,
  status: 'completed',
  lines: lines,
  payments: const [],
  subtotal: 5,
  total: 5,
);

SaleOrderLine _line({required int id, SaleLineIntegration? integration}) =>
    SaleOrderLine(
      id: id,
      productId: 1,
      variantId: 1,
      quantity: 1,
      returnedQuantity: 0,
      returnableQuantity: 0,
      unitPrice: 5,
      total: 5,
      integration: integration,
    );

const _pendingVoucher = SaleLineIntegration(
  provider: 'qareeb',
  subscriberRef: '',
  kind: 'voucher',
  status: 'pending',
);

IntegrationChargeResult _charged({
  required int orderLine,
  Map<String, String> receipt = const {'code': '1234-5678', 'serial': 'SN-9'},
}) => IntegrationChargeResult(
  fulfillment: 99,
  outcome: 'charged',
  orderLine: orderLine,
  kind: 'voucher',
  providerReference: 'ref-1',
  receipt: receipt,
);

void main() {
  group('orderWithPerformedRecharges', () {
    test(
      'overlays a charged card onto its line so the receipt prints the PIN',
      () {
        final order = _order([_line(id: 7, integration: _pendingVoucher)]);

        final merged = orderWithPerformedRecharges(order, [
          _charged(orderLine: 7),
        ]);

        final integration = merged.lines.single.integration!;
        expect(integration.status, 'confirmed');
        expect(integration.isConfirmed, isTrue);
        expect(integration.receipt['code'], '1234-5678');
        expect(integration.receipt['serial'], 'SN-9');
        expect(integration.providerReference, 'ref-1');
        // The line the pending order carried before the charge answered.
        expect(order.lines.single.integration!.status, 'pending');
        expect(order.lines.single.integration!.receipt, isEmpty);
      },
    );

    test(
      'leaves a refused charge exactly as recorded — the receipt stays honest',
      () {
        final order = _order([_line(id: 7, integration: _pendingVoucher)]);

        final merged = orderWithPerformedRecharges(order, const [
          IntegrationChargeResult(
            fulfillment: 99,
            outcome: 'refused',
            orderLine: 7,
            kind: 'voucher',
            errorCode: 'insufficient_float',
          ),
        ]);

        expect(merged.lines.single.integration!.status, 'pending');
        expect(merged.lines.single.integration!.receipt, isEmpty);
      },
    );

    test('ignores a charged result that carries no printed slip', () {
      final order = _order([_line(id: 7, integration: _pendingVoucher)]);

      final merged = orderWithPerformedRecharges(order, [
        _charged(orderLine: 7, receipt: const {}),
      ]);

      expect(merged.lines.single.integration!.status, 'pending');
    });

    test('only overlays the line the result names, leaving the rest alone', () {
      final order = _order([
        _line(id: 7, integration: _pendingVoucher),
        _line(id: 8, integration: _pendingVoucher),
      ]);

      final merged = orderWithPerformedRecharges(order, [
        _charged(orderLine: 8),
      ]);

      expect(merged.lines[0].integration!.status, 'pending');
      expect(merged.lines[1].integration!.status, 'confirmed');
      expect(merged.lines[1].integration!.receipt['code'], '1234-5678');
    });

    test('returns the order untouched when nothing matches', () {
      final order = _order([_line(id: 7, integration: _pendingVoucher)]);

      expect(orderWithPerformedRecharges(order, const []), same(order));
      expect(
        orderWithPerformedRecharges(order, [_charged(orderLine: 999)]),
        same(order),
      );
    });

    test('never invents an integration on an ordinary line', () {
      final order = _order([_line(id: 7)]);

      final merged = orderWithPerformedRecharges(order, [
        _charged(orderLine: 7),
      ]);

      expect(merged.lines.single.integration, isNull);
    });
  });
}
