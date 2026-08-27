// Dev-only preview harness for the subscription status page (Shop Settings).
//
// Renders the relay installation ID + remote-access / AI subscription page
// full-viewport, backed by an in-memory fake repository (no backend). Pick the
// scenario with a `?screen=` query param and resize the browser to test
// responsiveness. Run with:
//
//   flutter run -d web-server --web-port 8080 -t lib/dev/subscription_preview.dart
//
// Scenarios: active | expiring | expired | ai_off | unconfigured | sync_fail
//
// See AGENTS.md ("UI preview harness") for the pattern. Not part of the
// shipping app. Safe to delete.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/ai_chat.dart';
import 'package:pointy_frontend/src/data/models/relay_installation_status.dart';
import 'package:pointy_frontend/src/data/repositories/subscription_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/settings/view_models/subscription_status_view_model.dart';
import 'package:pointy_frontend/src/features/settings/views/subscription_status_page.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/shell/shell.dart';

void main() => runApp(const _PreviewApp());

class _PreviewApp extends StatelessWidget {
  const _PreviewApp();

  @override
  Widget build(BuildContext context) {
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
      home: SubscriptionStatusPage(
        viewModel: SubscriptionStatusViewModel(
          _FakeSubscriptionRepository(_screen()),
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
  return parsed?.queryParameters['screen'] ?? 'active';
}

/// In-memory store backing the preview — returns a canned snapshot + usage for
/// the chosen scenario, and simulates a relay sync failure for `sync_fail`.
class _FakeSubscriptionRepository extends SubscriptionRepository {
  _FakeSubscriptionRepository(this.scenario) : super(PosApiService());

  final String scenario;

  @override
  Future<Result<RelayInstallationStatus>> loadStatus({
    bool sync = false,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (scenario == 'sync_fail' && sync) {
      return Error(Exception('relay unreachable'));
    }
    return Ok(_status());
  }

  @override
  Future<Result<AiUsage>> loadAiUsage() async {
    await Future<void>.delayed(const Duration(milliseconds: 150));
    return Ok(
      AiUsage(
        fiveHour: AiUsageWindow(
          used: 12,
          limit: 40,
          resetAt: DateTime.now().add(const Duration(hours: 3)),
        ),
        weekly: AiUsageWindow(
          used: 188,
          limit: 200,
          resetAt: DateTime.now().add(const Duration(days: 4)),
        ),
      ),
    );
  }

  RelayInstallationStatus _status() {
    final now = DateTime.now();
    return switch (scenario) {
      'unconfigured' => const RelayInstallationStatus(
        configured: false,
        remoteAccessSupported: false,
        installationId: '',
        shopName: '',
        relayPublicApiUrl: '',
        relayConnectorAddress: '',
        relayEnabled: false,
        subscriptionActive: false,
        aiEnabled: false,
      ),
      'expired' => RelayInstallationStatus(
        configured: true,
        remoteAccessSupported: false,
        installationId: 'POS-LY-7F3A-9K21',
        shopName: 'صيدلية الشفاء',
        relayPublicApiUrl: 'https://relay.pointy.ly',
        relayConnectorAddress: 'relay.pointy.ly:8443',
        relayEnabled: true,
        subscriptionActive: false,
        aiEnabled: true,
        subscriptionEndsAt: now.subtract(const Duration(days: 6)),
        lastSyncedAt: now.subtract(const Duration(hours: 2)),
        connectorLastSeenAt: now.subtract(const Duration(days: 7)),
        connectorVersion: '1.4.0',
      ),
      'ai_off' => RelayInstallationStatus(
        configured: true,
        remoteAccessSupported: true,
        installationId: 'POS-LY-7F3A-9K21',
        shopName: 'مطعم البحر',
        relayPublicApiUrl: 'https://relay.pointy.ly',
        relayConnectorAddress: 'relay.pointy.ly:8443',
        relayEnabled: true,
        subscriptionActive: true,
        aiEnabled: false,
        subscriptionEndsAt: now.add(const Duration(days: 210)),
        lastSyncedAt: now.subtract(const Duration(minutes: 5)),
        connectorLastSeenAt: now.subtract(const Duration(minutes: 1)),
        connectorVersion: '1.4.0',
      ),
      'expiring' => RelayInstallationStatus(
        configured: true,
        remoteAccessSupported: true,
        installationId: 'POS-LY-7F3A-9K21',
        shopName: 'بقالة النور',
        relayPublicApiUrl: 'https://relay.pointy.ly',
        relayConnectorAddress: 'relay.pointy.ly:8443',
        relayEnabled: true,
        subscriptionActive: true,
        aiEnabled: true,
        subscriptionEndsAt: now.add(const Duration(days: 4)),
        lastSyncedAt: now.subtract(const Duration(minutes: 5)),
        connectorLastSeenAt: now.subtract(const Duration(minutes: 2)),
        connectorVersion: '1.4.0',
      ),
      _ => RelayInstallationStatus(
        configured: true,
        remoteAccessSupported: true,
        installationId: 'POS-LY-7F3A-9K21',
        shopName: 'سوبر ماركت الوفاء',
        relayPublicApiUrl: 'https://relay.pointy.ly',
        relayConnectorAddress: 'relay.pointy.ly:8443',
        relayEnabled: true,
        subscriptionActive: true,
        aiEnabled: true,
        subscriptionEndsAt: now.add(const Duration(days: 318)),
        lastSyncedAt: now.subtract(const Duration(minutes: 5)),
        connectorLastSeenAt: now.subtract(const Duration(seconds: 40)),
        connectorVersion: '1.4.0',
      ),
    };
  }
}
