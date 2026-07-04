import '../../core/result.dart';
import '../models/register_cash_movement.dart';
import '../models/register_cash_movement_page.dart';
import '../models/register_session.dart';
import '../models/register_session_page.dart';
import '../models/register_session_summary.dart';
import '../services/pos_api_service.dart';

class RegisterSessionRepository {
  RegisterSessionRepository(this._service);

  final PosApiService _service;

  Future<Result<RegisterSession?>> loadCurrentSession() async {
    return Result.guard(_service.fetchCurrentRegisterSession);
  }

  Future<Result<RegisterSessionPage>> loadSessionHistory({int page = 1}) async {
    return Result.guard(() => _service.fetchRegisterSessionHistory(page: page));
  }

  Future<Result<RegisterCashMovementPage>> loadCashMovementsForSession(
    int sessionId, {
    int page = 1,
  }) async {
    return Result.guard(
      () => _service.fetchRegisterSessionCashMovements(sessionId, page: page),
    );
  }

  Future<Result<RegisterSessionSummary>> loadSessionSummary(
    int sessionId,
  ) async {
    return Result.guard(() => _service.fetchRegisterSessionSummary(sessionId));
  }

  Future<Result<RegisterSession>> startSession({
    required double openingCash,
  }) async {
    return Result.guard(
      () => _service.startRegisterSession(openingCash: openingCash),
    );
  }

  Future<Result<RegisterSession>> closeSession({
    required int sessionId,
    required RegisterSessionCloseDraft draft,
  }) async {
    return Result.guard(
      () => _service.closeRegisterSession(sessionId: sessionId, draft: draft),
    );
  }

  Future<Result<RegisterCashMovement>> createCashMovement({
    required int sessionId,
    required RegisterCashMovementType movementType,
    required RegisterCashMovementDraft draft,
  }) async {
    return Result.guard(
      () => _service.createRegisterCashMovement(
        sessionId: sessionId,
        movementType: movementType,
        draft: draft,
      ),
    );
  }
}
