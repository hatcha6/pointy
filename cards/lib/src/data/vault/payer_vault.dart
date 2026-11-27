import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// What a mobile wallet was paid from, kept so the customer is not asked it
/// again: the wallet's number (a phone, or a wallet card) and, for Sadad, the
/// payer's birth year. One per way to pay, the last that paid.
@immutable
class SavedPayer {
  const SavedPayer({
    required this.method,
    required this.provider,
    required this.methodName,
    required this.payer,
    this.birthYear = '',
    required this.kind,
  });

  factory SavedPayer.fromJson(Map<String, dynamic> json) => SavedPayer(
    method: '${json['method'] ?? ''}',
    provider: '${json['provider'] ?? ''}',
    methodName: '${json['method_name'] ?? ''}',
    payer: '${json['payer'] ?? ''}',
    birthYear: '${json['birth_year'] ?? ''}',
    kind: '${json['kind'] ?? ''}',
  );

  /// The way to pay it is for (its key, as the relay names it).
  final String method;
  final String provider;
  final String methodName;
  final String payer;
  final String birthYear;

  /// What [payer] is: "phone" or "card" (a wallet card's number).
  final String kind;

  /// The number as it may be shown: its first digits and its last three,
  /// the rest hidden (0912 ••• 567).
  String get masked {
    final digits = payer.replaceAll(' ', '');
    if (digits.length <= 7) {
      return digits;
    }
    return '${digits.substring(0, 4)} ••• ${digits.substring(digits.length - 3)}';
  }

  Map<String, Object> toJson() => {
    'method': method,
    'provider': provider,
    'method_name': methodName,
    'payer': payer,
    if (birthYear.isNotEmpty) 'birth_year': birthYear,
    'kind': kind,
  };
}

/// The wallets' payers kept on this device, beside the bank cards
/// ([CardVault]). Kept only once a payment from them went through.
///
/// A wallet's number pays nothing alone (the wallet sends its own code to
/// the phone for every payment), so unlike a card's number it is readable
/// without Face ID: it sits in the Keychain (iOS) or the encrypted storage
/// (Android) of this device only, never in a backup; on the web, in the
/// browser's storage, encrypted.
abstract class PayerVault {
  Future<List<SavedPayer>> payers();

  /// Keeps [payer] for its way to pay, in place of the one kept before.
  Future<void> keep(SavedPayer payer);

  Future<void> remove(String method);

  /// All of them, on deleting the account.
  Future<void> clear();
}

class SecurePayerVault implements PayerVault {
  SecurePayerVault([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const _key = 'cards.payers.v1';
  static const _iOS = IOSOptions(
    accessibility: KeychainAccessibility.unlocked_this_device,
    synchronizable: false,
  );
  static const _android = AndroidOptions(storageNamespace: 'saved_payers');

  @override
  Future<List<SavedPayer>> payers() async {
    try {
      final raw = await _storage.read(
        key: _key,
        iOptions: _iOS,
        aOptions: _android,
      );
      if (raw == null) {
        return const [];
      }
      return [
        for (final row in jsonDecode(raw) as List)
          if (row is Map<String, dynamic>) SavedPayer.fromJson(row),
      ];
    } on Object {
      return const [];
    }
  }

  @override
  Future<void> keep(SavedPayer payer) async => _write([
    payer,
    ...(await payers()).where((p) => p.method != payer.method),
  ]);

  @override
  Future<void> remove(String method) async =>
      _write((await payers()).where((p) => p.method != method).toList());

  @override
  Future<void> clear() async {
    try {
      await _storage.delete(key: _key, iOptions: _iOS, aOptions: _android);
    } on Object {
      // Nothing kept.
    }
  }

  Future<void> _write(List<SavedPayer> payers) async {
    try {
      await _storage.write(
        key: _key,
        value: jsonEncode([for (final p in payers) p.toJson()]),
        iOptions: _iOS,
        aOptions: _android,
      );
    } on Object {
      // Remembering is a convenience: the payment stands either way.
    }
  }
}

/// Kept in memory: tests and the preview.
class MemoryPayerVault implements PayerVault {
  MemoryPayerVault([List<SavedPayer> payers = const []])
    : _payers = List.of(payers);

  final List<SavedPayer> _payers;

  @override
  Future<List<SavedPayer>> payers() async => List.of(_payers);

  @override
  Future<void> keep(SavedPayer payer) async {
    _payers
      ..removeWhere((p) => p.method == payer.method)
      ..insert(0, payer);
  }

  @override
  Future<void> remove(String method) async =>
      _payers.removeWhere((p) => p.method == method);

  @override
  Future<void> clear() async => _payers.clear();
}
