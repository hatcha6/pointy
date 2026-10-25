import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// A bank card the customer chose to keep on this phone, as the app may show
/// it without asking: the last four digits, the holder's name and the expiry.
/// The full number is kept apart, behind the phone's own lock.
@immutable
class SavedCard {
  const SavedCard({
    required this.id,
    required this.last4,
    required this.name,
    required this.expiryMonth,
    required this.expiryYear,
  });

  factory SavedCard.fromJson(Map<String, dynamic> json) => SavedCard(
    id: '${json['id'] ?? ''}',
    last4: '${json['last4'] ?? ''}',
    name: '${json['name'] ?? ''}',
    expiryMonth: (json['expiry_month'] as num?)?.toInt() ?? 0,
    expiryYear: (json['expiry_year'] as num?)?.toInt() ?? 0,
  );

  final String id;
  final String last4;
  final String name;
  final int expiryMonth;

  /// Two digits (27 for 2027).
  final int expiryYear;

  String get expiry =>
      '${expiryMonth.toString().padLeft(2, '0')}/'
      '${expiryYear.toString().padLeft(2, '0')}';

  bool expiredAt(DateTime now) =>
      !DateTime(2000 + expiryYear, expiryMonth + 1).isAfter(now);

  Map<String, Object> toJson() => {
    'id': id,
    'last4': last4,
    'name': name,
    'expiry_month': expiryMonth,
    'expiry_year': expiryYear,
  };
}

/// Cards kept on this phone for faster payment, only when the customer asks.
///
/// The full number never leaves the phone and is never readable by the app
/// alone: it sits in the Keychain (iOS) or Keystore (Android) under an
/// access control that needs Face ID, a fingerprint or the passcode for
/// every read, on this device only (no iCloud, no backup). Local cards have
/// no CVV, so a number, name and expiry are enough to charge one: that is
/// why the phone itself guards the read, not just the app.
abstract class CardVault {
  /// Whether this platform can keep cards at all (not the web).
  bool get available;

  Future<List<SavedCard>> cards();

  /// Keeps a card that has just paid. A number already kept replaces its
  /// old entry (a renewed expiry, a corrected name).
  Future<SavedCard?> keep({
    required String number,
    required String name,
    required int expiryMonth,
    required int expiryYear,
  });

  /// The card's full number, after the phone asks its owner. Null when they
  /// cancel or the card is gone.
  Future<String?> number(SavedCard card, {required String reason});

  Future<void> remove(SavedCard card);

  /// Every card, on signing out or deleting the account.
  Future<void> clear();
}

class SecureCardVault implements CardVault {
  SecureCardVault([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const _indexKey = 'cards.saved.v1';
  String _numberKey(String id) => 'cards.saved.number.v1.$id';

  /// The list: no full numbers, readable while the phone is unlocked.
  static const _indexIOS = IOSOptions(
    accessibility: KeychainAccessibility.unlocked_this_device,
    synchronizable: false,
  );

  /// The numbers: this device only, and only after Face ID or the passcode.
  static const _numberIOS = IOSOptions(
    accessibility: KeychainAccessibility.passcode,
    synchronizable: false,
    accessControlFlags: [AccessControlFlag.userPresence],
  );

  static const _indexAndroid = AndroidOptions(storageNamespace: 'saved_cards');

  static AndroidOptions _numberAndroid(String reason) =>
      AndroidOptions.biometric(
        storageNamespace: 'saved_card_numbers',
        enforceBiometrics: true,
        requireBiometricsPerOperation: true,
        biometricPromptTitle: reason,
      );

  @override
  bool get available => !kIsWeb;

  @override
  Future<List<SavedCard>> cards() async {
    if (!available) {
      return const [];
    }
    try {
      final raw = await _storage.read(
        key: _indexKey,
        iOptions: _indexIOS,
        aOptions: _indexAndroid,
      );
      if (raw == null) {
        return const [];
      }
      return [
        for (final row in jsonDecode(raw) as List)
          if (row is Map<String, dynamic>) SavedCard.fromJson(row),
      ];
    } on Object {
      return const [];
    }
  }

  @override
  Future<SavedCard?> keep({
    required String number,
    required String name,
    required int expiryMonth,
    required int expiryYear,
  }) async {
    if (!available || number.length < 4) {
      return null;
    }
    try {
      final existing = await cards();
      final id = _idOf(number);
      final card = SavedCard(
        id: id,
        last4: number.substring(number.length - 4),
        name: name,
        expiryMonth: expiryMonth,
        expiryYear: expiryYear,
      );
      await _storage.write(
        key: _numberKey(id),
        value: number,
        iOptions: _numberIOS,
        aOptions: _numberAndroid(''),
      );
      await _writeIndex([card, ...existing.where((c) => c.id != id)]);
      return card;
    } on Object {
      // A phone without a passcode cannot hold one: it is simply not saved.
      return null;
    }
  }

  @override
  Future<String?> number(SavedCard card, {required String reason}) async {
    try {
      return await _storage.read(
        key: _numberKey(card.id),
        iOptions: _numberIOS,
        aOptions: _numberAndroid(reason),
      );
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<void> remove(SavedCard card) async {
    try {
      await _storage.delete(
        key: _numberKey(card.id),
        iOptions: _numberIOS,
        aOptions: _numberAndroid(''),
      );
    } on Object {
      // Its index entry still goes: the card is not offered again.
    }
    final left = (await cards()).where((c) => c.id != card.id).toList();
    await _writeIndex(left);
  }

  @override
  Future<void> clear() async {
    for (final card in await cards()) {
      await remove(card);
    }
    try {
      await _storage.delete(
        key: _indexKey,
        iOptions: _indexIOS,
        aOptions: _indexAndroid,
      );
    } on Object {
      // Nothing kept.
    }
  }

  Future<void> _writeIndex(List<SavedCard> cards) => _storage.write(
    key: _indexKey,
    value: jsonEncode([for (final card in cards) card.toJson()]),
    iOptions: _indexIOS,
    aOptions: _indexAndroid,
  );

  /// The same number always lands on the same entry, so saving a card again
  /// replaces it. The id is a short checksum, not the number: it is only a
  /// key on this phone.
  static String _idOf(String number) {
    var hash = 0x811C9DC5;
    for (final unit in number.codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0xFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }
}

/// Kept in memory: tests and the preview.
class MemoryCardVault implements CardVault {
  MemoryCardVault({this.allowRead = true});

  /// What the phone's lock answers.
  bool allowRead;
  final Map<String, String> _numbers = {};
  final List<SavedCard> _cards = [];
  int reads = 0;

  @override
  bool get available => true;

  @override
  Future<List<SavedCard>> cards() async => List.of(_cards);

  @override
  Future<SavedCard?> keep({
    required String number,
    required String name,
    required int expiryMonth,
    required int expiryYear,
  }) async {
    final id = Random(number.hashCode).nextInt(1 << 30).toRadixString(16);
    final card = SavedCard(
      id: id,
      last4: number.substring(number.length - 4),
      name: name,
      expiryMonth: expiryMonth,
      expiryYear: expiryYear,
    );
    _numbers[id] = number;
    _cards
      ..removeWhere((c) => c.id == id)
      ..insert(0, card);
    return card;
  }

  @override
  Future<String?> number(SavedCard card, {required String reason}) async {
    reads++;
    return allowRead ? _numbers[card.id] : null;
  }

  @override
  Future<void> remove(SavedCard card) async {
    _numbers.remove(card.id);
    _cards.removeWhere((c) => c.id == card.id);
  }

  @override
  Future<void> clear() async {
    _numbers.clear();
    _cards.clear();
  }
}
