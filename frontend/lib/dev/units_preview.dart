// Dev-only preview harness for the units-of-measure management screen.
// Safe to delete — never imported by lib/main.dart.
//
// Run: flutter run -d web-server --web-port 8080 -t lib/dev/units_preview.dart
// (or `make frontend-units-preview`). Reload the browser once after the server
// reports "is being served at" so Flutter paints.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/core/result.dart';
import 'package:pointy_frontend/src/data/models/unit_of_measure.dart';
import 'package:pointy_frontend/src/data/repositories/catalog_repository.dart';
import 'package:pointy_frontend/src/data/services/pos_api_service.dart';
import 'package:pointy_frontend/src/features/catalog/view_models/units_management_view_model.dart';
import 'package:pointy_frontend/src/features/catalog/views/units_management_screen.dart';
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
      home: _Home(showEditor: Uri.base.queryParameters['screen'] == 'editor'),
    );
  }
}

class _Home extends StatefulWidget {
  const _Home({required this.showEditor});

  final bool showEditor;

  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> {
  @override
  void initState() {
    super.initState();
    if (widget.showEditor) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        showUnitEditorDialog(context);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return UnitsManagementScreen(
      viewModel: UnitsManagementViewModel(_FakeCatalogRepository()),
    );
  }
}

class _FakeCatalogRepository extends CatalogRepository {
  _FakeCatalogRepository() : super(PosApiService());

  final List<UnitOfMeasure> _units = [
    const UnitOfMeasure(
      id: 1,
      code: 'piece',
      name: 'قطعة',
      abbreviation: 'قطعة',
      dimension: 'count',
      referenceFactor: 1,
      isSystem: true,
    ),
    const UnitOfMeasure(
      id: 2,
      code: 'dozen',
      name: 'دزينة',
      abbreviation: 'دزينة',
      dimension: 'count',
      referenceFactor: 12,
      isSystem: true,
    ),
    const UnitOfMeasure(
      id: 3,
      code: 'box',
      name: 'صندوق',
      abbreviation: 'صندوق',
      dimension: 'count',
      productCount: 5,
    ),
    const UnitOfMeasure(
      id: 4,
      code: 'carton',
      name: 'كرتون',
      abbreviation: 'كرتون',
      dimension: 'count',
      isActive: false,
    ),
    const UnitOfMeasure(
      id: 5,
      code: 'kg',
      name: 'كيلوغرام',
      abbreviation: 'كجم',
      dimension: 'weight',
      referenceFactor: 1,
      allowsFractional: true,
      isSystem: true,
      productCount: 3,
    ),
    const UnitOfMeasure(
      id: 6,
      code: 'g',
      name: 'غرام',
      abbreviation: 'جم',
      dimension: 'weight',
      referenceFactor: 0.001,
      allowsFractional: true,
      isSystem: true,
    ),
    const UnitOfMeasure(
      id: 7,
      code: 'l',
      name: 'لتر',
      abbreviation: 'لتر',
      dimension: 'volume',
      referenceFactor: 1,
      allowsFractional: true,
      isSystem: true,
    ),
  ];

  @override
  Future<Result<List<UnitOfMeasure>>> loadAllUnits({
    bool activeOnly = true,
  }) async {
    return Ok(List<UnitOfMeasure>.of(_units));
  }

  @override
  Future<Result<UnitOfMeasure>> createUnit(UnitOfMeasureDraft draft) async {
    final created = UnitOfMeasure(
      id: _units.length + 1,
      code: draft.code,
      name: draft.name,
      abbreviation: draft.abbreviation,
      dimension: draft.dimension,
      referenceFactor: draft.referenceFactor,
      allowsFractional: draft.allowsFractional,
      isActive: draft.isActive,
    );
    _units.add(created);
    return Ok(created);
  }

  @override
  Future<Result<UnitOfMeasure>> updateUnit({
    required int id,
    required UnitOfMeasureDraft draft,
  }) async {
    final index = _units.indexWhere((unit) => unit.id == id);
    if (index != -1) {
      final existing = _units[index];
      _units[index] = UnitOfMeasure(
        id: existing.id,
        code: draft.includeCode ? draft.code : existing.code,
        name: draft.name,
        abbreviation: draft.abbreviation,
        dimension: draft.dimension,
        referenceFactor: draft.referenceFactor,
        allowsFractional: draft.allowsFractional,
        isSystem: existing.isSystem,
        isActive: draft.isActive,
        productCount: existing.productCount,
      );
    }
    return Ok(_units[index == -1 ? 0 : index]);
  }

  @override
  Future<Result<void>> deleteUnit(int id) async {
    _units.removeWhere((unit) => unit.id == id);
    return const Ok(null);
  }
}
