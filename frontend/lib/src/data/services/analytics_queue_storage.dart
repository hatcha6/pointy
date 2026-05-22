import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/analytics_event.dart';

abstract class AnalyticsQueueStorage {
  Future<List<AnalyticsEventDraft>> loadEvents();
  Future<void> saveEvents(List<AnalyticsEventDraft> events);
  Future<String?> loadInstallationId();
  Future<void> saveInstallationId(String installationId);
}

class SharedPreferencesAnalyticsQueueStorage implements AnalyticsQueueStorage {
  const SharedPreferencesAnalyticsQueueStorage();

  static const _queueKey = 'pointy.analytics.queue.v1';
  static const _installationIdKey = 'pointy.analytics.installation_id.v1';

  @override
  Future<List<AnalyticsEventDraft>> loadEvents() async {
    final preferences = await SharedPreferences.getInstance();
    final encodedEvents = preferences.getStringList(_queueKey) ?? const [];
    return encodedEvents
        .map(_decodeEvent)
        .whereType<AnalyticsEventDraft>()
        .toList(growable: false);
  }

  @override
  Future<void> saveEvents(List<AnalyticsEventDraft> events) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setStringList(
      _queueKey,
      events.map((event) => jsonEncode(event.toJson())).toList(growable: false),
    );
  }

  @override
  Future<String?> loadInstallationId() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getString(_installationIdKey);
  }

  @override
  Future<void> saveInstallationId(String installationId) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_installationIdKey, installationId);
  }

  AnalyticsEventDraft? _decodeEvent(String encoded) {
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
}

class MemoryAnalyticsQueueStorage implements AnalyticsQueueStorage {
  MemoryAnalyticsQueueStorage({
    List<AnalyticsEventDraft> events = const [],
    String? installationId,
  }) : _events = List<AnalyticsEventDraft>.of(events),
       _installationId = installationId;

  List<AnalyticsEventDraft> _events;
  String? _installationId;

  @override
  Future<List<AnalyticsEventDraft>> loadEvents() async {
    return List<AnalyticsEventDraft>.of(_events);
  }

  @override
  Future<void> saveEvents(List<AnalyticsEventDraft> events) async {
    _events = List<AnalyticsEventDraft>.of(events);
  }

  @override
  Future<String?> loadInstallationId() async {
    return _installationId;
  }

  @override
  Future<void> saveInstallationId(String installationId) async {
    _installationId = installationId;
  }
}
