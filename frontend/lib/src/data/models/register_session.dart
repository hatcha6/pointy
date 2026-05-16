class RegisterSession {
  const RegisterSession({
    required this.id,
    required this.sessionNumber,
    required this.status,
    required this.openingCash,
    this.closingCash,
    this.count025 = 0,
    this.count050 = 0,
    this.count075 = 0,
    this.count100 = 0,
    this.openedAt,
    this.closedAt,
    this.createdAt,
    this.updatedAt,
  });

  final int id;
  final String sessionNumber;
  final String status;
  final double openingCash;
  final double? closingCash;
  final int count025;
  final int count050;
  final int count075;
  final int count100;
  final DateTime? openedAt;
  final DateTime? closedAt;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  factory RegisterSession.fromJson(Map<String, Object?> json) {
    return RegisterSession(
      id: json['id'] as int,
      sessionNumber: json['session_number'].toString(),
      status: json['status'] as String,
      openingCash: _moneyFromJson(json['opening_cash']),
      closingCash: _nullableMoneyFromJson(json['closing_cash']),
      count025: _intFromJson(json['count_025']),
      count050: _intFromJson(json['count_050']),
      count075: _intFromJson(json['count_075']),
      count100: _intFromJson(json['count_100']),
      openedAt: _dateTimeFromJson(json['opened_at']),
      closedAt: _dateTimeFromJson(json['closed_at']),
      createdAt: _dateTimeFromJson(json['created_at']),
      updatedAt: _dateTimeFromJson(json['updated_at']),
    );
  }

  static double _moneyFromJson(Object? value) {
    return double.parse((value ?? 0).toString());
  }

  static double? _nullableMoneyFromJson(Object? value) {
    if (value == null) {
      return null;
    }
    return double.parse(value.toString());
  }

  static int _intFromJson(Object? value) {
    if (value == null) {
      return 0;
    }
    if (value is int) {
      return value;
    }
    return int.parse(value.toString());
  }

  static DateTime? _dateTimeFromJson(Object? value) {
    if (value == null) {
      return null;
    }
    return DateTime.tryParse(value.toString());
  }
}

class RegisterSessionCloseDraft {
  const RegisterSessionCloseDraft({
    required this.closingCash,
    required this.count025,
    required this.count050,
    required this.count075,
    required this.count100,
  });

  final double closingCash;
  final int count025;
  final int count050;
  final int count075;
  final int count100;

  Map<String, Object?> toJson() {
    return {
      'closing_cash': closingCash.toStringAsFixed(2),
      'count_025': count025,
      'count_050': count050,
      'count_075': count075,
      'count_100': count100,
    };
  }
}
