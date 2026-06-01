import 'package:flutter/foundation.dart';

import '../../../core/result.dart';
import '../../../data/models/business_alert.dart';
import '../../../data/repositories/business_alert_repository.dart';

class NotificationCenterViewModel extends ChangeNotifier {
  NotificationCenterViewModel(this._repository);

  static const int defaultPeriodDays = 30;
  static const Duration defaultSnoozeDuration = Duration(hours: 4);

  final BusinessAlertRepository _repository;

  BusinessAlertDigest? _digest;
  bool _isLoading = false;
  bool _hasError = false;
  bool _hasLoaded = false;

  BusinessAlertDigest? get digest => _digest;
  bool get isLoading => _isLoading;
  bool get hasError => _hasError;
  bool get hasLoaded => _hasLoaded;
  DateTime? get generatedAt => _digest?.generatedAt;

  List<BusinessAlert> get alerts => _digest?.alerts ?? const [];

  List<BusinessAlert> get activeAlerts {
    final visible = alerts
        .where((alert) => !alert.isHidden)
        .toList(growable: false);
    visible.sort(_compareAlerts);
    return visible;
  }

  int get activeCount => activeAlerts.length;

  int get hiddenCount {
    return alerts.where((alert) => alert.isHidden).length;
  }

  int get criticalCount => activeAlerts
      .where((alert) => alert.severity == BusinessAlertSeverity.critical)
      .length;

  int get warningCount => activeAlerts
      .where((alert) => alert.severity == BusinessAlertSeverity.warning)
      .length;

  BusinessAlertSeverity? get highestActiveSeverity {
    final visible = activeAlerts;
    if (visible.isEmpty) {
      return null;
    }
    return visible.first.severity;
  }

  Future<void> loadAlerts({bool force = false}) async {
    if (_isLoading || (_hasLoaded && !force)) {
      return;
    }

    _isLoading = true;
    _hasError = false;
    notifyListeners();

    final result = await _repository.loadAlerts();
    switch (result) {
      case Ok<BusinessAlertLoadResult>(value: final value):
        _digest = value.digest;
        _hasLoaded = true;
      case Error<BusinessAlertLoadResult>(exception: _):
        _hasError = true;
    }

    _isLoading = false;
    notifyListeners();
  }

  Future<void> refresh() => loadAlerts(force: true);

  Future<void> dismissAlert(String id) async {
    await _updateAlert(id, () => _repository.dismissAlert(id));
  }

  Future<void> snoozeAlert(
    String id, {
    Duration duration = defaultSnoozeDuration,
  }) async {
    await _updateAlert(
      id,
      () => _repository.snoozeAlert(id, hours: duration.inHours),
    );
  }

  Future<void> dismissActiveAlerts() async {
    if (activeAlerts.isEmpty) {
      return;
    }

    final result = await _repository.dismissActiveAlerts();
    switch (result) {
      case Ok<void>():
        _digest = BusinessAlertDigest(
          alerts: [
            for (final alert in alerts)
              alert.isHidden
                  ? alert
                  : alert.copyWith(
                      isHidden: true,
                      hiddenReason: 'acknowledged',
                    ),
          ],
          generatedAt: _digest?.generatedAt,
        );
        _hasError = false;
      case Error<void>(exception: _):
        _hasError = true;
    }
    notifyListeners();
  }

  Future<void> restoreHiddenAlerts() async {
    if (hiddenCount == 0) {
      return;
    }

    final result = await _repository.restoreHiddenAlerts();
    switch (result) {
      case Ok<void>():
        _digest = BusinessAlertDigest(
          alerts: [
            for (final alert in alerts)
              alert.isHidden
                  ? alert.copyWith(isHidden: false, hiddenReason: '')
                  : alert,
          ],
          generatedAt: _digest?.generatedAt,
        );
        _hasError = false;
      case Error<void>(exception: _):
        _hasError = true;
    }
    notifyListeners();
  }

  Future<void> _updateAlert(
    String id,
    Future<Result<BusinessAlert>> Function() operation,
  ) async {
    final result = await operation();
    switch (result) {
      case Ok<BusinessAlert>(value: final updated):
        _digest = BusinessAlertDigest(
          alerts: [
            for (final alert in alerts) alert.id == id ? updated : alert,
          ],
          generatedAt: _digest?.generatedAt,
        );
        _hasError = false;
      case Error<BusinessAlert>(exception: _):
        _hasError = true;
    }
    notifyListeners();
  }

  int _compareAlerts(BusinessAlert a, BusinessAlert b) {
    final severity = a.severity.priority.compareTo(b.severity.priority);
    if (severity != 0) {
      return severity;
    }
    final score = a.sortScore.compareTo(b.sortScore);
    if (score != 0) {
      return score;
    }
    final aSeen = a.lastSeenAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    final bSeen = b.lastSeenAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    return bSeen.compareTo(aSeen);
  }
}
