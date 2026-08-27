// Benchmark: how long the client spends turning a catalog-search response into
// `Product` models. Points at a real payload via the CATALOG_PAYLOAD env var:
//
//   CATALOG_PAYLOAD=/path/to/payload.json flutter test \
//     test/benchmarks/catalog_parse_benchmark_test.dart
//
// Reports raw jsonDecode time vs. the full `ProductPage.fromJson` model build
// (the extra cost is the object graph — inflated today by each variant carrying
// a full `product_detail` copy of its parent product).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/data/models/product_page.dart';

void main() {
  test('catalog payload parse benchmark', () {
    final path = Platform.environment['CATALOG_PAYLOAD'];
    if (path == null || !File(path).existsSync()) {
      // ignore: avoid_print
      print(
        'SKIP: set CATALOG_PAYLOAD to a payload JSON file to run this benchmark.',
      );
      return;
    }
    final raw = File(path).readAsStringSync();
    const iterations = 25;

    for (var i = 0; i < 3; i++) {
      ProductPage.fromJson(jsonDecode(raw) as Map<String, Object?>);
    }

    final swDecode = Stopwatch()..start();
    for (var i = 0; i < iterations; i++) {
      jsonDecode(raw);
    }
    swDecode.stop();

    final swParse = Stopwatch()..start();
    late ProductPage page;
    for (var i = 0; i < iterations; i++) {
      page = ProductPage.fromJson(jsonDecode(raw) as Map<String, Object?>);
    }
    swParse.stop();

    final variants = page.products.fold<int>(
      0,
      (sum, p) => sum + p.variants.length,
    );
    final decodeMs = swDecode.elapsedMicroseconds / iterations / 1000;
    final parseMs = swParse.elapsedMicroseconds / iterations / 1000;

    // ignore: avoid_print
    print(
      'PARSE  ${(raw.length / 1024).toStringAsFixed(0)}KB  '
      'products=${page.products.length} variants=$variants  |  '
      'jsonDecode=${decodeMs.toStringAsFixed(1)}ms  '
      'fromJson(total)=${parseMs.toStringAsFixed(1)}ms  '
      'modelBuild=${(parseMs - decodeMs).toStringAsFixed(1)}ms',
    );
    expect(page.products, isNotEmpty);
  });
}
