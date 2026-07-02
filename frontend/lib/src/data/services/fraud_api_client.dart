import '../models/fraud_finding.dart';
import 'api_session.dart';

class FraudApiClient {
  const FraudApiClient(this._session);

  final PosApiSession _session;

  Future<FraudFindingPage> fetchFindings({
    int page = 1,
    String status = '',
  }) async {
    final response = await _session.get(
      'fraud-findings/',
      query: {
        'page': '$page',
        if (status.trim().isNotEmpty) 'status': status.trim(),
      },
    );
    _session.ensureSuccess(
      response,
      'Fraud findings request failed with status',
    );
    return FraudFindingPage.fromAny(_session.decodedBody(response));
  }

  Future<FraudFinding> reviewFinding(int id, {String note = ''}) {
    return _triage(id, 'review', note: note);
  }

  Future<FraudFinding> dismissFinding(int id, {String note = ''}) {
    return _triage(id, 'dismiss', note: note);
  }

  Future<FraudFinding> reopenFinding(int id) {
    return _triage(id, 'reopen');
  }

  Future<FraudFinding> _triage(
    int id,
    String action, {
    String note = '',
  }) async {
    final response = await _session.post(
      'fraud-findings/$id/$action/',
      body: {if (note.trim().isNotEmpty) 'note': note.trim()},
    );
    _session.ensureSuccess(
      response,
      'Fraud finding $action failed with status',
    );
    return FraudFinding.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }
}
