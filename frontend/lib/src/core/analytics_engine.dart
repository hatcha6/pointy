import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';

import '../data/models/analytics_event.dart';
import '../data/repositories/analytics_repository.dart';
import '../data/services/api_session.dart';
import '../data/services/analytics_queue_storage.dart';
import 'result.dart';

class AnalyticsEngine {
  AnalyticsEngine(
    this._sink, {
    AnalyticsQueueStorage? storage,
    DateTime Function()? clock,
    this.flushInterval = const Duration(seconds: 30),
    this.maxBatchSize = 25,
    this.maxQueueSize = 500,
  }) : _storage = storage ?? const SharedPreferencesAnalyticsQueueStorage(),
       _clock = clock ?? (() => DateTime.now().toUtc());

  final AnalyticsEventSink _sink;
  final AnalyticsQueueStorage _storage;
  final DateTime Function() _clock;
  final Duration flushInterval;
  final int maxBatchSize;
  final int maxQueueSize;

  final List<AnalyticsEventDraft> _queue = [];
  Timer? _flushTimer;
  Future<void>? _startFuture;
  bool _isStarted = false;
  bool _isFlushing = false;
  String? _installationId;
  int? _currentUserId;

  int get pendingEventCount => _queue.length;

  Future<void> start() {
    if (_isStarted) {
      return Future<void>.value();
    }
    final inFlight = _startFuture;
    if (inFlight != null) {
      return inFlight;
    }
    final future = _start().catchError((Object _) {}).whenComplete(() {
      _startFuture = null;
    });
    _startFuture = future;
    return future;
  }

  Future<void> _start() async {
    _queue
      ..clear()
      ..addAll(await _storage.loadEvents());
    _installationId = await _loadOrCreateInstallationId();
    _isStarted = true;
    _flushTimer = Timer.periodic(flushInterval, (_) {
      unawaited(flush());
    });
    await trackUsage(AnalyticsEventName.appStarted, flushImmediately: true);
  }

  void setCurrentUser(int? userId) {
    _currentUserId = userId;
  }

  Future<void> trackUsage(
    AnalyticsEventName name, {
    AnalyticsEventSeverity severity = AnalyticsEventSeverity.info,
    Map<String, Object?> attributes = const {},
    Map<String, num> metrics = const {},
    String? entityType,
    String? entityId,
    bool flushImmediately = false,
  }) {
    return track(
      AnalyticsEventDraft.usage(
        name,
        severity: severity,
        attributes: attributes,
        metrics: metrics,
        entityType: entityType,
        entityId: entityId,
        occurredAt: _clock(),
      ),
      flushImmediately: flushImmediately,
    );
  }

  Future<void> trackPerformance({
    required String name,
    required Duration duration,
    AnalyticsEventSeverity severity = AnalyticsEventSeverity.info,
    Map<String, Object?> attributes = const {},
    Map<String, num> metrics = const {},
    String? entityType,
    String? entityId,
    bool flushImmediately = false,
  }) {
    return track(
      AnalyticsEventDraft.performance(
        name: name,
        duration: duration,
        severity: severity,
        attributes: attributes,
        metrics: metrics,
        entityType: entityType,
        entityId: entityId,
        occurredAt: _clock(),
      ),
      flushImmediately: flushImmediately,
    );
  }

  Future<T> measure<T>(
    String operationName,
    Future<T> Function() operation, {
    Map<String, Object?> attributes = const {},
    Map<String, num> metrics = const {},
  }) async {
    final stopwatch = Stopwatch()..start();
    try {
      final result = await operation();
      stopwatch.stop();
      unawaited(
        trackPerformance(
          name: analyticsEventNameToJson(AnalyticsEventName.frontendOperation),
          duration: stopwatch.elapsed,
          attributes: {'operation': operationName, ...attributes},
          metrics: metrics,
        ),
      );
      return result;
    } on Exception catch (exception) {
      stopwatch.stop();
      unawaited(
        trackPerformance(
          name: analyticsEventNameToJson(AnalyticsEventName.frontendOperation),
          duration: stopwatch.elapsed,
          severity: AnalyticsEventSeverity.error,
          attributes: {
            'operation': operationName,
            'error_message': _truncate(exception.toString(), 512),
            ...attributes,
          },
          metrics: metrics,
          flushImmediately: true,
        ),
      );
      rethrow;
    }
  }

