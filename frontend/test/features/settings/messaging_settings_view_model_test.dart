import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/messaging_gateway.dart';
import 'package:pointy_frontend/src/data/repositories/messaging_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/settings/view_models/messaging_settings_view_model.dart';

void main() {
  MessagingGateway gateway({
    bool isActivated = false,
    String baseUrl = 'http://192.168.1.50:8080',
  }) {
    return MessagingGateway(
      id: 1,
      name: 'هاتف الرسائل',
      provider: MessagingProvider.smsGate,
      baseUrl: baseUrl,
      username: 'pointy',
      isDefault: true,
      hasPassword: true,
      isActivated: isActivated,
    );
  }

  group('normalizeGatewayBaseUrl', () {
    test('adds the scheme and the default SMS Gate port', () {
      expect(
        normalizeGatewayBaseUrl('192.168.1.50'),
        'http://192.168.1.50:8080',
      );
    });

    test('keeps an explicit port and scheme', () {
      expect(
        normalizeGatewayBaseUrl('https://phone.local:9000'),
        'https://phone.local:9000',
      );
    });

    test('drops the endpoint path pasted from the SMS Gate docs', () {
      // The docs' example URL is http://<ip>:8080/message, and the driver
      // appends its own path — left alone this sends to /message/messages.
      expect(
        normalizeGatewayBaseUrl('http://192.168.1.50:8080/message'),
        'http://192.168.1.50:8080',
      );
      expect(
        normalizeGatewayBaseUrl('http://192.168.1.50:8080/messages/'),
        'http://192.168.1.50:8080',
      );
    });

    test('leaves a genuine sub-path in place', () {
      expect(
        normalizeGatewayBaseUrl('http://192.168.1.50:8080/gate'),
        'http://192.168.1.50:8080/gate',
      );
    });

    test('rejects input that is not an address', () {
      expect(isValidGatewayBaseUrl('not a url'), isFalse);
      expect(isValidGatewayBaseUrl('192.168.1.50'), isTrue);
    });
  });

  group('MessagingSettingsViewModel dirty state', () {
    test('a freshly loaded gateway is not dirty', () async {
      final vm = MessagingSettingsViewModel(_FakeRepo(stored: gateway()));
      await vm.load();

      expect(vm.isDirty, isFalse);
      expect(vm.canTest, isTrue);
      expect(vm.canSave, isFalse);
    });

    test('an edit blocks Test-send, which runs on the saved config', () async {
      final vm = MessagingSettingsViewModel(_FakeRepo(stored: gateway()));
      await vm.load();

      vm.setBaseUrl('192.168.1.77');

      expect(vm.isDirty, isTrue);
      expect(vm.canTest, isFalse);
      expect(vm.canSave, isTrue);
    });

    test('a stored address that needs normalizing reads as dirty', () async {
      final vm = MessagingSettingsViewModel(
        _FakeRepo(stored: gateway(baseUrl: 'http://192.168.1.50:8080/message')),
      );
      await vm.load();

      expect(vm.isDirty, isTrue);
    });
  });

  group('MessagingSettingsViewModel.connect', () {
    test('saves the normalized address, then activates', () async {
      final repo = _FakeRepo();
      final vm = MessagingSettingsViewModel(repo);
      await vm.load();

      vm.setBaseUrl('192.168.1.50');
      vm.setUsername('pointy');
      vm.setPassword('secret');
      final outcome = await vm.connect();

      expect(outcome, MessagingConnectOutcome.connected);
      expect(repo.savedDraft?.baseUrl, 'http://192.168.1.50:8080');
      expect(repo.activatedId, 1);
      expect(vm.registeredWebhooks, 4);
      expect(vm.isDirty, isFalse);
    });

    test('reports a save that landed without reaching the device', () async {
      final repo = _FakeRepo(
        activation: const Ok(
          GatewayActivation(ok: false, registered: 0, total: 4),
        ),
      );
      final vm = MessagingSettingsViewModel(repo);
      await vm.load();

      vm.setBaseUrl('192.168.1.50');
      vm.setPassword('secret');

      expect(await vm.connect(), MessagingConnectOutcome.savedNotActivated);
      expect(repo.savedDraft, isNotNull);
    });

    test('surfaces the backend reason when the save itself fails', () async {
      final repo = _FakeRepo(createResult: Error(Exception('nope')));
      final vm = MessagingSettingsViewModel(repo);
      await vm.load();

      vm.setBaseUrl('192.168.1.50');
      vm.setPassword('secret');

      expect(await vm.connect(), MessagingConnectOutcome.failed);
      expect(repo.activatedId, isNull);
    });

    test('an already-saved gateway activates without re-saving', () async {
      final repo = _FakeRepo(stored: gateway());
      final vm = MessagingSettingsViewModel(repo);
      await vm.load();

      expect(await vm.connect(), MessagingConnectOutcome.connected);
      expect(repo.savedDraft, isNull);
      expect(repo.activatedId, 1);
    });
  });

  group('MessagingSettingsViewModel setup stage', () {
    test('separates "can send" from "fully connected"', () async {
      final vm = MessagingSettingsViewModel(
        _FakeRepo(stored: gateway(isActivated: false)),
      );
      await vm.load();
      expect(vm.setupStage, MessagingSetupStage.configured);

      final ready = MessagingSettingsViewModel(
        _FakeRepo(stored: gateway(isActivated: true)),
      );
      await ready.load();
      expect(ready.setupStage, MessagingSetupStage.ready);
    });

    test('an empty shop starts unconfigured', () async {
      final vm = MessagingSettingsViewModel(_FakeRepo());
      await vm.load();

      expect(vm.setupStage, MessagingSetupStage.unconfigured);
      expect(vm.canConnect, isFalse);
    });
  });

  test('a zeroed per-minute rate is flagged as unpaced', () async {
    final vm = MessagingSettingsViewModel(_FakeRepo(stored: gateway()));
    await vm.load();

    expect(vm.isUnpaced, isFalse);
    vm.setMaxMessagesPerMinute(0);
    expect(vm.isUnpaced, isTrue);
  });
}

