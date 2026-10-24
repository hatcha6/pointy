import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_cards/src/core/money.dart';

void main() {
  test('reads the relay amounts exactly', () {
    expect(Money.parse('10.000').dirhams, 10000);
    expect(Money.parse('10.5').dirhams, 10500);
    expect(Money.parse('0.210').dirhams, 210);
    expect(Money.parse('-3.25').dirhams, -3250);
    expect(Money.parse('abc'), Money.zero);
    expect(Money.parse(null), Money.zero);
  });

  test('writes three places for the relay and two for people', () {
    expect(const Money(20410).toWire(), '20.410');
    expect(const Money(20410).toFixed2(), '20.41');
    expect(const Money(10005).toFixed2(), '10.01');
    expect(const Money(10004).toFixed2(), '10.00');
    expect((Money.parse('10') * 2 + Money.parse('0.41')).toWire(), '20.410');
  });
}
