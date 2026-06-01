import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/business_alert.dart';
import 'package:pointy_frontend/src/data/repositories/business_alert_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/notifications/view_models/notification_center_view_model.dart';

void main() {
  test(
    'hides dismissed and snoozed alerts without deleting alert facts',
    () async {
      final repository = _FakeBusinessAlertRepository(
        const BusinessAlertLoadResult(
          digest: BusinessAlertDigest(
            alerts: [
              BusinessAlert(
                id: '1',
                code: 'inventory.out_of_stock',
                type: BusinessAlertType.outOfStock,
                category: BusinessAlertCategory.inventory,
                severity: BusinessAlertSeverity.critical,
                sortScore: 10,
                isHidden: false,
                count: 1,
              ),
              BusinessAlert(
                id: '2',
                code: 'inventory.low_stock',
                type: BusinessAlertType.lowStock,
                category: BusinessAlertCategory.inventory,
                severity: BusinessAlertSeverity.warning,
                sortScore: 30,
                isHidden: false,
                count: 1,
              ),
            ],
          ),
        ),
      );
      final viewModel = NotificationCenterViewModel(repository);
      addTearDown(viewModel.dispose);

      await viewModel.loadAlerts();

      expect(viewModel.activeCount, 2);
      expect(viewModel.criticalCount, 1);

      await viewModel.dismissAlert('1');

      expect(viewModel.activeCount, 1);
      expect(viewModel.hiddenCount, 1);
      expect(repository.dismissedIds, contains('1'));

      await viewModel.snoozeAlert('2', duration: const Duration(hours: 1));

      expect(viewModel.activeCount, 0);
      expect(viewModel.hiddenCount, 2);
      expect(repository.snoozedIds, contains('2'));

      await viewModel.restoreHiddenAlerts();

      expect(viewModel.activeCount, 2);
      expect(repository.restoreCount, 1);
    },
  );
}

class _FakeBusinessAlertRepository extends BusinessAlertRepository {
  _FakeBusinessAlertRepository(this.result) : super(PosApiService());

  final BusinessAlertLoadResult result;
  final dismissedIds = <String>[];
  final snoozedIds = <String>[];
  int restoreCount = 0;

  @override
  Future<Result<BusinessAlertLoadResult>> loadAlerts() async {
    return Ok(result);
  }

  @override
  Future<Result<BusinessAlert>> dismissAlert(String id) async {
    dismissedIds.add(id);
    return Ok(
      result.digest.alerts
          .firstWhere((alert) => alert.id == id)
          .copyWith(isHidden: true, hiddenReason: 'acknowledged'),
    );
  }

  @override
  Future<Result<BusinessAlert>> snoozeAlert(
    String id, {
    required int hours,
  }) async {
    snoozedIds.add(id);
    return Ok(
      result.digest.alerts
          .firstWhere((alert) => alert.id == id)
          .copyWith(isHidden: true, hiddenReason: 'snoozed'),
    );
  }

  @override
  Future<Result<void>> restoreHiddenAlerts() async {
    restoreCount += 1;
    return const Ok(null);
  }
}
