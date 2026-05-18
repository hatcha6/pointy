import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/print_job.dart';
import '../../../data/models/register_cash_movement.dart';
import '../../../data/models/register_cash_movement_page.dart';
import '../../../data/models/register_session.dart';
import '../../../data/models/register_session_page.dart';
import '../../../data/models/sale_order.dart';
import '../../../data/models/sale_order_page.dart';
import '../../../data/repositories/register_session_repository.dart';
import '../../../data/repositories/sale_repository.dart';

class RegisterSessionHistoryViewModel extends ChangeNotifier {
  RegisterSessionHistoryViewModel(
    this._registerSessionRepository,
    this._saleRepository,
  ) {
    loadSessions();
  }

  final RegisterSessionRepository _registerSessionRepository;
  final SaleRepository _saleRepository;

  List<RegisterSession> _sessions = [];
  List<SaleOrder> _orders = [];
  List<RegisterCashMovement> _cashMovements = [];
  RegisterSession? _selectedSession;
  bool _isLoadingSessions = false;
  bool _isLoadingMoreSessions = false;
  bool _isLoadingOrders = false;
  bool _isLoadingMoreOrders = false;
  bool _isLoadingCashMovements = false;
  bool _isLoadingMoreCashMovements = false;
  bool _hasSessionLoadError = false;
  bool _hasOrderLoadError = false;
  bool _hasCashMovementLoadError = false;
  bool _hasMoreSessions = true;
  bool _hasMoreOrders = false;
  bool _hasMoreCashMovements = false;
  int _nextSessionPage = 1;
  int _nextOrderPage = 1;
  int _nextCashMovementPage = 1;

  List<RegisterSession> get sessions => List.unmodifiable(_sessions);
  List<SaleOrder> get orders => List.unmodifiable(_orders);
  List<RegisterCashMovement> get cashMovements =>
      List.unmodifiable(_cashMovements);
  RegisterSession? get selectedSession => _selectedSession;
  bool get isLoadingSessions => _isLoadingSessions;
  bool get isLoadingMoreSessions => _isLoadingMoreSessions;
  bool get isLoadingOrders => _isLoadingOrders;
  bool get isLoadingMoreOrders => _isLoadingMoreOrders;
  bool get isLoadingCashMovements => _isLoadingCashMovements;
  bool get isLoadingMoreCashMovements => _isLoadingMoreCashMovements;
  bool get hasSessionLoadError => _hasSessionLoadError;
  bool get hasOrderLoadError => _hasOrderLoadError;
  bool get hasCashMovementLoadError => _hasCashMovementLoadError;
  bool get hasMoreSessions => _hasMoreSessions;
  bool get hasMoreOrders => _hasMoreOrders;
  bool get hasMoreCashMovements => _hasMoreCashMovements;

  Future<void> loadSessions() async {
    _isLoadingSessions = true;
    _hasSessionLoadError = false;
    _hasMoreSessions = true;
    _nextSessionPage = 1;
    notifyListeners();

    final result = await _registerSessionRepository.loadSessionHistory(
      page: _nextSessionPage,
    );
    switch (result) {
      case Ok<RegisterSessionPage>():
        _sessions = result.value.sessions;
        _hasMoreSessions = result.value.hasMore;
        _nextSessionPage = 2;
        if (_selectedSession != null &&
            !_sessions.any((session) => session.id == _selectedSession!.id)) {
          _selectedSession = null;
          _orders = [];
          _cashMovements = [];
          _hasMoreOrders = false;
          _hasMoreCashMovements = false;
          _nextOrderPage = 1;
          _nextCashMovementPage = 1;
        }
      case Error<RegisterSessionPage>():
        _sessions = [];
        _selectedSession = null;
        _orders = [];
        _cashMovements = [];
        _hasMoreOrders = false;
        _hasMoreCashMovements = false;
        _nextOrderPage = 1;
        _nextCashMovementPage = 1;
        _hasSessionLoadError = true;
        _hasMoreSessions = false;
    }

    _isLoadingSessions = false;
    notifyListeners();
  }

  Future<void> loadMoreSessions() async {
    if (_isLoadingSessions || _isLoadingMoreSessions || !_hasMoreSessions) {
      return;
    }

    _isLoadingMoreSessions = true;
    notifyListeners();

    final result = await _registerSessionRepository.loadSessionHistory(
      page: _nextSessionPage,
    );
    switch (result) {
      case Ok<RegisterSessionPage>():
        _sessions = [..._sessions, ...result.value.sessions];
        _hasMoreSessions = result.value.hasMore;
        _nextSessionPage += 1;
      case Error<RegisterSessionPage>():
        _hasSessionLoadError = true;
        _hasMoreSessions = false;
    }

    _isLoadingMoreSessions = false;
    notifyListeners();
  }

