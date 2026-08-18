import 'query.dart';
import 'register_cash_movement.dart';

class RegisterCashMovementPage {
  const RegisterCashMovementPage({
    required this.movements,
    required this.hasMore,
    this.nextCursor,
  });

  final List<RegisterCashMovement> movements;
  final bool hasMore;

  /// Opaque keyset cursor for the following page. Null on the last page.
  final String? nextCursor;

  factory RegisterCashMovementPage.fromJson(Map<String, Object?> json) {
    final results = (json['results'] as List<Object?>)
        .cast<Map<String, Object?>>()
        .map(RegisterCashMovement.fromJson)
        .toList(growable: false);

    return RegisterCashMovementPage(
      movements: results,
      hasMore: json['next'] != null,
      nextCursor: nextPageCursor(json['next']),
    );
  }
}
