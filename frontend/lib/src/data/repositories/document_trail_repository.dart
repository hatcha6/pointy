import '../../core/result.dart';
import '../models/document_trail_event.dart';
import '../services/pos_api_service.dart';

/// A document's own history.
///
/// Deliberately its own repository rather than a method on each domain's:
/// every kind of document answers the same question the same way, and a
/// screen that wants to show a trail should not have to know which domain
/// owns the document to ask for it.
class DocumentTrailRepository {
  const DocumentTrailRepository(this._service);

  final PosApiService _service;

  Future<Result<List<DocumentTrailEvent>>> loadTrail({
    required String documentType,
    required int documentId,
  }) {
    return Result.guard(
      () => _service.fetchDocumentTrail(
        documentType: documentType,
        documentId: documentId,
      ),
    );
  }
}
