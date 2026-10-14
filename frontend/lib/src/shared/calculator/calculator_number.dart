import 'package:flutter/foundation.dart';

/// An exact rational number for the calculator.
///
/// The till's calculator answers money questions, so it must never show the
/// binary floating-point residue a `double` leaves behind (0.1 + 0.2 is 0.3,
/// and 10 ÷ 3 × 3 is 10). Apple's Calculate engine gets there with 38-digit
/// decimals; a fraction of two [BigInt]s is simpler and exact for everything
/// the keypad can express. Rounding happens only when a value is displayed.
@immutable
class CalculatorNumber implements Comparable<CalculatorNumber> {
  const CalculatorNumber._(this.numerator, this.denominator);

  /// [numerator] / [denominator], reduced. The denominator must not be zero.
  factory CalculatorNumber.fraction(BigInt numerator, BigInt denominator) {
    assert(denominator != BigInt.zero, 'zero denominator');
    if (denominator.isNegative) {
      numerator = -numerator;
      denominator = -denominator;
    }
    final divisor = numerator.gcd(denominator);
    if (divisor > BigInt.one) {
      numerator = numerator ~/ divisor;
      denominator = denominator ~/ divisor;
    }
    return CalculatorNumber._(numerator, denominator);
  }

  factory CalculatorNumber.fromInt(int value) =>
      CalculatorNumber._(BigInt.from(value), BigInt.one);

  /// Parses a plain decimal literal ("12", "12.", ".5", "0.125"). Returns null
  /// for anything else; grouping separators are the caller's business.
  static CalculatorNumber? tryParse(String literal) {
    final match = RegExp(r'^(-?)(\d*)(?:\.(\d*))?$').firstMatch(literal);
    if (match == null) {
      return null;
    }
    final whole = match.group(2)!;
    final fraction = match.group(3) ?? '';
    if (whole.isEmpty && fraction.isEmpty) {
      return null;
    }
    final digits = BigInt.parse('${whole.isEmpty ? '0' : whole}$fraction');
    final scale = BigInt.from(10).pow(fraction.length);
    final value = CalculatorNumber.fraction(digits, scale);
    return match.group(1)!.isEmpty ? value : -value;
  }

  static final CalculatorNumber zero = CalculatorNumber._(
    BigInt.zero,
    BigInt.one,
  );
  static final CalculatorNumber hundred = CalculatorNumber.fromInt(100);

  final BigInt numerator;
  final BigInt denominator;

  bool get isZero => numerator == BigInt.zero;
  bool get isNegative => numerator.isNegative;
  bool get isInteger => denominator == BigInt.one;

  CalculatorNumber abs() =>
      isNegative ? CalculatorNumber._(-numerator, denominator) : this;

  CalculatorNumber operator -() => CalculatorNumber._(-numerator, denominator);

  CalculatorNumber operator +(CalculatorNumber other) =>
      CalculatorNumber.fraction(
        numerator * other.denominator + other.numerator * denominator,
        denominator * other.denominator,
      );

  CalculatorNumber operator -(CalculatorNumber other) => this + (-other);

  CalculatorNumber operator *(CalculatorNumber other) =>
      CalculatorNumber.fraction(
        numerator * other.numerator,
        denominator * other.denominator,
      );

  /// Throws [CalculatorDivisionByZero] when [other] is zero.
  CalculatorNumber operator /(CalculatorNumber other) {
    if (other.isZero) {
      throw const CalculatorDivisionByZero();
    }
    return CalculatorNumber.fraction(
      numerator * other.denominator,
      denominator * other.numerator,
    );
  }

  /// Floored remainder, the sign following the divisor — Apple's `mod`:
  /// -7 mod 3 = 2, 7 mod -3 = -2, 7.5 mod 2 = 1.5.
  CalculatorNumber remainder(CalculatorNumber other) {
    final quotient = this / other;
    return this - other * CalculatorNumber._(quotient._floor(), BigInt.one);
  }

  BigInt _floor() {
    final truncated = numerator ~/ denominator;
    final exact = truncated * denominator == numerator;
    return numerator.isNegative && !exact ? truncated - BigInt.one : truncated;
  }

  /// Rounded half away from zero to [fractionDigits] decimal places.
  CalculatorNumber roundedTo(int fractionDigits) {
    final scale = BigInt.from(10).pow(fractionDigits);
    return CalculatorNumber.fraction(_scaledRounded(scale), scale);
  }

  /// |this| × [scale], rounded half away from zero, signed like this.
  BigInt _scaledRounded(BigInt scale) {
    final scaled = numerator.abs() * scale;
    var quotient = scaled ~/ denominator;
    final remainder = scaled - quotient * denominator;
    if (remainder * BigInt.two >= denominator) {
      quotient += BigInt.one;
    }
    return isNegative ? -quotient : quotient;
  }

  /// Power of ten of the leading digit: 0 for 1–9.99…, 2 for 100, -3 for
  /// 0.001. Undefined for zero.
  int get _exponent {
    final magnitude = abs();
    final whole = magnitude.numerator ~/ magnitude.denominator;
    if (whole > BigInt.zero) {
      return whole.toString().length - 1;
    }
    var exponent = 0;
    var scaled = magnitude;
    final ten = CalculatorNumber.fromInt(10);
    while (scaled.numerator < scaled.denominator) {
      scaled = scaled * ten;
      exponent--;
    }
    return exponent;
  }

  /// Whether |this| is at least 10^[power].
  bool reaches(int power) => !isZero && abs().compareTo(_pow10(power)) >= 0;

