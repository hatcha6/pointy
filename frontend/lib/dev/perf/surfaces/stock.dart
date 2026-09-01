// Dev-only sweep script: stock group — catalog, categories, purchasing,
// stock counts.
import 'common.dart';

List<SweepSurface> stockSurfaces() => [
  screen('catalog'),
  screen('categories'),
  screen('purchase_orders'),
  screen('stock_counts'),
];
