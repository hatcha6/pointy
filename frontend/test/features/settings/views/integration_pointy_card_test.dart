import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/integration_provider.dart';
import 'package:pointy_frontend/src/data/repositories/integrations_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/settings/view_models/integrations_view_model.dart';
import 'package:pointy_frontend/src/features/settings/views/integrations_page.dart';

/// «كروت دفتر» asks the shop for nothing: the company buys the cards with its
/// own account. Its card is a switch, its balance the wallet's voucher
/// balance, and its one setting the low-balance alert.
void main() {
  late AppLocalizations l10n;

  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('ar'));
  });

  Widget harness(IntegrationsViewModel viewModel) {
    return MaterialApp(
      locale: const Locale('ar'),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: IntegrationsPage(viewModel: viewModel),
    );
  }

  testWidgets('off: a switch, never a login form', (tester) async {
    final repo = _Repo(enabled: false);
    await tester.pumpWidget(harness(IntegrationsViewModel(repo)));
    await tester.pumpAndSettle();

    expect(find.text(l10n.integrationProviderPointyName), findsOneWidget);
    expect(find.text(l10n.integrationStatusNotEnabled), findsOneWidget);
    expect(find.text(l10n.integrationEnableTitle), findsOneWidget);
    expect(find.text(l10n.integrationConnect), findsNothing);
    expect(find.text(l10n.integrationDisconnect), findsNothing);
    // No float to record into: the balance is filled from the wallet. (The
    // capability chip says «الرصيد» too, so look for the button.)
    expect(
      find.ancestor(
        of: find.text(l10n.integrationFloatAction),
        matching: find.byWidgetPredicate((widget) => widget is OutlinedButton),
      ),
      findsNothing,
    );
  });

  testWidgets('switching it on saves only the switch, and says so', (
    tester,
  ) async {
    final repo = _Repo(enabled: false);
    await tester.pumpWidget(harness(IntegrationsViewModel(repo)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('integration_enable_pointy')));
    await tester.pumpAndSettle();

    expect(repo.saved.single.toJson(), {'is_active': true});
    expect(find.text(l10n.integrationEnabledToast), findsOneWidget);
    expect(find.text(l10n.integrationStatusEnabled), findsOneWidget);
    // On: its balance is the wallet's voucher balance.
    expect(find.text(l10n.integrationVoucherBalanceLabel), findsOneWidget);
    expect(find.textContaining('345.50'), findsOneWidget);
    expect(find.text(l10n.integrationRefreshBalance), findsOneWidget);
    expect(find.text(l10n.integrationSettingsAction), findsOneWidget);
  });

  testWidgets('switching it off is the same switch', (tester) async {
    final repo = _Repo(enabled: true);
    await tester.pumpWidget(harness(IntegrationsViewModel(repo)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('integration_enable_pointy')));
    await tester.pumpAndSettle();

    expect(repo.saved.single.toJson(), {'is_active': false});
    expect(find.text(l10n.integrationDisabledToast), findsOneWidget);
    expect(find.text(l10n.integrationStatusNotEnabled), findsOneWidget);
  });
}

class _Repo extends IntegrationsRepository {
  _Repo({required this.enabled}) : super(PosApiService());

  bool enabled;
  final List<IntegrationCredentialsDraft> saved = [];

  IntegrationProvider get _pointy => IntegrationProvider(
    key: IntegrationProviderKey.pointy,
    availability: IntegrationAvailability.available,
    capabilities: const [
      IntegrationCapability.balance,
      IntegrationCapability.vouchers,
    ],
    settings: const [
      IntegrationSetting(
        key: IntegrationSettingKey.lowBalanceThreshold,
        kind: 'amount',
        value: '50',
        defaultValue: '50',
        minimum: 0,
        maximum: 1000000,
      ),
    ],
    isConfigurable: true,
    account: IntegrationAccount(
      provider: IntegrationProviderKey.pointy,
      isConfigured: true,
      isActive: enabled,
      balance: 345.5,
      lastCheckedAt: DateTime(2026, 10, 7, 9, 30),
    ),
  );

  @override
  Future<Result<List<IntegrationProvider>>> loadProviders() async =>
      Ok([_pointy]);

  @override
  Future<Result<IntegrationProvider>> saveCredentials(
    String providerKey,
    IntegrationCredentialsDraft draft,
  ) async {
    saved.add(draft);
    enabled = draft.isActive ?? enabled;
    return Ok(_pointy);
  }
}
