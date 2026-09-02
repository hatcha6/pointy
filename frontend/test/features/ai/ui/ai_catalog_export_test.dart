// The Dart catalog is the source of truth for what the assistant may draw, but
// the backend needs the same vocabulary to validate `render_ui` payloads and to
// describe the catalog in the system prompt. This test keeps the exported JSON
// contract in step with the code that actually renders.
//
// Regenerate after adding or changing a catalog item:
//   make frontend-export-ai-catalog
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointy_frontend/src/features/ai/ui/ai_catalog_export.dart';

const String _catalogPath = '../shared/ai_ui_catalog/pointy_catalog.json';

void main() {
  test('exported AI UI catalog matches the Dart catalog', () {
    final expected =
        '${const JsonEncoder.withIndent('  ').convert(exportAiCatalog())}\n';
    final file = File(_catalogPath);
    final shouldWrite = Platform.environment['POINTY_WRITE_AI_CATALOG'] == '1';

    if (shouldWrite) {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(expected);
      return;
    }

    expect(
      file.existsSync(),
      isTrue,
      reason: 'Run `make frontend-export-ai-catalog` to create $_catalogPath.',
    );
    expect(
      file.readAsStringSync(),
      expected,
      reason:
          'The catalog changed. Run `make frontend-export-ai-catalog` so the '
          'backend validator and system prompt see the same components.',
    );
  });
}