  T measureSync<T>(
    String operationName,
    T Function() operation, {
    Map<String, Object?> attributes = const {},
    Map<String, num> metrics = const {},
  }) {
    final stopwatch = Stopwatch()..start();
    try {
      final result = operation();
      stopwatch.stop();
      unawaited(
        trackPerformance(
          name: analyticsEventNameToJson(AnalyticsEventName.frontendOperation),
          duration: stopwatch.elapsed,
          attributes: {'operation': operationName, ...attributes},
          metrics: metrics,
        ),
      );
      return result;
    } on Exception catch (exception) {
      stopwatch.stop();
      unawaited(
        trackPerformance(
          name: analyticsEventNameToJson(AnalyticsEventName.frontendOperation),
          duration: stopwatch.elapsed,
          severity: AnalyticsEventSeverity.error,
          attributes: {
            'operation': operationName,
            'error_message': _truncate(exception.toString(), 512),
            ...attributes,
          },
          metrics: metrics,
          flushImmediately: true,
        ),
      );
      rethrow;
    }
  }

  void recordApiRequest(ApiRequestPerformance performance) {
    final statusCode = performance.statusCode;
    final metrics = <String, num>{
      'request_size_bytes': performance.requestSizeBytes,
      'response_size_bytes': performance.responseSizeBytes,
    };
    if (statusCode != null) {
      metrics['status_code'] = statusCode;
    }
    final severity = _performanceSeverity(
      duration: performance.duration,
      statusCode: statusCode,
      failed: performance.failed,
    );
    unawaited(
      trackPerformance(
        name: analyticsEventNameToJson(AnalyticsEventName.frontendHttpRequest),
        duration: performance.duration,
        severity: severity,
        attributes: {
          'method': performance.method,
          'path': performance.path,
          'status_family': statusCode == null
              ? 'network_error'
              : '${statusCode ~/ 100}xx',
          if (performance.errorMessage.isNotEmpty)
            'error_message': _truncate(performance.errorMessage, 512),
        },
        metrics: metrics,
        flushImmediately: severity == AnalyticsEventSeverity.error,
      ),
    );
  }

  void recordFrameTimings(List<FrameTiming> timings) {
    if (timings.isEmpty) {
      return;
    }

    var buildMicros = 0;
    var rasterMicros = 0;
    var totalMicros = 0;
    var maxTotalMicros = 0;
    var slowFrames = 0;
    var jankyFrames = 0;
    for (final timing in timings) {
      final total = timing.totalSpan.inMicroseconds;
      buildMicros += timing.buildDuration.inMicroseconds;
      rasterMicros += timing.rasterDuration.inMicroseconds;
      totalMicros += total;
      if (total > maxTotalMicros) {
        maxTotalMicros = total;
      }
      if (total > 16000) {
        slowFrames += 1;
      }
      if (total > 32000) {
        jankyFrames += 1;
      }
    }

    final frameCount = timings.length;
    unawaited(
      trackPerformance(
        name: analyticsEventNameToJson(AnalyticsEventName.frontendFrameTiming),
        duration: Duration(microseconds: maxTotalMicros),
        severity: jankyFrames > 0
            ? AnalyticsEventSeverity.warning
            : AnalyticsEventSeverity.info,
        attributes: {'sample': 'frame_timing_batch'},
        metrics: {
          'frame_count': frameCount,
          'average_build_ms': buildMicros / frameCount / 1000,
          'average_raster_ms': rasterMicros / frameCount / 1000,
          'average_total_ms': totalMicros / frameCount / 1000,
          'max_total_ms': maxTotalMicros / 1000,
          'slow_frame_count': slowFrames,
          'janky_frame_count': jankyFrames,
        },
      ),
    );
  }

