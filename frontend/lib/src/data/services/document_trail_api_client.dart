import '../models/document_trail_event.dart';
import 'api_session.dart';

/// Reads a single document's history.
///
/// One endpoint for every kind of document: the trail has the same shape
/// whichever one it belongs to, and it is always asked about exactly one.
class DocumentTrailApiClient {
  const DocumentTrailApiClient(this._session);

  final PosApiSession _session;

  Future<List<DocumentTrailEvent>> fetchTrail({
    required String documentType,
    required int documentId,
  }) async {
    final response = await _session.get(
      'document-events/',
      query: {'document_type': documentType, 'object_id': '$documentId'},
    );
    _session.ensureSuccess(response, 'Document trail request failed with status');
    return documentTrailEventsFromResponse(_session.decodedBody(response));
  }
}
