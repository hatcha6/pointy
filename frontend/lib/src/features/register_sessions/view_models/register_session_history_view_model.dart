import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/register_session.dart';
import '../../../data/models/register_session_page.dart';
import '../../../data/models/sale_order.dart';
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
  RegisterSession? _selectedSession;
  bool _isLoadingSessions = false;
  bool _isLoadingMoreSessions = false;
  bool _isLoadingOrders = false;
  bool _hasSessionLoadError = false;
  bool _hasOrderLoadError = false;
  bool _hasMoreSessions = true;
  int _nextSessionPage = 1;

  List<RegisterSession> get sessions => List.unmodifiable(_sessions);
  List<SaleOrder> get orders => List.unmodifiable(_orders);
  RegisterSession? get selectedSession => _selectedSession;
  bool get isLoadingSessions => _isLoadingSessions;
  bool get isLoadingMoreSessions => _isLoadingMoreSessions;
  bool get isLoadingOrders => _isLoadingOrders;
  bool get hasSessionLoadError => _hasSessionLoadError;
  bool get hasOrderLoadError => _hasOrderLoadError;
  bool get hasMoreSessions => _hasMoreSessions;

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
        }
      case Error<RegisterSessionPage>():
        _sessions = [];
        _selectedSession = null;
        _orders = [];
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
    _isLoadingOrders = true;
    _hasOrderLoadError = false;
    notifyListeners();

    final result = await _saleRepository.loadOrdersForSession(session.id);
    switch (result) {
      case Ok<List<SaleOrder>>():
        _orders = result.value;
      case Error<List<SaleOrder>>():
        _orders = [];
        _hasOrderLoadError = true;
    }

    _isLoadingOrders = false;
    notifyListeners();
  }
}
