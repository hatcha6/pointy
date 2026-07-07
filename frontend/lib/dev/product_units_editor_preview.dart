// Dev-only preview harness for the product-form "Units & conversions" editor,
// focused on the per-unit packaging-barcode entry. Safe to delete — never
// imported by lib/main.dart.
//
// Run: flutter run -d web-server --web-port 8080 -t lib/dev/product_units_editor_preview.dart
// (or `make frontend-product-units-editor-preview`). Reload the browser once
// after the server reports "is being served at" so Flutter paints.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:pointy_frontend/l10n/generated/app_localizations.dart';
import 'package:pointy_frontend/src/data/models/product_unit.dart';
import 'package:pointy_frontend/src/data/models/unit_of_measure.dart';
import 'package:pointy_frontend/src/features/catalog/views/product_units_editor.dart';
import 'package:pointy_frontend/src/shared/design/design.dart';

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
      home: const _Home(),
    );
  }
}

const _availableUnits = <UnitOfMeasure>[
  UnitOfMeasure(id: 2, code: 'dozen', name: 'دزينة', abbreviation: 'دزينة'),
  UnitOfMeasure(id: 3, code: 'box', name: 'صندوق', abbreviation: 'صندوق'),
  UnitOfMeasure(id: 4, code: 'carton', name: 'كرتون', abbreviation: 'كرتون'),
];

class _Home extends StatefulWidget {
  const _Home();

  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> {
  List<ProductUnit> _units = const [
    ProductUnit(
      unit: UnitOfMeasure(
        id: 3,
        code: 'box',
        name: 'صندوق',
        abbreviation: 'صندوق',
      ),
      factorToBase: 12,
      barcodes: ['6001002003001'],
    ),
    ProductUnit(
      unit: UnitOfMeasure(
        id: 4,
        code: 'carton',
        name: 'كرتون',
        abbreviation: 'كرتون',
      ),
      factorToBase: 144,
    ),
  ];
  String _defaultSaleUnit = 'box';
  String _defaultPurchaseUnit = 'carton';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('محرر وحدات المنتج — الباركود')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ProductUnitsEditor(
            availableUnits: _availableUnits,
            baseUnitCode: 'piece',
            units: _units,
            defaultSaleUnit: _defaultSaleUnit,
            defaultPurchaseUnit: _defaultPurchaseUnit,
            onUnitsChanged: (units) => setState(() => _units = units),
            onDefaultSaleChanged: (value) =>
                setState(() => _defaultSaleUnit = value),
            onDefaultPurchaseChanged: (value) =>
                setState(() => _defaultPurchaseUnit = value),
          ),
        ),
      ),
    );
  }
}
