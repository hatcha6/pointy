import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/result.dart';
import '../api/relay_api.dart';
import '../models/customer.dart';
import '../session/session_store.dart';

/// Phone sign-in and the device's session.
///
/// [session] is what the app listens to: it turns null when the customer signs
/// out here, deletes the account, or the relay ends the session.
class AuthRepository {
  AuthRepository({
    required this.api,
    required this.sessions,
    this.preferences,
  }) {
    api.onSignedOut = () => session.value = null;
  }

  final RelayApi api;
  final SessionStore sessions;
  final SharedPreferencesAsync? preferences;
  final ValueNotifier<CustomerSession?> session = ValueNotifier(null);

  /// Reads the saved session at launch.
  Future<void> restore() async {
    session.value = await sessions.read();
  }

  bool get isSignedIn => session.value != null;

  Future<Result<CodeChallenge>> requestCode(String phone) =>
      Result.guard(() async {
        final answer = await api.post(
          '/v1/customers/auth/otp',
          body: {'phone': phone},
        );
        return CodeChallenge.fromJson(answer);
      });

  Future<Result<Customer>> verify(String phone, String code) =>
      Result.guard(() async {
        final answer = await api.post(
          '/v1/customers/auth/verify',
          body: {
            'phone': phone,
            'code': code,
            'device': {
              'id': await _deviceId(),
              'name': _deviceName(),
              'platform': kIsWeb ? 'web' : defaultTargetPlatform.name,
            },
          },
        );
        final signedIn = CustomerSession.fromSignIn(answer);
        await sessions.write(signedIn);
        session.value = signedIn;
        return Customer.fromJson(
          answer['customer'] as Map<String, dynamic>? ?? const {},
        );
      });

  Future<Result<Customer>> me() => Result.guard(() async {
    final answer = await api.get('/v1/customers/me', signedIn: true);
    return Customer.fromJson(
      answer['customer'] as Map<String, dynamic>? ?? const {},
    );
  });

  Future<Result<List<DeviceSession>>> devices() => Result.guard(() async {
    final answer = await api.get('/v1/customers/me/sessions', signedIn: true);
    return [
      for (final row in (answer['sessions'] as List? ?? const []))
        if (row is Map<String, dynamic>) DeviceSession.fromJson(row),
    ];
  });

  Future<Result<void>> signOutOtherDevices() => Result.guard(() async {
    await api.delete('/v1/customers/me/sessions');
  });

  /// Signs this device out. Forgotten locally even when the relay cannot be
  /// reached: the customer asked to be signed out.
  Future<void> signOut() async {
    try {
      await api.post('/v1/customers/auth/logout', signedIn: true);
    } on RelayApiException {
      // Already ended, or offline: the local session goes either way.
    }
    await _forget();
  }

  /// Deletes the account (App Store guideline 5.1.1(v)).
  Future<Result<void>> deleteAccount() => Result.guard(() async {
    await api.delete('/v1/customers/me');
    await _forget();
  });

  Future<void> _forget() async {
    await sessions.clear();
    session.value = null;
  }

  /// A random id kept for this install, so the device list can tell two
  /// phones of the same model apart.
  Future<String> _deviceId() async {
    const key = 'cards.device_id';
    final stored = await preferences?.getString(key);
    if (stored != null && stored.isNotEmpty) {
      return stored;
    }
    final random = Random.secure();
    final id = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    await preferences?.setString(key, id);
    return id;
  }

  /// The device as the list names it. A browser sends none: the account
  /// page names it in the customer's language from its platform.
  static String _deviceName() {
    if (kIsWeb) {
      return '';
    }
    return switch (defaultTargetPlatform) {
      TargetPlatform.iOS => 'iPhone',
      TargetPlatform.android => 'Android',
      _ => defaultTargetPlatform.name,
    };
  }
}
