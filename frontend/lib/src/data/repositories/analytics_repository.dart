import '../../core/result.dart';
import '../models/analytics_event.dart';
import '../services/pos_api_service.dart';

abstract class AnalyticsEventSink {
  Future<Result<AnalyticsIngestResult>> ingestEvents(
    List<AnalyticsEventDraft> events,
  );
}

class AnalyticsRepository implements AnalyticsEventSink {
  AnalyticsRepository(this._service);

  final PosApiService _service;

  Future<Result<AnalyticsEventPage>> loadEvents({
    required AnalyticsEventQuery query,
    String? cursor,
  }) {
    return Result.guard(
      () => _service.fetchAnalyticsEvents(query: query, cursor: cursor),
    );
  }

  @override
  Future<Result<AnalyticsIngestResult>> ingestEvents(
    List<AnalyticsEventDraft> events,
  ) {
    return Result.guard(() => _service.ingestAnalyticsEvents(events));
  }
}
