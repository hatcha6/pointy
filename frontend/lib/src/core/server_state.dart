import 'package:flutter/foundation.dart';

/// The names the backend publishes in `X-Pointy-State` and `GET state/`.
///
/// Mirrors `apps/core/state_version.py`. A name the client does not know is
/// carried through untouched — an older client on a newer backend simply
/// ignores domains it has no watcher for, and a newer client on an older
/// backend sees them absent and falls back to its TTLs. Neither direction
/// needs a coordinated release.
abstract final class ServerStateDomain {
  /// Composite catalog stamp (definitions *and* stock). Keys the client's
  /// scan/search caches. Moves on every checkout in the shop, so it must never
  /// drive a visible refresh — [catalogDefs] is the one for that.
  static const String catalog = 'catalog';

  /// Catalog *definitions*: names, prices, barcodes, images, categories,
  /// units, modifiers. Rare, and wrong-on-screen is customer-visible, so this
  /// is the domain that earns an immediate refresh.
  static const String catalogDefs = 'catalog_defs';

  /// Stock quantities only. Moves constantly; treated as lazy.
  static const String stock = 'stock';

  static const String settings = 'settings';
  static const String discounts = 'discounts';
  static const String notifications = 'notifications';
  static const String notificationsUser = 'notifications_user';

  /// Any permission-affecting change. Treated as "drop every cached body and
  /// re-resolve who I am": a permission that was just revoked must not leave
  /// readable data sitting in a cache. See [ServerStateNotifier].
  static const String permissions = 'permissions';

  static const String channels = 'channels';
  static const String contacts = 'contacts';
  static const String employees = 'employees';
  static const String expenseCategories = 'expense_categories';
  static const String fx = 'fx';
  static const String operationsSetup = 'operations_setup';
  static const String printing = 'printing';
  static const String scales = 'scales';
  static const String users = 'users';
  static const String warehouses = 'warehouses';
}

/// Parses `catalog=812,settings=37` into a map. Tolerant by design: a
/// malformed pair is skipped rather than throwing, because a header the client
/// cannot read must cost freshness, never the response it rode in on.
Map<String, String> parseServerStateHeader(String? raw) {
  if (raw == null || raw.isEmpty) {
    return const {};
  }
  final parsed = <String, String>{};
  for (final pair in raw.split(',')) {
    final separator = pair.indexOf('=');
    if (separator <= 0) {
      continue;
    }
    final name = pair.substring(0, separator).trim();
    final value = pair.substring(separator + 1).trim();
    if (name.isNotEmpty && value.isNotEmpty) {
      parsed[name] = value;
    }
  }
  return parsed;
}

/// The client's view of the server's "what changed" counters.
///
/// Fed from two places, which is the whole point: every API response carries
/// the vector (so a till that is being used learns from what it was already
/// doing), and [ServerStateWatcher] polls a tiny endpoint (so a till that is
/// *not* being used still learns). Listeners are notified with the set of
/// domains whose number actually moved — never on a re-read of the same value,
/// or the POS would refresh in a loop.
class ServerStateNotifier extends ChangeNotifier {
  final Map<String, String> _versions = {};
  Set<String> _lastChanged = const {};

  /// Domains that moved in the most recent [apply] that changed anything.
  Set<String> get lastChanged => _lastChanged;

  Map<String, String> get versions => Map.unmodifiable(_versions);

  String? versionOf(String domain) => _versions[domain];

  /// Merge a vector (from a header or the poll). Returns the domains that moved.
  ///
  /// A domain seen for the *first* time is not a change: the client had no
  /// cached data keyed to an older value, so treating it as one would make
  /// every device re-fetch everything on its first response after a restart.
  Set<String> apply(Map<String, String> incoming) {
    if (incoming.isEmpty) {
      return const {};
    }
    final changed = <String>{};
    for (final entry in incoming.entries) {
      final previous = _versions[entry.key];
      _versions[entry.key] = entry.value;
      if (previous != null && previous != entry.value) {
        changed.add(entry.key);
      }
    }
    if (changed.isEmpty) {
      return const {};
    }
    _lastChanged = changed;
    notifyListeners();
    return changed;
  }

  /// Forget everything. Called on sign-out and when the connection target
  /// changes: the counters belong to one backend and one session, and carrying
  /// them across either would make the next vector look unchanged when in
  /// truth the client knows nothing.
  void reset() {
    _versions.clear();
    _lastChanged = const {};
  }
}
