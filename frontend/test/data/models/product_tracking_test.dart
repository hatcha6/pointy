import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/identified_stock_settings.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/models/product.dart';
import 'package:pointy_frontend/src/data/models/product_draft.dart';
import 'package:pointy_frontend/src/data/models/product_tracking.dart';
import 'package:pointy_frontend/src/data/models/product_update_draft.dart';
import 'package:pointy_frontend/src/data/models/shop_settings.dart';
import 'package:pointy_frontend/src/data/models/tracking_mode.dart';
import 'package:pointy_frontend/src/shared/tracking/tracking_features.dart';

/// How a product's tracking travels between the form and the server, and the
/// shop switches that decide whether the form offers it at all.
void main() {
  group('a product\'s tracking', () {
    test('is read whole off the product payload', () {
      final product = Product.fromJson({
        'id': 1,
        'name': 'iPhone 13',
        'quantity_on_hand': 0,
        'tracking_mode': 'serial',
        'asset_type': 4,
        'warranty_days': 365,
        'shelf_life_days': 0,
        'expiry_warning_days': 45,
        'auto_pick_strategy': 'fifo',
        'prevent_selling_expired': false,
      });

      expect(
        product.tracking,
        const ProductTracking(
          mode: TrackingMode.serial,
          assetTypeId: 4,
          warrantyDays: 365,
          expiryWarningDays: 45,
          autoPickStrategy: BatchPickStrategy.fifo,
          preventSellingExpired: false,
        ),
      );
    });

    test('a catalog-list variant takes its product\'s mode', () {
      // The list drops each variant's product_detail and the variant payload
      // carried no mode of its own, so every serialized product in the till's
      // grid read as `quantity`: no unit picker, and a quantity box instead.
      final product = Product.fromJson({
        'id': 1,
        'name': 'iPhone 13',
        'quantity_on_hand': 2,
        'tracking_mode': 'serial',
        'variants': [
          {'id': 11, 'product': 1, 'sku': 'IP13-128', 'unit_price': '1500'},
        ],
        'default_variant': {
          'id': 11,
          'product': 1,
          'sku': 'IP13-128',
          'unit_price': '1500',
        },
      });

      expect(product.variants.single.trackingMode, TrackingMode.serial);
      expect(product.defaultVariant!.trackingMode, TrackingMode.serial);
    });

    test('an update that edited it sends the mode and its facts', () {
      const draft = ProductUpdateDraft(
        name: 'Amoxicillin 500',
        description: '',
        isActive: true,
        tracksExpiry: true,
        categoryIds: [],
        tracking: ProductTracking(
          mode: TrackingMode.batch,
          autoPickStrategy: BatchPickStrategy.fefo,
        ),
      );

      final json = draft.toJson();

      expect(json['tracking_mode'], 'batch');
      // Derived from the mode, for a server that predates it.
      expect(json['tracks_expiry'], isTrue);
      expect(json['auto_pick_strategy'], 'fefo');
      expect(json['prevent_selling_expired'], isTrue);
      expect(json.containsKey('warranty_days'), isTrue);
    });

    test('an update that never showed the choice sends only the old flag', () {
      const draft = ProductUpdateDraft(
        name: 'Milk',
        description: '',
        isActive: true,
        tracksExpiry: false,
        categoryIds: [],
      );

      final json = draft.toJson();

      expect(json['tracks_expiry'], isFalse);
      expect(json.containsKey('tracking_mode'), isFalse);
    });

    test('a new product carries the kind of device and its warranty', () {
      const draft = ProductDraft(
        variantSku: '',
        name: 'Galaxy A55',
        variantUnitPrice: 900,
        isActive: true,
        tracksExpiry: false,
        tracking: ProductTracking(
          mode: TrackingMode.serial,
          assetTypeId: 2,
          warrantyDays: 180,
        ),
      );

      final json = draft.toJson();

      expect(json['tracking_mode'], 'serial');
      expect(json['asset_type'], 2);
      expect(json['warranty_days'], 180);
      expect(json['tracks_expiry'], isFalse);
    });
  });

  group('the shop\'s identified-stock settings', () {
    test('are read off the settings payload, and off when absent', () {
      final settings = ShopSettings.fromJson(const {
        'shop_name': 'محل',
        'enable_serialized_inventory': true,
        'serialized_capture_later_allowed': true,
        'consignment_default_liability_policy': 'shop_liable',
        'consignment_clause_shop_liable': 'المحل ضامن.',
        'consignment_unclaimed_payout_reminder_days': 0,
      });

      final stock = settings.identifiedStock;
      expect(stock.enableSerializedInventory, isTrue);
      expect(stock.enableBatchTracking, isFalse);
      expect(stock.captureLaterAllowed, isTrue);
      expect(stock.requireCustomerForAsset, isTrue);
      expect(stock.clauseFor('shop_liable'), 'المحل ضامن.');
      expect(stock.consignmentUnclaimedPayoutReminderDays, 0);
    });

    test('are saved naming only their own keys', () {
      // The page saves a partial update: a key it does not own would be a
      // setting it could reset without showing it.
      final json = const IdentifiedStockSettings(
        enableBatchTracking: true,
      ).toJson();

      expect(json['enable_batch_tracking'], isTrue);
      expect(
        json.keys.every(
          (key) =>
              key.startsWith('enable_serialized') ||
              key.startsWith('enable_batch') ||
              key.startsWith('serialized_') ||
              key.startsWith('consignment_') ||
              key.contains('batch') ||
              key.contains('expir'),
        ),
        isTrue,
        reason: json.keys.join(', '),
      );
      expect(json.containsKey('shop_name'), isFalse);
      expect(json.containsKey('allow_overselling'), isFalse);
    });
  });

  group('which modes a product form offers', () {
    test('a shop with neither trade on offers nothing new', () {
      expect(TrackingFeatures.none.any, isFalse);
      expect(TrackingFeatures.none.offeredModes(), [TrackingMode.quantity]);
    });

    test('serial and lots together offer the fourth mode too', () {
      const features = TrackingFeatures(serial: true, batch: true);
      expect(features.offeredModes(), TrackingMode.values);
    });

    test('a product keeps its own mode on offer after its trade is off', () {
      const features = TrackingFeatures(batch: true);
      expect(features.offeredModes(current: TrackingMode.serial), [
        TrackingMode.quantity,
        TrackingMode.batch,
        TrackingMode.serial,
      ]);
    });

    test('are read off the signed-in user', () {
      const user = PosUser(
        id: 1,
        username: 'owner',
        displayName: 'owner',
        role: UserRole.manager,
        isActive: true,
        serializedInventoryEnabled: true,
        serializedCaptureLaterAllowed: true,
      );
      final features = TrackingFeatures.of(user);
      expect(features.serial, isTrue);
      expect(features.batch, isFalse);
      expect(features.captureLater, isTrue);
    });
  });
}
