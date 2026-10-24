/// An amount of Libyan dinars, held as whole thousandths (dirhams) so sums
/// never drift: the relay sends amounts as strings with up to three places.
class Money implements Comparable<Money> {
  const Money(this.dirhams);

  static const Money zero = Money(0);

  /// Reads "10", "10.5", "10.000"; anything else is zero.
  factory Money.parse(String? raw) {
    final text = raw?.trim() ?? '';
    final match = RegExp(r'^(-)?(\d+)(?:\.(\d{1,3}))?$').firstMatch(text);
    if (match == null) {
      return zero;
    }
    final whole = int.parse(match.group(2)!);
    final fraction = (match.group(3) ?? '').padRight(3, '0');
    final value = whole * 1000 + int.parse(fraction);
    return Money(match.group(1) == null ? value : -value);
  }

  final int dirhams;

  bool get isZero => dirhams == 0;
  bool get isPositive => dirhams > 0;

  Money operator +(Money other) => Money(dirhams + other.dirhams);
  Money operator -(Money other) => Money(dirhams - other.dirhams);
  Money operator *(int times) => Money(dirhams * times);

  /// The amount as the relay takes it: three places.
  String toWire() {
    final sign = dirhams < 0 ? '-' : '';
    final value = dirhams.abs();
    return '$sign${value ~/ 1000}.${(value % 1000).toString().padLeft(3, '0')}';
  }

  /// Two places, rounded half up: "10.21".
  String toFixed2() {
    final sign = dirhams < 0 ? '-' : '';
    final cents = (dirhams.abs() + 5) ~/ 10;
    return '$sign${cents ~/ 100}.${(cents % 100).toString().padLeft(2, '0')}';
  }

  @override
  int compareTo(Money other) => dirhams.compareTo(other.dirhams);

  @override
  bool operator ==(Object other) => other is Money && other.dirhams == dirhams;

  @override
  int get hashCode => dirhams.hashCode;

  @override
  String toString() => toWire();
}
