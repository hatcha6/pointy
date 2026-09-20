import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/integration_provider.dart';
import 'package:pointy_frontend/src/data/repositories/integrations_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/settings/view_models/integrations_view_model.dart';

void main() {
  test('load keeps the whole catalog, planned entries included', () async {
    final viewModel = IntegrationsViewModel(_FakeRepo());
    await viewModel.load();

    expect(viewModel.providers, hasLength(2));
    expect(viewModel.hasLoadError, isFalse);
    expect(
      viewModel.providerFor(IntegrationProviderKey.lnet)?.availability,
      IntegrationAvailability.planned,
    );
  });

  test(
    'a failed load is flagged rather than shown as an empty catalog',
    () async {
      final viewModel = IntegrationsViewModel(_FakeRepo(failLoad: true));
      await viewModel.load();

      expect(viewModel.hasLoadError, isTrue);
      expect(viewModel.providers, isEmpty);
    },
  );

  test('a probe refreshes only the provider it tested', () async {
    final viewModel = IntegrationsViewModel(_FakeRepo());
    await viewModel.load();
    await viewModel.probe(IntegrationProviderKey.hdbox);

    expect(viewModel.lastProbe?.ok, isTrue);
    expect(
      viewModel.providerFor(IntegrationProviderKey.hdbox)?.account?.balance,
      42,
    );
    // The untested provider is untouched.
    expect(
      viewModel.providerFor(IntegrationProviderKey.lnet)?.availability,
      IntegrationAvailability.planned,
    );
  });

  test(
    'a provider saying no is a probe result, not a request failure',
    () async {
      final viewModel = IntegrationsViewModel(
        _FakeRepo(probeError: IntegrationErrorCode.unauthorized),
      );
      await viewModel.load();
      await viewModel.probe(IntegrationProviderKey.hdbox);

      expect(viewModel.actionException, isNull);
      expect(viewModel.lastProbe?.ok, isFalse);
      expect(viewModel.lastProbe?.errorCode, IntegrationErrorCode.unauthorized);
    },
  );

  test(
    'a broken request surfaces as an exception the page can localize',
    () async {
      final viewModel = IntegrationsViewModel(_FakeRepo(failProbe: true));
      await viewModel.load();
      await viewModel.probe(IntegrationProviderKey.hdbox);

      expect(viewModel.actionException, isNotNull);
      expect(viewModel.lastProbe, isNull);
    },
  );

  test('busy state is scoped to one provider', () async {
    final repo = _FakeRepo();
    final viewModel = IntegrationsViewModel(repo);
    await viewModel.load();

    final pending = viewModel.probe(IntegrationProviderKey.hdbox);
    expect(viewModel.isBusy(IntegrationProviderKey.hdbox), isTrue);
    expect(viewModel.isBusy(IntegrationProviderKey.lnet), isFalse);
    await pending;
    expect(viewModel.isBusy(IntegrationProviderKey.hdbox), isFalse);
  });
}

IntegrationProvider _hdbox({double? balance}) => IntegrationProvider(
  key: IntegrationProviderKey.hdbox,
  availability: IntegrationAvailability.available,
  isConfigurable: true,
  account: IntegrationAccount(
    provider: IntegrationProviderKey.hdbox,
    username: 'Alnassim',
    hasPassword: true,
    isConfigured: true,
    balance: balance,
  ),
);

class _FakeRepo extends IntegrationsRepository {
  _FakeRepo({this.failLoad = false, this.failProbe = false, this.probeError})
    : super(PosApiService());

  final bool failLoad;
  final bool failProbe;
  final String? probeError;

  @override
  Future<Result<List<IntegrationProvider>>> loadProviders() async {
    if (failLoad) return Error(Exception('nope'));
    return Ok([
      _hdbox(),
      const IntegrationProvider(
        key: IntegrationProviderKey.lnet,
        availability: IntegrationAvailability.planned,
        blockedReason: IntegrationBlockedReason.portalUnreachable,
      ),
    ]);
  }

  @override
  Future<Result<IntegrationProbeResult>> probe(String providerKey) async {
    if (failProbe) return Error(Exception('network down'));
    return Ok(
      IntegrationProbeResult(
        ok: probeError == null,
        errorCode: probeError ?? '',
        provider: _hdbox(balance: 42),
      ),
    );
  }
}
