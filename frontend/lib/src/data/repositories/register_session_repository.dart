import '../../core/result.dart';
import '../models/register_session.dart';
import '../models/register_session_page.dart';
import '../services/pos_api_service.dart';

class RegisterSessionRepository {
  RegisterSessionRepository(this._service);

  final PosApiService _service;

  Future<Result<RegisterSession?>> loadCurrentSession() async {
    try {
      return Ok(await _service.fetchCurrentRegisterSession());
    } on Exception catch (exception) {
      return Error(exception);
    }
  }

  Future<Result<RegisterSessionPage>> loadSessionHistory({int page = 1}) async {
    try {
      return Ok(await _service.fetchRegisterSessionHistory(page: page));
    } on Exception catch (exception) {
      return Error(exception);
    }
  }

  Future<Result<RegisterSession>> startSession({
    required double openingCash,
  }) async {
    try {
      return Ok(await _service.startRegisterSession(openingCash: openingCash));
    } on Exception catch (exception) {
      return Error(exception);
    }
  }

  Future<Result<RegisterSession>> closeSession({
    required int sessionId,
    required RegisterSessionCloseDraft draft,
  }) async {
    try {
      return Ok(
        await _service.closeRegisterSession(sessionId: sessionId, draft: draft),
      );
    } on Exception catch (exception) {
      return Error(exception);
    }
  }
}
