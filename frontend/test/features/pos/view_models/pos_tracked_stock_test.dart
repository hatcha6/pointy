import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/cart_line.dart';
import 'package:pointy_frontend/src/data/models/product.dart';
import 'package:pointy_frontend/src/data/models/product_variant.dart';
import 'package:pointy_frontend/src/data/models/sale_order.dart';
import 'package:pointy_frontend/src/data/models/stock_batch.dart';
import 'package:pointy_frontend/src/data/models/stock_unit.dart';
import 'package:pointy_frontend/src/data/models/tracked_scan.dart';
import 'package:pointy_frontend/src/data/models/tracking_mode.dart';

/// The till's half of identified stock, tested where the rules live.
///
/// Every one of these is named after what goes wrong without it, and the two
/// that matter most are about *not merging*: a serialized line is one specific
/// handset, and a cart that added a second one to its quantity would be a cart
/// claiming to hold two devices with the same IMEI.
void main() {
  ProductVariant variant({
    int id = 1,
    TrackingMode mode = TrackingMode.serial,
    double price = 1500,
  }) {
    return ProductVariant(
      id: id,
      productId: 10,
      sku: 'IP13P',
      unitPrice: price,
      productName: 'iPhone 13 Pro',
      trackingMode: mode,
      productDetail: Product(
        id: 10,
        name: 'iPhone 13 Pro',
        quantityOnHand: 3,
        trackingMode: mode,
      ),
    );
  }

  StockUnit unit({
    int id = 100,
    String code = '351234567890116',
    double? price,
  }) {
    return StockUnit(
      id: id,
      variantId: 1,
      code: code,
      listPrice: price,
      inStockSince: DateTime.now().subtract(const Duration(days: 45)),
    );
  }

  StockBatch batch({int id = 7, String code = 'A-2026-01', DateTime? expiry}) {
    return StockBatch(
      id: id,
      variantId: 1,
      code: code,
      displayCode: code,
      expiryDate: expiry ?? DateTime.now().add(const Duration(days: 200)),
    );
  }

  group('TrackingMode', () {
    test('the fourth mode is both, which is the whole point of it', () {
      expect(TrackingMode.serialBatch.tracksUnits, isTrue);
      expect(TrackingMode.serialBatch.tracksLots, isTrue);
      expect(TrackingMode.serialBatch.requiresLot, isTrue);
    });

    test(
      'quantity tracks nothing and is what an unknown value falls back to',
      () {
        expect(TrackingMode.quantity.isTracked, isFalse);
        expect(TrackingMode.fromWire('something_new'), TrackingMode.quantity);
        expect(TrackingMode.fromWire(null), TrackingMode.quantity);
      },
    );
  });

  group('a serialized cart line', () {
    test('is one article, so its quantity may not be edited', () {
      final line = CartLine.create(
        variant: variant(),
        quantity: 1,
        stockUnitId: 100,
        stockUnitCode: '351234567890116',
      );
      expect(line.isSerialized, isTrue);
      expect(line.allowsQuantityEdit, isFalse);
    });

    test('an ordinary line still steps freely', () {
      final line = CartLine.create(variant: variant(), quantity: 2);
      expect(line.isSerialized, isFalse);
      expect(line.allowsQuantityEdit, isTrue);
    });

    test('survives a restart with the article it named', () {
      final line = CartLine.create(
        variant: variant(),
        quantity: 1,
        stockUnitId: 100,
        stockUnitCode: '351234567890116',
        stockBatchId: 7,
        stockBatchCode: 'A-2026-01',
        stockBatchExpiry: DateTime(2027, 8, 31),
      );
      final restored = CartLine.fromJson(line.toJson());

      expect(restored.stockUnitId, 100);
      expect(restored.stockUnitCode, '351234567890116');
      expect(restored.stockBatchId, 7);
      expect(restored.stockBatchCode, 'A-2026-01');
      expect(restored.stockBatchExpiry, DateTime(2027, 8, 31));
    });
  });

  group('the checkout payload', () {
    test('names the article a serialized line rings up', () {
      final draft = SaleCheckoutDraft.fromCart(
        cart: [
          CartLine.create(
            variant: variant(),
            quantity: 1,
            stockUnitId: 100,
            stockUnitCode: '351234567890116',
          ),
        ],
        payments: const [],
      );
      final line = draft.lines.single.toJson();

      expect(line['stock_units'], [100]);
      expect(line.containsKey('stock_batches'), isFalse);
    });

    test('names a pinned lot, and stays silent when FEFO should choose', () {
      final pinned = SaleCheckoutDraft.fromCart(
        cart: [
          CartLine.create(
            variant: variant(mode: TrackingMode.batch),
            quantity: 3,
            stockBatchId: 7,
          ),
        ],
        payments: const [],
      ).lines.single.toJson();
      expect(pinned['stock_batches'], [7]);

      final unpinned = SaleCheckoutDraft.fromCart(
        cart: [
          CartLine.create(
            variant: variant(mode: TrackingMode.batch),
            quantity: 3,
          ),
        ],
        payments: const [],
      ).lines.single.toJson();
      // Absent, not null: leaving the choice to the backend is an instruction,
      // and an explicit null would read as "no lot".
      expect(unpinned.containsKey('stock_batches'), isFalse);
    });

    test('an untracked line carries neither key', () {
      final line = SaleCheckoutDraft.fromCart(
        cart: [
          CartLine.create(
            variant: variant(mode: TrackingMode.quantity),
            quantity: 2,
          ),
        ],
        payments: const [],
      ).lines.single.toJson();

      expect(line.containsKey('stock_units'), isFalse);
      expect(line.containsKey('stock_batches'), isFalse);
    });
  });

  group('a resolved scan', () {
    test('prices the line at the article\'s own asking price', () {
      final scan = TrackedScan(
        kind: TrackedScanKind.stockUnit,
        variant: variant(),
        unit: unit(price: 1650),
      );
      expect(scan.resolvedUnitPrice, 1650);
    });

    test('falls back to the variant price when the article has none', () {
      final scan = TrackedScan(
        kind: TrackedScanKind.stockUnit,
        variant: variant(),
        unit: unit(),
      );
      expect(scan.resolvedUnitPrice, 1500);
    });

    test('reads a GS1 answer whole', () {
      final scan = TrackedScan.fromJson({
        'kind': 'gs1',
        'found': true,
        'expiry_date': '2027-08-31',
        'variant': {
          'id': 4,
          'sku': 'VAX',
          'unit_price': '90.00',
          'product': {
            'id': 9,
            'name': 'لقاح',
            'tracking_mode': 'serial_batch',
            'unit': 'piece',
          },
        },
        'stock_unit': {'id': 12, 'code': 'PACK-1', 'variant': 4},
        'stock_batch': {
          'id': 3,
          'variant': 4,
          'code': 'ABC123',
          'display_code': 'ABC123',
          'expiry_date': '2027-08-31',
        },
        'warnings': const [],
      });

      expect(scan.isGs1, isTrue);
      expect(scan.variant?.id, 4);
      // The product rides along, so the till knows the mode without a lookup.
      expect(scan.variant?.trackingMode, TrackingMode.serialBatch);
      expect(scan.unit?.code, 'PACK-1');
      expect(scan.batch?.code, 'ABC123');
      expect(scan.expiryDate, DateTime(2027, 8, 31));
    });

    test('a misconfigured reader is singled out from ordinary warnings', () {
      final scan = TrackedScan.fromJson({
        'kind': 'none',
        'found': false,
        'warnings': [
          {'code': 'unknown_lot', 'message': 'lot'},
          {'code': 'missing_group_separator', 'message': 'أعد ضبط القارئ'},
        ],
      });

      expect(scan.warnings.length, 2);
      expect(
        scan.warnings.where((warning) => warning.isScannerConfiguration).length,
        1,
      );
    });
  });

  group('a lot', () {
    test('knows how close it is to turning', () {
      final soon = batch(expiry: DateTime.now().add(const Duration(days: 10)));
      expect(soon.daysUntilExpiry, inInclusiveRange(9, 10));
      expect(soon.isExpired, isFalse);

      final gone = batch(
        expiry: DateTime.now().subtract(const Duration(days: 1)),
      );
      expect(gone.isExpired, isTrue);
    });

    test('a generated code renders as no code at all', () {
      final generated = StockBatch(
        id: 1,
        variantId: 1,
        code: 'RL-42',
        displayCode: '',
        codeIsGenerated: true,
      );
      // «بدون رقم دفعة» rather than a number nobody printed on a box.
      expect(generated.label, isEmpty);
    });

    test('answers where it is, per place', () {
      final lot = StockBatch(
        id: 1,
        variantId: 1,
        code: 'A-1',
        displayCode: 'A-1',
        onHand: 100,
        balances: const [
          StockBatchBalance(
            id: 1,
            batchId: 1,
            warehouseId: 5,
            remainingQuantity: 60,
          ),
          StockBatchBalance(
            id: 2,
            batchId: 1,
            warehouseId: 6,
            remainingQuantity: 40,
          ),
        ],
      );

      expect(lot.quantityAt(5), 60);
      expect(lot.quantityAt(6), 40);
      // No place named means the whole lot, wherever it is.
      expect(lot.quantityAt(null), 100);
      // A place it has never been in holds none of it.
      expect(lot.quantityAt(99), 0);
    });
  });

  group('an identified article', () {
    test('hides its cost when the reader may not see it', () {
      final masked = StockUnit.fromJson({
        'id': 1,
        'variant': 1,
        'code': 'X',
        'status': 'in_stock',
      });
      expect(masked.showsCost, isFalse);
      expect(masked.totalCost, isNull);

      final visible = StockUnit.fromJson({
        'id': 1,
        'variant': 1,
        'code': 'X',
        'status': 'in_stock',
        'total_cost': '1200.00',
      });
      expect(visible.showsCost, isTrue);
      expect(visible.totalCost, 1200);
    });

    test('a placeholder is on the shelf but may not be sold', () {
      final placeholder = StockUnit.fromJson({
        'id': 1,
        'variant': 1,
        'code': '#R12-1',
        'status': 'in_stock',
        'is_identified': false,
      });
      expect(placeholder.isOnHand, isTrue);
      expect(placeholder.isSellable, isFalse);
    });
  });
}
