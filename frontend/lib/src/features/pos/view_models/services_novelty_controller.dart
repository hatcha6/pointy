import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../core/storage/app_key_value_store.dart';

/// Which of the services still wear the «جديد» badge.
///
/// A service is new for a month from the day this till first showed it — not
/// for ever: a badge that never goes away stops meaning anything. The day each
/// service was first shown is kept on this machine, so the month is counted
/// across restarts and across cashiers.
///
/// Nothing is new until the stored days have been read, so a returning till
/// never flashes a badge up and takes it down. Storage that fails changes
/// nothing for the cashier: the days are kept for the session instead, and a
/// day that could not be read is never overwritten by a guess.
class ServicesNoveltyController extends ChangeNotifier {
  ServicesNoveltyController({
    this.storageKey = 'pos_services_first_seen',
    this.newFor = const Duration(days: 30),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now {
    loaded = _load();
  }

  final String storageKey;

  /// How long after it is first shown a service is still called new.
  final Duration newFor;
  final DateTime Function() _clock;

  /// Completes when the stored days have been read (or could not be).
  late final Future<void> loaded;

  final Map<String, DateTime> _firstSeen = {};
  bool _isLoaded = false;
  bool _canSave = true;
  bool _disposed = false;

  /// Whether the badge of [key] is still on: it was never shown, or was first
  /// shown less than [newFor] ago.
  bool isNew(String key) {
    if (!_isLoaded) {
      return false;
    }
    final seen = _firstSeen[key];
    return seen == null || _clock().difference(seen) < newFor;
  }

  Future<void> _load() async {
    try {
      final store = await AppKeyValueStore.instance();
      final stored = await store.getString(storageKey);
      if (stored != null && stored.isNotEmpty) {
        _firstSeen.addAll(_decode(stored));
      }
    } on Object {
      // Not read: what is kept now lives for this session only, and is never
      // written over what may be there.
      _canSave = false;
    }
    _isLoaded = true;
    if (!_disposed) {
      notifyListeners();
    }
  }

  static Map<String, DateTime> _decode(String stored) {
    try {
      final decoded = jsonDecode(stored);
      if (decoded is! Map) {
        return const {};
      }
      return {
        for (final entry in decoded.entries)
          if (entry.key is String && entry.value is String)
            entry.key as String: ?DateTime.tryParse(entry.value as String),
      };
    } on Object {
      return const {};
    }
  }

  /// Notes today as the day each of [keys] was first shown, unless it already
  /// has one.
  Future<void> markSeen(Iterable<String> keys) async {
    if (!_isLoaded) {
      await loaded;
    }
    final now = _clock();
    var changed = false;
    for (final key in keys) {
      if (_firstSeen.putIfAbsent(key, () => now) == now) {
        changed = true;
      }
    }
    if (!changed || !_canSave) {
      return;
    }
    try {
      final store = await AppKeyValueStore.instance();
      await store.setString(
        storageKey,
        jsonEncode({
          for (final entry in _firstSeen.entries)
            entry.key: entry.value.toIso8601String(),
        }),
      );
    } on Object {
      // The days hold for this session even if they cannot be saved.
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
