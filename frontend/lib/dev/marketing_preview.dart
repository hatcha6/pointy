// Dev-only preview harness for marketing screenshots — safe to delete, never
// imported by lib/main.dart.
//
// Renders real Pointy (دفتر) screens with realistic Libyan Arabic fake data,
// no backend and no login. Pick a surface with `?screen=`:
//
//   updates              — app updates: a new build waiting on the shop server
//   updates-downloading  — that build downloading
//   updates-current      — already on the newest build
//   attendance           — fingerprint attendance, one employee's September
//   attendance-device    — the BioTime/ZKTeco connection, synced and mapped
//   payroll              — September's payroll run built from that attendance
//   payroll-home         — the payroll tab and its run history
//   product-fx           — a new product priced in dollars, dinar beside it
//   exchange-rates       — parallel-market cash rates and the repricing list
//   pos-serial           — the till asking which IMEI is being sold
//   pos-phones           — the same phone-shop till, no picker open
//
// Add `&theme=dark` for the dark palette.
//
//   flutter build web -t lib/dev/marketing_preview.dart
//
// See AGENTS.md ("UI Preview Harness"). Screens that are only reached by input
// (a chosen tab, a typed price) are driven there by lib/dev/marketing/drive.dart.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/shell/shell.dart';
import 'package:pointy_frontend/src/shared/tracking/tracking_features.dart';

import 'marketing/fx_surfaces.dart';
import 'marketing/pos_serial_surface.dart';
import 'marketing/staff_surfaces.dart';
import 'marketing/updates_surface.dart';

void main() => runApp(const _MarketingPreviewApp());

final _railController = PointyNavigationRailController();

class _MarketingPreviewApp extends StatelessWidget {
  const _MarketingPreviewApp();

  @override
  Widget build(BuildContext context) {
    final query = Uri.base.queryParameters;
    final screen = query['screen'] ?? 'updates';
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
      theme: query['theme'] == 'dark'
          ? PointyTheme.dark()
          : PointyTheme.light(),
      builder: (context, child) => TrackingFeaturesScope(
        // A phone shop: handsets are sold by IMEI.
        features: const TrackingFeatures(serial: true),
        child: PointyNavigationRailScope(
          isActive: false,
          controller: _railController,
          child: child ?? const SizedBox.shrink(),
        ),
      ),
      home: switch (screen) {
        'updates-downloading' => const UpdatesSurface(state: 'downloading'),
        'updates-current' => const UpdatesSurface(state: 'current'),
        'attendance' ||
        'attendance-device' ||
        'payroll' ||
        'payroll-home' => StaffSurface(screen: screen),
        'product-fx' => const ProductFxSurface(),
        'exchange-rates' => const ExchangeRatesSurface(),
        'pos-serial' => const PosSerialSurface(openPicker: true),
        'pos-phones' => const PosSerialSurface(openPicker: false),
        _ => const UpdatesSurface(state: 'available'),
      },
    );
  }
}
