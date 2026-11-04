import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/shared/tracking/expiry_date_field.dart';

/// An expiry is typed the way it is printed: month and year, mostly. The
/// parser is the whole of what makes `12/27` + Enter faster than a calendar.
void main() {
  test('a month and year is the last day of that month', () {
    expect(parseTypedExpiry('12/27'), DateTime(2027, 12, 31));
    expect(parseTypedExpiry('02/2028'), DateTime(2028, 2, 29));
    expect(parseTypedExpiry('0827'), DateTime(2027, 8, 31));
    expect(parseTypedExpiry('082027'), DateTime(2027, 8, 31));
    expect(parseTypedExpiry('2027-06'), DateTime(2027, 6, 30));
    expect(parseTypedExpiry(' 4 . 27 '), DateTime(2027, 4, 30));
  });

  test('a full date is that day, in either order', () {
    expect(parseTypedExpiry('15/03/2027'), DateTime(2027, 3, 15));
    expect(parseTypedExpiry('15.03.27'), DateTime(2027, 3, 15));
    expect(parseTypedExpiry('31082027'), DateTime(2027, 8, 31));
    expect(parseTypedExpiry('310827'), DateTime(2027, 8, 31));
    expect(parseTypedExpiry('2027-03-15'), DateTime(2027, 3, 15));
  });

  test('an Arabic keyboard types Arabic-Indic digits', () {
    expect(parseTypedExpiry('١٢/٢٧'), DateTime(2027, 12, 31));
    expect(parseTypedExpiry('۰۸/۲۰۲۷'), DateTime(2027, 8, 31));
  });

  test('a typo is not quietly turned into some other date', () {
    expect(parseTypedExpiry('13/27'), isNull);
    expect(parseTypedExpiry('31/04/2027'), isNull);
    expect(parseTypedExpiry('00/27'), isNull);
    expect(parseTypedExpiry('12'), isNull);
    expect(parseTypedExpiry('12/ab'), isNull);
    expect(parseTypedExpiry(''), isNull);
  });

  test('a date is written back the way it was most likely typed', () {
    expect(formatTypedExpiry(DateTime(2027, 12, 31)), '12/2027');
    expect(formatTypedExpiry(DateTime(2027, 3, 15)), '15/03/2027');
    expect(
      parseTypedExpiry(formatTypedExpiry(DateTime(2027, 3, 15))),
      DateTime(2027, 3, 15),
    );
  });
}
