import 'register_cash_movement.dart';

class RegisterCashMovementPage {
  const RegisterCashMovementPage({
    required this.movements,
    required this.hasMore,
  });

  final List<RegisterCashMovement> movements;
  final bool hasMore;

  factory RegisterCashMovementPage.fromJson(Map<String, Object?> json) {
    final results = (json['results'] as List<Object?>)
        .cast<Map<String, Object?>>()
        .map(RegisterCashMovement.fromJson)
        .toList(growable: false);

    return RegisterCashMovementPage(
      movements: results,
      hasMore: json['next'] != null,
    );
  }
}