  static CalculatorNumber _pow10(int power) => power >= 0
      ? CalculatorNumber._(BigInt.from(10).pow(power), BigInt.one)
      : CalculatorNumber._(BigInt.one, BigInt.from(10).pow(-power));

  /// A value bounded in size, for carrying a result into the next
  /// calculation. Exact unless its denominator has grown absurd (repeated
  /// division by 3), where 40 decimal places are far beyond anything shown.
  CalculatorNumber bounded() =>
      denominator.bitLength > 256 ? roundedTo(40) : this;

  /// For the display: grouped digits, a real minus sign, at most
  /// [maxSignificantDigits] significant digits and [maxFractionDigits]
  /// decimals; scientific notation (`1.219326311×10¹⁷`) past 15 integer
  /// digits or below 10⁻¹⁰.
  String format({
    bool grouping = true,
    int maxSignificantDigits = 15,
    int maxFractionDigits = 10,
    String minusSign = '−',
  }) {
    if (isZero) {
      return '0';
    }
    final exponent = _exponent;
    if (exponent >= 15 || exponent < -maxFractionDigits) {
      return _scientific(exponent, minusSign);
    }
    final fractionDigits = exponent >= 0
        ? (maxSignificantDigits - exponent - 1).clamp(0, maxFractionDigits)
        : maxFractionDigits;
    final text = _fixed(fractionDigits, grouping: grouping);
    if (text == '0') {
      return '0';
    }
    return isNegative ? '$minusSign$text' : text;
  }

  /// A money amount: rounded half away from zero to exactly [decimals]
  /// places and padded ("35.940" for dinars, "0.70" for euros), grouped —
  /// how Calculator.app shows a converted currency. Scientific past 15 whole
  /// digits, like [format].
  String formatMoney(int decimals, {String minusSign = '−'}) {
    final rounded = roundedTo(decimals);
    if (rounded.isZero) {
      return decimals == 0 ? '0' : '0.${'0' * decimals}';
    }
    if (rounded._exponent >= 15) {
      return rounded._scientific(rounded._exponent, minusSign);
    }
    final scale = BigInt.from(10).pow(decimals);
    final scaled = rounded._scaledRounded(scale).abs();
    final whole = groupDigits((scaled ~/ scale).toString());
    final text = decimals == 0
        ? whole
        : '$whole.${(scaled % scale).toString().padLeft(decimals, '0')}';
    return rounded.isNegative ? '$minusSign$text' : text;
  }

  /// Plain ASCII for the clipboard and for typing into a field: no grouping,
  /// `-` for minus, `.` for the decimal point, never scientific notation.
  String toPlainString({int maxFractionDigits = 10}) {
    final text = _fixed(maxFractionDigits, grouping: false);
    if (text == '0') {
      return '0';
    }
    return isNegative ? '-$text' : text;
  }

  /// Unsigned |this| with [fractionDigits] decimals, trailing zeros trimmed.
  String _fixed(int fractionDigits, {required bool grouping}) {
    final scale = BigInt.from(10).pow(fractionDigits);
    final rounded = _scaledRounded(scale).abs();
    final whole = (rounded ~/ scale).toString();
    var fraction = fractionDigits == 0
        ? ''
        : (rounded % scale).toString().padLeft(fractionDigits, '0');
    fraction = fraction.replaceFirst(RegExp(r'0+$'), '');
    final wholeText = grouping ? groupDigits(whole) : whole;
    return fraction.isEmpty ? wholeText : '$wholeText.$fraction';
  }

  String _scientific(int exponent, String minusSign) {
    const significant = 10;
    var power = exponent;
    var mantissa = (abs() / _pow10(power))._scaledRounded(
      BigInt.from(10).pow(significant - 1),
    );
    // 9.9999999999 rounds up to 10.000000000: one more power of ten.
    if (mantissa.toString().length > significant) {
      power += 1;
      mantissa = (abs() / _pow10(power))._scaledRounded(
        BigInt.from(10).pow(significant - 1),
      );
    }
    final digits = mantissa.toString();
    final fraction = digits.substring(1).replaceFirst(RegExp(r'0+$'), '');
    final head = fraction.isEmpty ? digits[0] : '${digits[0]}.$fraction';
    final sign = isNegative ? minusSign : '';
    return '$sign$head×10${_superscript(power)}';
  }

  static String _superscript(int value) {
    const digits = ['⁰', '¹', '²', '³', '⁴', '⁵', '⁶', '⁷', '⁸', '⁹'];
    final text = value
        .abs()
        .toString()
        .split('')
        .map((d) => digits[int.parse(d)]);
    return '${value < 0 ? '⁻' : ''}${text.join()}';
  }

  @override
  int compareTo(CalculatorNumber other) =>
      (numerator * other.denominator).compareTo(other.numerator * denominator);

  @override
  bool operator ==(Object other) =>
      other is CalculatorNumber &&
      other.numerator == numerator &&
      other.denominator == denominator;

  @override
  int get hashCode => Object.hash(numerator, denominator);

  @override
  String toString() => toPlainString();
}

/// Inserts `,` every three digits of an unsigned run of digits.
String groupDigits(String digits) {
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) {
      buffer.write(',');
    }
    buffer.write(digits[i]);
  }
  return buffer.toString();
}

/// Raised by [CalculatorNumber./] and [CalculatorNumber.remainder].
class CalculatorDivisionByZero implements Exception {
  const CalculatorDivisionByZero();
}
