import 'key_value_store.dart';
import 'sqlite_analytics_queue.dart';

/// What a platform's local persistence provides.
///
/// [analyticsQueue] is null on web, which has no SQLite and keeps its pending
/// telemetry in a key/value entry instead.
class LocalStores {
  const LocalStores({required this.keyValue, required this.analyticsQueue});

  final KeyValueStore keyValue;
  final SqliteAnalyticsQueue? analyticsQueue;
}

/// Where the pending queue lived before it had a table of its own. Read once at
/// startup to migrate it across, then deleted.
const String legacyAnalyticsQueueKey = 'pointy.analytics.queue.v1';
