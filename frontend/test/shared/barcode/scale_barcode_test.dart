import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/shared/barcode/scale_barcode.dart';

/// The shared vectors. Every one of these also lives in
/// `backend/apps/catalog/test_scale_barcodes.py` and must read identically on
/// both sides: the till reads a sticker locally, the price checker reads the
/// same sticker on the server, and a shop that got two answers from one label
/// would be right never to trust either.
const weightRule = ScaleBarcodeRule(pattern: '21IIIIIVVVVVC', name: 'weight');
const priceRule = ScaleBarcodeRule(
  pattern: '23IIIIIVVVVVC',
  valueKind: ScaleValueKind.price,
  valueDecimals: 2,
  name: 'price',
);
const compatRule = ScaleBarcodeRule(
  pattern: '2XIIIIIVVVVVC',
  name: 'compat',
  sequence: 100,
);

const rules = [weightRule, priceRule, compatRule];

void main() {
  group('parseScaleBarcode', () {
    test('reads the shared vectors exactly as the backend does', () {
      final vectors = <List<Object>>[
        ['2112345015002', 'weight', '12345', 1.5, '2112345000008'],
        ['2112345000008', 'weight', '12345', 0.0, '2112345000008'],
        ['2312345012500', 'price', '12345', 12.5, '2312345000002'],
        ['2012345007505', 'compat', '12345', 0.75, '2012345000001'],
      ];
      for (final vector in vectors) {
        final match = parseScaleBarcode(vector[0] as String, rules);
        expect(match, isNotNull, reason: '${vector[0]}');
        expect(match!.rule.name, vector[1]);
        expect(match.itemCode, vector[2]);
        expect(match.value, closeTo(vector[3] as double, 0.0000001));
        expect(match.baseCode, vector[4]);
      }
    });

    test('the base code is itself a valid barcode', () {
      final match = parseScaleBarcode('2112345015002', rules);
      expect(hasValidCheckDigit(match!.baseCode), isTrue);
    });

    test('candidates are ordered most specific first', () {
      final code = buildScaleCode(weightRule, '00123', 1.5);
      final match = parseScaleBarcode(code, rules);
      expect(match!.candidateBarcodes, <String>[
        '2100123000005',
        '2100123',
        '00123',
        '123',
      ]);
    });

    test('a code no rule describes is not a scale label', () {
      for (final code in <String?>[
        null,
        '',
        '   ',
        '6221031492030', // an ordinary supplier EAN
        '21123450150', // too short
        '211234501500222', // too long
        '21ABC45015002', // not digits
        '20123ا5015005', // Arabic-Indic stray from a flaky wedge
      ]) {
        expect(parseScaleBarcode(code, rules), isNull, reason: '$code');
      }
    });

    test('surrounding whitespace is stripped, not rejected', () {
      expect(parseScaleBarcode('  2112345015002 ', rules), isNotNull);
    });

    test('a wrong check digit is refused', () {
      expect(parseScaleBarcode('2112345015003', rules), isNull);
    });

    test('a scale that prints a wrong check digit can be accommodated', () {
      const lenient = ScaleBarcodeRule(
        pattern: '21IIIIIVVVVVC',
        requireCheckDigit: false,
      );
      final match = parseScaleBarcode('2112345015003', [lenient]);
      expect(match, isNotNull);
      expect(match!.value, closeTo(1.5, 0.0000001));
    });

    test('price and weight are never confused', () {
      final weight = parseScaleBarcode('2112345012506', rules);
      final price = parseScaleBarcode('2312345012500', rules);
      expect(weight!.valueKind, ScaleValueKind.weight);
      expect(weight.value, closeTo(1.25, 0.0000001));
      expect(price!.valueKind, ScaleValueKind.price);
      expect(price.value, closeTo(12.5, 0.0000001));
    });

    test('an unusable pattern never matches anything', () {
      const noPrefix = ScaleBarcodeRule(pattern: 'IIIIIVVVVVVVC');
      const noItem = ScaleBarcodeRule(pattern: '21VVVVVVVVVVC');
      expect(noPrefix.isUsable, isFalse);
      expect(noItem.isUsable, isFalse);
      expect(parseScaleBarcode('2112345015002', [noPrefix, noItem]), isNull);
    });
  });

  group('orderScaleRules', () {
    test('a more specific rule beats an earlier broad one', () {
      final ordered = orderScaleRules([compatRule, priceRule]);
      expect(ordered.first.name, 'price');
      final match = parseScaleBarcode('2312345012500', ordered);
      expect(match!.valueKind, ScaleValueKind.price);
    });

    test('inactive and unusable rules are dropped', () {
      const inactive = ScaleBarcodeRule(
        pattern: '21IIIIIVVVVVC',
        isActive: false,
      );
      const broken = ScaleBarcodeRule(pattern: 'nonsense');
      expect(orderScaleRules([inactive, broken]), isEmpty);
    });
  });

  group('buildScaleCode', () {
    test('round-trips every rule', () {
      for (final rule in rules) {
        for (final value in <double>[0, 1.5, 99.999]) {
          final rounded = rule.valueDecimals == 2
              ? (value * 100).round() / 100
              : value;
          final code = buildScaleCode(rule, '12345', rounded);
          final match = parseScaleBarcode(code, [rule]);
          expect(match, isNotNull, reason: '${rule.name} $value');
          expect(match!.value, closeTo(rounded, 0.0000001));
        }
      }
    });

    test('refuses a value that does not fit the pattern', () {
      expect(buildScaleCode(weightRule, '12345', 1000), '');
    });
  });

  group('resolveScaleQuantity', () {
    ScaleBarcodeMatch matchOf(String code) => parseScaleBarcode(code, rules)!;

    test('a weight label rings its weight', () {
      final resolved = resolveScaleQuantity(
        matchOf('2112345015002'),
        unitPrice: 40,
        allowsFractional: true,
      );
      expect(resolved.quantity, closeTo(1.5, 0.0000001));
      expect(resolved.hasWarning, isFalse);
    });

    test('a weight label converts into the product own unit', () {
      final resolved = resolveScaleQuantity(
        matchOf('2112345015002'),
        unitPrice: 0.04,
        allowsFractional: true,
        unitFactor: 1000,
      );
      expect(resolved.quantity, closeTo(1500, 0.0000001));
    });

    test('a counted product never takes a weight', () {
      final resolved = resolveScaleQuantity(
        matchOf('2112345015002'),
        unitPrice: 40,
        allowsFractional: false,
      );
      expect(resolved.quantity, 1);
      expect(resolved.warning, kScaleWarnNotFractional);
    });

    test('a weight that cannot reach the product unit is reported', () {
      final resolved = resolveScaleQuantity(
        matchOf('2112345015002'),
        unitPrice: 40,
        allowsFractional: true,
        unitFactor: null,
      );
      expect(resolved.quantity, 1);
      expect(resolved.warning, kScaleWarnUnitMismatch);
    });

    test('a zero-value label is an identity, not a measurement', () {
      final resolved = resolveScaleQuantity(
        matchOf('2112345000008'),
        unitPrice: 40,
        allowsFractional: true,
      );
      expect(resolved.quantity, 1);
      expect(resolved.hasWarning, isFalse);
    });

    test('a price label becomes the quantity that costs it', () {
      final resolved = resolveScaleQuantity(
        matchOf('2312345012500'),
        unitPrice: 4,
        allowsFractional: true,
      );
      expect(resolved.quantity, closeTo(3.125, 0.0000001));
      expect(resolved.labelTotal, closeTo(12.5, 0.0000001));
      expect(resolved.rungTotal, closeTo(12.5, 0.0000001));
      expect(resolved.hasWarning, isFalse);
    });

    test(
      'a tie goes down, so the customer is never charged above the sticker',
      () {
        // 12.50 / 40.00 is 0.3125 — exactly between two storable quantities.
        final resolved = resolveScaleQuantity(
          matchOf('2312345012500'),
          unitPrice: 40,
          allowsFractional: true,
        );
        expect(resolved.quantity, closeTo(0.312, 0.0000001));
        expect(resolved.rungTotal, closeTo(12.48, 0.0000001));
        expect(resolved.warning, kScaleWarnRoundingDrift);
      },
    );

    test('a price label that cannot be rung exactly says so', () {
      final resolved = resolveScaleQuantity(
        matchOf('2312345012500'),
        unitPrice: 300,
        allowsFractional: true,
      );
      expect(resolved.quantity, closeTo(0.042, 0.0000001));
      expect(resolved.rungTotal, closeTo(12.6, 0.0000001));
      expect(resolved.warning, kScaleWarnRoundingDrift);
      expect(resolved.drift, closeTo(0.10, 0.0000001));
    });

    test('a price label never divides by a zero price', () {
      final resolved = resolveScaleQuantity(
        matchOf('2312345012500'),
        unitPrice: 0,
        allowsFractional: true,
      );
      expect(resolved.quantity, 1);
      expect(resolved.warning, kScaleWarnNoUnitPrice);
    });

    test('a count label rings its count', () {
      const countRule = ScaleBarcodeRule(
        pattern: '24IIIIIVVVVVC',
        valueKind: ScaleValueKind.count,
        valueDecimals: 0,
      );
      final code = buildScaleCode(countRule, '12345', 6);
      final resolved = resolveScaleQuantity(
        parseScaleBarcode(code, [countRule])!,
        unitPrice: 5,
        allowsFractional: false,
      );
      expect(resolved.quantity, 6);
    });
  });
}
