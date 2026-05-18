enum RegisterCashMovementType {
  payIn,
  payOut;

  factory RegisterCashMovementType.fromJson(Object? value) {
    return switch (value?.toString()) {
      'pay_out' => RegisterCashMovementType.payOut,
      _ => RegisterCashMovementType.payIn,
    };
  }

  String toJson() {
    return switch (this) {
      RegisterCashMovementType.payIn => 'pay_in',
      RegisterCashMovementType.payOut => 'pay_out',
    };
  }
}

class RegisterCashMovement {
  const RegisterCashMovement({
    required this.id,
    required this.registerSession,
    required this.movementType,
    required this.amount,
    required this.reason,
    this.sessionNumber,
    this.createdBy,
    this.createdByUsername,
    this.createdAt,
    this.updatedAt,
  });

  final int id;
  final int registerSession;
  final RegisterCashMovementType movementType;
  final double amount;
  final String reason;
  final String? sessionNumber;
  final int? createdBy;
  final String? createdByUsername;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  factory RegisterCashMovement.fromJson(Map<String, Object?> json) {
    return RegisterCashMovement(
      id: json['id'] as int,
      registerSession: _intFromJson(json['register_session']),
      sessionNumber: json['session_number']?.toString(),
      movementType: RegisterCashMovementType.fromJson(json['movement_type']),
      amount: _moneyFromJson(json['amount']),
      reason: json['reason']?.toString() ?? '',
      createdBy: _nullableIntFromJson(json['created_by']),
      createdByUsername: json['created_by_username']?.toString(),
      createdAt: _dateTimeFromJson(json['created_at']),
      updatedAt: _dateTimeFromJson(json['updated_at']),
    );
  }

  static double _moneyFromJson(Object? value) {
    return double.parse((value ?? 0).toString());
  }

  static int _intFromJson(Object? value) {
    if (value is int) {
      return value;
    }
    return int.parse(value.toString());
  }

  static int? _nullableIntFromJson(Object? value) {
    if (value == null) {
      return null;
    }
    return _intFromJson(value);
  }

  static DateTime? _dateTimeFromJson(Object? value) {
    if (value == null) {
      return null;
    }
    return DateTime.tryParse(value.toString());
  }
}

class RegisterCashMovementDraft {
  const RegisterCashMovementDraft({required this.amount, required this.reason});

  final double amount;
  final String reason;

  Map<String, Object?> toJson() {
    return {'amount': amount.toStringAsFixed(2), 'reason': reason.trim()};
  }
}
