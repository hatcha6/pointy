import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/integration_provider.dart';
import 'package:pointy_frontend/src/data/repositories/integrations_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/settings/view_models/integrations_view_model.dart';
import 'package:pointy_frontend/src/features/settings/views/integration_credentials_sheet.dart';
import 'package:pointy_frontend/src/features/settings/views/integrations_page.dart';

/// What this screen must never get wrong.
///
/// It is the door to a credential that can spend the shop's float at a
/// provider, and it is also the only place an owner learns that a provider is
/// coming rather than broken. Both of those are pinned here.
void main() {
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

  testWidgets('lists planned providers alongside the working one', (
    tester,
  ) async {
    await tester.pumpWidget(harness(IntegrationsViewModel(_FakeRepo())));
    await tester.pumpAndSettle();

    // The roadmap is the feature: a shop that resells LNET next year should
    // see it listed today rather than wonder whether Pointy will ever do it.
    expect(find.text('HD Box'), findsOneWidget);
    expect(find.text('LNET'), findsOneWidget);
    expect(find.text('قريب'), findsOneWidget);
    expect(find.text('قريباً'), findsNWidgets(2));
  });

  testWidgets('a planned provider offers no way to enter a password', (
    tester,
  ) async {
    await tester.pumpWidget(harness(IntegrationsViewModel(_FakeRepo())));
    await tester.pumpAndSettle();

    // One connect button, for HD Box — not three. Credentials typed against a
    // provider with no driver would sit in the database doing nothing.
    expect(find.text('ربط الحساب'), findsOneWidget);
  });

  testWidgets('a connected provider shows its float and last check', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(IntegrationsViewModel(_FakeRepo(connected: true))),
    );
    await tester.pumpAndSettle();

    expect(find.text('الرصيد لدى المزوّد'), findsOneWidget);
    expect(find.textContaining('25.00'), findsOneWidget);
    expect(find.text('متصل'), findsOneWidget);
  });

  testWidgets('a rejected credential is named, not hidden behind "error"', (
    tester,
  ) async {
    final repo = _FakeRepo(connected: true, probeError: 'unauthorized');
    final viewModel = IntegrationsViewModel(repo);
    await tester.pumpWidget(harness(viewModel));
    await tester.pumpAndSettle();

    await tester.tap(find.text('اختبار الاتصال'));
    await tester.pumpAndSettle();

    expect(
      find.text('رفض المزوّد اسم المستخدم أو كلمة المرور'),
      findsOneWidget,
    );
  });

  testWidgets('re-saving with a blank password keeps the stored one', (
    tester,
  ) async {
    // The form never received the password, so it cannot resend it. If blank
    // were taken as "erase", editing the URL would silently break the login.
    IntegrationCredentialsDraft? submitted;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ar'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: IntegrationCredentialsForm(
            provider: _provider(connected: true),
            onSubmit: (draft) async {
              submitted = draft;
              return true;
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('حفظ'));
    await tester.pumpAndSettle();

    expect(
      submitted,
      isNotNull,
      reason: 'a blank password must still validate',
    );
    expect(submitted!.toJson().containsKey('password'), isFalse);
  });
}

IntegrationProvider _provider({required bool connected}) {
  return IntegrationProvider(
    key: IntegrationProviderKey.hdbox,
    availability: IntegrationAvailability.available,
    capabilities: const [IntegrationCapability.balance],
    fields: const [
      IntegrationField.baseUrl,
      IntegrationField.username,
      IntegrationField.password,
    ],
    secretFields: const [IntegrationField.password],
    defaultBaseUrl: 'http://cas.example:18688',
    isConfigurable: true,
    account: connected
        ? IntegrationAccount(
            provider: IntegrationProviderKey.hdbox,
            baseUrl: 'http://cas.example:18688',
            username: 'Alnassim',
            hasPassword: true,
            isConfigured: true,
            balance: 25,
            accountLabel: 'Alnassim',
            lastCheckedAt: DateTime(2026, 9, 19, 9, 14),
          )
        : null,
  );
}

class _FakeRepo extends IntegrationsRepository {
  _FakeRepo({this.connected = false, this.probeError}) : super(PosApiService());

  final bool connected;
  final String? probeError;

  @override
  Future<Result<List<IntegrationProvider>>> loadProviders() async {
    return Ok([
      _provider(connected: connected),
      const IntegrationProvider(
        key: IntegrationProviderKey.lnet,
        availability: IntegrationAvailability.planned,
        blockedReason: IntegrationBlockedReason.portalUnreachable,
      ),
      const IntegrationProvider(
        key: IntegrationProviderKey.qareeb,
        availability: IntegrationAvailability.planned,
        blockedReason: IntegrationBlockedReason.awaitingAccess,
      ),
    ]);
  }

  @override
  Future<Result<IntegrationProbeResult>> probe(String providerKey) async {
    return Ok(
      IntegrationProbeResult(
        ok: probeError == null,
        errorCode: probeError ?? '',
        provider: _provider(connected: connected),
      ),
    );
  }
}
