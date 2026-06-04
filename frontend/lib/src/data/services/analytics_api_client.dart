import '../models/analytics_event.dart';
import 'api_session.dart';

class AnalyticsApiClient {
  const AnalyticsApiClient(this._session);

  final PosApiSession _session;

  Future<AnalyticsEventPage> fetchEvents({
    required AnalyticsEventQuery query,
    int page = 1,
  }) async {
    final response = await _session.get(
      'analytics-events/',
      query: query.toQueryParameters(page: page),
    );
    _session.throwApiException(
      response,
      'Analytics event list failed with status',
    );
    return AnalyticsEventPage.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<AnalyticsIngestResult> ingestEvents(
    List<AnalyticsEventDraft> events,
  ) async {
    final response = await _session.post(
      'analytics-events/ingest/',
      body: {
        'events': events.map((event) => event.toJson()).toList(growable: false),
      },
    );
    _session.throwApiException(response, 'Analytics ingest failed with status');
    return AnalyticsIngestResult.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }
}
