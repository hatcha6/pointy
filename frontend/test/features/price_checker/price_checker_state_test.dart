import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/price_checker_config.dart';
import 'package:pointy_frontend/src/data/models/price_lookup_result.dart';
import 'package:pointy_frontend/src/shared/price_checker/price_checker_mode_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PriceLookupResult.fromJson', () {
    test('parses a found, discounted payload with image + discounts', () {
      final result = PriceLookupResult.fromJson({
        'found': true,
        'barcode': '6001234500001',
        'in_stock': true,
        'currency': 'د.ل',
        'product_name': 'قميص',
        'variant_name': 'L',
        'sku': 'TEE-1',
        'unit': 'PCS',
        'original_price': '20.00',
        'final_price': '18.00',
        'discount_total': '2.00',
        'discount_percent': 10,
        'has_discount': true,
        'original_price_display': '20.00 د.ل',
        'final_price_display': '18.00 د.ل',
        'image_url': 'http://host/api/attachments/5/content/?token=abc',
        'discounts': [
          {
            'name': '10% off',
            'value_type': 'percentage',
            'value': '10.00',
            'amount': '2.00',
          },
        ],
      });

      expect(result.found, isTrue);
      expect(result.hasImage, isTrue);
      expect(result.hasDiscount, isTrue);
      expect(result.discountPercent, 10);
      expect(result.showsVariant, isTrue);
      expect(result.finalPriceDisplay, '18.00 د.ل');
      expect(result.discounts.single.name, '10% off');
      expect(result.discounts.single.isPercentage, isTrue);
    });

    test('parses a not-found payload', () {
      final result = PriceLookupResult.fromJson({
        'found': false,
        'barcode': 'nope',
        'in_stock': true,
        'currency': 'د.ل',
      });
      expect(result.found, isFalse);
      expect(result.hasImage, isFalse);
      expect(result.discounts, isEmpty);
    });

    test('discount_percent tolerates string and num shapes', () {
      expect(
        PriceLookupResult.fromJson({
          'found': true,
          'discount_percent': '15',
        }).discountPercent,
        15,
      );
      expect(
        PriceLookupResult.fromJson({
          'found': true,
          'discount_percent': 12.6,
        }).discountPercent,
        13,
      );
    });

    test('a variant equal to the product name is not shown twice', () {
      final result = PriceLookupResult.fromJson({
        'found': true,
        'product_name': 'قميص',
        'variant_name': 'قميص',
      });
      expect(result.showsVariant, isFalse);
    });
  });

  group('PriceCheckerConfig', () {
    test('round-trips through JSON', () {
      const config = PriceCheckerConfig(
        enabled: true,
        pin: '4321',
        deviceName: 'Aisle 3',
        location: 'Front',
        identifier: 'pc-aisle-3-ab12cd',
        cameraEnabled: false,
        cameraFacing: PriceCheckerCameraFacing.back,
        foundDwellSeconds: 15,
      );
      final decoded = PriceCheckerConfig.decode(config.encode());
      expect(decoded.enabled, isTrue);
      expect(decoded.pin, '4321');
      expect(decoded.deviceName, 'Aisle 3');
      expect(decoded.identifier, 'pc-aisle-3-ab12cd');
      expect(decoded.isConfigured, isTrue);
      expect(decoded.cameraEnabled, isFalse);
      expect(decoded.cameraFacing, PriceCheckerCameraFacing.back);
      expect(decoded.foundDwellSeconds, 15);
    });

    test('empty config decodes from null/blank', () {
      expect(PriceCheckerConfig.decode(null).isConfigured, isFalse);
      expect(PriceCheckerConfig.decode('').enabled, isFalse);
    });

    test('configs saved before camera support decode with the defaults', () {
      final decoded = PriceCheckerConfig.decode(
        '{"enabled": true, "pin": "1234", "device_name": "Aisle 3", '
        '"location": "", "identifier": "pc-aisle-3-ab12cd"}',
      );
      expect(decoded.cameraEnabled, isTrue);
      expect(decoded.cameraFacing, PriceCheckerCameraFacing.front);
      expect(
        decoded.foundDwellSeconds,
        PriceCheckerConfig.defaultFoundDwellSeconds,
      );
    });

    test('found dwell is clamped to a kiosk-safe range', () {
      final config = PriceCheckerConfig.empty();
      expect(
        config.copyWith(foundDwellSeconds: 0).foundDwellSeconds,
        PriceCheckerConfig.minFoundDwellSeconds,
      );
      expect(
        config.copyWith(foundDwellSeconds: 900).foundDwellSeconds,
        PriceCheckerConfig.maxFoundDwellSeconds,
      );
      expect(
        PriceCheckerConfig.fromJson(const {
          'found_dwell_seconds': 999,
        }).foundDwellSeconds,
        PriceCheckerConfig.maxFoundDwellSeconds,
      );
    });
  });

  group('PriceCheckerModeController', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test(
      'configureAndEnable enables, mints an identifier, and persists',
      () async {
        final controller = PriceCheckerModeController();
        await controller.load();
        expect(controller.enabled, isFalse);
        expect(controller.isConfigured, isFalse);

        await controller.configureAndEnable(pin: '1234', deviceName: 'Aisle 3');
        expect(controller.enabled, isTrue);
        expect(controller.isConfigured, isTrue);
        expect(controller.config.identifier, isNotEmpty);
        expect(controller.verifyPin('1234'), isTrue);
        expect(controller.verifyPin('0000'), isFalse);

        // Survives a fresh controller (persisted to SharedPreferences).
        final reloaded = PriceCheckerModeController();
        await reloaded.load();
        expect(reloaded.enabled, isTrue);
        expect(reloaded.config.deviceName, 'Aisle 3');
        expect(reloaded.config.identifier, controller.config.identifier);
      },
    );

    test('exit disables but keeps the config; enter re-enables', () async {
      final controller = PriceCheckerModeController();
      await controller.configureAndEnable(pin: '1234');

      await controller.exit();
      expect(controller.enabled, isFalse);
      expect(controller.isConfigured, isTrue); // PIN retained

      final identifier = controller.config.identifier;
      await controller.enter();
      expect(controller.enabled, isTrue);
      // Re-entering must not mint a new identifier.
      expect(controller.config.identifier, identifier);
    });

    test('clear forgets the configuration entirely', () async {
      final controller = PriceCheckerModeController();
      await controller.configureAndEnable(pin: '1234', deviceName: 'X');
      await controller.clear();
      expect(controller.enabled, isFalse);
      expect(controller.isConfigured, isFalse);
      expect(controller.config.deviceName, isEmpty);
    });

    test('enter is a no-op when not configured', () async {
      final controller = PriceCheckerModeController();
      await controller.load();
      await controller.enter();
      expect(controller.enabled, isFalse);
    });

    test('updateScanSettings persists camera + dwell preferences', () async {
      final controller = PriceCheckerModeController();
      await controller.configureAndEnable(pin: '1234');
      await controller.updateScanSettings(
        cameraEnabled: false,
        cameraFacing: PriceCheckerCameraFacing.back,
        foundDwellSeconds: 20,
      );

      final reloaded = PriceCheckerModeController();
      await reloaded.load();
      expect(reloaded.config.cameraEnabled, isFalse);
      expect(reloaded.config.cameraFacing, PriceCheckerCameraFacing.back);
      expect(reloaded.config.foundDwellSeconds, 20);
    });
  });
}
