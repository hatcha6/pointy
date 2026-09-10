import 'dart:convert';

import '../../core/storage/app_key_value_store.dart';
import '../../core/storage/sqlite_analytics_queue.dart';
import '../models/analytics_event.dart';

/// Durable home for events that have not reached the backend yet.
///
/// The shape is a queue, not a document: append what arrived, remove what was
/// delivered, drop the oldest when full. It used to be `saveEvents(wholeList)`,
/// which meant every one of those operations rewrote every pending event —
/// see [SqliteAnalyticsQueue] for what that cost.
abstract class AnalyticsQueueStorage {
  /// Everything still pending, oldest first.
  /// The most recent [limit] queued events, oldest first. A null [limit] reads
  /// the lot, which only a test should want.
  Future<List<AnalyticsEventDraft>> loadEvents({int? limit});

  /// Adds newly recorded events. Idempotent per `clientEventId`, so a retry
  /// after a crash cannot double-queue.
  Future<void> appendEvents(List<AnalyticsEventDraft> events);

  /// Drops the events a flush delivered.
  Future<void> removeEvents(Iterable<String> clientEventIds);

  /// Keeps only the [maxEvents] most recent, dropping the oldest.
  Future<void> trimToMostRecent(int maxEvents);

  /// Drops everything pending.
  Future<void> clearEvents();

  Future<String?> loadInstallationId();
  Future<void> saveInstallationId(String installationId);
}

/// The native queue: a real table, sharing the app's single SQLite connection.
class LocalAnalyticsQueueStorage implements AnalyticsQueueStorage {
  const LocalAnalyticsQueueStorage();

  static const String legacyQueueKey = 'pointy.analytics.queue.v1';
  static const String _installationIdKey =
      'pointy.analytics.installation_id.v1';

  @override
  Future<List<AnalyticsEventDraft>> loadEvents({int? limit}) async {
    final queue = await AppAnalyticsQueue.instance();
    final payloads = await queue.loadPayloads(limit: limit);
    return payloads
        .map(decodeAnalyticsEvent)
        .whereType<AnalyticsEventDraft>()
        .toList(growable: false);
  }

  @override
  Future<void> appendEvents(List<AnalyticsEventDraft> events) async {
    if (events.isEmpty) {
      return;
    }
    final queue = await AppAnalyticsQueue.instance();
    await queue.append([
      for (final event in events)
        QueuedAnalyticsPayload(
          clientEventId: event.clientEventId,
          payload: jsonEncode(event.toJson()),
        ),
    ]);
  }

  @override
  Future<void> removeEvents(Iterable<String> clientEventIds) async {
    final queue = await AppAnalyticsQueue.instance();
    await queue.remove(clientEventIds);
  }

  @override
  Future<void> trimToMostRecent(int maxEvents) async {
    final queue = await AppAnalyticsQueue.instance();
    await queue.trimToMostRecent(maxEvents);
  }

  @override
  Future<void> clearEvents() async {
    final queue = await AppAnalyticsQueue.instance();
    await queue.clear();
  }

  // The installation id is a setting, not a queued event, so it stays in the
  // key/value table.
  @override
  Future<String?> loadInstallationId() async {
    final store = await AppKeyValueStore.instance();
    return store.getString(_installationIdKey);
  }

  @override
  Future<void> saveInstallationId(String installationId) async {
    final store = await AppKeyValueStore.instance();
    await store.setString(_installationIdKey, installationId);
  }
}

/// Queue kept in a single key/value entry.
///
/// This is the old shape, retained for **web**, where storage is the browser's
/// and there is no SQLite to give the queue a table of its own. Web is also the
/// one place the shape is harmless: there is no torn-write problem, no write
/// lock to hold, and no shop till driving it.
class KeyValueAnalyticsQueueStorage implements AnalyticsQueueStorage {
  const KeyValueAnalyticsQueueStorage();

  static const _queueKey = LocalAnalyticsQueueStorage.legacyQueueKey;
  static const _installationIdKey = 'pointy.analytics.installation_id.v1';

