import '../models/register_cash_movement.dart';
import '../models/register_cash_movement_page.dart';
import '../models/register_session.dart';
import '../models/register_session_page.dart';
import '../models/sale_order.dart';
import '../models/sale_order_page.dart';
import 'api_session.dart';

class RegisterSessionApiClient {
  const RegisterSessionApiClient(this._session);

  final PosApiSession _session;

  Future<RegisterSession?> fetchCurrentRegisterSession() async {
    final response = await _session.get('register-sessions/current/');
    if (response.statusCode == 204) {
      return null;
    }

    _session.ensureSuccess(
      response,
      'Register session request failed with status',
    );
    return RegisterSession.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<RegisterSessionPage> fetchRegisterSessionHistory({
    int page = 1,
  }) async {
    final response = await _session.get(
      'register-sessions/',
      query: {'page': '$page'},
    );
    _session.ensureSuccess(
      response,
      'Register session history request failed with status',
    );
    return RegisterSessionPage.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<SaleOrderPage> fetchRegisterSessionOrders(
    int sessionId, {
    SaleOrderQuery query = const SaleOrderQuery(),
    int page = 1,
  }) async {
    final response = await _session.get(
      'register-sessions/$sessionId/orders/',
      query: query.toQueryParameters(page: page),
    );
    _session.ensureSuccess(
      response,
      'Register session orders request failed with status',
    );

    final decoded = _session.decodedBody(response);
    if (decoded is Map<String, Object?>) {
      return SaleOrderPage.fromJson(decoded);
    }
    if (decoded is List<Object?>) {
      return SaleOrderPage(
        orders: decoded
            .whereType<Map<String, Object?>>()
            .map(SaleOrder.fromJson)
            .toList(growable: false),
        hasMore: false,
      );
    }
    return const SaleOrderPage(orders: [], hasMore: false);
  }

  Future<RegisterCashMovementPage> fetchRegisterSessionCashMovements(
    int sessionId, {
    int page = 1,
  }) async {
    final response = await _session.get(
      'register-sessions/$sessionId/cash-movements/',
      query: {'page': '$page'},
    );
    _session.ensureSuccess(
      response,
      'Register session cash movements request failed with status',
    );

    final decoded = _session.decodedBody(response);
    if (decoded is Map<String, Object?>) {
      return RegisterCashMovementPage.fromJson(decoded);
    }
    if (decoded is List<Object?>) {
      return RegisterCashMovementPage(
        movements: decoded
            .whereType<Map<String, Object?>>()
            .map(RegisterCashMovement.fromJson)
            .toList(growable: false),
        hasMore: false,
      );
    }
    return const RegisterCashMovementPage(movements: [], hasMore: false);
  }

  Future<RegisterCashMovement> createRegisterCashMovement({
    required int sessionId,
    required RegisterCashMovementType movementType,
    required RegisterCashMovementDraft draft,
  }) async {
    final actionPath = switch (movementType) {
      RegisterCashMovementType.payIn => 'pay-in',
      RegisterCashMovementType.payOut => 'pay-out',
    };
    final response = await _session.post(
      'register-sessions/$sessionId/$actionPath/',
      body: draft.toJson(),
    );
    _session.ensureSuccess(
      response,
      'Register session cash movement create failed with status',
    );
    return RegisterCashMovement.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<RegisterSession> startRegisterSession({
    required double openingCash,
  }) async {
    final response = await _session.post(
      'register-sessions/start/',
      body: {'opening_cash': openingCash.toStringAsFixed(2)},
    );
    _session.ensureSuccess(
      response,
      'Register session start failed with status',
    );
    return RegisterSession.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }

  Future<RegisterSession> closeRegisterSession({
    required int sessionId,
    required RegisterSessionCloseDraft draft,
  }) async {
    final response = await _session.post(
      'register-sessions/$sessionId/close/',
      body: draft.toJson(),
    );
    _session.ensureSuccess(
      response,
      'Register session close failed with status',
    );
    return RegisterSession.fromJson(
      _session.decodedBody(response) as Map<String, Object?>,
    );
  }
}
