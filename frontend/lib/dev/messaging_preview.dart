// Dev-only preview harness for the SMS device settings page (Shop Settings).
//
// Renders the messaging gateway page full-viewport, backed by an in-memory fake
// repository (no backend). Pick the scenario with a `?screen=` query param and
// resize the browser to test responsiveness. Run with:
//
//   flutter run -d web-server --web-port 8080 -t lib/dev/messaging_preview.dart
//
// Scenarios: configured | unconfigured | not_activated | device_error | error
//            | test_fail | activate_fail
//
// See AGENTS.md ("UI preview harness") for the pattern. Not part of the shipping
// app. Safe to delete.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/messaging_gateway.dart';
import 'package:pointy_frontend/src/data/repositories/messaging_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/settings/view_models/messaging_settings_view_model.dart';
import 'package:pointy_frontend/src/features/settings/views/messaging_settings_page.dart';
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
      home: MessagingSettingsPage(
        viewModel: MessagingSettingsViewModel(
          _FakeMessagingRepository(_screen()),
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
  return parsed?.queryParameters['screen'] ?? 'configured';
}

/// In-memory store backing the preview — returns a canned gateway (or none) and
/// simulates a Test-send success/failure for the chosen scenario.
class _FakeMessagingRepository extends MessagingRepository {
  _FakeMessagingRepository(this.scenario) : super(PosApiService());

  final String scenario;

  /// Flipped by [activate] so the `not_activated` scenario can be walked all
  /// the way through to a connected gateway.
  bool _activated = false;

  @override
  Future<Result<List<MessagingGateway>>> loadGateways() async {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    return switch (scenario) {
      'error' => Error(Exception('load failed')),
      'unconfigured' => const Ok(<MessagingGateway>[]),
      // Saved and able to send, but the device webhooks were never registered —
      // the state the page exists to make visible.
      'not_activated' => Ok([_gateway(activated: _activated)]),
      'device_error' => Ok([
        _gateway(
          activated: true,
          lastError: 'unreachable: Connection refused',
          lastErrorAt: DateTime(2026, 8, 30, 9, 41),
        ),
      ]),
      _ => Ok([_gateway(activated: true)]),
    };
  }

  static MessagingGateway _gateway({
    required bool activated,
    String lastError = '',
    DateTime? lastErrorAt,
  }) {
    return MessagingGateway(
      id: 1,
      name: 'هاتف الرسائل',
      provider: MessagingProvider.smsGate,
      baseUrl: 'http://192.168.1.50:8080',
      username: 'pointy',
      isDefault: true,
      isActive: true,
      maxMessagesPerMinute: 6,
      dailyCap: 200,
      hasPassword: true,
      isActivated: activated,
      lastError: lastError,
      lastErrorAt: lastErrorAt,
      lastSeenAt: DateTime(2026, 8, 30, 10, 15),
    );
  }

  @override
  Future<Result<GatewayActivation>> activate(int id) async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (scenario == 'activate_fail') {
      return const Ok(GatewayActivation(ok: false, registered: 0, total: 4));
    }
    _activated = true;
    return const Ok(GatewayActivation(ok: true, registered: 4, total: 4));
  }

  @override
  Future<Result<MessagingGateway>> createGateway(
    MessagingGatewayDraft draft,
  ) async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    return Ok(
      MessagingGateway(
        id: 1,
        name: draft.name,
        provider: draft.provider,
        baseUrl: draft.baseUrl,
        username: draft.username,
        isDefault: true,
        isActive: true,
        maxMessagesPerMinute: draft.maxMessagesPerMinute,
        dailyCap: draft.dailyCap,
        hasPassword: true,
        isActivated: _activated,
      ),
    );
  }

  @override
  Future<Result<MessagingGateway>> updateGateway(
    int id,
    MessagingGatewayDraft draft,
  ) => createGateway(draft);

  @override
  Future<Result<MessagingSendResult>> testSend({
    required int id,
    required String to,
    String? body,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (scenario == 'test_fail') {
      return const Ok(
        MessagingSendResult(
          status: 'failed',
          errorCode: 'unreachable',
          errorDetail: 'تعذّر الوصول إلى الهاتف',
        ),
      );
    }
    return const Ok(MessagingSendResult(status: 'sent'));
  }
}