  @override
  Future<List<AnalyticsEventDraft>> loadEvents({int? limit}) async {
    final store = await AppKeyValueStore.instance();
    final encoded = await store.getStringList(_queueKey) ?? const <String>[];
    final events = encoded
        .map(decodeAnalyticsEvent)
        .whereType<AnalyticsEventDraft>()
        .toList(growable: false);
    if (limit == null || limit <= 0 || events.length <= limit) {
      return events;
    }
    // The newest, same rule as the SQLite store: a backlog sheds its history.
    return events.sublist(events.length - limit);
  }

  @override
  Future<void> appendEvents(List<AnalyticsEventDraft> events) async {
    if (events.isEmpty) {
      return;
    }
    final current = await loadEvents();
    final known = current.map((e) => e.clientEventId).toSet();
    await _save([
      ...current,
      ...events.where((e) => known.add(e.clientEventId)),
    ]);
  }

  @override
  Future<void> removeEvents(Iterable<String> clientEventIds) async {
    final drop = clientEventIds.toSet();
    if (drop.isEmpty) {
      return;
    }
    final current = await loadEvents();
    await _save(current.where((e) => !drop.contains(e.clientEventId)).toList());
  }

  @override
  Future<void> trimToMostRecent(int maxEvents) async {
    final current = await loadEvents();
    if (current.length <= maxEvents) {
      return;
    }
    await _save(current.sublist(current.length - maxEvents));
  }

  @override
  Future<void> clearEvents() => _save(const []);

  @override
  Future<String?> loadInstallationId() async {
    final store = await AppKeyValueStore.instance();
    return store.getString(_installationIdKey);
  }

  @override
  Future<void> saveInstallationId(String installationId) async {
    final store = await AppKeyValueStore.instance();
    await store.setString(_installationIdKey, installationId);
  }

  Future<void> _save(List<AnalyticsEventDraft> events) async {
    final store = await AppKeyValueStore.instance();
    await store.setStringList(
      _queueKey,
      events.map((event) => jsonEncode(event.toJson())).toList(growable: false),
    );
  }
}

/// Decodes one stored payload, or null if it will not parse. A single bad row
/// costs that row and nothing else.
AnalyticsEventDraft? decodeAnalyticsEvent(String encoded) {
  try {
    final decoded = jsonDecode(encoded);
    if (decoded is Map) {
      return AnalyticsEventDraft.fromJson(decoded.cast<String, Object?>());
    }
  } on FormatException {
    return null;
  }
  return null;
}

class MemoryAnalyticsQueueStorage implements AnalyticsQueueStorage {
  MemoryAnalyticsQueueStorage({
    List<AnalyticsEventDraft> events = const [],
    String? installationId,
  }) : _events = List<AnalyticsEventDraft>.of(events),
       _installationId = installationId;

  final List<AnalyticsEventDraft> _events;
  String? _installationId;

  @override
  Future<List<AnalyticsEventDraft>> loadEvents({int? limit}) async {
    final events = List<AnalyticsEventDraft>.of(_events);
    if (limit == null || limit <= 0 || events.length <= limit) {
      return events;
    }
    return events.sublist(events.length - limit);
  }

  @override
  Future<void> appendEvents(List<AnalyticsEventDraft> events) async {
    final known = _events.map((e) => e.clientEventId).toSet();
    _events.addAll(events.where((e) => known.add(e.clientEventId)));
  }

  @override
  Future<void> removeEvents(Iterable<String> clientEventIds) async {
    final drop = clientEventIds.toSet();
    _events.removeWhere((e) => drop.contains(e.clientEventId));
  }

  @override
  Future<void> trimToMostRecent(int maxEvents) async {
    if (_events.length <= maxEvents) {
      return;
    }
    _events.removeRange(0, _events.length - maxEvents);
  }

  @override
  Future<void> clearEvents() async => _events.clear();

  @override
  Future<String?> loadInstallationId() async => _installationId;

  @override
  Future<void> saveInstallationId(String installationId) async {
    _installationId = installationId;
  }
}

/// Selected at construction by [AnalyticsEngine]; a table on native, the
/// key/value entry on web.
const AnalyticsQueueStorage defaultAnalyticsQueueStorage =
    bool.fromEnvironment('dart.library.io')
    ? LocalAnalyticsQueueStorage()
    : KeyValueAnalyticsQueueStorage();
