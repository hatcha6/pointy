// Dev-only sweep script: stock group — catalog, categories, purchasing,
// stock counts.
import 'package:flutter/material.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/shared/query_controls/debounced_search_field.dart';

import 'common.dart';

/// The product search on a catalog-style screen. Both the catalog and the
/// purchase draft reach it through the same shared field.
Finder _productSearch() => find.byType(DebouncedSearchField);

List<SweepSurface> stockSurfaces() => [
  // The catalog and the purchase draft are the two screens the back office
  // lives on, and the 2026-09-16 field export has both raster-bound there:
  // 35% and 41% of their frames dropped, against 0.9% on the till's POS.
  // Both are measured while *typing* into the product search, which is what
  // the buyer actually does — 3,601 keystrokes on the purchase draft in six
  // days, more than any other interaction on it.
  screen(
    'catalog',
    extras: (d) async {
      await d.typeSearch(_productSearch().first, 'حليب');
    },
  ),
  screen('categories'),
  screen('purchase_orders'),
  // Reached from the purchases list's "new order" button, not the drawer.
  SweepSurface('purchase_create', (d) async {
    await d.dismissOverlays();
    await d.measureSurface(
      'purchase_create',
      reach: () async {
        await d.navigate(destinationLabels['purchase_orders']!);
        await d.settle();
        await d.tap(
          find.byType(FloatingActionButton),
          what: 'new purchase order',
        );
      },
      extras: () async {
        await d.typeSearch(_productSearch().first, 'حليب');
      },
    );
    // Leave the editor so the surfaces after this one start from the shell.
    await d.closeTop(phaseName: 'close:purchase_create');
  }),
  screen('stock_counts'),
];
