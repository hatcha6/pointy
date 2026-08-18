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

  /// First page when [cursor] is null, then the page after [cursor]
  /// (a [RegisterSessionPage.nextCursor] from the previous response).
  Future<Result<RegisterSessionPage>> loadSessionHistory({
    String? cursor,
  }) async {
    return Result.guard(
      () => _service.fetchRegisterSessionHistory(cursor: cursor),
    );
  }

  Future<Result<RegisterCashMovementPage>> loadCashMovementsForSession(
    int sessionId, {
    String? cursor,
  }) async {
    return Result.guard(
      () =>
          _service.fetchRegisterSessionCashMovements(sessionId, cursor: cursor),
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
