import 'dart:collection';

/// A tiny LRU cache whose entries are only valid while a version token holds.
///
/// The POS keys its client-side catalog caches (barcode resolutions, search
/// pages) on the backend's catalog version (X-Pointy-Catalog-Version, tracked
/// by PosApiSession). Any product/price/stock/discount change server-side
/// advances the token, so every entry stored under the old one is instantly
/// unreadable — deterministic invalidation, with the TTL as a backstop for
/// backends that don't send the header (or before the first response carries
/// it, when the stored and current tokens are both null and time alone
/// governs).
///
/// Values may be null-like domain "not found" results — wrap them so a miss
/// (null return) stays distinguishable from a cached negative.
class TokenLruCache<T> {
  TokenLruCache({required this.capacity, required this.ttl});

  final int capacity;
  final Duration ttl;
  final LinkedHashMap<String, _TokenCacheEntry<T>> _entries = LinkedHashMap();

  T? read(String key, String? currentToken) {
    final entry = _entries.remove(key);
    if (entry == null) {
      return null;
    }
    final expired = DateTime.now().difference(entry.storedAt) > ttl;
    if (expired || entry.token != currentToken) {
      return null;
    }
    _entries[key] = entry; // Re-insert: most recently used.
    return entry.value;
  }

  void write(String key, T value, String? token) {
    _entries.remove(key);
    _entries[key] = _TokenCacheEntry(
      value: value,
      token: token,
      storedAt: DateTime.now(),
    );
    while (_entries.length > capacity) {
      _entries.remove(_entries.keys.first);
    }
  }

  /// The stored value ignoring both the token and the TTL, or null if nothing
  /// was ever stored.
  ///
  /// For the one case where stale beats empty: a load that *failed*. A scale
  /// rule from ten minutes ago still reads the label correctly; refusing the
  /// scan because the network blinked does not.
  T? readStale(String key) => _entries[key]?.value;

  void clear() {
    _entries.clear();
  }
}

class _TokenCacheEntry<T> {
  const _TokenCacheEntry({
    required this.value,
    required this.token,
    required this.storedAt,
  });

  final T value;
  final String? token;
  final DateTime storedAt;
}
