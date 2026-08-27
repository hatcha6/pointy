import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/ai_chat.dart';
import 'package:pointy_frontend/src/data/models/relay_installation_status.dart';
import 'package:pointy_frontend/src/data/repositories/subscription_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/settings/view_models/subscription_status_view_model.dart';

void main() {
  RelayInstallationStatus status({
    bool aiEnabled = true,
    bool subscriptionActive = true,
  }) {
    return RelayInstallationStatus(
      configured: true,
      remoteAccessSupported: subscriptionActive,
      installationId: 'POS-1',
      shopName: 'shop',
      relayPublicApiUrl: '',
      relayConnectorAddress: '',
      relayEnabled: true,
      subscriptionActive: subscriptionActive,
      aiEnabled: aiEnabled,
      subscriptionEndsAt: DateTime.now().add(const Duration(days: 30)),
    );
  }

  AiUsage usage() => const AiUsage(
    fiveHour: AiUsageWindow(used: 1, limit: 40),
    weekly: AiUsageWindow(used: 5, limit: 200),
  );

  group('SubscriptionStatusViewModel.load', () {
    test('loads the status and AI usage when AI is entitled', () async {
      final vm = SubscriptionStatusViewModel(
        _FakeRepo(statusResult: Ok(status()), usageResult: Ok(usage())),
      );

      await vm.load();

      expect(vm.status, isNotNull);
      expect(vm.hasLoadError, isFalse);
      expect(vm.usage, isNotNull);
    });

    test('skips the usage call when AI is not entitled', () async {
      final repo = _FakeRepo(
        statusResult: Ok(status(aiEnabled: false)),
        usageResult: Ok(usage()),
      );
      final vm = SubscriptionStatusViewModel(repo);

      await vm.load();

      expect(vm.usage, isNull);
      expect(repo.usageCalls, 0);
    });

    test('a usage failure is non-fatal — status still shows', () async {
      final vm = SubscriptionStatusViewModel(
        _FakeRepo(
          statusResult: Ok(status()),
          usageResult: Error(Exception('boom')),
        ),
      );

      await vm.load();

      expect(vm.status, isNotNull);
      expect(vm.usage, isNull);
    });

    test('a status failure sets the load error', () async {
      final vm = SubscriptionStatusViewModel(
        _FakeRepo(
          statusResult: Error(Exception('down')),
          usageResult: Ok(usage()),
        ),
      );

      await vm.load();

      expect(vm.status, isNull);
      expect(vm.hasLoadError, isTrue);
    });
  });

  group('SubscriptionStatusViewModel.sync', () {
    test('returns true and refreshes the snapshot on success', () async {
      final vm = SubscriptionStatusViewModel(
        _FakeRepo(statusResult: Ok(status()), usageResult: Ok(usage())),
      );

      final ok = await vm.sync();

      expect(ok, isTrue);
      expect(vm.lastSyncFailed, isFalse);
      expect(vm.status, isNotNull);
    });

    test(
      'keeps the cached snapshot and flags failure when sync fails',
      () async {
        final repo = _FakeRepo(
          statusResult: Ok(status()),
          usageResult: Ok(usage()),
        );
        final vm = SubscriptionStatusViewModel(repo);
        await vm.load();

        repo.statusResult = Error(Exception('relay unreachable'));
        final ok = await vm.sync();

        expect(ok, isFalse);
        expect(vm.lastSyncFailed, isTrue);
        expect(vm.status, isNotNull, reason: 'cached snapshot is kept');
      },
    );
  });
}

class _FakeRepo extends SubscriptionRepository {
  _FakeRepo({required this.statusResult, required this.usageResult})
    : super(PosApiService());

  Result<RelayInstallationStatus> statusResult;
  Result<AiUsage> usageResult;
  int usageCalls = 0;

  @override
  Future<Result<RelayInstallationStatus>> loadStatus({
    bool sync = false,
  }) async {
    return statusResult;
  }

  @override
  Future<Result<AiUsage>> loadAiUsage() async {
    usageCalls++;
    return usageResult;
  }
}
