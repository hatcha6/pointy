// Dev-only preview harness for the data-migration settings route.
//
// Renders the Data Migration page full-viewport with an in-memory fake
// repository and no backend/auth, so the design can be exercised end to end.
// Pick the surface with `?screen=` and the theme with `?theme=`. Run with:
//
//   flutter run -d web-server --web-port 8080 -t lib/dev/migration_preview.dart
//
// Screens: configured (default) | setup
// Themes:  light (default) | dark
//
// See AGENTS.md ("UI preview harness") for the pattern. Not part of the
// shipping app. Safe to delete.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/migration.dart';
import 'package:pointy_frontend/src/data/repositories/migration_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/migration/view_models/migration_view_model.dart';
import 'package:pointy_frontend/src/features/migration/views/data_migration_page.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';
import 'package:pointy_frontend/src/shared/shell/shell.dart';

void main() => runApp(const _PreviewApp());

class _PreviewApp extends StatelessWidget {
  const _PreviewApp();

  @override
  Widget build(BuildContext context) {
    final dark = _param('theme') == 'dark';
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
      theme: dark ? PointyTheme.dark() : PointyTheme.light(),
      builder: (context, child) => PointyNavigationRailScope(
        isActive: false,
        controller: PointyNavigationRailController(),
        child: child ?? const SizedBox.shrink(),
      ),
      home: DataMigrationPage(
        viewModel: MigrationViewModel(
          _param('screen') == 'setup'
              ? _FakeMigrationRepository.empty()
              : _FakeMigrationRepository.configured(),
        ),
      ),
    );
  }
}

String _param(String key) {
  final uri = Uri.base;
  final direct = uri.queryParameters[key];
  if (direct != null) return direct;
  final fragment = uri.fragment;
  final parsed = Uri.tryParse(
    fragment.startsWith('/') ? fragment.substring(1) : fragment,
  );
  return parsed?.queryParameters[key] ?? '';
}

/// In-memory repository so the harness renders without a backend.
class _FakeMigrationRepository extends MigrationRepository {
  _FakeMigrationRepository(this._sources) : super(PosApiService());

  factory _FakeMigrationRepository.configured() =>
      _FakeMigrationRepository([_seedSource]);

  factory _FakeMigrationRepository.empty() => _FakeMigrationRepository(const []);

  final List<MigrationSource> _sources;

  @override
  Future<Result<MigrationCatalog>> loadCatalog() async {
    await Future<void>.delayed(const Duration(milliseconds: 150));
    return Ok(MigrationCatalog.fromJson(_catalogJson));
  }

  @override
  Future<Result<List<MigrationSource>>> loadSources() async {
    await Future<void>.delayed(const Duration(milliseconds: 150));
    return Ok(_sources);
  }

  @override
  Future<Result<List<DiscoveredServer>>> discoverServers() async {
    await Future<void>.delayed(const Duration(milliseconds: 600));
    return Ok([
      DiscoveredServer.fromJson(const {
        'address': '192.168.1.50',
        'server_name': 'POSPC',
        'instance_name': 'SQLEXPRESS',
        'version': '10.50.1600.1',
        'tcp_port': 1433,
      }),
      DiscoveredServer.fromJson(const {
        'address': '192.168.1.77',
        'server_name': 'BACKOFFICE',
        'instance_name': 'MSSQLSERVER',
        'version': '8.00.760',
        'tcp_port': 1433,
      }),
    ]);
  }

  @override
  Future<Result<MigrationConnectionTest>> testConnection(int id) async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    return Ok(MigrationConnectionTest.fromJson(const {
      'ok': true,
      'table_count': 23,
      'tables': ['Items', 'Groups', 'Customers'],
    }));
  }

  @override
  Future<Result<CompatibilityReport>> checkCompatibility(int id) async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    return Ok(CompatibilityReport.fromJson(_compatJson));
  }
}

const _compatJson = <String, Object?>{
  'compatible': true,
  'detected_version': 'demo-2019',
  'missing_tables': <String>[],
  'missing_columns': <String, Object?>{},
  'supported_entities': ['product', 'customer'],
  'notes': <String>[],
};

final _seedSource = MigrationSource.fromJson(const {
  'id': 1,
  'name': 'نظام نقاط البيع القديم',
  'system_key': 'demo_mssql',
  'transport_kind': 'mssql',
  'host': '192.168.1.50',
  'port': 1433,
  'database_name': 'LegacyPOS',
  'username': 'sa',
  'has_password': true,
  'extra_options': <String, Object?>{},
  'detected_version': 'demo-2019',
  'last_compat_status': 'compatible',
  'last_compat_report': _compatJson,
  'last_run_at': null,
  'credentials_cleared': false,
  'is_archived': false,
});

const _catalogJson = <String, Object?>{
  'systems': [
    {
      'system_key': 'demo_mssql',
      'display_name': 'Demo POS (SQL Server)',
      'required_transport': 'mssql',
      'supported_entities': [
        'unit',
        'category',
        'product',
        'product_unit',
        'stock',
        'customer',
        'supplier',
        'purchase_order',
        'supplier_payment',
        'sale',
        'expense_category',
        'expense',
      ],
      'versions': ['demo-2019'],
      'implemented': true,
    },
    {
      'system_key': 'aboghris_mssql',
      'display_name': 'AboGhris (SQL Server)',
      'required_transport': 'mssql',
      'supported_entities': ['category', 'product', 'stock', 'customer', 'supplier'],
      'versions': ['aboghris-unknown'],
      'implemented': false,
    },
  ],
  'entities': [
    {'entity_type': 'unit', 'label': 'وحدات القياس', 'implemented': true},
    {'entity_type': 'category', 'label': 'الفئات', 'implemented': true},
    {'entity_type': 'product', 'label': 'المنتجات', 'implemented': true},
    {'entity_type': 'stock', 'label': 'المخزون', 'implemented': true},
    {'entity_type': 'customer', 'label': 'العملاء', 'implemented': true},
    {'entity_type': 'supplier', 'label': 'المورّدون', 'implemented': true},
  ],
};
