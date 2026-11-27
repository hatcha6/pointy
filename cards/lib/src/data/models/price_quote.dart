import '../../core/money.dart';
import 'json.dart';

/// The price an order placed now is charged, held for a while by the relay
/// (`POST /v1/customers/me/quote`). Dollar cards follow a moving exchange
/// rate: the checkout shows this price, not the shelf's, and the order
/// carries [token] back so it is charged what was shown (or less).
class PriceQuote {
  const PriceQuote({
    required this.item,
    required this.unitPrice,
    required this.token,
    required this.expiresAt,
  });

  /// A quote as the relay answers it, or as a `price_changed` refusal
  /// carries a fresh one (with no item: [item] is then the one ordered).
  /// Null when it holds no usable price.
  static PriceQuote? fromJson(
    Map<String, dynamic> json, {
    required String item,
    required DateTime now,
  }) {
    final price = Money.parse(readString(json, 'unit_price'));
    final token = readString(json, 'quote');
    if (!price.isPositive || token.isEmpty) {
      return null;
    }
    // A relay that gives no expiry is taken at the shortest it holds one.
    final expires =
        readTime(json, 'expires_at') ??
        readTime(json, 'quote_expires_at') ??
        now.add(const Duration(minutes: 5));
    return PriceQuote(
      item: readString(json, 'item').isEmpty ? item : readString(json, 'item'),
      unitPrice: price,
      token: token,
      expiresAt: expires,
    );
  }

  final String item;
  final Money unitPrice;
  final String token;
  final DateTime expiresAt;

  /// When the checkout asks for a new one while it stays open: a minute
  /// before this one lapses, so the one sent with the order is alive.
  Duration refreshIn(DateTime now) {
    final left = expiresAt.difference(now) - const Duration(minutes: 1);
    return left < const Duration(seconds: 20)
        ? const Duration(seconds: 20)
        : left;
  }
}
