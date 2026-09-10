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
    this.flushInterval = const Duration(seconds: 15),
    this.maxBatchSize = 50,
    this.maxQueueSize = 2000,
    this.maxRequestsPerWindow = 6,
    this.frameTimingWindow = const Duration(seconds: 10),
    this.queuePersistInterval = const Duration(seconds: 2),
    this.errorRepeatWindow = const Duration(minutes: 1),
    this.initialFlushBackoff = const Duration(seconds: 30),
    this.maxFlushBackoff = const Duration(minutes: 30),
    void Function(String deviceId, String platform)? onIdentityResolved,
  }) : _onIdentityResolved = onIdentityResolved,
       _storage = storage ?? defaultAnalyticsQueueStorage,
       _clock = clock ?? (() => DateTime.now().toUtc());

  final AnalyticsEventSink _sink;
  final void Function(String deviceId, String platform)? _onIdentityResolved;
  final AnalyticsQueueStorage _storage;
  final DateTime Function() _clock;
  final Duration flushInterval;
  final int maxBatchSize;
  final int maxQueueSize;

  /// How many ingest requests may be sent per [flushInterval].
  ///
  /// A queue that cannot drain sits above [maxBatchSize], and `track` flushes
  /// on every event once it does — so without a bound the request rate becomes
  /// the event rate. On 2026-08-17 a till flooding the ingest endpoint took the
  /// shop's own traffic to 104-second product-list calls and stopped sales for
  /// four minutes. Sized so only a backlog ever meets it.
  final int maxRequestsPerWindow;

  /// Frame timing is the highest-volume telemetry stream. Instead of one event
  /// per engine callback (which floods ingestion on a busy till), raw frame
  /// counts accumulate and emit as a single sample per window. Aggregating —
  /// not sampling — keeps janky%/slow% ratios exact.
  final Duration frameTimingWindow;

  /// How long an identical error stays suppressed after the first is recorded.
  final Duration errorRepeatWindow;

  /// How long a queued event may sit unwritten. See [_schedulePersist].
  final Duration queuePersistInterval;

  /// How long to wait after a failed flush before trying again, doubling up to
  /// [maxFlushBackoff]. Without this the engine has no failure state at all: a
  /// queue that cannot drain sits above [maxBatchSize], so `track` re-triggers
  /// a flush on every event and the request rate becomes the event rate. In the
  /// field that produced 5.1M rejected uploads, flat around the clock.
  final Duration initialFlushBackoff;
  final Duration maxFlushBackoff;

  final List<AnalyticsEventDraft> _queue = [];
  DateTime? _requestWindowStartedAt;
  int _requestsInWindow = 0;
  int _consecutiveFlushFailures = 0;
  DateTime? _retryFlushAfter;
  bool _isCollecting = true;
  Timer? _flushTimer;
  Future<void>? _startFuture;
  bool _isStarted = false;
  bool _isFlushing = false;
  String? _installationId;
  String? _sessionId;
  String? _currentScreen;
  int? _currentUserId;

  /// One 60fps frame. Both phases of a frame have to fit inside this for the
  /// frame to land on time.
  static const int _frameBudgetMicros = 16667;

  /// Changes the queue has made since the last write, waiting on
  /// [_persistTimer]. See [_schedulePersist].
  /// One error repeating cannot be allowed to bury every other signal.
  ///
  /// A single client loop produced 1,999 identical errors in 118 seconds —
  /// 92% of every platform error in the field — and the interesting ones were
  /// somewhere underneath. The first of a kind is always recorded; identical
  /// repeats inside [errorRepeatWindow] are counted, not sent, and the count
  /// rides along on the next one that is.
  final Map<String, DateTime> _errorFirstSeen = <String, DateTime>{};
  int _repeatedErrorCount = 0;
  int _lastErrorBurst = 0;

  Timer? _persistTimer;
  final List<AnalyticsEventDraft> _pendingAppends = <AnalyticsEventDraft>[];
  final List<String> _pendingRemovals = <String>[];
  bool _needsTrim = false;

  bool get _hasPendingWrites =>
      _pendingAppends.isNotEmpty || _pendingRemovals.isNotEmpty || _needsTrim;

  // Frame timing accumulator, drained once per [frameTimingWindow].
  int _frameBuildMicros = 0;
  int _frameRasterMicros = 0;
  int _frameTotalMicros = 0;
  int _frameMaxTotalMicros = 0;
  int _frameMaxBuildMicros = 0;
  int _frameMaxRasterMicros = 0;
  int _frameSlowCount = 0;
  int _frameJankyCount = 0;
  int _frameDroppedCount = 0;
  int _frameCount = 0;
  DateTime? _frameWindowStartedAt;

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
    // Bounded, and newest-first underneath: a till that has been unable to
    // deliver can hold far more than [maxQueueSize] on disk, and reading the
    // lot meant decoding every one of them at startup only to drop most.
    _queue
      ..clear()
      ..addAll(await _storage.loadEvents(limit: maxQueueSize));
    // Make the table agree now rather than on the next `track`. Until this ran,
    // a device could carry weeks of history it would never deliver and never
    // discard — one till in the field was still shipping a day from three weeks
    // earlier when the export was taken.
    unawaited(_trimStoredEvents());
    _installationId = await _loadOrCreateInstallationId();
    _sessionId = generateAnalyticsEventId();
    _isStarted = true;
    _onIdentityResolved?.call(_installationId ?? '', _platformName());
    _flushTimer = Timer.periodic(flushInterval, (_) {
      unawaited(_flushIfDue());
    });
    await trackUsage(AnalyticsEventName.appStarted, flushImmediately: true);
  }

  /// The stable per-install identifier, once [start] has resolved it.
  String? get installationId => _installationId;

  String get platformName => _platformName();

  /// Turn collection on or off for this device.
  ///
  /// A price-checker kiosk renders instead of the auth gate, so it can never
  /// sign in and can never ship anything it records — every event it collects
  /// is queued forever. A device that structurally cannot deliver telemetry
  /// should not gather it.
  Future<void> setCollectionEnabled(bool enabled) async {
    if (_isCollecting == enabled) {
      return;
    }
    _isCollecting = enabled;
    if (enabled) {
      return;
    }
    _flushTimer?.cancel();
    _flushTimer = null;
    _queue.clear();
    _resetFrameAccumulator();
    try {
      await _storage.clearEvents();
    } on Exception {
      return;
    }
  }

  bool get isCollecting => _isCollecting;

  void setCurrentUser(int? userId) {
    // Also the flush gate: [flush] holds everything until this is non-null, so
    // nothing is POSTed before sign-in. The backlog ships on the first flush
    // after login — see PointyAppDependencies.handleAuthChanged.
    _currentUserId = userId;
    // Credentials just changed, so whatever was rejecting us may no longer be:
    // start the next attempt from a clean slate rather than serving out a
    // backoff earned by the previous identity.
    _recordFlushSuccess();
  }

  void setCurrentScreen(String? screenName) {
    if (_currentScreen == screenName) {
      return;
    }
    // Close the open frame window first, billed to the outgoing screen. A batch
    // carries whichever screen was current when it was *emitted*, so without
    // this a 10-second window that spans a navigation is billed entirely to the
    // screen the user landed on — which quietly charges every destination for
    // the cost of arriving at it.
    _emitFrameTimings(screen: _currentScreen);
    _currentScreen = screenName;
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

  Future<void> trackInteraction({
    required String action,
    String target = 'app',
    AnalyticsEventSeverity severity = AnalyticsEventSeverity.debug,
    Map<String, Object?> attributes = const {},
    Map<String, num> metrics = const {},
    bool flushImmediately = false,
  }) {
    return trackUsage(
      AnalyticsEventName.frontendInteraction,
      severity: severity,
      attributes: {'action': action, 'target': target, ...attributes},
      metrics: metrics,
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

    for (final timing in timings) {
      final total = timing.totalSpan.inMicroseconds;
      _frameBuildMicros += timing.buildDuration.inMicroseconds;
      _frameRasterMicros += timing.rasterDuration.inMicroseconds;
      _frameTotalMicros += total;
      if (total > _frameMaxTotalMicros) {
        _frameMaxTotalMicros = total;
      }
      final build = timing.buildDuration.inMicroseconds;
      final raster = timing.rasterDuration.inMicroseconds;
      if (build > _frameMaxBuildMicros) {
        _frameMaxBuildMicros = build;
      }
      if (raster > _frameMaxRasterMicros) {
        _frameMaxRasterMicros = raster;
      }
      if (total > 16000) {
        _frameSlowCount += 1;
      }
      if (total > 32000) {
        _frameJankyCount += 1;
      }
      // The one that means "the user saw a stutter". slow/janky above are
      // measured on totalSpan, which runs vsync -> raster-finish and so
      // includes queueing: a pipelined 60fps app clears 16ms on totalSpan
      // routinely without dropping anything, and a frame still in flight when
      // the machine sleeps reports the length of the nap. A frame is only
      // genuinely late when the work itself overran the budget, so measure the
      // phases. Kept alongside the old counters rather than replacing them, so
      // history stays comparable.
      if (build > _frameBudgetMicros || raster > _frameBudgetMicros) {
        _frameDroppedCount += 1;
      }
      _frameCount += 1;
    }

    final now = _clock();
    _frameWindowStartedAt ??= now;
    if (now.difference(_frameWindowStartedAt!) >= frameTimingWindow) {
      _emitFrameTimings();
    }
  }

  /// Emit the accumulated frame stats as one sample, then reset the window.
  /// The counts are summed across every callback in the window, so the derived
  /// janky/slow ratios are identical to reporting each callback separately —
  /// only the request count drops.
  void _emitFrameTimings({String? screen}) {
    screen ??= _currentScreen;
    final frameCount = _frameCount;
    if (frameCount == 0) {
      return;
    }
    final buildMicros = _frameBuildMicros;
    final rasterMicros = _frameRasterMicros;
    final totalMicros = _frameTotalMicros;
    final maxTotalMicros = _frameMaxTotalMicros;
    final maxBuildMicros = _frameMaxBuildMicros;
    final maxRasterMicros = _frameMaxRasterMicros;
    final slowFrames = _frameSlowCount;
    final jankyFrames = _frameJankyCount;
    final droppedFrames = _frameDroppedCount;
    _resetFrameAccumulator();

    unawaited(
      trackPerformance(
        name: analyticsEventNameToJson(AnalyticsEventName.frontendFrameTiming),
        duration: Duration(microseconds: maxTotalMicros),
        severity: droppedFrames > 0
            ? AnalyticsEventSeverity.warning
            : AnalyticsEventSeverity.info,
        attributes: {
          'sample': 'frame_timing_batch',
          // Stamped here rather than left to _enrich: emission is async, so by
          // the time the enricher reads _currentScreen the navigation that
          // triggered this flush has already happened, and the batch would be
          // billed to the screen the user just arrived at.
          if (screen != null && screen.isNotEmpty) 'screen': screen,
        },
        metrics: {
          'frame_count': frameCount,
          'average_build_ms': buildMicros / frameCount / 1000,
          'average_raster_ms': rasterMicros / frameCount / 1000,
          'average_total_ms': totalMicros / frameCount / 1000,
          'max_total_ms': maxTotalMicros / 1000,
          // Separating the maxima is what tells a real freeze from a sleeping
          // laptop: a genuine stall shows up in build or raster, while a
          // suspended window shows a huge total against ordinary phases.
          'max_build_ms': maxBuildMicros / 1000,
          'max_raster_ms': maxRasterMicros / 1000,
          'slow_frame_count': slowFrames,
          'janky_frame_count': jankyFrames,
          'dropped_frame_count': droppedFrames,
        },
      ),
    );
  }

  void _resetFrameAccumulator() {
    _frameBuildMicros = 0;
    _frameRasterMicros = 0;
    _frameTotalMicros = 0;
    _frameMaxTotalMicros = 0;
    _frameMaxBuildMicros = 0;
    _frameMaxRasterMicros = 0;
    _frameSlowCount = 0;
    _frameJankyCount = 0;
    _frameDroppedCount = 0;
    _frameCount = 0;
    _frameWindowStartedAt = null;
  }

  Future<void> track(
    AnalyticsEventDraft event, {
    bool flushImmediately = false,
  }) async {
    try {
      if (!_isCollecting) {
        return;
      }
      await _ensureStarted();
      final enrichedEvent = _enrich(event);
      _queue.add(enrichedEvent);
      _pendingAppends.add(enrichedEvent);
      _trimQueue();
      _schedulePersist();
      // Only ship early while shipping is actually working: a queue that cannot
      // drain sits permanently above maxBatchSize, so without this guard every
      // event fires its own doomed request.
      if (_isFlushBackedOff()) {
        return;
      }
      if (flushImmediately || _queue.length >= maxBatchSize) {
        await flush();
      }
    } on Exception {
      return;
    }
  }

  /// The timer's retry, which respects the backoff. [flush] itself does not: an
  /// explicit caller (the post-login backlog, teardown) has new information and
  /// should not wait behind a failure that predates it.
  Future<void> _flushIfDue() async {
    if (_isFlushBackedOff()) {
      return;
    }
    await flush();
  }

  bool _isFlushBackedOff() {
    final retryAfter = _retryFlushAfter;
    return retryAfter != null && _clock().isBefore(retryAfter);
  }

  void _recordFlushFailure() {
    _consecutiveFlushFailures += 1;
    var delay = initialFlushBackoff * (1 << (_consecutiveFlushFailures - 1));
    if (delay > maxFlushBackoff) {
      delay = maxFlushBackoff;
    }
    _retryFlushAfter = _clock().add(delay);
  }

  void _recordFlushSuccess() {
    _consecutiveFlushFailures = 0;
    _retryFlushAfter = null;
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
    final message = _truncate(error.toString(), 1024);
    final suppressed = _countRepeatedError('${name.name}|$message');
    if (suppressed > 0) {
      return Future<void>.value();
    }
    return track(
      AnalyticsEventDraft.error(
        name,
        severity: severity,
        attributes: {
          ...attributes,
          'message': message,
          if (_lastErrorBurst > 0) 'suppressed_since_last': _lastErrorBurst,
          if (stackTrace != null)
            'stack': _truncate(stackTrace.toString(), 4096),
        },
        occurredAt: _clock(),
      ),
      flushImmediately: true,
    );
  }

  /// Takes one of this window's request slots, or reports that none is left.
  bool _claimRequestSlot() {
    if (maxRequestsPerWindow <= 0) {
      return true;
    }
    final now = _clock();
    final startedAt = _requestWindowStartedAt;
    if (startedAt == null || now.difference(startedAt) >= flushInterval) {
      _requestWindowStartedAt = now;
      _requestsInWindow = 0;
    }
    if (_requestsInWindow >= maxRequestsPerWindow) {
      return false;
    }
    _requestsInWindow += 1;
    return true;
  }

  /// Returns how many identical errors have been swallowed, or 0 to record.
  int _countRepeatedError(String signature) {
    final now = _clock();
    final firstSeen = _errorFirstSeen[signature];
    if (firstSeen != null && now.difference(firstSeen) < errorRepeatWindow) {
      _repeatedErrorCount += 1;
      return _repeatedErrorCount;
    }
    // Window opened or expired: this one is recorded, and it carries however
    // many its predecessor swallowed so the volume is never simply lost.
    _errorFirstSeen[signature] = now;
    _lastErrorBurst = _repeatedErrorCount;
    _repeatedErrorCount = 0;
    if (_errorFirstSeen.length > 64) {
      // A client throwing 64 distinct errors has bigger problems than a tidy
      // map; drop the oldest rather than grow without bound.
      final oldest = _errorFirstSeen.entries.reduce(
        (a, b) => a.value.isBefore(b.value) ? a : b,
      );
      _errorFirstSeen.remove(oldest.key);
    }
    return 0;
  }

  Future<void> flush() async {
    try {
      await _ensureStarted();
      // Never POST before sign-in. The ingest endpoint requires an
      // authenticated user, so a pre-auth flush only produces 401s — in the
      // field these were ~4 of every 5 ingest calls. Events stay queued (and
      // persisted across restarts) and ship on the first flush after login.
      if (!_isCollecting || _currentUserId == null) {
        return;
      }
      if (_isFlushing || _queue.isEmpty || !_claimRequestSlot()) {
        return;
      }
      _isFlushing = true;
      // Get anything still only in memory onto disk before trying to send it,
      // so a crash mid-flush replays it rather than losing it. Delivered events
      // are deleted below.
      await flushPendingWrites();
      // The NEWEST first, not the oldest. The queue is chronological, so a
      // backlog's head is its stalest end — and delivering that first is how a
      // device spends its whole send budget on three-week-old telemetry while
      // today's sits behind it, forever. Today's data is the data worth having;
      // history is what the trim is allowed to lose.
      final batch = _queue
          .skip(_queue.length > maxBatchSize ? _queue.length - maxBatchSize : 0)
          .toList(growable: false);
      final result = await _sink.ingestEvents(batch);
      switch (result) {
        case Ok<AnalyticsIngestResult>():
          _recordFlushSuccess();
          final submittedIds = batch
              .map((event) => event.clientEventId)
              .toSet();
          _queue.removeWhere(
            (event) => submittedIds.contains(event.clientEventId),
          );
          // Delete what was delivered rather than rewriting the survivors. (A
          // resend after a crash here is safe — the backend deduplicates on
          // clientEventId — but pointless.)
          _pendingRemovals.addAll(submittedIds);
          await flushPendingWrites();
        case Error<AnalyticsIngestResult>():
          _recordFlushFailure();
          await flushPendingWrites();
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
    _persistTimer?.cancel();
    _persistTimer = null;
    // Fold the open frame-timing window into the queue so its ~last window
    // isn't lost (the queue is persisted, so it survives even if this flush
    // can't finish during teardown).
    _emitFrameTimings();
    if (_isStarted) {
      unawaited(flush());
    } else if (_hasPendingWrites) {
      unawaited(flushPendingWrites());
    }
  }

  Future<void> _ensureStarted() async {
    if (_isStarted) {
      return;
    }
    await start();
  }

  AnalyticsEventDraft _enrich(AnalyticsEventDraft event) {
    final contextAttributes = <String, Object?>{
      if (_currentUserId != null) 'user_id': _currentUserId,
      if (_currentScreen != null && _currentScreen!.isNotEmpty)
        'screen': _currentScreen,
    };
    return event.copyWith(
      sessionId: event.sessionId ?? _sessionId,
      installationId: event.installationId ?? _installationId,
      deviceId: event.deviceId ?? _installationId,
      platform: event.platform ?? _platformName(),
      attributes: {...contextAttributes, ...event.attributes},
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

  /// Arranges for the queue's pending changes to reach disk, soon.
  ///
  /// Persisting inside `track` used to rewrite the *entire* queue — up to
  /// [maxQueueSize] events re-encoded and fsync'd — once per event. Now the
  /// queue is a table, so a write is an insert of what actually arrived and a
  /// delete of what actually left; coalescing them on a short timer means a
  /// burst still costs one commit rather than one each.
  ///
  /// The queue is telemetry, so trading up to [queuePersistInterval] of it
  /// against a power cut is a good deal — and every point where losing it would
  /// matter (a flush, teardown, going to the background) writes synchronously.
  void _schedulePersist() {
    if (_persistTimer != null) {
      return;
    }
    _persistTimer = Timer(queuePersistInterval, () {
      _persistTimer = null;
      unawaited(flushPendingWrites());
    });
  }

  /// Writes everything the queue has accumulated since the last write.
  ///
  /// Order matters: append before trimming, so a burst that overflowed the cap
  /// is trimmed by the same rule on disk as in memory rather than leaving the
  /// table holding events the queue has already dropped.
  Future<void> flushPendingWrites() async {
    _persistTimer?.cancel();
    _persistTimer = null;

    final appends = _pendingAppends.toList(growable: false);
    _pendingAppends.clear();
    final removals = _pendingRemovals.toList(growable: false);
    _pendingRemovals.clear();
    final trim = _needsTrim;
    _needsTrim = false;

    try {
      if (appends.isNotEmpty) {
        await _storage.appendEvents(appends);
      }
      if (removals.isNotEmpty) {
        await _storage.removeEvents(removals);
      }
      if (trim) {
        await _storage.trimToMostRecent(maxQueueSize);
      }
    } catch (error, stackTrace) {
      // Local storage is best-effort: telemetry that cannot be written is
      // dropped rather than retried forever or allowed to fail the caller.
      // Losing it costs a report; blocking on it costs the shop.
      debugPrint('Analytics queue write failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  /// Applies [maxQueueSize] to the table itself, independently of what is in
  /// memory. Best-effort: a queue that cannot be trimmed is not a reason to
  /// fail startup.
  Future<void> _trimStoredEvents() async {
    try {
      await _storage.trimToMostRecent(maxQueueSize);
    } catch (error) {
      debugPrint('Analytics queue trim failed: $error');
    }
  }

  void _trimQueue() {
    if (_queue.length <= maxQueueSize) {
      return;
    }
    _queue.removeRange(0, _queue.length - maxQueueSize);
    // The table has to shed the same events; without this it keeps growing
    // past the cap the in-memory queue enforces.
    _needsTrim = true;
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
