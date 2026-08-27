// Dev-only preview harness for the price-checker settings route.
//
// Renders the price-checker devices page (and a device's details screen)
// full-viewport, with an in-memory fake repository and no backend/auth. The
// network "scan" and the per-device scan-event list both return seeded data so
// the design can be exercised end to end. Pick the surface with a `?screen=`
// query param and resize the browser to test responsiveness. Run with:
//
//   flutter run -d web-server --web-port 8080 -t lib/dev/price_checker_preview.dart
//
// Screens: list | empty | details
//
// See AGENTS.md ("UI preview harness") for the pattern. Not part of the
// shipping app. Safe to delete.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/price_check_event.dart';
import 'package:pointy_frontend/src/data/models/price_checker_device.dart';
import 'package:pointy_frontend/src/data/repositories/price_checker_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/settings/view_models/price_checkers_view_model.dart';
import 'package:pointy_frontend/src/features/settings/views/price_checker_device_details_screen.dart';
import 'package:pointy_frontend/src/features/settings/views/price_checkers_page.dart';
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
      home: const _Router(),
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
  return parsed?.queryParameters['screen'] ?? 'list';
}

class _Router extends StatelessWidget {
  const _Router();

  @override
  Widget build(BuildContext context) {
    switch (_screen()) {
      case 'empty':
        return PriceCheckersPage(
          viewModel: PriceCheckersViewModel(
            _FakePriceCheckerRepository.empty(),
          ),
        );
      case 'details':
        final repo = _FakePriceCheckerRepository.seeded();
        return PriceCheckerDeviceDetailsScreen(
          device: _seedDevices.first,
          loadEvents: repo.loadEventsForPreview,
        );
      case 'list':
      default:
        return PriceCheckersPage(
          viewModel: PriceCheckersViewModel(
            _FakePriceCheckerRepository.seeded(),
          ),
        );
    }
  }
}

/// In-memory repository so the harness renders without a backend.
class _FakePriceCheckerRepository extends PriceCheckerRepository {
  _FakePriceCheckerRepository(this._devices) : super(PosApiService());

  factory _FakePriceCheckerRepository.seeded() =>
      _FakePriceCheckerRepository(_seedDevices);

  factory _FakePriceCheckerRepository.empty() =>
      _FakePriceCheckerRepository(const []);

  final List<PriceCheckerDevice> _devices;

  @override
  Future<Result<List<PriceCheckerDevice>>> loadDevices({int page = 1}) async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    return Ok(_devices);
  }

  @override
  Future<Result<PriceCheckerScanSummary>> runScan() async {
    await Future<void>.delayed(const Duration(milliseconds: 600));
    return const Ok(PriceCheckerScanSummary(found: 2, registeredCount: 1));
  }

  @override
  Future<Result<List<PriceCheckEvent>>> loadEvents({
    int? deviceId,
    int page = 1,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    return Ok(_seedEvents);
  }

  Future<List<PriceCheckEvent>?> loadEventsForPreview(int deviceId) async {
    final result = await loadEvents(deviceId: deviceId);
    return switch (result) {
      Ok<List<PriceCheckEvent>>(value: final events) => events,
      Error<List<PriceCheckEvent>>() => null,
    };
  }
}

final List<PriceCheckerDevice> _seedDevices = [
  PriceCheckerDevice.fromJson(const {
    'id': 1,
    'identifier': 'pc-counter',
    'name': 'فاحص الكاشير',
    'driver': 'scantech_shuttle',
    'make': 'Scantech',
    'model': 'Shuttle SH-220',
    'transport': 'tcp',
    'address': '192.168.1.21',
    'port': 9101,
    'mac_address': 'AA:BB:CC:11:22:33',
    'display_rows': 5,
    'display_cols': 20,
    'arabic_support': 'cp1256',
    'encoding': 'cp1256',
    'location': 'طاولة الدفع الأمامية',
    'status': 'active',
    'discovery_method': 'scan',
    'is_serving': true,
    'last_seen_at': '2026-06-16T09:42:00Z',
  }),
  PriceCheckerDevice.fromJson(const {
    'id': 2,
    'identifier': 'pc-aisle-3',
    'name': 'فاحص الممر 3',
    'driver': 'generic_http',
    'make': '',
    'model': '',
    'transport': 'http',
    'address': '192.168.1.34',
    'port': 80,
    'mac_address': '',
    'display_rows': 4,
    'display_cols': 20,
    'arabic_support': 'unicode',
    'encoding': 'utf-8',
    'location': 'الممر 3 — المعلبات',
    'status': 'discovered',
    'discovery_method': 'self',
    'is_serving': false,
    'last_seen_at': '2026-06-16T08:05:00Z',
  }),
  PriceCheckerDevice.fromJson(const {
    'id': 3,
    'identifier': 'pc-store-room',
    'name': 'فاحص المستودع',
    'driver': 'generic_tcp',
    'make': 'Generic',
    'model': '',
    'transport': 'tcp',
    'address': '192.168.1.58',
    'port': 9100,
    'mac_address': 'DD:EE:FF:44:55:66',
    'display_rows': 2,
    'display_cols': 16,
    'arabic_support': 'none',
    'encoding': 'ascii',
    'location': 'المستودع',
    'status': 'disabled',
    'discovery_method': 'manual',
    'is_serving': false,
    'last_seen_at': null,
  }),
];

final List<PriceCheckEvent> _seedEvents = [
  PriceCheckEvent.fromJson(const {
    'id': 11,
    'device': 1,
    'device_identifier': 'pc-counter',
    'barcode': '6001234500001',
    'result': 'found',
    'product_name': 'قميص قطني',
    'original_price': '20.00',
    'final_price': '18.00',
    'discount_total': '2.00',
    'currency': 'د.ل',
    'latency_ms': 42,
    'created_at': '2026-06-16T09:41:30Z',
  }),
  PriceCheckEvent.fromJson(const {
    'id': 12,
    'device': 1,
    'device_identifier': 'pc-counter',
    'barcode': '6009999999999',
    'result': 'not_found',
    'product_name': '',
    'currency': 'د.ل',
    'latency_ms': 30,
    'created_at': '2026-06-16T09:39:10Z',
  }),
  PriceCheckEvent.fromJson(const {
    'id': 13,
    'device': 1,
    'device_identifier': 'pc-counter',
    'barcode': '6001112223334',
    'result': 'found',
    'product_name': 'علبة عصير',
    'original_price': '3.50',
    'final_price': '3.50',
    'currency': 'د.ل',
    'latency_ms': 51,
    'created_at': '2026-06-16T09:30:00Z',
  }),
];
