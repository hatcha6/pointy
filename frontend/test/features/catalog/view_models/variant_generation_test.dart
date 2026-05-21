import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/variant_option.dart';
import 'package:pointy_frontend/src/data/models/variant_option_value.dart';
import 'package:pointy_frontend/src/features/catalog/view_models/variant_generation.dart';

void main() {
  group('variant generation', () {
    test('generates every selected option value combination', () {
      final combinations = generateVariantCombinations(
        options: const [_colorOption, _storageOption],
        selectedValueIdsByOption: const {
          1: {11, 12},
          2: {21, 22},
        },
      );

      expect(combinations, hasLength(4));
      expect(combinations.map((combination) => combination.autoName), [
        'Black 128GB',
        'Black 256GB',
        'White 128GB',
        'White 256GB',
      ]);
      expect(combinations.first.skuFromBase(' iphone '), 'IPHONE-BLACK-128GB');
    });

    test('requires at least one selected value per selected option', () {
      final combinations = generateVariantCombinations(
        options: const [_colorOption, _storageOption],
        selectedValueIdsByOption: const {
          1: {11},
          2: {},
        },
      );

      expect(combinations, isEmpty);
    });
  });
}

const _colorOption = VariantOption(
  id: 1,
  code: 'color',
  name: 'Color',
  values: [
    VariantOptionValue(
      id: 11,
      optionId: 1,
      optionName: 'Color',
      code: 'black',
      name: 'Black',
    ),
    VariantOptionValue(
      id: 12,
      optionId: 1,
      optionName: 'Color',
      code: 'white',
      name: 'White',
    ),
  ],
);

const _storageOption = VariantOption(
  id: 2,
  code: 'storage',
  name: 'Storage',
  values: [
    VariantOptionValue(
      id: 21,
      optionId: 2,
      optionName: 'Storage',
      code: '128gb',
      name: '128GB',
    ),
    VariantOptionValue(
      id: 22,
      optionId: 2,
      optionName: 'Storage',
      code: '256gb',
      name: '256GB',
    ),
  ],
);
