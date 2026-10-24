import 'json.dart';

class Customer {
  const Customer({
    required this.id,
    required this.phone,
    required this.phoneMasked,
  });

  factory Customer.fromJson(Map<String, dynamic> json) => Customer(
    id: readString(json, 'id'),
    phone: readString(json, 'phone'),
    phoneMasked: readString(json, 'phone_masked'),
  );

  final String id;

  /// "218" + the national number.
  final String phone;

  /// "091•••678".
  final String phoneMasked;
}

/// A sign-in code on its way (`POST /v1/customers/auth/otp`).
class CodeChallenge {
  const CodeChallenge({
    required this.phone,
    required this.phoneMasked,
    required this.codeLength,
    required this.expiresAt,
    required this.resendAt,
    this.testCode = '',
  });

  factory CodeChallenge.fromJson(Map<String, dynamic> json) => CodeChallenge(
    phone: readString(json, 'phone'),
    phoneMasked: readString(json, 'phone_masked'),
    codeLength: readInt(json, 'code_length'),
    expiresAt: readTime(json, 'expires_at'),
    resendAt: readTime(json, 'resend_at'),
    testCode: readString(json, 'test_code'),
  );

  final String phone;
  final String phoneMasked;
  final int codeLength;
  final DateTime? expiresAt;
  final DateTime? resendAt;

  /// Only from a relay in OTP test mode: development builds fill it in.
  final String testCode;
}

class DeviceSession {
  const DeviceSession({
    required this.id,
    required this.deviceName,
    required this.platform,
    required this.lastSeenAt,
    required this.current,
  });

  factory DeviceSession.fromJson(Map<String, dynamic> json) => DeviceSession(
    id: readString(json, 'id'),
    deviceName: readString(json, 'device_name'),
    platform: readString(json, 'platform'),
    lastSeenAt: readTime(json, 'last_seen_at'),
    current: readBool(json, 'current'),
  );

  final String id;
  final String deviceName;
  final String platform;
  final DateTime? lastSeenAt;
  final bool current;
}
