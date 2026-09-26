import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/authorization.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/device_printers.dart';
import 'package:pointy_frontend/src/data/models/device_settings.dart';
import 'package:pointy_frontend/src/data/models/pos_user.dart';
import 'package:pointy_frontend/src/data/repositories/device_settings_repository.dart';
import 'package:pointy_frontend/src/data/repositories/price_checker_repository.dart';
import 'package:pointy_frontend/src/data/repositories/printing_repository.dart';
import 'package:pointy_frontend/src/data/services/client_update_service.dart';
import 'package:pointy_frontend/src/data/services/fake_print_transport.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/device_settings/view_models/device_settings_view_model.dart';
import 'package:pointy_frontend/src/features/device_settings/views/device_settings_screen.dart';
import 'package:pointy_frontend/src/features/printing/view_models/printing_settings_view_model.dart';
import 'package:pointy_frontend/src/features/settings/views/app_updates_page.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/navigation/app_navigation.dart';
import 'package:pointy_frontend/src/shared/price_checker/price_checker_mode_controller.dart';
import 'package:pointy_frontend/src/shared/shell/shell.dart';

const _cashier = PosUser(
  id: 7,
  username: 'cashier',
  role: UserRole.cashier,
  isActive: true,
);

class _FakeDeviceSettingsRepository extends DeviceSettingsRepository {
  const _FakeDeviceSettingsRepository();

  @override
  Future<Result<DeviceSettings>> loadSettings() async =>
      Ok(DeviceSettings.defaults());
}

class _FakePrintingRepository extends PrintingRepository {
  _FakePrintingRepository()
    : super(
        PosApiService(),
        serialTransport: const FakePrintTransport(),
        bluetoothTransport: const FakePrintTransport(),
        wifiTransport: const FakePrintTransport(),
        usbTransport: const FakePrintTransport(),
      );

  @override
  Future<Result<DevicePrinters>> loadDevicePrinters() async =>
      const Ok(DevicePrinters.empty);
}

class _FakeNavigation implements AppNavigation {
  @override
  PosUser get currentUser => _cashier;

  @override
  AuthorizationCapabilities get capabilities =>
      AuthorizationCapabilities.forUser(_cashier);

  @override
  void navigateTo(
    BuildContext context,
    AppNavigationDestination destination, {
    AppNavigationDestination? from,
  }) {}

  @override
  void openAiChat(
    BuildContext context, {
    String? seedPrompt,
    bool autoSend = false,
    AppNavigationDestination? from,
  }) {}

  @override
  void logout(BuildContext context) {}
}

/// App updates live in device settings, not shop settings: an update replaces
/// the app on one machine, and the cashier at that machine has to reach it
/// without being handed the shop's settings.
void main() {
  testWidgets('a cashier opens app updates from device settings', (
    tester,
  ) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('ar'));
    final updates = ClientUpdateService(
      apiBaseUrl: () => 'http://10.0.0.5:8000/api',
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'version': '1.3.0',
            'clients': {
              'windows': {
                'version': '1.3.0',
                'file': 'pointy-1.3.0-windows-setup.exe',
                'sha256': 'abc',
                'size': 10,
                'url': '/clients/files/pointy-1.3.0-windows-setup.exe',
              },
            },
          }),
          200,
        ),
      ),
      readRunningVersion: () async => '1.3.0',
      platform: () => ClientPlatform.windows,
    );

    await tester.pumpWidget(
      MaterialApp(
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
        home: DeviceSettingsScreen(
          deviceSettingsViewModel: DeviceSettingsViewModel(
            const _FakeDeviceSettingsRepository(),
          ),
          printingSettingsViewModel: PrintingSettingsViewModel(
            _FakePrintingRepository(),
          ),
          priceCheckerController: PriceCheckerModeController(),
          priceCheckerRepository: PriceCheckerRepository(PosApiService()),
          clientUpdateService: updates,
          capabilities: AuthorizationCapabilities.forUser(_cashier),
          navigation: _FakeNavigation(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text(l10n.clientUpdatesTitle));
    await tester.pumpAndSettle();

    expect(find.byType(AppUpdatesPage), findsOneWidget);
    expect(find.text(l10n.appUpdatesUpToDate), findsOneWidget);
  });
}