class _FakeRepo extends MessagingRepository {
  _FakeRepo({
    this.stored,
    this.createResult,
    Result<GatewayActivation>? activation,
  }) : activation =
           activation ??
           const Ok(GatewayActivation(ok: true, registered: 4, total: 4)),
       super(PosApiService());

  MessagingGateway? stored;
  final Result<MessagingGateway>? createResult;
  final Result<GatewayActivation> activation;

  MessagingGatewayDraft? savedDraft;
  int? activatedId;

  @override
  Future<Result<List<MessagingGateway>>> loadGateways() async {
    final gateway = stored;
    return Ok(gateway == null ? const [] : [gateway]);
  }

  @override
  Future<Result<MessagingGateway>> createGateway(
    MessagingGatewayDraft draft,
  ) async {
    savedDraft = draft;
    final failure = createResult;
    if (failure != null) {
      return failure;
    }
    stored = MessagingGateway(
      id: 1,
      name: draft.name,
      provider: draft.provider,
      baseUrl: draft.baseUrl,
      username: draft.username,
      isDefault: true,
      hasPassword: true,
      maxMessagesPerMinute: draft.maxMessagesPerMinute,
      dailyCap: draft.dailyCap,
    );
    return Ok(stored!);
  }

  @override
  Future<Result<MessagingGateway>> updateGateway(
    int id,
    MessagingGatewayDraft draft,
  ) => createGateway(draft);

  @override
  Future<Result<GatewayActivation>> activate(int id) async {
    activatedId = id;
    final result = activation;
    if (result is Ok<GatewayActivation> && result.value.ok) {
      final current = stored;
      if (current != null) {
        stored = MessagingGateway(
          id: current.id,
          name: current.name,
          provider: current.provider,
          baseUrl: current.baseUrl,
          username: current.username,
          isDefault: true,
          hasPassword: true,
          isActivated: true,
          maxMessagesPerMinute: current.maxMessagesPerMinute,
          dailyCap: current.dailyCap,
        );
      }
    }
    return result;
  }
}
