import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/analytics_event.dart';
import '../../../data/models/pos_user.dart';
import '../../../data/repositories/analytics_repository.dart';
import '../../../data/repositories/user_repository.dart';

class ActivityLogViewModel extends ChangeNotifier {
  ActivityLogViewModel(
    this._analyticsRepository,
    this._userRepository, {
    DateTime Function()? clock,
  }) : _clock = clock ?? (() => DateTime.now()) {
    _query = _queryForDateRange(
      const AnalyticsEventQuery(),
      AnalyticsEventDateRange.last7Days,
    );
    loadEvents();
    loadUsers();
  }

  final AnalyticsRepository _analyticsRepository;
  final UserRepository _userRepository;
  final DateTime Function() _clock;

  List<AnalyticsEventRecord> _events = [];
  List<PosUser> _users = [];
  late AnalyticsEventQuery _query;
  AnalyticsEventRecord? _selectedEvent;
  bool _isLoading = false;
  bool _isLoadingMore = false;
  bool _isLoadingUsers = false;
  bool _hasLoadError = false;
  bool _hasUserLoadError = false;
  bool _hasMoreEvents = true;
  int _nextPage = 1;
  int _totalCount = 0;
  int _loadSerial = 0;
  String _investigationReason = '';

  List<AnalyticsEventRecord> get events => List.unmodifiable(_events);
  List<PosUser> get users => List.unmodifiable(_users);
  AnalyticsEventQuery get query => _query;
  AnalyticsEventRecord? get selectedEvent => _selectedEvent;
  bool get isLoading => _isLoading;
  bool get isLoadingMore => _isLoadingMore;
  bool get isLoadingUsers => _isLoadingUsers;
  bool get hasLoadError => _hasLoadError;
  bool get hasUserLoadError => _hasUserLoadError;
  bool get hasMoreEvents => _hasMoreEvents;
  int get totalCount => _totalCount;
  int get loadedCount => _events.length;
  String get investigationReason => _investigationReason;
  int get loadedFraudSignalCount =>
      _events.where((event) => event.isFraudSignal).length;
  int get loadedHighRiskCount =>
      _events.where((event) => (event.riskScore ?? 0) >= 70).length;

  Future<void> loadEvents() async {
    final loadSerial = ++_loadSerial;
    final query = _query;
    _isLoading = true;
    _hasLoadError = false;
    _hasMoreEvents = true;
    _nextPage = 1;
    notifyListeners();

    final result = await _analyticsRepository.loadEvents(
      query: query,
      page: _nextPage,
    );
    if (loadSerial != _loadSerial) {
      return;
    }
    switch (result) {
      case Ok<AnalyticsEventPage>():
        _events = result.value.events;
        _totalCount = result.value.totalCount;
        _hasMoreEvents = result.value.hasMore;
        _nextPage = 2;
        _syncSelectedEvent();
      case Error<AnalyticsEventPage>():
        _events = [];
        _selectedEvent = null;
        _totalCount = 0;
        _hasLoadError = true;
        _hasMoreEvents = false;
    }

    _isLoading = false;
    notifyListeners();
  }

  Future<void> loadMoreEvents() async {
    if (_isLoading || _isLoadingMore || !_hasMoreEvents) {
      return;
    }

    final loadSerial = _loadSerial;
    final query = _query;
    _isLoadingMore = true;
    notifyListeners();

    final result = await _analyticsRepository.loadEvents(
      query: query,
      page: _nextPage,
    );
    if (loadSerial != _loadSerial) {
      _isLoadingMore = false;
      notifyListeners();
      return;
    }
    switch (result) {
      case Ok<AnalyticsEventPage>():
        _events = [..._events, ...result.value.events];
        _totalCount = result.value.totalCount;
        _hasMoreEvents = result.value.hasMore;
        _nextPage += 1;
        _syncSelectedEvent();
      case Error<AnalyticsEventPage>():
        _hasLoadError = true;
        _hasMoreEvents = false;
    }

    _isLoadingMore = false;
    notifyListeners();
  }

  Future<void> loadUsers() async {
    _isLoadingUsers = true;
    _hasUserLoadError = false;
    notifyListeners();

    final users = <PosUser>[];
    var page = 1;
    var hasMore = true;
    while (hasMore) {
      final result = await _userRepository.loadUsers(page: page);
      switch (result) {
        case Ok<PosUserPage>():
          users.addAll(result.value.users);
          hasMore = result.value.hasMore;
          page += 1;
        case Error<PosUserPage>():
          _hasUserLoadError = true;
          hasMore = false;
      }
    }

    _users = users;
    _isLoadingUsers = false;
    notifyListeners();
  }

  Future<void> updateSearch(String search) async {
    if (search == _query.search) {
      return;
    }
    _investigationReason = '';
    _query = _query.copyWith(search: search);
    await loadEvents();
  }

  Future<void> applyQuery(AnalyticsEventQuery query) async {
    _investigationReason = '';
    if (query == _query) {
      notifyListeners();
      return;
    }
    _query = _normalizedQuery(query);
    await loadEvents();
  }

  Future<void> applyInvestigationQuery(
    AnalyticsEventQuery query, {
    required String reason,
  }) async {
    _investigationReason = reason.trim();
    _query = _normalizedQuery(query);
    await loadEvents();
  }

  Future<void> resetQuery() async {
    _investigationReason = '';
    await applyQuery(
      _queryForDateRange(
        const AnalyticsEventQuery(),
        AnalyticsEventDateRange.last7Days,
      ),
    );
  }

  void selectEvent(AnalyticsEventRecord event) {
    if (_selectedEvent?.id == event.id) {
      return;
    }
    _selectedEvent = event;
    notifyListeners();
  }

  AnalyticsEventQuery _normalizedQuery(AnalyticsEventQuery query) {
    if (query.dateRange == AnalyticsEventDateRange.custom) {
      return query;
    }
    return _queryForDateRange(query, query.dateRange);
  }

  AnalyticsEventQuery _queryForDateRange(
    AnalyticsEventQuery query,
    AnalyticsEventDateRange range,
  ) {
    final now = _clock();
    final today = DateTime(now.year, now.month, now.day);
    return switch (range) {
      AnalyticsEventDateRange.all => query.copyWith(
        dateRange: range,
        clearOccurredAfter: true,
        clearOccurredBefore: true,
      ),
      AnalyticsEventDateRange.today => query.copyWith(
        dateRange: range,
        occurredAfter: today,
        occurredBefore: today.add(const Duration(days: 1)),
      ),
      AnalyticsEventDateRange.last7Days => query.copyWith(
        dateRange: range,
        occurredAfter: today.subtract(const Duration(days: 6)),
        occurredBefore: today.add(const Duration(days: 1)),
      ),
      AnalyticsEventDateRange.last30Days => query.copyWith(
        dateRange: range,
        occurredAfter: today.subtract(const Duration(days: 29)),
        occurredBefore: today.add(const Duration(days: 1)),
      ),
      AnalyticsEventDateRange.custom => query,
    };
  }

  void _syncSelectedEvent() {
    final selected = _selectedEvent;
    if (selected != null) {
      final refreshed = _events
          .where((event) => event.id == selected.id)
          .firstOrNull;
      if (refreshed != null) {
        _selectedEvent = refreshed;
        return;
      }
    }
    _selectedEvent = _events.firstOrNull;
  }
}
