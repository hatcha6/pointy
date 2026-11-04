import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// An account a top-up went to before, kept on this phone so the next one
/// is a tap: a player's ID (and server), a Telegram username.
class SavedAccount {
  const SavedAccount({required this.values, this.name = ''});

  factory SavedAccount.fromJson(Map<String, dynamic> json) => SavedAccount(
    values: {
      for (final MapEntry(:key, :value)
          in ((json['values'] as Map?) ?? const {}).entries)
        if (key is String && value is String) key: value,
    },
    name: json['name'] is String ? json['name'] as String : '',
  );

  /// By the brand's target fields, as the relay took them.
  final Map<String, String> values;

  /// The player's nickname, when the game gave it.
  final String name;

  bool same(Map<String, String> other) =>
      values.length == other.length &&
      values.entries.every((e) => other[e.key] == e.value);

  Map<String, Object> toJson() => {'values': values, 'name': name};
}

/// The accounts each brand was topped up to on this phone, the latest
/// first. They are the customer's own typing, kept beside their codes and
/// forgotten with them on signing out.
class SavedAccounts {
  SavedAccounts({this.preferences});

  /// Null in tests and the preview: the accounts are then kept in memory.
  final SharedPreferencesAsync? preferences;

  Map<String, List<SavedAccount>>? _memory;

  static const _key = 'cards.saved_accounts';

  /// Each brand keeps its last few.
  static const perBrand = 4;

  Future<List<SavedAccount>> of(String brand) async =>
      (await _all())[brand] ?? const [];

  /// [values] became [brand]'s latest; a name the check gave is kept, and an
  /// earlier one survives a check that gave none.
  Future<void> remember(
    String brand,
    Map<String, String> values, {
    String name = '',
  }) async {
    final all = await _all();
    final list = List.of(all[brand] ?? const <SavedAccount>[]);
    final before = list.where((a) => a.same(values)).firstOrNull;
    list.removeWhere((a) => a.same(values));
    list.insert(
      0,
      SavedAccount(
        values: Map.of(values),
        name: name.isNotEmpty ? name : before?.name ?? '',
      ),
    );
    all[brand] = list.take(perBrand).toList();
    await _save(all);
  }

  Future<void> forget(String brand, Map<String, String> values) async {
    final all = await _all();
    final list = List.of(all[brand] ?? const <SavedAccount>[])
      ..removeWhere((a) => a.same(values));
    if (list.isEmpty) {
      all.remove(brand);
    } else {
      all[brand] = list;
    }
    await _save(all);
  }

  /// Puts a forgotten account back at [at] in its brand's list.
  Future<void> restore(String brand, SavedAccount account, {int at = 0}) async {
    final all = await _all();
    final list = List.of(all[brand] ?? const <SavedAccount>[])
      ..removeWhere((a) => a.same(account.values));
    list.insert(at.clamp(0, list.length), account);
    all[brand] = list.take(perBrand).toList();
    await _save(all);
  }

  Future<void> clear() async {
    _memory = {};
    await preferences?.remove(_key);
  }

  Future<Map<String, List<SavedAccount>>> _all() async {
    if (_memory case final memory?) {
      return memory;
    }
    final raw = await preferences?.getString(_key);
    final all = <String, List<SavedAccount>>{};
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          for (final MapEntry(:key, :value) in decoded.entries) {
            if (value is List) {
              all[key] = [
                for (final row in value)
                  if (row is Map<String, dynamic>) SavedAccount.fromJson(row),
              ];
            }
          }
        }
      } on FormatException {
        // A damaged list is simply forgotten.
      }
    }
    return _memory = all;
  }

  Future<void> _save(Map<String, List<SavedAccount>> all) async {
    _memory = all;
    await preferences?.setString(
      _key,
      jsonEncode({
        for (final MapEntry(:key, :value) in all.entries)
          key: [for (final account in value) account.toJson()],
      }),
    );
  }
}