  Future<void> track(
    AnalyticsEventDraft event, {
    bool flushImmediately = false,
  }) async {
    try {
      await _ensureStarted();
      final enrichedEvent = _enrich(event);
      _queue.add(enrichedEvent);
      _trimQueue();
      await _persistQueue();
      if (flushImmediately || _queue.length >= maxBatchSize) {
        await flush();
      }
    } on Exception {
      return;
    }
  }

  Future<void> captureFlutterError(FlutterErrorDetails details) {
    return captureError(
      details.exception,
      details.stack,
      name: AnalyticsEventName.appFlutterError,
      severity: AnalyticsEventSeverity.error,
      attributes: {
        'library': details.library,
        'context': details.context?.toDescription(),
      },
    );
  }

  Future<void> captureError(
    Object error,
    StackTrace? stackTrace, {
    AnalyticsEventName name = AnalyticsEventName.appPlatformError,
    AnalyticsEventSeverity severity = AnalyticsEventSeverity.error,
    Map<String, Object?> attributes = const {},
  }) {
    return track(
      AnalyticsEventDraft.error(
        name,
        severity: severity,
        attributes: {
          ...attributes,
          'message': _truncate(error.toString(), 1024),
          if (stackTrace != null)
            'stack': _truncate(stackTrace.toString(), 4096),
        },
        occurredAt: _clock(),
      ),
      flushImmediately: true,
    );
  }

  Future<void> flush() async {
    try {
      await _ensureStarted();
      if (_isFlushing || _queue.isEmpty) {
        return;
      }
      _isFlushing = true;
      final batch = _queue.take(maxBatchSize).toList(growable: false);
      final result = await _sink.ingestEvents(batch);
      switch (result) {
        case Ok<AnalyticsIngestResult>():
          final submittedIds = batch
              .map((event) => event.clientEventId)
              .toSet();
          _queue.removeWhere(
            (event) => submittedIds.contains(event.clientEventId),
          );
          await _persistQueue();
        case Error<AnalyticsIngestResult>():
          await _persistQueue();
      }
    } on Exception {
      return;
    } finally {
      _isFlushing = false;
    }
  }

  void dispose() {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (_isStarted) {
      unawaited(flush());
    }
  }

  Future<void> _ensureStarted() async {
    if (_isStarted) {
      return;
    }
    await start();
  }

  AnalyticsEventDraft _enrich(AnalyticsEventDraft event) {
    final userAttributes = _currentUserId == null
        ? const <String, Object?>{}
        : <String, Object?>{'user_id': _currentUserId};
    return event.copyWith(
      installationId: event.installationId ?? _installationId,
      deviceId: event.deviceId ?? _installationId,
      platform: event.platform ?? _platformName(),
      attributes: {...userAttributes, ...event.attributes},
    );
  }

  Future<String> _loadOrCreateInstallationId() async {
    final existingInstallationId = await _storage.loadInstallationId();
    if (existingInstallationId != null && existingInstallationId.isNotEmpty) {
      return existingInstallationId;
    }
    final installationId = generateAnalyticsEventId();
    await _storage.saveInstallationId(installationId);
    return installationId;
  }

  Future<void> _persistQueue() async {
    await _storage.saveEvents(_queue);
  }

  void _trimQueue() {
    if (_queue.length <= maxQueueSize) {
      return;
    }
    _queue.removeRange(0, _queue.length - maxQueueSize);
  }

  String _platformName() {
    if (kIsWeb) {
      return 'flutter-web';
    }
    return 'flutter-${defaultTargetPlatform.name}';
  }

  String _truncate(String value, int maxLength) {
    if (value.length <= maxLength) {
      return value;
    }
    return value.substring(0, maxLength);
  }

  AnalyticsEventSeverity _performanceSeverity({
    required Duration duration,
    required int? statusCode,
    required bool failed,
  }) {
    if (statusCode != null && statusCode >= 500) {
      return AnalyticsEventSeverity.error;
    }
    if (failed || duration.inMilliseconds >= 750) {
      return AnalyticsEventSeverity.warning;
    }
    return AnalyticsEventSeverity.info;
  }
}
