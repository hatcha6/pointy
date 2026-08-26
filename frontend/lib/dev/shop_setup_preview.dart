// Dev-only preview harness for the first-run shop-setup wizard.
//
// Renders the real ShopSetupWizard with a fake repository (no backend). Start in
// dark with `?screen=dark`. Run with:
//
//   flutter run -d web-server --web-port 8080 -t lib/dev/shop_setup_preview.dart
//
// Not part of the shipping app. Safe to delete.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/shop_settings.dart';
import 'package:pointy_frontend/src/data/repositories/shop_settings_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/onboarding/views/shop_setup_wizard.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/shell/shell.dart';

void main() => runApp(const _PreviewApp());

ThemeMode _mode() =>
    Uri.base.queryParameters['screen'] == 'dark' ? ThemeMode.dark : ThemeMode.light;

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
      darkTheme: PointyTheme.dark(),
      themeMode: _mode(),
      builder: (context, child) => PointyNavigationRailScope(
        isActive: false,
        controller: PointyNavigationRailController(),
        child: child ?? const SizedBox.shrink(),
      ),
      home: ShopSetupWizard(
        shopSettingsRepository: _FakeShopSettingsRepository(),
        onComplete: () {},
      ),
    );
  }
}

class _FakeShopSettingsRepository extends ShopSettingsRepository {
  _FakeShopSettingsRepository() : super(PosApiService());

  @override
  Future<Result<ShopSettings>> setupShop({
    required String shopType,
    String? shopName,
    bool? allowOverselling,
    bool? requireOpeningCash,
    bool? autoPrintReceipts,
    bool? autoPrintKitchenTickets,
    InventoryValuationMethod? inventoryValuationMethod,
  }) async {
    return const Ok(
      ShopSettings(
        shopName: 'متجر',
        receiptHeader: '',
        receiptFooter: '',
        enableOnlineInvoices: false,
        requireOpeningCash: true,
        autoPrintReceipts: false,
        allowOverselling: false,
        preventSellingAtLoss: true,
        lowStockThreshold: 5,
        cashierReturnWindowHours: 42,
        enableCashPayments: true,
        enableCardPayments: true,
        enableTransferPayments: true,
        requireCardPaymentReceipt: false,
        trustedCardTerminalIds: [],
        cardCommissionPercent: 1,
        transferCommissionPercent: 0,
      ),
    );
  }
}