  Future<void> selectSession(RegisterSession session) async {
    if (_selectedSession?.id == session.id && _orders.isNotEmpty) {
      return;
    }

    _selectedSession = session;
    _orders = [];
    _cashMovements = [];
    _isLoadingOrders = true;
    _isLoadingMoreOrders = false;
    _isLoadingCashMovements = true;
    _isLoadingMoreCashMovements = false;
    _hasOrderLoadError = false;
    _hasCashMovementLoadError = false;
    _hasMoreOrders = true;
    _hasMoreCashMovements = true;
    _nextOrderPage = 1;
    _nextCashMovementPage = 1;
    notifyListeners();

    final result = await _saleRepository.loadOrdersForSession(
      session.id,
      page: _nextOrderPage,
    );
    switch (result) {
      case Ok<SaleOrderPage>():
        _orders = result.value.orders;
        _hasMoreOrders = result.value.hasMore;
        _nextOrderPage = 2;
      case Error<SaleOrderPage>():
        _orders = [];
        _hasOrderLoadError = true;
        _hasMoreOrders = false;
    }

    _isLoadingOrders = false;
    notifyListeners();

    final movementResult = await _registerSessionRepository
        .loadCashMovementsForSession(session.id, page: _nextCashMovementPage);
    switch (movementResult) {
      case Ok<RegisterCashMovementPage>():
        _cashMovements = movementResult.value.movements;
        _hasMoreCashMovements = movementResult.value.hasMore;
        _nextCashMovementPage = 2;
      case Error<RegisterCashMovementPage>():
        _cashMovements = [];
        _hasCashMovementLoadError = true;
        _hasMoreCashMovements = false;
    }

    _isLoadingCashMovements = false;
    notifyListeners();
  }

  Future<void> loadMoreOrders() async {
    final session = _selectedSession;
    if (session == null ||
        _isLoadingOrders ||
        _isLoadingMoreOrders ||
        !_hasMoreOrders) {
      return;
    }

    _isLoadingMoreOrders = true;
    notifyListeners();

    final result = await _saleRepository.loadOrdersForSession(
      session.id,
      page: _nextOrderPage,
    );
    switch (result) {
      case Ok<SaleOrderPage>():
        _orders = [..._orders, ...result.value.orders];
        _hasMoreOrders = result.value.hasMore;
        _nextOrderPage += 1;
      case Error<SaleOrderPage>():
        _hasOrderLoadError = true;
        _hasMoreOrders = false;
    }

    _isLoadingMoreOrders = false;
    notifyListeners();
  }

  Future<void> loadMoreCashMovements() async {
    final session = _selectedSession;
    if (session == null ||
        _isLoadingCashMovements ||
        _isLoadingMoreCashMovements ||
        !_hasMoreCashMovements) {
      return;
    }

    _isLoadingMoreCashMovements = true;
    notifyListeners();

    final result = await _registerSessionRepository.loadCashMovementsForSession(
      session.id,
      page: _nextCashMovementPage,
    );
    switch (result) {
      case Ok<RegisterCashMovementPage>():
        _cashMovements = [..._cashMovements, ...result.value.movements];
        _hasMoreCashMovements = result.value.hasMore;
        _nextCashMovementPage += 1;
      case Error<RegisterCashMovementPage>():
        _hasCashMovementLoadError = true;
        _hasMoreCashMovements = false;
    }

    _isLoadingMoreCashMovements = false;
    notifyListeners();
  }

  Future<bool> requestReprint(SaleOrder order) async {
    final result = await _saleRepository.requestReprint(order.id);
    return switch (result) {
      Ok<PrintJob>() => true,
      Error<PrintJob>() => false,
    };
  }

  Future<bool> voidOrder(SaleOrder order, {String reason = ''}) async {
    final result = await _saleRepository.voidOrder(
      saleOrderId: order.id,
      draft: SaleVoidDraft(reason: reason),
    );
    return _handleOrderAdjustmentResult(result);
  }

  Future<bool> returnItems(
    SaleOrder order, {
    required List<SaleReturnLineDraft> lines,
    String reason = '',
  }) async {
    final result = await _saleRepository.returnItems(
      saleOrderId: order.id,
      draft: SaleReturnDraft(lines: lines, reason: reason),
    );
    return _handleOrderAdjustmentResult(result);
  }

  bool _handleOrderAdjustmentResult(Result<SaleOrder> result) {
    switch (result) {
      case Ok<SaleOrder>():
        _replaceOrder(result.value);
        notifyListeners();
        return true;
      case Error<SaleOrder>():
        return false;
    }
  }

  void _replaceOrder(SaleOrder updatedOrder) {
    _orders = [
      for (final order in _orders)
        if (order.id == updatedOrder.id) updatedOrder else order,
    ];
  }
}
