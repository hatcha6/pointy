// Dev-only preview harness for Shop Settings → Integrations.
//
// Renders the integrations page against an in-memory fake repository (no
// backend, no auth). Pick the scenario with a `?screen=` query param and resize
// the browser to test responsiveness. Run with:
//
//   flutter run -d web-server --web-port 8080 -t lib/dev/integrations_preview.dart
//
// Scenarios: catalog | connected | failed | unconfigured | error | board
//
// See AGENTS.md ("UI preview harness") for the pattern. Not part of the
// shipping app. Safe to delete.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/integration_provider.dart';
import 'package:pointy_frontend/src/data/repositories/integrations_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/settings/view_models/integrations_view_model.dart';
import 'package:pointy_frontend/src/features/settings/views/integrations_page.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/shell/shell.dart';

void main() => runApp(const _PreviewApp());

class _PreviewApp extends StatelessWidget {
  const _PreviewApp();

  @override
  Widget build(BuildContext context) {
    final screen = _screen();
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: PointyTheme.light(),
      builder: (context, child) => PointyNavigationRailScope(
        isActive: false,
        controller: PointyNavigationRailController(),
        child: child ?? const SizedBox.shrink(),
      ),
      home: screen == 'board'
          ? const _Board()
          : IntegrationsPage(
              viewModel: IntegrationsViewModel(
                _FakeIntegrationsRepository(screen),
              ),
            ),
    );
  }
}

String _screen() {
  final uri = Uri.base;
  final direct = uri.queryParameters['screen'];
  if (direct != null) {
    return direct;
  }
  final fragment = uri.fragment;
  final parsed = Uri.tryParse(
    fragment.startsWith('/') ? fragment.substring(1) : fragment,
  );
  return parsed?.queryParameters['screen'] ?? 'catalog';
}

/// Every card state at once, in a phone frame, for one review screenshot.
class _Board extends StatelessWidget {
  const _Board();

  @override
  Widget build(BuildContext context) {
    const scenarios = ['catalog', 'connected', 'failed', 'unconfigured'];
    return Scaffold(
      backgroundColor: context.pointyColors.surfaceSunken,
      body: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.all(24),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final scenario in scenarios) ...[
              _Frame(
                label: scenario,
                child: IntegrationsPage(
                  viewModel: IntegrationsViewModel(
                    _FakeIntegrationsRepository(scenario),
                  ),
                ),
              ),
              const SizedBox(width: 24),
            ],
          ],
        ),
      ),
    );
  }
}

class _Frame extends StatelessWidget {
  const _Frame({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    const size = Size(390, 844);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 8),
        SizedBox(
          width: size.width,
          height: size.height,
          child: MediaQuery(
            data: MediaQuery.of(context).copyWith(
              size: size,
              padding: EdgeInsets.zero,
              viewInsets: EdgeInsets.zero,
            ),
            child: child,
          ),
        ),
      ],
    );
  }
}

/// Canned catalog responses. Mirrors the real payload shape: every provider is
/// present in every scenario, because that is the point of the screen.
class _FakeIntegrationsRepository extends IntegrationsRepository {
  _FakeIntegrationsRepository(this.scenario) : super(PosApiService());

  final String scenario;

  @override
  Future<Result<List<IntegrationProvider>>> loadProviders() async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    if (scenario == 'error') {
      return Error(Exception('load failed'));
    }
    return Ok([_hdbox(scenario), _lnet(), _qareeb()]);
  }

  @override
  Future<Result<IntegrationProvider>> saveCredentials(
    String providerKey,
    IntegrationCredentialsDraft draft,
  ) async {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    return Ok(_hdbox('connected'));
  }

  @override
  Future<Result<IntegrationProbeResult>> probe(String providerKey) async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    return Ok(IntegrationProbeResult(ok: true, provider: _hdbox('connected')));
  }

  @override
  Future<Result<IntegrationProvider>> disconnect(String providerKey) async {
    await Future<void>.delayed(const Duration(milliseconds: 150));
    return Ok(_hdbox('unconfigured'));
  }

  static IntegrationProvider _hdbox(String scenario) {
    final account = switch (scenario) {
      'unconfigured' => null,
      'failed' => IntegrationAccount(
        provider: IntegrationProviderKey.hdbox,
        baseUrl: 'http://cas.hdboxly.com:18688',
        username: 'Alnassim',
        hasPassword: true,
        isConfigured: true,
        balance: 25,
        balanceAt: DateTime(2026, 9, 18, 20, 8),
        accountLabel: 'Alnassim',
        lastCheckedAt: DateTime(2026, 9, 19, 9, 14),
        lastErrorCode: IntegrationErrorCode.unauthorized,
        lastError: 'login rejected',
        lastErrorAt: DateTime(2026, 9, 19, 9, 14),
      ),
      _ => IntegrationAccount(
        provider: IntegrationProviderKey.hdbox,
        baseUrl: 'http://cas.hdboxly.com:18688',
        username: 'Alnassim',
        hasPassword: true,
        isConfigured: true,
        balance: 25,
        balanceAt: DateTime(2026, 9, 19, 9, 14),
        accountLabel: 'Alnassim',
        lastCheckedAt: DateTime(2026, 9, 19, 9, 14),
        lastConnectedAt: DateTime(2026, 9, 19, 9, 14),
      ),
    };
    return IntegrationProvider(
      key: IntegrationProviderKey.hdbox,
      availability: IntegrationAvailability.available,
      capabilities: const [
        IntegrationCapability.balance,
        IntegrationCapability.lookup,
      ],
      fields: const [
        IntegrationField.baseUrl,
        IntegrationField.username,
        IntegrationField.password,
      ],
      secretFields: const [IntegrationField.password],
      defaultBaseUrl: 'http://cas.hdboxly.com:18688',
      isConfigurable: true,
      account: scenario == 'catalog' ? null : account,
    );
  }

  static IntegrationProvider _lnet() => const IntegrationProvider(
    key: IntegrationProviderKey.lnet,
    availability: IntegrationAvailability.available,
    capabilities: [
      IntegrationCapability.balance,
      IntegrationCapability.lookup,
      IntegrationCapability.recharge,
    ],
    fields: [
      IntegrationField.baseUrl,
      IntegrationField.username,
      IntegrationField.password,
    ],
    secretFields: [IntegrationField.password],
    defaultBaseUrl: 'https://billing.lnet.ly/lnet-billing/public',
    isConfigurable: true,
    // The shop's own commercial terms, declared by the backend and rendered
    // by the generic form — this is what the settings section is for.
    settings: [
      IntegrationSetting(
        key: IntegrationSettingKey.commissionPercent,
        kind: 'percent',
        value: '5',
        defaultValue: '5',
        minimum: 0,
        maximum: 50,
      ),
      IntegrationSetting(
        key: IntegrationSettingKey.denominations,
        kind: 'amount_list',
        value: ['10', '20', '25', '30', '40', '45', '50', '100'],
      ),
    ],
  );

  static IntegrationProvider _qareeb() => const IntegrationProvider(
    key: IntegrationProviderKey.qareeb,
    availability: IntegrationAvailability.planned,
    blockedReason: IntegrationBlockedReason.awaitingAccess,
    capabilities: [
      IntegrationCapability.balance,
      IntegrationCapability.recharge,
    ],
    fields: [
      IntegrationField.baseUrl,
      IntegrationField.username,
      IntegrationField.password,
    ],
    secretFields: [IntegrationField.password],
  );
}
